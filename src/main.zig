const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const build_options = @import("build_options");

const session = @import("session.zig");
const client_handler = @import("client_handler.zig");
const cli = @import("cli.zig");
const file_manager = @import("file_manager.zig");
const posix = std.posix;
const atomic = std.atomic;
const builtin = @import("builtin");

const log = std.log.scoped(.rmate_launcher);

var shutdown_requested: atomic.Value(bool) = atomic.Value(bool).init(false);

fn handleSignal(sig: c_int) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .release);
}

fn acceptInterruptible(server: *net.Server) (error{Interrupted} || posix.AcceptError)!net.Server.Connection {
    var accepted_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);

    const fd: posix.socket_t = blk: {
        const have_accept4 = !(builtin.target.os.tag.isDarwin() or builtin.target.os.tag == .windows or builtin.target.os.tag == .haiku);
        if (have_accept4) {
            const rc = posix.system.accept4(server.stream.handle, &accepted_addr.any, &addr_len, posix.SOCK.CLOEXEC);
            switch (posix.errno(rc)) {
                .SUCCESS => break :blk @as(posix.socket_t, @intCast(rc)),
                .INTR => return error.Interrupted,
                .AGAIN => return error.WouldBlock,
                .BADF => unreachable,
                .CONNABORTED => return error.ConnectionAborted,
                .FAULT => unreachable,
                .INVAL => return error.SocketNotListening,
                .NOTSOCK => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return posix.unexpectedErrno(err),
            }
        } else {
            const rc = posix.system.accept(server.stream.handle, &accepted_addr.any, &addr_len);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const new_fd: posix.socket_t = @intCast(rc);
                    // Ensure CLOEXEC on the accepted fd (best-effort on platforms without accept4)
                    if (posix.fcntl(new_fd, posix.F.GETFD, 0)) |current| {
                        _ = posix.fcntl(new_fd, posix.F.SETFD, @as(usize, @intCast(current | posix.FD_CLOEXEC))) catch {};
                    } else |_| {}
                    break :blk new_fd;
                },
                .INTR => return error.Interrupted,
                .AGAIN => return error.WouldBlock,
                .BADF => unreachable,
                .CONNABORTED => return error.ConnectionAborted,
                .FAULT => unreachable,
                .INVAL => return error.SocketNotListening,
                .NOTSOCK => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    };

    return .{
        .stream = .{ .handle = fd },
        .address = accepted_addr,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const should_exit = try cli.parseArgs(allocator);
    if (should_exit) return;

    // Cleanup any leftover temp folders from previous runs
    {
        var fm = try file_manager.FileManager.init(allocator, null);
        defer fm.deinit();
        fm.cleanupLeftoverHostDirs();
    }

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

    // Setup cleanup for Unix socket
    const cleanup_socket_path = session_manager.config.socket_path;
    defer {
        if (cleanup_socket_path) |socket_path| {
            std.fs.deleteFileAbsolute(socket_path) catch |err| {
                log.warn("Failed to cleanup Unix socket {s}: {}", .{ socket_path, err });
            };
        }
    }

    // Accept loop (blocking). Our wrapper returns Interrupted on signal.
    while (true) {
        if (acceptInterruptible(&listener)) |connection| {
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
