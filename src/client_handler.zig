const std = @import("std");
const net = std.net;
const Thread = std.Thread;

const protocol = @import("protocol.zig");
const file_manager = @import("file_manager.zig");
const Config = @import("config.zig").Config;
const FileWatcher = @import("file_watcher.zig").FileWatcher;

const log = std.log.scoped(.rmate_client);

const FileWatcherContext = struct {
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    base_dir: []const u8,
    token: []const u8,
    temp_path: []const u8,
};

pub fn handleClientWrapper(config: *const Config, allocator: std.mem.Allocator, stream: net.Stream) void {
    handleClient(config, allocator, stream) catch |err| {
        log.err("Client handler error: {}", .{err});
    };
}

pub fn handleClient(config: *const Config, allocator: std.mem.Allocator, stream: net.Stream) !void {
    defer stream.close();

    log.debug("handleClient: Starting client handler", .{});

    var wait_group: std.Thread.WaitGroup = .{};

    const reader = stream.reader().any();
    const commands = try protocol.parseCommands(allocator, reader);
    defer commands.deinit();
    log.debug("handleClient: Read {} commands", .{commands.items.len});

    // Process commands
    for (commands.items, 0..) |cmd, i| {
        log.debug("handleClient: Processing open command {} of {} for file: {s}", .{ i + 1, commands.items.len, cmd.display_name });
        try handleOpenCommand(allocator, stream.writer().any(), config, cmd, &wait_group);
    }

    log.debug("handleClient: All commands processed, waiting for files to close", .{});
    wait_group.wait();

    log.debug("handleClient: All files closed, client handler exiting", .{});
}

pub fn handleOpenCommand(allocator: std.mem.Allocator, writer: std.io.AnyWriter, config: *const Config, cmd: protocol.OpenCommand, wait_group: *Thread.WaitGroup) !void {
    log.info("Opening file: {s}", .{cmd.display_name});

    // Extract hostname from display_name (format: hostname:...)
    // Always mirror the actual remote path from real_path
    var hostname: []const u8 = "localhost";
    const remote_path = cmd.real_path;

    if (std.mem.indexOf(u8, cmd.display_name, ":")) |colon_idx| {
        hostname = cmd.display_name[0..colon_idx];
    }

    const temp_path = try file_manager.createTempFile(allocator, config.base_dir, hostname, remote_path);
    errdefer allocator.free(temp_path);

    // Write initial content to temp file
    const write_data: []const u8 = if (cmd.data) |d| d else "";
    file_manager.writeTempFile(temp_path, write_data) catch |err| switch (err) {
        error.PathAlreadyExists => {
            log.warn("Another session already created temp file, closing token immediately. Path: {s}", .{temp_path});
            protocol.writeCloseCommand(writer, cmd.token) catch |write_err| {
                log.err("Failed to send close command: {}", .{write_err});
            };
            // Free allocated temp_path since we won't track a session for it
            allocator.free(temp_path);
            return;
        },
        else => return err,
    };

    var watcher: ?*FileWatcher = null;
    var watcher_ctx: ?*FileWatcherContext = null;

    // Start file watcher if data_on_save is true
    if (cmd.data_on_save) {
        watcher_ctx = try allocator.create(FileWatcherContext);
        errdefer allocator.destroy(watcher_ctx.?);
        watcher_ctx.?.* = .{ .allocator = allocator, .writer = writer, .base_dir = config.base_dir, .token = cmd.token, .temp_path = temp_path };

        watcher = try allocator.create(FileWatcher);
        errdefer allocator.destroy(watcher.?);
        watcher.?.* = try FileWatcher.init(allocator, temp_path, fileChangedCallback, watcher_ctx.?);
        try watcher.?.start();
        errdefer watcher.?.deinit();
    }

    // Spawn editor in a separate thread and track lifecycle with wait group
    const editor_cmd = config.getEditor(hostname, remote_path);
    wait_group.start();
    const thread = Thread.spawn(.{}, editorThread, .{ allocator, writer, config.base_dir, editor_cmd, temp_path, cmd.token, watcher, watcher_ctx, wait_group }) catch |err| {
        wait_group.finish();
        return err;
    };
    thread.detach();
}

fn fileChangedCallback(ctx: *anyopaque, path: []const u8) void {
    const watcher_ctx = @as(*FileWatcherContext, @ptrCast(@alignCast(ctx)));

    log.info("File changed: {s}", .{path});
    log.debug("fileChangedCallback: Reading file at path: {s}", .{watcher_ctx.temp_path});

    // Read the file contents
    const contents = file_manager.readTempFile(watcher_ctx.allocator, watcher_ctx.temp_path) catch |err| {
        log.err("Failed to read changed file: {}", .{err});
        return;
    };
    defer watcher_ctx.allocator.free(contents);

    log.debug("fileChangedCallback: Read {} bytes from file", .{contents.len});
    log.debug("fileChangedCallback: Sending save command for token: {s}", .{watcher_ctx.token});

    // Send save command to client
    protocol.writeSaveCommand(watcher_ctx.writer, watcher_ctx.token, contents) catch |err| {
        log.err("Failed to send save command: {}", .{err});
        return;
    };

    log.debug("fileChangedCallback: Save command sent successfully", .{});
}

