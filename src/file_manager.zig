const std = @import("std");
const fs = std.fs;
const posix = std.posix;
const log = std.log.scoped(.file_manager);

pub fn initBaseDir(allocator: std.mem.Allocator, base_dir: []const u8) ![]u8 {
    const base_path: []const u8 = base_dir;

    fs.makeDirAbsolute(base_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    posix.fchmodat(posix.AT.FDCWD, base_path, 0o700, 0) catch |chmod_err| {
        log.warn("Failed to set permissions 0700 on {s}: {}", .{ base_path, chmod_err });
    };

    return try allocator.dupe(u8, base_path);
}

pub fn createTempFile(allocator: std.mem.Allocator, base_dir: []const u8, hostname: []const u8, filepath: []const u8) ![]u8 {
    const safe_hostname = try sanitizeHostname(allocator, hostname);
    defer allocator.free(safe_hostname);

    const mirrored_rel_path = try sanitizePath(allocator, filepath);
    defer allocator.free(mirrored_rel_path);

    var base = try fs.openDirAbsolute(base_dir, .{});
    defer base.close();

    base.makePath(safe_hostname) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    if (fs.path.dirname(mirrored_rel_path)) |rel_parent| {
        const full_rel_parent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ safe_hostname, rel_parent });
        defer allocator.free(full_rel_parent);
        try base.makePath(full_rel_parent);
    }

    const temp_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base_dir, safe_hostname, mirrored_rel_path });
    return temp_path;
}

pub fn writeTempFile(path: []const u8, data: []const u8) !void {
    const file = try fs.createFileAbsolute(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(data);
}

pub fn readTempFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    const contents = try allocator.alloc(u8, stat.size);
    _ = try file.read(contents);
    return contents;
}

pub fn cleanupTempPath(base_dir: []const u8, temp_path: []const u8) void {
    const under_base =
        std.mem.startsWith(u8, temp_path, base_dir) and
        (temp_path.len == base_dir.len or temp_path[base_dir.len] == '/');
    if (!under_base) {
        log.warn("Refusing to cleanup outside base dir: {s}", .{temp_path});
        return;
    }

    std.fs.deleteFileAbsolute(temp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("Failed to delete temp file {s}: {}", .{ temp_path, err }),
    };

    var parent_opt = std.fs.path.dirname(temp_path);
    while (parent_opt) |parent| {
        if (parent.len <= base_dir.len) break;
        if (!std.mem.startsWith(u8, parent, base_dir)) break;

        std.fs.deleteDirAbsolute(parent) catch |err| switch (err) {
            error.DirNotEmpty => break,
            error.FileNotFound => {},
            else => break,
        };

        parent_opt = std.fs.path.dirname(parent);
    }
}

pub fn cleanupLeftoverHostDirs(allocator: std.mem.Allocator, base_dir: []const u8) void {
    var base_dir_handle = fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch |err| {
        log.warn("Unable to open temp base directory: {s}: {}", .{ base_dir, err });
        return;
    };
    defer base_dir_handle.close();

    const recovered_rel = "_recovered";
    var recovered_ts_rel: ?[]u8 = null;
    defer if (recovered_ts_rel) |p| allocator.free(p);

    var it = base_dir_handle.iterate();
    while (true) {
        const maybe_entry = it.next() catch |err| {
            log.warn("Error iterating temp base directory {s}: {}", .{ base_dir, err });
            break;
        };
        if (maybe_entry == null) break;
        const entry = maybe_entry.?;

        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, recovered_rel)) continue;

        if (recovered_ts_rel == null) {
            recovered_ts_rel = ensureRecoveredSubdir(allocator, base_dir, base_dir_handle);
            if (recovered_ts_rel == null) {
                return;
            }
        }

        const new_rel = std.fmt.allocPrint(allocator, "{s}/{s}", .{ recovered_ts_rel.?, entry.name }) catch {
            log.warn("Failed to allocate target path for recovered folder {s}; skipping", .{entry.name});
            continue;
        };
        defer allocator.free(new_rel);

        log.warn("Quarantining leftover temp folder: {s}/{s} -> {s}/{s}", .{ base_dir, entry.name, base_dir, new_rel });
        base_dir_handle.rename(entry.name, new_rel) catch |ren_err| {
            log.warn("Failed to quarantine {s}/{s}: {}", .{ base_dir, entry.name, ren_err });
        };
    }
}

