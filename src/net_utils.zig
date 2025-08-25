const std = @import("std");
const net = std.net;
const posix = std.posix;
const builtin = @import("builtin");

// Accept a connection in a way that can be interrupted by signals.
// This substitutes for Zig std's accept behavior, which does not return
// error.Interrupted on signal; we need the loop in main to break promptly
// when a shutdown signal arrives.
pub fn acceptInterruptible(server: *net.Server) (error{Interrupted} || posix.AcceptError)!net.Server.Connection {
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
