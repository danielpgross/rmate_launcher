const std = @import("std");
const Thread = std.Thread;

const protocol = @import("protocol.zig");
const file_manager = @import("file_manager.zig");
const FileWatcher = @import("file_watcher.zig").FileWatcher;
const session = @import("session.zig");

const log = std.log.scoped(.rmate_file_ops);

pub fn handleOpenCommand(client_session: *session.ClientSession, fm: *file_manager.FileManager, cmd: protocol.OpenCommand) !void {
    log.info("Opening file: {s}", .{cmd.display_name});

    // Extract hostname from display_name (format: hostname:...)
    // Always mirror the actual remote path from real_path
    var hostname: []const u8 = "localhost";
    const remote_path = cmd.real_path;

    if (std.mem.indexOf(u8, cmd.display_name, ":")) |colon_idx| {
        hostname = cmd.display_name[0..colon_idx];
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
    var file_session = session.FileSession{
        .token = cmd.token,
        .display_name = cmd.display_name,
        .real_path = cmd.real_path,
        .temp_path = temp_path,
        .data_on_save = cmd.data_on_save,
        .watcher = null,
        .watcher_context = null,
        .allocator = client_session.allocator,
    };

    // Start file watcher if data_on_save is true
    if (cmd.data_on_save) {
        const watcher_ctx = try client_session.allocator.create(session.WatcherContext);
        watcher_ctx.* = .{
            .session = client_session,
            .fm = fm,
            .token = file_session.token,
            .temp_path = file_session.temp_path,
            .mutex = std.Thread.Mutex{},
        };

        const watcher = try client_session.allocator.create(FileWatcher);
        watcher.* = try FileWatcher.init(client_session.allocator, temp_path, fileChangedCallback, watcher_ctx);
        try watcher.start();

        file_session.watcher = watcher;
        file_session.watcher_context = watcher_ctx;
    }

    try client_session.files.append(file_session);

    // Get editor command
    const editor_cmd = client_session.config.getEditor(hostname, remote_path);

    // Spawn editor in a separate thread
    const editor_ctx = try client_session.allocator.create(session.EditorContext);
    editor_ctx.* = .{
        .session = client_session,
        .fm = fm,
        .editor_cmd = editor_cmd,
        .temp_path = temp_path,
        .token = cmd.token,
    };

    const thread = try Thread.spawn(.{}, editorThread, .{editor_ctx});
    thread.detach();
}

pub fn fileChangedCallback(ctx: *anyopaque, path: []const u8) void {
    const watcher_ctx = @as(*session.WatcherContext, @ptrCast(@alignCast(ctx)));

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

fn editorThread(ctx: *session.EditorContext) !void {
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

    // Stop and cleanup resources BEFORE removing the session entry to avoid races
    var i: usize = 0;
    while (i < ctx.session.files.items.len) {
        if (std.mem.eql(u8, ctx.session.files.items[i].token, ctx.token)) {
            // Grab needed resources while the entry still exists
            const temp_path = ctx.session.files.items[i].temp_path;
            const watcher_ptr = ctx.session.files.items[i].watcher;
            const watcher_ctx_ptr = ctx.session.files.items[i].watcher_context;

            // Stop and cleanup watcher (joins background thread)
            if (watcher_ptr) |watcher| {
                watcher.deinit();
                ctx.session.allocator.destroy(watcher);
                ctx.session.files.items[i].watcher = null;
            }

            // Cleanup watcher context
            if (watcher_ctx_ptr) |watcher_ctx| {
                ctx.session.allocator.destroy(watcher_ctx);
                ctx.session.files.items[i].watcher_context = null;
            }

            // Cleanup temp file and any empty parent directories
            ctx.fm.cleanupTempPath(temp_path);

            // Now remove the file session entry
            _ = ctx.session.files.orderedRemove(i);
            break;
        }
        i += 1;
    }

    log.info("Editor closed for file: {s}", .{ctx.token});
}