fn ensureRecoveredSubdir(allocator: std.mem.Allocator, base_dir: []const u8, base_dir_handle: fs.Dir) ?[]u8 {
    base_dir_handle.makePath("_recovered") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create recovered directory {s}/_recovered: {}", .{ base_dir, err });
            return null;
        },
    };

    const now_i64 = std.time.timestamp();
    const now_secs: u64 = if (now_i64 >= 0) @as(u64, @intCast(now_i64)) else 0;
    const es = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const ts = std.fmt.allocPrint(allocator, "{d}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        @as(u8, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch {
        log.warn("Failed to allocate timestamp for recovered directory; skipping cleanup", .{});
        return null;
    };
    defer allocator.free(ts);

    const recovered_ts_rel = std.fmt.allocPrint(allocator, "_recovered/{s}", .{ts}) catch {
        log.warn("Failed to allocate recovered path; skipping cleanup", .{});
        return null;
    };

    base_dir_handle.makePath(recovered_ts_rel) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create recovered timestamp directory {s}/{s}: {}", .{ base_dir, recovered_ts_rel, err });
            allocator.free(recovered_ts_rel);
            return null;
        },
    };
    return recovered_ts_rel;
}

pub fn sanitizeHostname(allocator: std.mem.Allocator, hostname: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, hostname.len);
    var i: usize = 0;
    for (hostname) |c| {
        const is_alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        const is_digit = (c >= '0' and c <= '9');
        const is_ok = is_alpha or is_digit or c == '.' or c == '-' or c == '_';
        result[i] = if (is_ok) c else '_';
        i += 1;
    }
    return try allocator.realloc(result, i);
}

