const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const build_options = @import("build_options");

const session = @import("session.zig");
const client_handler = @import("client_handler.zig");
const cli = @import("cli.zig");

const log = std.log.scoped(.rmate_server);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const should_exit = try cli.parseArgs(allocator);
    if (should_exit) return;

    var session_manager = try session.SessionManager.init(allocator);
    defer session_manager.deinit();

    // Setup TCP server
    const address = try net.Address.parseIp(session_manager.config.ip, session_manager.config.port);
    var listener = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 128,
    });
    defer listener.deinit();

    log.info("RMate server {} listening on {s}:{}", .{ build_options.version, session_manager.config.ip, session_manager.config.port });

    // Accept loop
    while (true) {
        if (listener.accept()) |connection| {
            log.info("Client connected from {}", .{connection.address});

            // Send greeting
            const version_string = try std.fmt.allocPrint(std.heap.page_allocator, "RMate Server {}\n", .{build_options.version});
            defer std.heap.page_allocator.free(version_string);
            try connection.stream.writeAll(version_string);

            // Spawn thread to handle client
            const thread = Thread.spawn(.{}, client_handler.handleClientWrapper, .{
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
