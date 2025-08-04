const std = @import("std");
const log = std.log.scoped(.protocol);

pub const Command = union(enum) {
    open: OpenCommand,
    save: SaveCommand,
    close: CloseCommand,
};

pub const OpenCommand = struct {
    display_name: []u8,
    real_path: []u8,
    data_on_save: bool = false,
    re_activate: bool = false,
    token: []u8,
    selection: ?[]u8 = null,
    file_type: ?[]u8 = null,
    data: ?[]u8 = null,
};

pub const SaveCommand = struct {
    token: []u8,
    data: []u8,
};

pub const CloseCommand = struct {
    token: []u8,
};

pub const ProtocolParser = struct {
    allocator: std.mem.Allocator,
    reader: std.io.AnyReader,

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) ProtocolParser {
        return .{
            .allocator = allocator,
            .reader = reader,
        };
    }

    pub fn readCommands(self: *ProtocolParser) !std.ArrayList(Command) {
        var commands = std.ArrayList(Command).init(self.allocator);
        errdefer commands.deinit();

        log.debug("readCommands: Starting to read commands", .{});

        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);

            log.debug("readCommands: Read line: '{s}'", .{line});

            // Check for end marker
            if (std.mem.eql(u8, line, ".")) {
                log.debug("readCommands: Found end marker", .{});
                break;
            }

            // Parse command
            if (std.mem.eql(u8, line, "open")) {
                log.debug("readCommands: Parsing open command", .{});
                const cmd = try self.parseOpenCommand();
                try commands.append(.{ .open = cmd });
            } else if (std.mem.eql(u8, line, "save")) {
                log.debug("readCommands: Parsing save command", .{});
                const cmd = try self.parseSaveCommand();
                try commands.append(.{ .save = cmd });
            } else if (std.mem.eql(u8, line, "close")) {
                log.debug("readCommands: Parsing close command", .{});
                const cmd = try self.parseCloseCommand();
                try commands.append(.{ .close = cmd });
            } else {
                log.warn("Unknown command: {s}", .{line});
            }
        }

        log.debug("readCommands: Finished reading {} commands", .{commands.items.len});
        return commands;
    }

    fn readLine(self: *ProtocolParser) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        while (true) {
            const byte = try self.reader.readByte();
            if (byte == '\n') break;
            try buf.append(byte);
        }

        return try buf.toOwnedSlice();
    }

    fn parseOpenCommand(self: *ProtocolParser) !OpenCommand {
        var cmd = OpenCommand{
            .display_name = undefined,
            .real_path = undefined,
            .token = undefined,
        };

        log.debug("parseOpenCommand: Starting to parse open command", .{});

        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);

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
                    cmd.display_name = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "real-path")) {
                    cmd.real_path = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "data-on-save")) {
                    cmd.data_on_save = std.mem.eql(u8, value, "yes");
                } else if (std.mem.eql(u8, key, "re-activate")) {
                    cmd.re_activate = std.mem.eql(u8, value, "yes");
                } else if (std.mem.eql(u8, key, "token")) {
                    cmd.token = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "selection")) {
                    cmd.selection = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "file-type")) {
                    cmd.file_type = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "data")) {
                    const size = try std.fmt.parseInt(usize, value, 10);
                    log.debug("parseOpenCommand: Reading {} bytes of data", .{size});
                    cmd.data = try self.allocator.alloc(u8, size);
                    _ = try self.reader.readAll(cmd.data.?);
                    // After reading data, we expect an empty line to end the command
                    const empty_line = try self.readLine();
                    log.debug("parseOpenCommand: After data, read line: '{s}'", .{empty_line});
                    defer self.allocator.free(empty_line);
                    // The data section is always last, so break out of the parsing loop
                    break;
                }
            }
        }

        log.debug("parseOpenCommand: Finished parsing open command", .{});
        return cmd;
    }

    fn parseSaveCommand(self: *ProtocolParser) !SaveCommand {
        var cmd = SaveCommand{
            .token = undefined,
            .data = undefined,
        };

        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);

            if (line.len == 0) break;

            if (std.mem.indexOf(u8, line, ": ")) |sep_idx| {
                const key = line[0..sep_idx];
                const value = line[sep_idx + 2 ..];

                if (std.mem.eql(u8, key, "token")) {
                    cmd.token = try self.allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "data")) {
                    const size = try std.fmt.parseInt(usize, value, 10);
                    cmd.data = try self.allocator.alloc(u8, size);
                    _ = try self.reader.readAll(cmd.data);
                    _ = try self.readLine(); // Read trailing newline
                }
            }
        }

        return cmd;
    }

    fn parseCloseCommand(self: *ProtocolParser) !CloseCommand {
        var cmd = CloseCommand{
            .token = undefined,
        };

        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);

            if (line.len == 0) break;

            if (std.mem.indexOf(u8, line, ": ")) |sep_idx| {
                const key = line[0..sep_idx];
                const value = line[sep_idx + 2 ..];

                if (std.mem.eql(u8, key, "token")) {
                    cmd.token = try self.allocator.dupe(u8, value);
                }
            }
        }

        return cmd;
    }
};

