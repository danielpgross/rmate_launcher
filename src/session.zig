const std = @import("std");
const net = std.net;
const Thread = std.Thread;

const Config = @import("config.zig").Config;
const FileWatcher = @import("file_watcher.zig").FileWatcher;

pub const SessionManager = struct {
    sessions: std.ArrayList(*ClientSession),
    mutex: Thread.Mutex,
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator) !SessionManager {
        return .{
            .sessions = std.ArrayList(*ClientSession).init(allocator),
            .mutex = Thread.Mutex{},
            .allocator = allocator,
            .config = try Config.init(),
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.config.deinit();
        self.sessions.deinit();
    }
};

pub const ClientSession = struct {
    stream: net.Stream,
    files: std.ArrayList(FileSession),
    allocator: std.mem.Allocator,
    config: *const Config,
    wait_group: Thread.WaitGroup,

    pub fn init(stream: net.Stream, allocator: std.mem.Allocator, config: *const Config) ClientSession {
        return .{
            .stream = stream,
            .files = std.ArrayList(FileSession).init(allocator),
            .allocator = allocator,
            .config = config,
            .wait_group = .{},
        };
    }

    pub fn deinit(self: *ClientSession) void {
        self.files.deinit();
    }
};

pub const FileSession = struct {
    token: []u8,
    display_name: []u8,
    real_path: []u8,
    temp_path: []u8,
    data_on_save: bool,
    watcher: ?*FileWatcher,
    watcher_context: ?*WatcherContext,
    allocator: std.mem.Allocator,
};

pub const WatcherContext = struct {
    session: *ClientSession,
    fm: *@import("file_manager.zig").FileManager,
    token: []const u8,
    temp_path: []const u8,
};

pub const EditorContext = struct {
    session: *ClientSession,
    fm: *@import("file_manager.zig").FileManager,
    editor_cmd: []const u8,
    temp_path: []const u8,
    token: []const u8,
};
