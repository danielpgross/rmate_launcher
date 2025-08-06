const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const build_options = @import("build_options");

const session = @import("session.zig");
const client_handler = @import("client_handler.zig");
const cli = @import("cli.zig");

const log = std.log.scoped(.rmate_launcher);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const should_exit = try cli.parseArgs(allocator);
    if (should_exit) return;

    var session_manager = try session.SessionManager.init(allocator);
    defer session_manager.deinit();

    // Setup server (Unix socket or TCP)
    var listener = if (session_manager.config.isUnixSocket()) blk: {
        const socket_path = session_manager.config.socket_path.?;

        // Remove existing socket file if it exists
        std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Ensure parent directory exists
        if (std.fs.path.dirname(socket_path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const address = try net.Address.initUnix(socket_path);
        const unix_listener = try address.listen(.{
            .kernel_backlog = 128,
        });

        log.info("RMate Launcher {} listening on Unix socket: {s}", .{ build_options.version, socket_path });
        break :blk unix_listener;
    } else blk: {
        const ip = session_manager.config.ip.?;
        const port = session_manager.config.port.?;
        const address = try net.Address.parseIp(ip, port);
        const tcp_listener = try address.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128,
        });

        log.info("RMate Launcher {} listening on TCP: {s}:{}", .{ build_options.version, ip, port });
        break :blk tcp_listener;
    };
    defer listener.deinit();

    // Setup cleanup for Unix socket
    if (session_manager.config.isUnixSocket()) {
        defer {
            if (session_manager.config.socket_path) |socket_path| {
                std.fs.deleteFileAbsolute(socket_path) catch |err| {
                    log.warn("Failed to cleanup Unix socket {s}: {}", .{ socket_path, err });
                };
            }
        }
    }

    // Accept loop
    while (true) {
        if (listener.accept()) |connection| {
            log.info("Client connected from {}", .{connection.address});

            // Send greeting
            const version_string = try std.fmt.allocPrint(std.heap.page_allocator, "RMate Launcher {}\n", .{build_options.version});
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