pub const ProtocolWriter = struct {
    writer: std.io.AnyWriter,

    pub fn init(writer: std.io.AnyWriter) ProtocolWriter {
        return .{ .writer = writer };
    }

    pub fn writeSaveCommand(self: *ProtocolWriter, token: []const u8, data: []const u8) !void {
        log.debug("writeSaveCommand: Writing save command for token: {s}, data length: {d}", .{ token, data.len });
        log.debug("writeSaveCommand: File content: '{s}'", .{data});

        try self.writer.writeAll("save\n");
        try self.writer.print("token: {s}\n", .{token});
        try self.writer.print("data: {d}\n", .{data.len});
        try self.writer.writeAll(data);
        try self.writer.writeAll("\n");

        log.debug("writeSaveCommand: Complete command sent", .{});
    }

    pub fn writeCloseCommand(self: *ProtocolWriter, token: []const u8) !void {
        try self.writer.writeAll("close\n");
        try self.writer.print("token: {s}\n", .{token});
        try self.writer.writeAll("\n");
    }
};

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

    var stream = std.io.fixedBufferStream(input);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 1);
    try std.testing.expect(std.meta.activeTag(commands.items[0]) == .open);

    const open_cmd = commands.items[0].open;
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
    var input_data = std.ArrayList(u8).init(std.testing.allocator);
    defer input_data.deinit();

    try input_data.appendSlice("open\n");
    try input_data.appendSlice("display-name: config.json\n");
    try input_data.appendSlice("real-path: /etc/config.json\n");
    try input_data.appendSlice("data-on-save: yes\n");
    try input_data.appendSlice("re-activate: yes\n");
    try input_data.appendSlice("token: xyz789\n");
    try input_data.appendSlice("selection: 1:5-2:10\n");
    try input_data.appendSlice("file-type: json\n");
    try std.fmt.format(input_data.writer(), "data: {d}\n", .{data_content.len});
    try input_data.appendSlice(data_content);
    try input_data.appendSlice("\n\n.\n");

    var stream = std.io.fixedBufferStream(input_data.items);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 1);
    const open_cmd = commands.items[0].open;

    try std.testing.expectEqualStrings("config.json", open_cmd.display_name);
    try std.testing.expectEqualStrings("/etc/config.json", open_cmd.real_path);
    try std.testing.expectEqualStrings("xyz789", open_cmd.token);
    try std.testing.expect(open_cmd.data_on_save == true);
    try std.testing.expect(open_cmd.re_activate == true);
    try std.testing.expectEqualStrings("1:5-2:10", open_cmd.selection.?);
    try std.testing.expectEqualStrings("json", open_cmd.file_type.?);
    try std.testing.expectEqualStrings(data_content, open_cmd.data.?);
}

