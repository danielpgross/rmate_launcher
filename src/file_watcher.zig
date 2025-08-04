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

// Test helpers
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expect = testing.expect;
const expectEqualStrings = testing.expectEqualStrings;

// Test context for callback verification
const TestContext = struct {
    calls: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestContext {
        return TestContext{
            .calls = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestContext) void {
        for (self.calls.items) |call| {
            self.allocator.free(call);
        }
        self.calls.deinit();
    }

    fn callback(ctx: *anyopaque, path: []const u8) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx));
        const path_copy = self.allocator.dupe(u8, path) catch return;
        self.calls.append(path_copy) catch return;
    }
};

test "FileWatcher init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const test_path = "/tmp/test_file.txt";
    var watcher = try FileWatcher.init(allocator, test_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    // Test that path is properly duplicated
    try expectEqualStrings(test_path, watcher.path);

    // Test that callback and context are set
    try expect(watcher.callback == TestContext.callback);
    try expect(@intFromPtr(watcher.callback_context) == @intFromPtr(&test_ctx));

    // Test initial state
    try expect(watcher.thread == null);
    try expectEqual(false, watcher.should_stop.load(.seq_cst));
}

test "FileWatcher path memory management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const test_path = "/tmp/test_file_memory.txt";
    var watcher = try FileWatcher.init(allocator, test_path, TestContext.callback, &test_ctx);

    // Verify the path is a different memory location (duplicated)
    try expect(watcher.path.ptr != test_path.ptr);
    try expectEqualStrings(test_path, watcher.path);

    watcher.deinit();
}

test "FileWatcher stop without start" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const test_path = "/tmp/test_file_stop.txt";
    var watcher = try FileWatcher.init(allocator, test_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    // Should be safe to call stop without start
    watcher.stop();
    try expect(watcher.thread == null);
}

test "FileWatcher should_stop atomic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const test_path = "/tmp/test_file_atomic.txt";
    var watcher = try FileWatcher.init(allocator, test_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    // Test initial state
    try expectEqual(false, watcher.should_stop.load(.seq_cst));

    // Test setting should_stop
    watcher.should_stop.store(true, .seq_cst);
    try expectEqual(true, watcher.should_stop.load(.seq_cst));

    // Test resetting should_stop
    watcher.should_stop.store(false, .seq_cst);
    try expectEqual(false, watcher.should_stop.load(.seq_cst));
}

test "FileWatcher callback mechanism" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const test_path = "/tmp/test_file_callback.txt";
    var watcher = try FileWatcher.init(allocator, test_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    // Simulate callback invocation
    watcher.callback(watcher.callback_context, watcher.path);

    // Verify callback was called with correct path
    try expectEqual(@as(usize, 1), test_ctx.calls.items.len);
    try expectEqualStrings(test_path, test_ctx.calls.items[0]);
}

test "FileWatcher multiple callback invocations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const test_path = "/tmp/test_file_multiple.txt";
    var watcher = try FileWatcher.init(allocator, test_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    // Simulate multiple callback invocations
    watcher.callback(watcher.callback_context, watcher.path);
    watcher.callback(watcher.callback_context, watcher.path);
    watcher.callback(watcher.callback_context, watcher.path);

    // Verify all callbacks were recorded
    try expectEqual(@as(usize, 3), test_ctx.calls.items.len);
    for (test_ctx.calls.items) |call| {
        try expectEqualStrings(test_path, call);
    }
}

test "FileWatcher platform-specific os_data initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const test_path = "/tmp/test_file_platform.txt";
    var watcher = try FileWatcher.init(allocator, test_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    // Test that os_data is properly initialized based on platform
    switch (target_os) {
        .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
            try expect(watcher.os_data == .kqueue);
            try expect(watcher.os_data.kqueue.kq == null);
            try expect(watcher.os_data.kqueue.file_fd == null);
        },
        .linux => {
            try expect(watcher.os_data == .inotify);
            try expect(watcher.os_data.inotify.inotify_fd == null);
            try expect(watcher.os_data.inotify.watch_descriptor == null);
        },
        else => {
            // This should not compile on unsupported platforms
            try expect(false);
        },
    }
}

test "FileWatcher empty path handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    const empty_path = "";
    var watcher = try FileWatcher.init(allocator, empty_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    try expectEqualStrings(empty_path, watcher.path);
    try expectEqual(@as(usize, 0), watcher.path.len);
}

test "FileWatcher long path handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_ctx = TestContext.init(allocator);
    defer test_ctx.deinit();

    // Create a very long path
    const long_path = "/very/long/path/to/some/deeply/nested/directory/structure/that/might/exist/on/some/filesystem/test_file.txt";
    var watcher = try FileWatcher.init(allocator, long_path, TestContext.callback, &test_ctx);
    defer watcher.deinit();

    try expectEqualStrings(long_path, watcher.path);
    try expectEqual(long_path.len, watcher.path.len);
}
