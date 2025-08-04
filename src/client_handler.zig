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
