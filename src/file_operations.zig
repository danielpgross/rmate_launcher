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

    // Determine initial content and write once with shared error handling
    const write_data: []const u8 = if (cmd.data) |d| d else "";
    fm.writeTempFile(temp_path, write_data) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Another session already created this temp file; close this token immediately
            log.warn("Another session already created temp file, closing token immediately. Path: {s}", .{temp_path});
            const writer = client_session.stream.writer().any();
            var proto_writer = protocol.ProtocolWriter.init(writer);
            proto_writer.writeCloseCommand(cmd.token) catch |write_err| {
                log.err("Failed to send close command: {}", .{write_err});
            };
            // Free allocated temp_path since we won't track a session for it
            fm.allocator.free(temp_path);
            return;
        },
        else => return err,
    };

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

// Unit test: duplicate open triggers immediate close
test "handleOpenCommand closes duplicate opens by sending close command" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const posix = std.posix;
    const net = std.net;

    // Set up a temporary base directory for FileManager
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(allocator, "{s}/rmate-test", .{tmp_root});
    defer allocator.free(base_under_tmp);

    var fm = try file_manager.FileManager.init(allocator, base_under_tmp);
    defer fm.deinit();

    // Pre-create the temp file to force PathAlreadyExists on write
    const host = "testhost";
    const real_path = "/dup/file.txt";
    const temp_path = try fm.createTempFile(host, real_path);
    defer allocator.free(temp_path);
    try fm.writeTempFile(temp_path, "first");

    // Create a pipe to capture protocol output
    var fds: [2]posix.fd_t = undefined;
    try posix.pipe(&fds);
    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    // Build a ClientSession with the write end of the pipe
    var cfg = @import("config.zig").Config{
        .default_editor = "true",
        .socket_path = null,
        .port = null,
        .ip = null,
    };
    const stream = net.Stream{ .handle = @as(posix.socket_t, @intCast(fds[1])) };
    const client = session.ClientSession.init(stream, allocator, &cfg);
    defer client.deinit();

    // Prepare an open command for the same file/path
    const open_cmd = protocol.OpenCommand{
        .display_name = try allocator.dupe(u8, "testhost:/dup/file.txt"),
        .real_path = try allocator.dupe(u8, real_path),
        .data_on_save = false,
        .re_activate = false,
        .token = try allocator.dupe(u8, "tok"),
        .selection = null,
        .file_type = null,
        .data = null,
    };
    defer {
        allocator.free(open_cmd.display_name);
        allocator.free(open_cmd.real_path);
        allocator.free(open_cmd.token);
    }

    // Act: this should detect existing file and send a close command
    try handleOpenCommand(&client, &fm, open_cmd);

    // Close writer to finish the pipe
    posix.close(fds[1]);

    // Read from the pipe
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var buf: [256]u8 = undefined;
    while (true) {
        const n = posix.read(fds[0], &buf) catch |err| switch (err) {
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
        if (n < buf.len) break;
    }

    // Expect a close command for the token
    try testing.expectEqualStrings("close\ntoken: tok\n\n", out.items);

    // Cleanup the pre-created temp file and directories
    fm.cleanupTempPath(temp_path);
}
