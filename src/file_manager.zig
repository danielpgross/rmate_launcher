const std = @import("std");
const fs = std.fs;
const log = std.log.scoped(.file_manager);

pub const FileManager = struct {
    allocator: std.mem.Allocator,
    base_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, maybe_base_dir: ?[]const u8) !FileManager {
        var owned_path: ?[]u8 = null;
        const base_path: []const u8 = if (maybe_base_dir) |base_dir_input| base_dir_input else blk: {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
            defer allocator.free(home);
            owned_path = try std.fmt.allocPrint(allocator, "{s}/.rmate_launcher", .{home});
            break :blk owned_path.?;
        };

        // Ensure base directory exists once
        fs.makeDirAbsolute(base_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Transfer ownership if we allocated, otherwise dupe the provided slice
        const base_dir: []u8 = if (owned_path) |p| p else try allocator.dupe(u8, base_path);

        return .{ .allocator = allocator, .base_dir = base_dir };
    }

    pub fn deinit(self: *FileManager) void {
        self.allocator.free(self.base_dir);
    }

    pub fn createTempFile(self: *FileManager, hostname: []const u8, filepath: []const u8) ![]u8 {
        // Sanitize hostname and path to mirror remote directory structure safely
        const safe_hostname = try self.sanitizeHostname(hostname);
        defer self.allocator.free(safe_hostname);

        const mirrored_rel_path = try self.sanitizePath(filepath);
        defer self.allocator.free(mirrored_rel_path);

        // Ensure parent directories exist under base_dir using std.fs.Dir.makePath
        var base = try fs.openDirAbsolute(self.base_dir, .{});
        defer base.close();

        // Ensure host directory exists
        base.makePath(safe_hostname) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        if (fs.path.dirname(mirrored_rel_path)) |rel_parent| {
            const full_rel_parent = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ safe_hostname, rel_parent });
            defer self.allocator.free(full_rel_parent);
            try base.makePath(full_rel_parent);
        }

        // Create temp file path, preserving the mirrored directory structure under the hostname
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.base_dir, safe_hostname, mirrored_rel_path });

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

    pub fn cleanupTempPath(self: *FileManager, temp_path: []const u8) void {
        // Safety: only operate within base_dir
        const under_base =
            std.mem.startsWith(u8, temp_path, self.base_dir) and
            (temp_path.len == self.base_dir.len or temp_path[self.base_dir.len] == '/');
        if (!under_base) {
            log.warn("Refusing to cleanup outside base dir: {s}", .{temp_path});
            return;
        }

        // Delete the file; ignore if it is already gone
        std.fs.deleteFileAbsolute(temp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("Failed to delete temp file {s}: {}", .{ temp_path, err }),
        };

        // Prune empty parent directories up to (but not including) base_dir
        var parent_opt = std.fs.path.dirname(temp_path);
        while (parent_opt) |parent| {
            if (parent.len <= self.base_dir.len) break;
            if (!std.mem.startsWith(u8, parent, self.base_dir)) break;

            std.fs.deleteDirAbsolute(parent) catch |err| switch (err) {
                error.DirNotEmpty => break,
                error.FileNotFound => {},
                else => break,
            };

            parent_opt = std.fs.path.dirname(parent);
        }
    }

    fn sanitizeHostname(self: *FileManager, hostname: []const u8) ![]u8 {
        // Allow only hostname-safe characters: A-Z a-z 0-9 . - _ ; replace others with '_'
        var result = try self.allocator.alloc(u8, hostname.len);
        var i: usize = 0;
        for (hostname) |c| {
            const is_alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
            const is_digit = (c >= '0' and c <= '9');
            const is_ok = is_alpha or is_digit or c == '.' or c == '-' or c == '_';
            result[i] = if (is_ok) c else '_';
            i += 1;
        }
        return try self.allocator.realloc(result, i);
    }

    fn sanitizePath(self: *FileManager, path: []const u8) ![]u8 {
        // Ignore invalid traversal components completely, and collapse '.' and empty components.
        // Always produce a relative path to be placed under hostname.
        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();

        var it = std.mem.splitScalar(u8, path, '/');
        var first = true;
        while (it.next()) |seg| {
            if (seg.len == 0) continue; // skip empty and leading '/'
            if (std.mem.eql(u8, seg, ".")) continue; // skip current dir
            if (std.mem.eql(u8, seg, "..")) continue; // ignore parent traversal entirely

            if (!first) try out.append('/');
            try out.appendSlice(seg);
            first = false;
        }

        return try out.toOwnedSlice();
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
    // Test basic initialization and cleanup using a temp base dir
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    // Verify base_dir is set correctly
    try testing.expectEqualStrings(base_under_tmp, fm.base_dir);
}

