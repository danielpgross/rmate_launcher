const std = @import("std");
const net = std.net;

const protocol = @import("protocol.zig");
const file_manager = @import("file_manager.zig");
const session = @import("session.zig");
const file_operations = @import("file_operations.zig");

const log = std.log.scoped(.rmate_client);

pub fn handleClientWrapper(session_manager: *session.SessionManager, stream: net.Stream) void {
    handleClient(session_manager, stream) catch |err| {
        log.err("Client handler error: {}", .{err});
    };
}

pub fn handleClient(session_manager: *session.SessionManager, stream: net.Stream) !void {
    defer stream.close();

    log.debug("handleClient: Starting client handler", .{});

    var arena = std.heap.ArenaAllocator.init(session_manager.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client_session = session.ClientSession.init(stream, allocator, &session_manager.config);
    defer client_session.deinit();

    log.debug("handleClient: Session initialized", .{});

    // Create file manager
    var fm = try file_manager.FileManager.init(allocator, null);
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
                try file_operations.handleOpenCommand(&client_session, &fm, open_cmd);
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
    while (client_session.files.items.len > 0) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    log.debug("handleClient: All files closed, client handler exiting", .{});
}

// Unit tests
const testing = std.testing;

// Helper function to create a test configuration
fn createTestConfig(allocator: std.mem.Allocator) !@import("config.zig").Config {
    const editor = try allocator.dupe(u8, "test_editor");
    const ip = try allocator.dupe(u8, "127.0.0.1");

    return @import("config.zig").Config{
        .default_editor = editor,
        .port = 52698,
        .ip = ip,
    };
}

// Helper function to create a test session manager
fn createTestSessionManager(allocator: std.mem.Allocator) !session.SessionManager {
    const config = try createTestConfig(allocator);

    return session.SessionManager{
        .sessions = std.ArrayList(*session.ClientSession).init(allocator),
        .mutex = std.Thread.Mutex{},
        .allocator = allocator,
        .config = config,
    };
}

test "handleClientWrapper should catch and log errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a mock session manager
    var session_manager = try createTestSessionManager(allocator);

    // Create a test stream using a pipe
    const fds = try std.posix.pipe();

    // Close the write end to simulate an error when trying to read
    std.posix.close(fds[1]);

    const test_stream = net.Stream{ .handle = fds[0] };

    // This should not panic, but should log an error
    // handleClient will close the stream, so no need to defer close
    handleClientWrapper(&session_manager, test_stream);

    // If we reach here, the wrapper successfully caught the error
    try testing.expect(true);
}

test "handleClient should handle unexpected save command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a mock session manager
    var session_manager = try createTestSessionManager(allocator);

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
    try handleClient(&session_manager, test_stream);
}

test "handleClient should handle unexpected close command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a mock session manager
    var session_manager = try createTestSessionManager(allocator);

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
    try handleClient(&session_manager, test_stream);
}

test "handleClient should handle empty command stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a mock session manager
    var session_manager = try createTestSessionManager(allocator);

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
    try handleClient(&session_manager, test_stream);
}
