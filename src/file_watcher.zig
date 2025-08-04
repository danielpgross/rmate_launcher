const std = @import("std");
const os = std.os;
const posix = std.posix;

const log = std.log.scoped(.file_watcher);

// kqueue constants for macOS
const EVFILT_VNODE: i16 = -4;
const EV_ADD: u16 = 0x0001;
const EV_ENABLE: u16 = 0x0004;
const EV_CLEAR: u16 = 0x0020;
const NOTE_WRITE: u32 = 0x00000002;
const NOTE_EXTEND: u32 = 0x00000004;
const NOTE_ATTRIB: u32 = 0x00000008;

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    callback: *const fn (ctx: *anyopaque, path: []const u8) void,
    callback_context: *anyopaque,
    kq: ?posix.fd_t,
    file_fd: ?posix.fd_t,
    thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, path: []const u8, callback: *const fn (*anyopaque, []const u8) void, context: *anyopaque) !FileWatcher {
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .callback = callback,
            .callback_context = context,
            .kq = null,
            .file_fd = null,
            .thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        self.stop();
        self.allocator.free(self.path);
    }

    pub fn start(self: *FileWatcher) !void {
        self.thread = try std.Thread.spawn(.{}, watchThread, .{self});
    }

    pub fn stop(self: *FileWatcher) void {
        self.should_stop.store(true, .seq_cst);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (self.file_fd) |fd| {
            posix.close(fd);
            self.file_fd = null;
        }

        if (self.kq) |kq| {
            posix.close(kq);
            self.kq = null;
        }
    }

    fn watchThread(self: *FileWatcher) !void {
        // Create kqueue
        self.kq = try posix.kqueue();
        errdefer {
            if (self.kq) |kq| posix.close(kq);
        }

        // Open the file for monitoring
        // Add null terminator for the system call
        const path_with_null = try self.allocator.allocSentinel(u8, self.path.len, 0);
        defer self.allocator.free(path_with_null);
        @memcpy(path_with_null[0..self.path.len], self.path);

        self.file_fd = try posix.open(path_with_null, .{ .ACCMODE = .RDONLY }, 0);
        errdefer {
            if (self.file_fd) |fd| posix.close(fd);
        }

        // Register kevent for file modifications
        var changelist = [1]posix.Kevent{
            posix.Kevent{
                .ident = @intCast(self.file_fd.?),
                .filter = EVFILT_VNODE,
                .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
                .fflags = NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB,
                .data = 0,
                .udata = 0,
            },
        };

        _ = try posix.kevent(self.kq.?, &changelist, &[0]posix.Kevent{}, null);

        log.debug("kqueue file watcher started for: {s}", .{self.path});

        // Event loop
        var eventlist: [1]posix.Kevent = undefined;
        while (!self.should_stop.load(.seq_cst)) {
            const timeout = posix.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }; // 100ms timeout

            const num_events = posix.kevent(self.kq.?, &[0]posix.Kevent{}, &eventlist, &timeout) catch |err| {
                log.err("kevent error: {}", .{err});
                return err;
            };

            if (num_events > 0) {
                const event = eventlist[0];

                log.debug("kqueue event received for file: {s}, fflags: 0x{x}", .{ self.path, event.fflags });

                // Check if it's a modification event we care about
                if ((event.fflags & (NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB)) != 0) {
                    log.debug("File modified: {s}", .{self.path});
                    self.callback(self.callback_context, self.path);
                }
            }
        }

        log.debug("kqueue file watcher stopped for: {s}", .{self.path});
    }
};
