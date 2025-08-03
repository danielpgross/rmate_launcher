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
