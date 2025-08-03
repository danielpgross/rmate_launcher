const std = @import("std");
const fs = std.fs;
const log = std.log.scoped(.file_manager);

pub const FileManager = struct {
    allocator: std.mem.Allocator,
    base_dir: []u8,

    pub fn init(allocator: std.mem.Allocator) !FileManager {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
        defer allocator.free(home);
        const base_dir = try std.fmt.allocPrint(allocator, "{s}/.rmate-server", .{home});

        // Create base directory if it doesn't exist
        fs.makeDirAbsolute(base_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return .{
            .allocator = allocator,
            .base_dir = base_dir,
        };
    }

    pub fn deinit(self: *FileManager) void {
        self.allocator.free(self.base_dir);
    }

    pub fn createTempFile(self: *FileManager, hostname: []const u8, filepath: []const u8) ![]u8 {
        // Sanitize hostname and filepath
        const safe_hostname = try self.sanitizePath(hostname);
        defer self.allocator.free(safe_hostname);

        const safe_filepath = try self.sanitizePath(filepath);
        defer self.allocator.free(safe_filepath);

        // Create directory structure: ~/.rmate-server/hostname/
        const host_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_dir, safe_hostname });
        defer self.allocator.free(host_dir);

        fs.makeDirAbsolute(host_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create temp file path
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.base_dir, safe_hostname, safe_filepath });

        // Ensure parent directories exist
        if (fs.path.dirname(temp_path)) |dir| {
            fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        return temp_path;
    }

    pub fn writeTempFile(self: *FileManager, path: []const u8, data: []const u8) !void {
        _ = self;
        const file = try fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    pub fn readTempFile(self: *FileManager, path: []const u8) ![]u8 {
        const file = try fs.openFileAbsolute(path, .{});
        defer file.close();

        const stat = try file.stat();
        const contents = try self.allocator.alloc(u8, stat.size);
        _ = try file.read(contents);

        return contents;
    }

    fn sanitizePath(self: *FileManager, path: []const u8) ![]u8 {
        var result = try self.allocator.alloc(u8, path.len);
        var i: usize = 0;
        var prev_was_dot = false;

        for (path) |c| {
            switch (c) {
                '/' => {
                    result[i] = '_';
                    i += 1;
                    prev_was_dot = false;
                },
                '.' => {
                    if (prev_was_dot) {
                        // Skip double dots
                        continue;
                    }
                    result[i] = c;
                    i += 1;
                    prev_was_dot = true;
                },
                else => {
                    result[i] = c;
                    i += 1;
                    prev_was_dot = false;
                },
            }
        }

        return try self.allocator.realloc(result, i);
    }
};

pub const EditorSpawner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EditorSpawner {
        return .{ .allocator = allocator };
    }

    pub fn spawnEditorBlocking(self: *EditorSpawner, editor_cmd: []const u8, file_path: []const u8) !void {
        // Use shell to handle complex editor commands with arguments
        var args = [_][]const u8{ "/bin/sh", "-c", undefined };

        // Build command string: "editor_cmd file_path"
        const full_cmd = try std.fmt.allocPrint(self.allocator, "{s} \"{s}\"", .{ editor_cmd, file_path });
        defer self.allocator.free(full_cmd);

        args[2] = full_cmd;

        var child = std.process.Child.init(&args, self.allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        const result = try child.wait();

        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    log.warn("Editor exited with code {d}", .{code});
                }
            },
            else => {
                log.warn("Editor terminated abnormally", .{});
            },
        }
    }
};
