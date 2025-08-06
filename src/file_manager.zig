const std = @import("std");
const fs = std.fs;
const log = std.log.scoped(.file_manager);

pub const FileManager = struct {
    allocator: std.mem.Allocator,
    base_dir: []u8,

    pub fn init(allocator: std.mem.Allocator) !FileManager {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
        defer allocator.free(home);
        const base_dir = try std.fmt.allocPrint(allocator, "{s}/.rmate_launcher", .{home});

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

        // Create directory structure: ~/.rmate_launcher/hostname/
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

// Unit Tests
const testing = std.testing;
const test_allocator = testing.allocator;

test "FileManager init and deinit" {
    // Test basic initialization and cleanup
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Verify base_dir is set correctly
    try testing.expect(fm.base_dir.len > 0);
    try testing.expect(std.mem.endsWith(u8, fm.base_dir, ".rmate_launcher"));
}

test "FileManager sanitizePath basic functionality" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Test basic path sanitization
    const result1 = try fm.sanitizePath("simple");
    defer test_allocator.free(result1);
    try testing.expectEqualStrings("simple", result1);

    // Test forward slash replacement
    const result2 = try fm.sanitizePath("path/with/slashes");
    defer test_allocator.free(result2);
    try testing.expectEqualStrings("path_with_slashes", result2);

    // Test double dot removal
    const result3 = try fm.sanitizePath("path..with..dots");
    defer test_allocator.free(result3);
    try testing.expectEqualStrings("path.with.dots", result3);

    // Test complex path
    const result4 = try fm.sanitizePath("/etc/../config/file.txt");
    defer test_allocator.free(result4);
    try testing.expectEqualStrings("_etc_._config_file.txt", result4);
}

test "FileManager sanitizePath edge cases" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Test empty string
    const result1 = try fm.sanitizePath("");
    defer test_allocator.free(result1);
    try testing.expectEqualStrings("", result1);

    // Test single character
    const result2 = try fm.sanitizePath("/");
    defer test_allocator.free(result2);
    try testing.expectEqualStrings("_", result2);

    // Test only dots
    const result3 = try fm.sanitizePath("...");
    defer test_allocator.free(result3);
    try testing.expectEqualStrings(".", result3);
}

test "FileManager createTempFile path structure" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Test temp file path creation
    const temp_path = try fm.createTempFile("server1", "/etc/hosts");
    defer test_allocator.free(temp_path);

    // Verify path structure: base_dir/hostname/filepath
    try testing.expect(std.mem.indexOf(u8, temp_path, fm.base_dir) == 0);
    try testing.expect(std.mem.indexOf(u8, temp_path, "server1") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "_etc_hosts") != null);
}

test "FileManager createTempFile with special characters" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Test with hostname and filepath containing special characters
    const temp_path = try fm.createTempFile("my-server.example.com", "/var/../log/app.log");
    defer test_allocator.free(temp_path);

    // Verify sanitization occurred
    try testing.expect(std.mem.indexOf(u8, temp_path, "my-server.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "_var_._log_app.log") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "..") == null);
}

test "FileManager write and read temp file" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Create a temp file path
    const temp_path = try fm.createTempFile("testhost", "/tmp/testfile.txt");
    defer test_allocator.free(temp_path);

    // Test data to write
    const test_data = "Hello, RMate!\nThis is a test file.\n";

    // Write to temp file
    try fm.writeTempFile(temp_path, test_data);

    // Read back from temp file
    const read_data = try fm.readTempFile(temp_path);
    defer test_allocator.free(read_data);

    // Verify content matches
    try testing.expectEqualStrings(test_data, read_data);

    // Cleanup - remove the test file
    std.fs.deleteFileAbsolute(temp_path) catch {};
}

test "FileManager write and read empty file" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Create a temp file path
    const temp_path = try fm.createTempFile("testhost", "/tmp/empty.txt");
    defer test_allocator.free(temp_path);

    // Write empty content
    try fm.writeTempFile(temp_path, "");

    // Read back
    const read_data = try fm.readTempFile(temp_path);
    defer test_allocator.free(read_data);

    // Verify empty
    try testing.expectEqualStrings("", read_data);

    // Cleanup
    std.fs.deleteFileAbsolute(temp_path) catch {};
}

test "FileManager write and read large file" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Create a temp file path
    const temp_path = try fm.createTempFile("testhost", "/tmp/large.txt");
    defer test_allocator.free(temp_path);

    // Create large test data (10KB)
    const large_data = try test_allocator.alloc(u8, 10240);
    defer test_allocator.free(large_data);

    // Fill with pattern
    for (large_data, 0..) |*byte, i| {
        byte.* = @intCast((i % 94) + 33); // Printable ASCII chars
    }

    // Write large file
    try fm.writeTempFile(temp_path, large_data);

    // Read back
    const read_data = try fm.readTempFile(temp_path);
    defer test_allocator.free(read_data);

    // Verify content matches
    try testing.expectEqualSlices(u8, large_data, read_data);

    // Cleanup
    std.fs.deleteFileAbsolute(temp_path) catch {};
}

test "EditorSpawner init" {
    // Test basic initialization
    const spawner = EditorSpawner.init(test_allocator);
    try testing.expect(spawner.allocator.ptr == test_allocator.ptr);
}

test "FileManager readTempFile nonexistent file" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Try to read a nonexistent file
    const result = fm.readTempFile("/nonexistent/path/file.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "FileManager createTempFile nested directories" {
    var fm = try FileManager.init(test_allocator);
    defer fm.deinit();

    // Test creating nested directory structure
    const temp_path = try fm.createTempFile("deephost", "/very/deep/nested/path/file.txt");
    defer test_allocator.free(temp_path);

    // Verify the path structure includes nested elements
    try testing.expect(std.mem.indexOf(u8, temp_path, "deephost") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "_very_deep_nested_path_file.txt") != null);

    // Test that we can actually write to this nested path
    const test_data = "nested file content";
    try fm.writeTempFile(temp_path, test_data);

    const read_data = try fm.readTempFile(temp_path);
    defer test_allocator.free(read_data);

    try testing.expectEqualStrings(test_data, read_data);

    // Cleanup
    std.fs.deleteFileAbsolute(temp_path) catch {};
}