fn editorThread(allocator: std.mem.Allocator, writer: std.io.AnyWriter, base_dir: []const u8, editor_cmd: []const u8, temp_path: []const u8, token: []const u8, watcher: ?*FileWatcher, watcher_ctx: ?*FileWatcherContext, wait_group: *Thread.WaitGroup) !void {
    // Spawn editor and wait for it to close
    file_manager.spawnEditorBlocking(allocator, editor_cmd, temp_path) catch |err| {
        log.err("Failed to spawn editor: {}", .{err});
    };

    // Stop watcher first to prevent any further save events before we notify close
    // Stop and cleanup watcher (joins background thread)
    if (watcher) |w| {
        w.deinit();
        allocator.destroy(w);
    }

    // Cleanup watcher context now that watcher is stopped
    if (watcher_ctx) |wc| {
        allocator.destroy(wc);
    }

    // Now that watcher is stopped, send close command to client
    protocol.writeCloseCommand(writer, token) catch |err| {
        log.err("Failed to send close command: {}", .{err});
    };

    // Cleanup temp file and any empty parent directories
    file_manager.cleanupTempPath(base_dir, temp_path);
    allocator.free(temp_path);

    log.info("Editor closed for file: {s}", .{token});
    // Signal completion to wait group last
    wait_group.finish();
}

// Unit tests
const testing = std.testing;

// Helper function to create a test configuration
fn createTestConfig(allocator: std.mem.Allocator) !@import("config.zig").Config {
    const editor = try allocator.dupe(u8, "test_editor");
    const ip = try allocator.dupe(u8, "127.0.0.1");

    return @import("config.zig").Config{
        .allocator = allocator,
        .default_editor = editor,
        .port = 52698,
        .ip = ip,
        .socket_path = null,
        .base_dir = "/tmp", // tests that don't use base_dir won't free it
    };
}

// Helper function to create a test config
fn createConfigForTest(allocator: std.mem.Allocator) !Config {
    return try createTestConfig(allocator);
}

test "handleClientWrapper should catch and log errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try createConfigForTest(allocator);

    // Create a test stream using a pipe
    const fds = try std.posix.pipe();

    // Close the write end to simulate an error when trying to read
    std.posix.close(fds[1]);

    const test_stream = net.Stream{ .handle = fds[0] };

    // This should not panic, but should log an error
    // handleClient will close the stream, so no need to defer close
    handleClientWrapper(&config, allocator, test_stream);

    // If we reach here, the wrapper successfully caught the error
    try testing.expect(true);
}

test "handleClient should handle unexpected save command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try createConfigForTest(allocator);

    // Create test data with unexpected save command
    const test_protocol_data =
        "save\n" ++
        "token: test_token_123\n" ++
        "data: 4\n" ++
        "test\n" ++
        "\n" ++
        ".\n";

    // Create a test stream using a pipe
    const fds = try std.posix.pipe();

    // Write test data to the pipe
    _ = try std.posix.write(fds[1], test_protocol_data);
    std.posix.close(fds[1]); // Close write end

    const test_stream = net.Stream{ .handle = fds[0] };

    // This should handle the unexpected save command and log a warning
    // handleClient will close the stream
    try handleClient(&config, allocator, test_stream);
}

test "handleClient should handle unexpected close command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try createConfigForTest(allocator);

    // Create test data with unexpected close command
    const test_protocol_data =
        "close\n" ++
        "token: test_token_123\n" ++
        "\n" ++
        ".\n";

    // Create a test stream using a pipe
    const fds = try std.posix.pipe();

    // Write test data to the pipe
    _ = try std.posix.write(fds[1], test_protocol_data);
    std.posix.close(fds[1]); // Close write end

    const test_stream = net.Stream{ .handle = fds[0] };

    // This should handle the unexpected close command and log a warning
    // handleClient will close the stream
    try handleClient(&config, allocator, test_stream);
}

test "handleClient should handle empty command stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try createConfigForTest(allocator);

    // Create test data with just the end marker
    const test_protocol_data = ".\n";

    // Create a test stream using a pipe
    const fds = try std.posix.pipe();

    // Write test data to the pipe
    _ = try std.posix.write(fds[1], test_protocol_data);
    std.posix.close(fds[1]); // Close write end

    const test_stream = net.Stream{ .handle = fds[0] };

    // This should handle empty command stream gracefully
    // handleClient will close the stream
    try handleClient(&config, allocator, test_stream);
}

// Unit test: duplicate open triggers immediate close
test "handleOpenCommand closes duplicate opens by sending close command" {
    const allocator = testing.allocator;
    const posix = std.posix;

    // Set up a temporary base directory for FileManager
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(allocator, "{s}/rmate-test", .{tmp_root});
    defer allocator.free(base_under_tmp);

    const base_dir = try file_manager.initBaseDir(allocator, base_under_tmp);
    defer allocator.free(base_dir);

    // Pre-create the temp file to force PathAlreadyExists on write
    const host = "testhost";
    const real_path = "/dup/file.txt";
    const temp_path = try file_manager.createTempFile(allocator, base_dir, host, real_path);
    defer allocator.free(temp_path);
    try file_manager.writeTempFile(temp_path, "first");

    // Create a pipe to capture protocol output
    var fds: [2]posix.fd_t = undefined;
    try posix.pipe(&fds);
    defer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }

    // Build a Config and writer with the write end of the pipe
    var cfg = @import("config.zig").Config{
        .allocator = allocator,
        .default_editor = "true",
        .socket_path = null,
        .port = null,
        .ip = null,
        .base_dir = base_dir,
    };
    const stream = net.Stream{ .handle = @as(posix.socket_t, @intCast(fds[1])) };
    const writer = stream.writer().any();

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
    var wg: Thread.WaitGroup = .{};
    try handleOpenCommand(allocator, writer, &cfg, open_cmd, &wg);
    wg.wait();

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
    file_manager.cleanupTempPath(base_dir, temp_path);
}