pub fn sanitizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) continue;
        if (!first) try out.append('/');
        try out.appendSlice(seg);
        first = false;
    }

    return try out.toOwnedSlice();
}

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

        log.debug("Spawning editor: {s}", .{full_cmd});
        var timer = try std.time.Timer.start();
        try child.spawn();
        const result = try child.wait();
        const elapsed_ms = timer.read() / std.time.ns_per_ms;

        switch (result) {
            .Exited => |code| {
                log.debug("Editor exited with code {d} after {d}ms", .{ code, elapsed_ms });
                if (code != 0) {
                    log.warn("Editor exited with code {d}", .{code});
                }
                if (code == 0 and elapsed_ms < 500) {
                    log.warn(
                        "Editor command returned after {d}ms; this usually means it did not block. Ensure your editor command waits for the file to close (e.g., \"code --wait\"). cmd=\"{s}\", path=\"{s}\"",
                        .{ elapsed_ms, editor_cmd, file_path },
                    );
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);
    try testing.expectEqualStrings(base_under_tmp, base_dir);
}

test "FileManager sanitizeHostname basic functionality" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const result1 = try sanitizeHostname(test_allocator, "simple");
    defer test_allocator.free(result1);
    try testing.expectEqualStrings("simple", result1);

    // Test forward slash replacement
    const result2 = try sanitizeHostname(test_allocator, "path/with/slashes");
    defer test_allocator.free(result2);
    try testing.expectEqualStrings("path_with_slashes", result2);

    // Test double dot removal
    const result3 = try sanitizeHostname(test_allocator, "path..with..dots");
    defer test_allocator.free(result3);
    try testing.expectEqualStrings("path.with.dots", result3);

    // Test complex path
    const result4 = try sanitizeHostname(test_allocator, "/etc/../config/file.txt");
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const result1 = try sanitizeHostname(test_allocator, "");
    defer test_allocator.free(result1);
    try testing.expectEqualStrings("", result1);

    // Test single character
    const result2 = try sanitizeHostname(test_allocator, "/");
    defer test_allocator.free(result2);
    try testing.expectEqualStrings("_", result2);

    // Test only dots
    const result3 = try sanitizeHostname(test_allocator, "...");
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const temp_path = try createTempFile(test_allocator, base_dir, "server1", "/etc/hosts");
    defer test_allocator.free(temp_path);

    // Verify path structure: base_dir/hostname/etc/hosts
    try testing.expect(std.mem.indexOf(u8, temp_path, base_dir) == 0);
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const temp_path = try createTempFile(test_allocator, base_dir, "my-server.example.com", "/var/../log/app.log");
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const temp_path = try createTempFile(test_allocator, base_dir, "testhost", "/tmp/testfile.txt");
    defer test_allocator.free(temp_path);

    // Test data to write
    const test_data = "Hello, RMate!\nThis is a test file.\n";

    // Write to temp file
    try writeTempFile(temp_path, test_data);

    // Read back from temp file
    const read_data = try readTempFile(test_allocator, temp_path);
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const temp_path = try createTempFile(test_allocator, base_dir, "testhost", "/tmp/empty.txt");
    defer test_allocator.free(temp_path);

    // Write empty content
    try writeTempFile(temp_path, "");

    // Read back
    const read_data = try readTempFile(test_allocator, temp_path);
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const temp_path = try createTempFile(test_allocator, base_dir, "testhost", "/tmp/large.txt");
    defer test_allocator.free(temp_path);

    // Create large test data (10KB)
    const large_data = try test_allocator.alloc(u8, 10240);
    defer test_allocator.free(large_data);

    // Fill with pattern
    for (large_data, 0..) |*byte, i| {
        byte.* = @intCast((i % 94) + 33); // Printable ASCII chars
    }

    // Write large file
    try writeTempFile(temp_path, large_data);

    // Read back
    const read_data = try readTempFile(test_allocator, temp_path);
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const host = "cleanuphost1";
    const temp_path = try createTempFile(test_allocator, base_dir, host, "/a/b/c/file.txt");
    defer test_allocator.free(temp_path);

    try writeTempFile(temp_path, "data");

    // Perform cleanup
    cleanupTempPath(base_dir, temp_path);

    // The file should be gone
    try testing.expectError(error.FileNotFound, fs.openFileAbsolute(temp_path, .{}));

    // The host directory should be pruned (since no siblings)
    const host_dir = try std.fmt.allocPrint(test_allocator, "{s}/{s}", .{ base_dir, host });
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const host = "cleanuphost2";
    const path1 = try createTempFile(test_allocator, base_dir, host, "/a/b/c/file1.txt");
    defer test_allocator.free(path1);
    const path2 = try createTempFile(test_allocator, base_dir, host, "/a/b/c/file2.txt");
    defer test_allocator.free(path2);

    try writeTempFile(path1, "data1");
    try writeTempFile(path2, "data2");

    // Cleanup first file only
    cleanupTempPath(base_dir, path1);

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
    cleanupTempPath(base_dir, path2);

    // Host directory should now be gone
    const host_dir = try std.fmt.allocPrint(test_allocator, "{s}/{s}", .{ base_dir, host });
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

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const result = readTempFile(test_allocator, "/nonexistent/path/file.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "FileManager createTempFile nested directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = tmp.dir.realpathAlloc(test_allocator, ".") catch unreachable;
    defer test_allocator.free(tmp_root);
    const base_under_tmp = try std.fmt.allocPrint(test_allocator, "{s}/rmate-test", .{tmp_root});
    defer test_allocator.free(base_under_tmp);

    const base_dir = try initBaseDir(test_allocator, base_under_tmp);
    defer test_allocator.free(base_dir);

    const temp_path = try createTempFile(test_allocator, base_dir, "deephost", "/very/deep/nested/path/file.txt");
    defer test_allocator.free(temp_path);

    // Verify the path structure mirrors nested elements
    try testing.expect(std.mem.indexOf(u8, temp_path, "deephost") != null);
    try testing.expect(std.mem.indexOf(u8, temp_path, "very/deep/nested/path/file.txt") != null);

    // Test that we can actually write to this nested path
    const test_data = "nested file content";
    try writeTempFile(temp_path, test_data);

    const read_data = try readTempFile(test_allocator, temp_path);
    defer test_allocator.free(read_data);

    try testing.expectEqualStrings(test_data, read_data);

    // Cleanup
    std.fs.deleteFileAbsolute(temp_path) catch {};
}
