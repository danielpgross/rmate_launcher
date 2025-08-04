const std = @import("std");
const net = std.net;
const fs = std.fs;
const Thread = std.Thread;

const protocol = @import("protocol.zig");
const file_manager = @import("file_manager.zig");
const FileWatcher = @import("file_watcher.zig").FileWatcher;

const log = std.log.scoped(.rmate_server);

// Configuration - can be extended later with pattern matching
const Config = struct {
    default_editor: []const u8,

    pub fn init() Config {
        // For now, just use environment variable or default
        const editor = std.process.getEnvVarOwned(std.heap.page_allocator, "RMATE_EDITOR") catch null orelse "code --wait";
        return .{
            .default_editor = editor,
        };
    }

    // Future: Add getEditorForFile(hostname, filepath) method for pattern matching
    pub fn getEditor(self: *const Config, hostname: []const u8, filepath: []const u8) []const u8 {
        _ = hostname;
        _ = filepath;
        return self.default_editor;
    }
};

// Session management
const SessionManager = struct {
    sessions: std.ArrayList(*ClientSession),
    mutex: Thread.Mutex,
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .sessions = std.ArrayList(*ClientSession).init(allocator),
            .mutex = Thread.Mutex{},
            .allocator = allocator,
            .config = Config.init(),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.sessions.deinit();
    }
};

const ClientSession = struct {
    stream: net.Stream,
    files: std.ArrayList(FileSession),
    allocator: std.mem.Allocator,
    config: *const Config,

    pub fn init(stream: net.Stream, allocator: std.mem.Allocator, config: *const Config) ClientSession {
        return .{
            .stream = stream,
            .files = std.ArrayList(FileSession).init(allocator),
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *ClientSession) void {
        self.files.deinit();
    }
};

const FileSession = struct {
    token: []u8,
    display_name: []u8,
    real_path: []u8,
    temp_path: []u8,
    data_on_save: bool,
    watcher: ?*FileWatcher,
    watcher_context: ?*WatcherContext,
    allocator: std.mem.Allocator,
};

fn handleClientWrapper(session_manager: *SessionManager, stream: net.Stream) void {
    handleClient(session_manager, stream) catch |err| {
        log.err("Client handler error: {}", .{err});
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var session_manager = SessionManager.init(allocator);
    defer session_manager.deinit();

    // Setup TCP server
    const address = try net.Address.parseIp("127.0.0.1", 52698);
    var listener = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 128,
    });
    defer listener.deinit();

    log.info("RMate server listening on port 52698", .{});

    // Accept loop
    while (true) {
        if (listener.accept()) |connection| {
            log.info("Client connected from {}", .{connection.address});

            // Send greeting
            try connection.stream.writeAll("RMate Server 1.0\n");

            // Spawn thread to handle client
            const thread = Thread.spawn(.{}, handleClientWrapper, .{
                &session_manager,
                connection.stream,
            }) catch |err| {
                log.err("Failed to spawn client handler thread: {}", .{err});
                connection.stream.close();
                continue;
            };
            thread.detach();
        } else |err| {
            log.err("Failed to accept connection: {}", .{err});
        }
    }
}

