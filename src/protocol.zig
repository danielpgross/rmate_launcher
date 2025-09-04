const std = @import("std");
const log = std.log.scoped(.protocol);

pub const OpenCommand = struct {
    display_name: []u8,
    real_path: []u8,
    data_on_save: bool = false,
    re_activate: bool = false,
    token: []u8,
    selection: ?[]u8 = null,
    file_type: ?[]u8 = null,
    data: ?[]u8 = null,

    pub fn deinit(self: *const OpenCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.display_name);
        allocator.free(self.real_path);
        allocator.free(self.token);
        if (self.selection) |s| allocator.free(s);
        if (self.file_type) |s| allocator.free(s);
        if (self.data) |s| allocator.free(s);
    }
};

pub fn parseCommands(allocator: std.mem.Allocator, reader: *std.Io.Reader) !std.array_list.AlignedManaged(OpenCommand, null) {
    var commands = std.array_list.AlignedManaged(OpenCommand, null).init(allocator);
    errdefer {
        for (commands.items) |cmd| cmd.deinit(allocator);
        commands.deinit();
    }

    log.debug("readCommands: Starting to read commands", .{});

    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        log.debug("readCommands: Read line: '{s}'", .{line});

        if (std.mem.eql(u8, line, ".")) {
            log.debug("readCommands: Found end marker", .{});
            break;
        }

        if (std.mem.eql(u8, line, "open")) {
            log.debug("readCommands: Parsing open command", .{});
            const cmd = try parseOpenCommand(allocator, reader);
            try commands.append(cmd);
        } else if (line.len > 0) {
            log.warn("Unknown command: {s}", .{line});
        }
        // Silently ignore empty lines
    }

    log.debug("readCommands: Finished reading {d} commands", .{commands.items.len});
    return commands;
}

fn parseOpenCommand(allocator: std.mem.Allocator, reader: *std.Io.Reader) !OpenCommand {
    var cmd = OpenCommand{
        .display_name = undefined,
        .real_path = undefined,
        .token = undefined,
    };

    log.debug("parseOpenCommand: Starting to parse open command", .{});

    while (true) {
        const line = try reader.takeDelimiterExclusive('\n');

        log.debug("parseOpenCommand: Read line: '{s}'", .{line});

        if (line.len == 0) {
            log.debug("parseOpenCommand: Found empty line, ending variable parsing", .{});
            break; // Empty line ends variables
        }

        if (std.mem.indexOf(u8, line, ": ")) |sep_idx| {
            const key = line[0..sep_idx];
            const value = line[sep_idx + 2 ..];

            log.debug("parseOpenCommand: Found key='{s}', value='{s}'", .{ key, value });

            if (std.mem.eql(u8, key, "display-name")) {
                cmd.display_name = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "real-path")) {
                cmd.real_path = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "data-on-save")) {
                cmd.data_on_save = std.mem.eql(u8, value, "yes");
            } else if (std.mem.eql(u8, key, "re-activate")) {
                cmd.re_activate = std.mem.eql(u8, value, "yes");
            } else if (std.mem.eql(u8, key, "token")) {
                cmd.token = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "selection")) {
                cmd.selection = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "file-type")) {
                cmd.file_type = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "data")) {
                const size = try std.fmt.parseInt(usize, value, 10);
                log.debug("parseOpenCommand: Reading {d} bytes of data", .{size});
                cmd.data = try allocator.alloc(u8, size);
                try reader.readSliceAll(cmd.data.?);
                break;
            }
        }
    }

    log.debug("parseOpenCommand: Finished parsing open command", .{});
    return cmd;
}

pub fn writeSaveCommand(writer: *std.Io.Writer, token: []const u8, data: []const u8) !void {
    log.debug("writeSaveCommand: Writing save command for token: {s}, data length: {d}", .{ token, data.len });
    log.debug("writeSaveCommand: File content: '{s}'", .{data});

    try writer.writeAll("save\n");
    try writer.print("token: {s}\n", .{token});
    try writer.print("data: {d}\n", .{data.len});
    try writer.writeAll(data);
    try writer.writeAll("\n");

    log.debug("writeSaveCommand: Complete command sent", .{});
}

pub fn writeCloseCommand(writer: *std.Io.Writer, token: []const u8) !void {
    try writer.writeAll("close\n");
    try writer.print("token: {s}\n", .{token});
    try writer.writeAll("\n");
}