test "parse save command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\save
        \\token: abc123
        \\data: 12
        \\hello world!
        \\
        \\.
        \\
    ;

    var stream = std.io.fixedBufferStream(input);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 1);
    try std.testing.expect(std.meta.activeTag(commands.items[0]) == .save);

    const save_cmd = commands.items[0].save;
    try std.testing.expectEqualStrings("abc123", save_cmd.token);
    try std.testing.expectEqualStrings("hello world!", save_cmd.data);
}

test "parse close command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\close
        \\token: abc123
        \\
        \\.
        \\
    ;

    var stream = std.io.fixedBufferStream(input);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 1);
    try std.testing.expect(std.meta.activeTag(commands.items[0]) == .close);

    const close_cmd = commands.items[0].close;
    try std.testing.expectEqualStrings("abc123", close_cmd.token);
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
        \\save
        \\token: token2
        \\data: 5
        \\hello
        \\
        \\close
        \\token: token3
        \\
        \\.
        \\
    ;

    var stream = std.io.fixedBufferStream(input);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 3);

    // Check first command (open)
    try std.testing.expect(std.meta.activeTag(commands.items[0]) == .open);
    try std.testing.expectEqualStrings("token1", commands.items[0].open.token);

    // Check second command (save)
    try std.testing.expect(std.meta.activeTag(commands.items[1]) == .save);
    try std.testing.expectEqualStrings("token2", commands.items[1].save.token);
    try std.testing.expectEqualStrings("hello", commands.items[1].save.data);

    // Check third command (close)
    try std.testing.expect(std.meta.activeTag(commands.items[2]) == .close);
    try std.testing.expectEqualStrings("token3", commands.items[2].close.token);
}

test "parse empty command list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = ".\n";

    var stream = std.io.fixedBufferStream(input);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    try std.testing.expect(commands.items.len == 0);
}

test "write save command" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var writer = ProtocolWriter.init(buffer.writer().any());
    try writer.writeSaveCommand("test123", "file content here");

    const expected = "save\ntoken: test123\ndata: 17\nfile content here\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "write close command" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var writer = ProtocolWriter.init(buffer.writer().any());
    try writer.writeCloseCommand("test456");

    const expected = "close\ntoken: test456\n\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "write save command with empty data" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var writer = ProtocolWriter.init(buffer.writer().any());
    try writer.writeSaveCommand("empty", "");

    const expected = "save\ntoken: empty\ndata: 0\n\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "write save command with multiline data" {
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    var writer = ProtocolWriter.init(buffer.writer().any());
    try writer.writeSaveCommand("multiline", "line1\nline2\nline3");

    const expected = "save\ntoken: multiline\ndata: 17\nline1\nline2\nline3\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
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

    var stream = std.io.fixedBufferStream(input);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    const open_cmd = commands.items[0].open;
    try std.testing.expect(open_cmd.data_on_save == false);
    try std.testing.expect(open_cmd.re_activate == true);
}

test "parse save command with binary data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE };
    var input_data = std.ArrayList(u8).init(std.testing.allocator);
    defer input_data.deinit();

    try input_data.appendSlice("save\ntoken: binary\ndata: 5\n");
    try input_data.appendSlice(&binary_data);
    try input_data.appendSlice("\n\n.\n");

    var stream = std.io.fixedBufferStream(input_data.items);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    const save_cmd = commands.items[0].save;
    try std.testing.expectEqualStrings("binary", save_cmd.token);
    try std.testing.expectEqualSlices(u8, &binary_data, save_cmd.data);
}

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

    var stream = std.io.fixedBufferStream(input);
    var parser = ProtocolParser.init(allocator, stream.reader().any());

    const commands = try parser.readCommands();
    defer commands.deinit();

    // Should have 1 command (open), unknown command should be ignored
    try std.testing.expect(commands.items.len == 1);
    try std.testing.expect(std.meta.activeTag(commands.items[0]) == .open);
}
