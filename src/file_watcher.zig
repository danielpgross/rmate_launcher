//! Cross-platform file watcher implementation
//! - Uses kqueue on macOS/BSD systems
//! - Uses inotify on Linux systems
//! Supports monitoring file modifications, attribute changes, and other file system events.

const std = @import("std");
const os = std.os;
const posix = std.posix;
const builtin = @import("builtin");

const log = std.log.scoped(.file_watcher);

// Platform-specific constants
const target_os = builtin.target.os.tag;

// kqueue constants for macOS/BSD
const EVFILT_VNODE: i16 = -4;
const EV_ADD: u16 = 0x0001;
const EV_ENABLE: u16 = 0x0004;
const EV_CLEAR: u16 = 0x0020;
const NOTE_WRITE: u32 = 0x00000002;
const NOTE_EXTEND: u32 = 0x00000004;
const NOTE_ATTRIB: u32 = 0x00000008;

// inotify constants for Linux
const IN_MODIFY: u32 = 0x00000002;
const IN_ATTRIB: u32 = 0x00000004;
const IN_CLOSE_WRITE: u32 = 0x00000008;
const IN_MOVED_FROM: u32 = 0x00000040;
const IN_MOVED_TO: u32 = 0x00000080;
const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_NONBLOCK: u32 = 0x00000800;
const IN_CLOEXEC: u32 = 0x00080000;

// Platform-specific OS data
const OsData = union(enum) {
    kqueue: struct {
        kq: ?posix.fd_t,
        file_fd: ?posix.fd_t,
    },
    inotify: struct {
        inotify_fd: ?posix.fd_t,
        watch_descriptor: ?i32,
    },
};

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    callback: *const fn (ctx: *anyopaque, path: []const u8) void,
    callback_context: *anyopaque,
    os_data: OsData,
    thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, path: []const u8, callback: *const fn (*anyopaque, []const u8) void, context: *anyopaque) !FileWatcher {
        const os_data = switch (target_os) {
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => OsData{ .kqueue = .{ .kq = null, .file_fd = null } },
            .linux => OsData{ .inotify = .{ .inotify_fd = null, .watch_descriptor = null } },
            else => @compileError("Unsupported operating system for file watching"),
        };

        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .callback = callback,
            .callback_context = context,
            .os_data = os_data,
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

        switch (target_os) {
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                if (self.os_data.kqueue.file_fd) |fd| {
                    posix.close(fd);
                    self.os_data.kqueue.file_fd = null;
                }
                if (self.os_data.kqueue.kq) |kq| {
                    posix.close(kq);
                    self.os_data.kqueue.kq = null;
                }
            },
            .linux => {
                if (self.os_data.inotify.watch_descriptor) |wd| {
                    if (self.os_data.inotify.inotify_fd) |fd| {
                        posix.inotify_rm_watch(fd, wd);
                    }
                    self.os_data.inotify.watch_descriptor = null;
                }
                if (self.os_data.inotify.inotify_fd) |fd| {
                    posix.close(fd);
                    self.os_data.inotify.inotify_fd = null;
                }
            },
            else => @compileError("Unsupported operating system for file watching"),
        }
    }

    fn watchThread(self: *FileWatcher) !void {
        switch (target_os) {
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => try self.watchThreadKqueue(),
            .linux => try self.watchThreadInotify(),
            else => @compileError("Unsupported operating system for file watching"),
        }
    }

    fn watchThreadKqueue(self: *FileWatcher) !void {
        // Create kqueue
        self.os_data.kqueue.kq = try posix.kqueue();
        errdefer {
            if (self.os_data.kqueue.kq) |kq| posix.close(kq);
        }

        // Open the file for monitoring
        // Add null terminator for the system call
        const path_with_null = try self.allocator.allocSentinel(u8, self.path.len, 0);
        defer self.allocator.free(path_with_null);
        @memcpy(path_with_null[0..self.path.len], self.path);

        self.os_data.kqueue.file_fd = try posix.open(path_with_null, .{ .ACCMODE = .RDONLY }, 0);
        errdefer {
            if (self.os_data.kqueue.file_fd) |fd| posix.close(fd);
        }

        // Register kevent for file modifications
        var changelist = [1]posix.Kevent{
            posix.Kevent{
                .ident = @intCast(self.os_data.kqueue.file_fd.?),
                .filter = EVFILT_VNODE,
                .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
                .fflags = NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB,
                .data = 0,
                .udata = 0,
            },
        };

        _ = try posix.kevent(self.os_data.kqueue.kq.?, &changelist, &[0]posix.Kevent{}, null);

        log.debug("kqueue file watcher started for: {s}", .{self.path});

        // Event loop
        var eventlist: [1]posix.Kevent = undefined;
        while (!self.should_stop.load(.seq_cst)) {
            const timeout = posix.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }; // 100ms timeout

            const num_events = posix.kevent(self.os_data.kqueue.kq.?, &[0]posix.Kevent{}, &eventlist, &timeout) catch |err| {
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

    fn watchThreadInotify(self: *FileWatcher) !void {
        // Create inotify instance
        self.os_data.inotify.inotify_fd = try posix.inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        errdefer {
            if (self.os_data.inotify.inotify_fd) |fd| posix.close(fd);
        }

        // Add watch for the file
        const path_with_null = try self.allocator.allocSentinel(u8, self.path.len, 0);
        defer self.allocator.free(path_with_null);
        @memcpy(path_with_null[0..self.path.len], self.path);

        const watch_mask = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE;
        self.os_data.inotify.watch_descriptor = try posix.inotify_add_watchZ(self.os_data.inotify.inotify_fd.?, path_with_null, watch_mask);

        log.debug("inotify file watcher started for: {s}", .{self.path});

        // Event loop
        var buffer: [4096]u8 = undefined;
        while (!self.should_stop.load(.seq_cst)) {
            const bytes_read = posix.read(self.os_data.inotify.inotify_fd.?, &buffer) catch |err| switch (err) {
                error.WouldBlock => {
                    // No events available, sleep briefly and continue
                    std.time.sleep(100 * std.time.ns_per_ms); // 100ms
                    continue;
                },
                else => {
                    log.err("inotify read error: {}", .{err});
                    return err;
                },
            };

            if (bytes_read == 0) continue;

            // Parse inotify events
            var offset: usize = 0;
            while (offset < bytes_read) {
                const event_ptr: *align(1) const std.os.linux.inotify_event = @ptrCast(&buffer[offset]);
                const event = event_ptr.*;

                log.debug("inotify event received for file: {s}, mask: 0x{x}", .{ self.path, event.mask });

                // Check if it's a modification event we care about
                if ((event.mask & (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE)) != 0) {
                    log.debug("File modified: {s}", .{self.path});
                    self.callback(self.callback_context, self.path);
                }

                // Move to next event
                offset += @sizeOf(std.os.linux.inotify_event) + event.len;
            }
        }

        log.debug("inotify file watcher stopped for: {s}", .{self.path});
    }
};