// Unit Tests
test "parse basic open command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\open
        \\display-name: test.txt
        \\real-path: /path/to/test.txt
        \\token: abc123
        \\
        \\.
        \\
    ;

    var r = std.Io.Reader.fixed(input);
    const commands = try parseCommands(allocator, &r);
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 1);

    const open_cmd = commands.items[0];
    try std.testing.expectEqualStrings("test.txt", open_cmd.display_name);
    try std.testing.expectEqualStrings("/path/to/test.txt", open_cmd.real_path);
    try std.testing.expectEqualStrings("abc123", open_cmd.token);
    try std.testing.expect(open_cmd.data_on_save == false);
    try std.testing.expect(open_cmd.re_activate == false);
    try std.testing.expect(open_cmd.selection == null);
    try std.testing.expect(open_cmd.file_type == null);
    try std.testing.expect(open_cmd.data == null);
}

test "parse open command with all fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build input with proper data section format
    const data_content = "{\"test\": \"file content\"}";
    var input_data = std.array_list.AlignedManaged(u8, null).init(std.testing.allocator);
    defer input_data.deinit();

    try input_data.appendSlice(std.testing.allocator, "open\n");
    try input_data.appendSlice(std.testing.allocator, "display-name: config.json\n");
    try input_data.appendSlice(std.testing.allocator, "real-path: /etc/config.json\n");
    try input_data.appendSlice(std.testing.allocator, "data-on-save: yes\n");
    try input_data.appendSlice(std.testing.allocator, "re-activate: yes\n");
    try input_data.appendSlice(std.testing.allocator, "token: xyz789\n");
    try input_data.appendSlice(std.testing.allocator, "selection: 1:5-2:10\n");
    try input_data.appendSlice(std.testing.allocator, "file-type: json\n");
    const header = try std.fmt.allocPrint(std.testing.allocator, "data: {d}\n", .{data_content.len});
    defer std.testing.allocator.free(header);
    try input_data.appendSlice(header);
    try input_data.appendSlice(std.testing.allocator, data_content);
    try input_data.appendSlice(std.testing.allocator, "\n.\n");

    var r = std.Io.Reader.fixed(input_data.items);
    const commands = try parseCommands(allocator, &r);
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 1);
    const open_cmd = commands.items[0];

    try std.testing.expectEqualStrings("config.json", open_cmd.display_name);
    try std.testing.expectEqualStrings("/etc/config.json", open_cmd.real_path);
    try std.testing.expectEqualStrings("xyz789", open_cmd.token);
    try std.testing.expect(open_cmd.data_on_save == true);
    try std.testing.expect(open_cmd.re_activate == true);
    try std.testing.expectEqualStrings("1:5-2:10", open_cmd.selection.?);
    try std.testing.expectEqualStrings("json", open_cmd.file_type.?);
    try std.testing.expectEqualStrings(data_content, open_cmd.data.?);
}

test "parse multiple commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\open
        \\display-name: file1.txt
        \\real-path: /path/file1.txt
        \\token: token1
        \\
        \\open
        \\display-name: file2.txt
        \\real-path: /path/file2.txt
        \\token: token2
        \\
        \\.
        \\
    ;

    var r = std.Io.Reader.fixed(input);
    const commands = try parseCommands(allocator, &r);
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 2);

    // Check first command (open)
    try std.testing.expectEqualStrings("token1", commands.items[0].token);

    // Check second command (open)
    try std.testing.expectEqualStrings("token2", commands.items[1].token);
}

test "parse empty command list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = ".\n";

    var stream = std.io.fixedBufferStream(input);
    const commands = try parseCommands(allocator, stream.reader().any());
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 0);
}

test "write save command" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeSaveCommand(&aw.writer, "test123", "file content here");

    const expected = "save\ntoken: test123\ndata: 17\nfile content here\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "write close command" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeCloseCommand(&aw.writer, "test456");

    const expected = "close\ntoken: test456\n\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "write save command with empty data" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeSaveCommand(&aw.writer, "empty", "");

    const expected = "save\ntoken: empty\ndata: 0\n\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "write save command with multiline data" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeSaveCommand(&aw.writer, "multiline", "line1\nline2\nline3");

    const expected = "save\ntoken: multiline\ndata: 17\nline1\nline2\nline3\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "parse open command with boolean fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\open
        \\display-name: test.txt
        \\real-path: /test.txt
        \\token: token1
        \\data-on-save: no
        \\re-activate: yes
        \\
        \\.
        \\
    ;

    var r = std.Io.Reader.fixed(input);
    const commands = try parseCommands(allocator, &r);
    defer commands.deinit();

    const open_cmd = commands.items[0];
    try std.testing.expect(open_cmd.data_on_save == false);
    try std.testing.expect(open_cmd.re_activate == true);
}

// removed save/close parse tests; we only parse open commands now

test "ignore unknown command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\unknown_command
        \\open
        \\display-name: test.txt
        \\real-path: /test.txt
        \\token: token1
        \\
        \\.
        \\
    ;

    var r = std.Io.Reader.fixed(input);
    const commands = try parseCommands(allocator, &r);
    defer commands.deinit();

    // Should have 1 command (open), unknown command should be ignored
    try std.testing.expect(commands.items.len == 1);
}
