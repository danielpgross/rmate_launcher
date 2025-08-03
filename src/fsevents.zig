const std = @import("std");
const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});

const log = std.log.scoped(.fsevents);

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    callback: *const fn (ctx: *anyopaque, path: []const u8) void,
    callback_context: *anyopaque,
    stream_ref: ?c.FSEventStreamRef,
    run_loop_ref: ?c.CFRunLoopRef,
    thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, callback: *const fn (*anyopaque, []const u8) void, context: *anyopaque) !FileWatcher {
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .callback = callback,
            .callback_context = context,
            .stream_ref = null,
            .run_loop_ref = null,
            .thread = null,
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
        if (self.run_loop_ref) |run_loop| {
            c.CFRunLoopStop(run_loop);
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (self.stream_ref) |stream| {
            c.FSEventStreamStop(stream);
            c.FSEventStreamInvalidate(stream);
            c.FSEventStreamRelease(stream);
            self.stream_ref = null;
        }
    }

    const WatcherContext = struct {
        watcher: *FileWatcher,
    };

    fn watchThread(self: *FileWatcher) !void {
        var context = WatcherContext{ .watcher = self };

        // Create paths array
        const path_cfstr = c.CFStringCreateWithCString(null, self.path.ptr, c.kCFStringEncodingUTF8);
        defer c.CFRelease(path_cfstr);

        var path_cfstr_ptr = path_cfstr;
        const paths = c.CFArrayCreate(null, @ptrCast(&path_cfstr_ptr), 1, &c.kCFTypeArrayCallBacks);
        defer c.CFRelease(paths);

        // Create FSEventStream
        var stream_context = c.FSEventStreamContext{
            .version = 0,
            .info = &context,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        self.stream_ref = c.FSEventStreamCreate(null, eventCallback, &stream_context, paths, c.kFSEventStreamEventIdSinceNow, 0.1, // 100ms latency
            c.kFSEventStreamCreateFlagFileEvents | c.kFSEventStreamCreateFlagNoDefer);

        if (self.stream_ref == null) {
            return error.FSEventStreamCreateFailed;
        }

        self.run_loop_ref = c.CFRunLoopGetCurrent();
        c.FSEventStreamScheduleWithRunLoop(self.stream_ref.?, self.run_loop_ref.?, c.kCFRunLoopDefaultMode);

        if (c.FSEventStreamStart(self.stream_ref.?) == 0) {
            return error.FSEventStreamStartFailed;
        }

        c.CFRunLoopRun();
    }

    fn eventCallback(stream: c.ConstFSEventStreamRef, client_callback_info: ?*anyopaque, num_events: usize, event_paths: ?*anyopaque, event_flags: [*c]const c.FSEventStreamEventFlags, event_ids: [*c]const c.FSEventStreamEventId) callconv(.C) void {
        _ = stream;
        _ = event_ids;

        const context = @as(*const WatcherContext, @ptrCast(@alignCast(client_callback_info.?)));
        const paths = @as([*][*:0]const u8, @ptrCast(@alignCast(event_paths.?)));

        var i: usize = 0;
        while (i < num_events) : (i += 1) {
            const path = std.mem.span(paths[i]);
            const flags = event_flags[i];

            log.debug("FSEvent received for path: {s}, flags: 0x{x}", .{ path, flags });

            // Check if it's a file modification event
            if ((flags & c.kFSEventStreamEventFlagItemModified) != 0) {
                log.debug("File modified: {s}", .{path});
                context.watcher.callback(context.watcher.callback_context, path);
            } else if ((flags & c.kFSEventStreamEventFlagItemCreated) != 0) {
                log.debug("File created: {s}", .{path});
                context.watcher.callback(context.watcher.callback_context, path);
            } else if ((flags & c.kFSEventStreamEventFlagItemRenamed) != 0) {
                log.debug("File renamed: {s}", .{path});
                context.watcher.callback(context.watcher.callback_context, path);
            } else {
                log.debug("Other FSEvent for: {s}, flags: 0x{x}", .{ path, flags });
            }
        }
    }
};
