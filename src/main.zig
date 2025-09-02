const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const build_options = @import("build_options");

const client_handler = @import("client_handler.zig");
const cli = @import("cli.zig");
const file_manager = @import("file_manager.zig");
const posix = std.posix;
const atomic = std.atomic;
const builtin = @import("builtin");
const net_utils = @import("net_utils.zig");

const log = std.log.scoped(.rmate_launcher);

var shutdown_requested: atomic.Value(bool) = atomic.Value(bool).init(false);

fn handleSignal(sig: c_int) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const base_allocator = gpa.allocator();
    var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = base_allocator };
    const allocator = thread_safe.allocator();

    // Parse command line arguments
    const should_exit = try cli.parseArgs(allocator);
    if (should_exit) return;

    // Register signal handlers for graceful shutdown
    {
        var sa = posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
    }

    // Load configuration (includes base_dir)
    var cfg = try @import("config.zig").Config.init(allocator);
    defer cfg.deinit();

    // Ensure base_dir exists and cleanup leftovers
    {
        const base_dir = try file_manager.initBaseDir(allocator, cfg.base_dir);
        defer allocator.free(base_dir);
        file_manager.cleanupLeftoverHostDirs(allocator, base_dir);
    }

    // Removed SessionManager; pass config and allocator directly

    // Setup server (Unix socket or TCP)
    var listener = if (cfg.isUnixSocket()) blk: {
        const socket_path = cfg.socket_path.?;

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

        std.posix.fchmodat(std.posix.AT.FDCWD, socket_path, 0o600, 0) catch |chmod_err| {
            log.warn("Failed to set permissions 0600 on socket {s}: {}", .{ socket_path, chmod_err });
        };

        log.info("RMate Launcher {} listening on Unix socket: {s}", .{ build_options.version, socket_path });
        break :blk unix_listener;
    } else blk: {
        const ip = cfg.ip.?;
        const port = cfg.port.?;
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
    const cleanup_socket_path = cfg.socket_path;
    defer {
        if (cleanup_socket_path) |socket_path| {
            std.fs.deleteFileAbsolute(socket_path) catch |err| {
                log.warn("Failed to cleanup Unix socket {s}: {}", .{ socket_path, err });
            };
        }
    }

    // Accept loop (blocking). Use net_utils.acceptInterruptible instead of std accept
    // so signals interrupt the blocking accept and allow graceful shutdown.
    while (true) {
        if (net_utils.acceptInterruptible(&listener)) |connection| {
            log.info("Client connected from {}", .{connection.address});

            // Send greeting
            const version_string = try std.fmt.allocPrint(std.heap.page_allocator, "RMate Launcher {}\n", .{build_options.version});
            defer std.heap.page_allocator.free(version_string);
            try connection.stream.writeAll(version_string);

            // Spawn thread to handle client
            const thread = Thread.spawn(.{}, client_handler.handleClientWrapper, .{ &cfg, allocator, connection.stream }) catch |err| {
                log.err("Failed to spawn client handler thread: {}", .{err});
                connection.stream.close();
                continue;
            };
            thread.detach();
        } else |err| switch (err) {
            error.Interrupted => {
                if (shutdown_requested.load(.acquire)) break;
                continue;
            },
            error.ConnectionAborted => continue,
            else => {
                log.err("Failed to accept connection: {}", .{err});
                continue;
            },
        }
    }
    log.info("Shutdown requested; exiting accept loop", .{});
}