fn handleClient(session_manager: *SessionManager, stream: net.Stream) !void {
    defer stream.close();

    log.debug("handleClient: Starting client handler", .{});

    var arena = std.heap.ArenaAllocator.init(session_manager.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var session = ClientSession.init(stream, allocator, &session_manager.config);
    defer session.deinit();

    log.debug("handleClient: Session initialized", .{});

    // Create file manager
    var fm = try file_manager.FileManager.init(allocator);
    defer fm.deinit();

    log.debug("handleClient: File manager initialized", .{});

    // Create protocol parser
    const reader = stream.reader().any();
    var parser = protocol.ProtocolParser.init(allocator, reader);

    log.debug("handleClient: Protocol parser initialized, reading commands...", .{});

    // Read commands
    const commands = try parser.readCommands();
    defer commands.deinit();

    log.debug("handleClient: Read {} commands", .{commands.items.len});

    // Process commands
    for (commands.items, 0..) |cmd, i| {
        log.debug("handleClient: Processing command {} of {}", .{ i + 1, commands.items.len });
        switch (cmd) {
            .open => |open_cmd| {
                log.debug("handleClient: Processing open command for file: {s}", .{open_cmd.display_name});
                try handleOpenCommand(&session, &fm, open_cmd);
            },
            .save => |save_cmd| {
                log.warn("Received save command from client (unexpected): {s}", .{save_cmd.token});
            },
            .close => |close_cmd| {
                log.warn("Received close command from client (unexpected): {s}", .{close_cmd.token});
            },
        }
    }

    log.debug("handleClient: All commands processed, waiting for files to close", .{});

    // Wait for all files to be closed
    while (session.files.items.len > 0) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    log.debug("handleClient: All files closed, client handler exiting", .{});
}

fn handleOpenCommand(session: *ClientSession, fm: *file_manager.FileManager, cmd: protocol.OpenCommand) !void {
    log.info("Opening file: {s}", .{cmd.display_name});

    // Extract hostname from display_name (format: hostname:path)
    var hostname: []const u8 = "localhost";
    var remote_path = cmd.real_path;

    if (std.mem.indexOf(u8, cmd.display_name, ":")) |colon_idx| {
        hostname = cmd.display_name[0..colon_idx];
        if (colon_idx + 1 < cmd.display_name.len) {
            remote_path = cmd.display_name[colon_idx + 1 ..];
        }
    }

    // Create temp file
    const temp_path = try fm.createTempFile(hostname, remote_path);

    // Write initial content if provided
    if (cmd.data) |data| {
        try fm.writeTempFile(temp_path, data);
    } else {
        // Create empty file
        try fm.writeTempFile(temp_path, "");
    }

    // Create file session
    var file_session = FileSession{
        .token = cmd.token,
        .display_name = cmd.display_name,
        .real_path = cmd.real_path,
        .temp_path = temp_path,
        .data_on_save = cmd.data_on_save,
        .watcher = null,
        .watcher_context = null,
        .allocator = session.allocator,
    };

    // Start file watcher if data_on_save is true
    if (cmd.data_on_save) {
        const watcher_ctx = try session.allocator.create(WatcherContext);
        watcher_ctx.* = .{
            .session = session,
            .fm = fm,
            .token = file_session.token,
            .temp_path = file_session.temp_path,
            .mutex = std.Thread.Mutex{},
        };

        const watcher = try session.allocator.create(FileWatcher);
        watcher.* = try FileWatcher.init(session.allocator, temp_path, fileChangedCallback, watcher_ctx);
        try watcher.start();

        file_session.watcher = watcher;
        file_session.watcher_context = watcher_ctx;
    }

    try session.files.append(file_session);

    // Get editor command
    const editor_cmd = session.config.getEditor(hostname, remote_path);

    // Spawn editor in a separate thread
    const editor_ctx = try session.allocator.create(EditorContext);
    editor_ctx.* = .{
        .session = session,
        .fm = fm,
        .editor_cmd = editor_cmd,
        .temp_path = temp_path,
        .token = cmd.token,
    };

    const thread = try Thread.spawn(.{}, editorThread, .{editor_ctx});
    thread.detach();
}

const WatcherContext = struct {
    session: *ClientSession,
    fm: *file_manager.FileManager,
    token: []const u8,
    temp_path: []const u8,
    mutex: std.Thread.Mutex,
};

const EditorContext = struct {
    session: *ClientSession,
    fm: *file_manager.FileManager,
    editor_cmd: []const u8,
    temp_path: []const u8,
    token: []const u8,
};

fn fileChangedCallback(ctx: *anyopaque, path: []const u8) void {
    const watcher_ctx = @as(*WatcherContext, @ptrCast(@alignCast(ctx)));

    log.info("File changed: {s}", .{path});
    log.debug("fileChangedCallback: Reading file at path: {s}", .{watcher_ctx.temp_path});

    // Lock to ensure thread safety
    watcher_ctx.mutex.lock();
    defer watcher_ctx.mutex.unlock();

    // Read the file contents
    const contents = watcher_ctx.fm.readTempFile(watcher_ctx.temp_path) catch |err| {
        log.err("Failed to read changed file: {}", .{err});
        return;
    };
    defer watcher_ctx.session.allocator.free(contents);

    log.debug("fileChangedCallback: Read {} bytes from file", .{contents.len});
    log.debug("fileChangedCallback: Sending save command for token: {s}", .{watcher_ctx.token});

    // Send save command to client
    const writer = watcher_ctx.session.stream.writer().any();
    var proto_writer = protocol.ProtocolWriter.init(writer);
    proto_writer.writeSaveCommand(watcher_ctx.token, contents) catch |err| {
        log.err("Failed to send save command: {}", .{err});
        return;
    };

    log.debug("fileChangedCallback: Save command sent successfully", .{});
}

fn editorThread(ctx: *EditorContext) !void {
    defer ctx.session.allocator.destroy(ctx);

    // Create editor spawner
    var spawner = file_manager.EditorSpawner.init(ctx.session.allocator);

    // Spawn editor and wait for it to close
    spawner.spawnEditorBlocking(ctx.editor_cmd, ctx.temp_path) catch |err| {
        log.err("Failed to spawn editor: {}", .{err});
    };

    // Send close command to client
    const writer = ctx.session.stream.writer().any();
    var proto_writer = protocol.ProtocolWriter.init(writer);
    proto_writer.writeCloseCommand(ctx.token) catch |err| {
        log.err("Failed to send close command: {}", .{err});
    };

    // Remove file session
    var i: usize = 0;
    while (i < ctx.session.files.items.len) {
        if (std.mem.eql(u8, ctx.session.files.items[i].token, ctx.token)) {
            const file_session = ctx.session.files.orderedRemove(i);

            // Stop and cleanup watcher
            if (file_session.watcher) |watcher| {
                watcher.deinit();
                ctx.session.allocator.destroy(watcher);
            }

            // Cleanup watcher context
            if (file_session.watcher_context) |watcher_ctx| {
                ctx.session.allocator.destroy(watcher_ctx);
            }

            break;
        }
        i += 1;
    }

    log.info("Editor closed for file: {s}", .{ctx.token});
}