test "FileManager sanitizeHostname basic functionality" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    // Test basic path sanitization
    const result1 = try fm.sanitizeHostname("simple");
    defer test_allocator.free(result1);
    try testing.expectEqualStrings("simple", result1);

    // Test forward slash replacement
    const result2 = try fm.sanitizeHostname("path/with/slashes");
    defer test_allocator.free(result2);
    try testing.expectEqualStrings("path_with_slashes", result2);

    // Test double dot removal
    const result3 = try fm.sanitizeHostname("path..with..dots");
    defer test_allocator.free(result3);
    try testing.expectEqualStrings("path.with.dots", result3);

    // Test complex path
    const result4 = try fm.sanitizeHostname("/etc/../config/file.txt");
    defer test_allocator.free(result4);
    try testing.expectEqualStrings("_etc_._config_file.txt", result4);
}

test "FileManager sanitizeHostname edge cases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    // Test empty string
    const result1 = try fm.sanitizeHostname("");
    defer test_allocator.free(result1);
    try testing.expectEqualStrings("", result1);

    // Test single character
    const result2 = try fm.sanitizeHostname("/");
    defer test_allocator.free(result2);
    try testing.expectEqualStrings("_", result2);

    // Test only dots
    const result3 = try fm.sanitizeHostname("...");
    defer test_allocator.free(result3);
    try testing.expectEqualStrings(".", result3);
}

test "FileManager createTempFile path structure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    // Test temp file path creation
    const temp_path = try fm.createTempFile("server1", "/etc/hosts");
    defer test_allocator.free(temp_path);

    // Verify path structure: base_dir/hostname/etc/hosts
    try testing.expect(std.mem.indexOf(u8, temp_path, fm.base_dir) == 0);
    try testing.expect(std.mem.indexOf(u8, temp_path, "server1") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "etc/hosts") != null);
}

test "FileManager createTempFile with special characters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    // Test with hostname and filepath containing special characters
    const temp_path = try fm.createTempFile("my-server.example.com", "/var/../log/app.log");
    defer test_allocator.free(temp_path);

    // Verify normalization occurred and mirrored path is preserved
    try testing.expect(std.mem.indexOf(u8, temp_path, "my-server.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "var/log/app.log") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "..") == null);
}

test "FileManager write and read temp file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
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

test "FileManager cleanupTempPath deletes file and prunes empty dirs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    const host = "cleanuphost1";
    const temp_path = try fm.createTempFile(host, "/a/b/c/file.txt");
    defer test_allocator.free(temp_path);

    try fm.writeTempFile(temp_path, "data");

    // Perform cleanup
    fm.cleanupTempPath(temp_path);

    // The file should be gone
    try testing.expectError(error.FileNotFound, fs.openFileAbsolute(temp_path, .{}));

    // The host directory should be pruned (since no siblings)
    const host_dir = try std.fmt.allocPrint(test_allocator, "{s}/{s}", .{ fm.base_dir, host });
    defer test_allocator.free(host_dir);
    try testing.expectError(error.FileNotFound, fs.openDirAbsolute(host_dir, .{}));
}

test "FileManager cleanupTempPath preserves non-empty dirs until all files removed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    const host = "cleanuphost2";
    const path1 = try fm.createTempFile(host, "/a/b/c/file1.txt");
    defer test_allocator.free(path1);
    const path2 = try fm.createTempFile(host, "/a/b/c/file2.txt");
    defer test_allocator.free(path2);

    try fm.writeTempFile(path1, "data1");
    try fm.writeTempFile(path2, "data2");

    // Cleanup first file only
    fm.cleanupTempPath(path1);

    // file1 should be gone
    try testing.expectError(error.FileNotFound, fs.openFileAbsolute(path1, .{}));

    // Directory should still exist because file2 remains
    const dir_c = (std.fs.path.dirname(path1) orelse return error.Unexpected);
    var dir_handle = try fs.openDirAbsolute(dir_c, .{});
    dir_handle.close();

    // file2 should still exist
    var f2 = try fs.openFileAbsolute(path2, .{});
    f2.close();

    // Now cleanup second file; this should prune directories as they become empty
    fm.cleanupTempPath(path2);

    // Host directory should now be gone
    const host_dir = try std.fmt.allocPrint(test_allocator, "{s}/{s}", .{ fm.base_dir, host });
    defer test_allocator.free(host_dir);
    try testing.expectError(error.FileNotFound, fs.openDirAbsolute(host_dir, .{}));
}

test "FileManager readTempFile nonexistent file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    // Try to read a nonexistent file
    const result = fm.readTempFile("/nonexistent/path/file.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "FileManager createTempFile nested directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    var fm = try FileManager.init(test_allocator, base_under_tmp);
    defer fm.deinit();

    // Test creating nested directory structure
    const temp_path = try fm.createTempFile("deephost", "/very/deep/nested/path/file.txt");
    defer test_allocator.free(temp_path);

    // Verify the path structure mirrors nested elements
    try testing.expect(std.mem.indexOf(u8, temp_path, "deephost") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "very/deep/nested/path/file.txt") != null);

    // Test that we can actually write to this nested path
    const test_data = "nested file content";
    try fm.writeTempFile(temp_path, test_data);

    const read_data = try fm.readTempFile(temp_path);
    defer test_allocator.free(read_data);

    try testing.expectEqualStrings(test_data, read_data);

    // Cleanup
    std.fs.deleteFileAbsolute(temp_path) catch {};
}
