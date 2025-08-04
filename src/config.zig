const std = @import("std");

const log = std.log.scoped(.rmate_config);

pub const Config = struct {
    default_editor: []const u8,
    port: u16,
    ip: []const u8,

    pub fn init() !Config {
        const editor = std.process.getEnvVarOwned(std.heap.page_allocator, "RMATE_EDITOR") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                log.err("RMATE_EDITOR environment variable is not set. Please set it to your preferred editor command (e.g., 'export RMATE_EDITOR=\"code --wait\"')", .{});
                return error.EditorNotConfigured;
            },
            else => return err,
        };

        const port: u16 = blk: {
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "RMATE_PORT")) |port_str| {
                defer std.heap.page_allocator.free(port_str);
                break :blk std.fmt.parseUnsigned(u16, port_str, 10) catch |err| {
                    log.warn("Invalid RMATE_PORT value '{s}', using default port 52698. Error: {}", .{ port_str, err });
                    break :blk 52698;
                };
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => break :blk 52698,
                else => return err,
            }
        };

        const ip = blk: {
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "RMATE_IP")) |ip_str| {
                break :blk ip_str;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    const default_ip = try std.heap.page_allocator.dupe(u8, "127.0.0.1");
                    break :blk default_ip;
                },
                else => return err,
            }
        };

        return .{
            .default_editor = editor,
            .port = port,
            .ip = ip,
        };
    }

    pub fn deinit(self: *Config) void {
        std.heap.page_allocator.free(self.default_editor);
        std.heap.page_allocator.free(self.ip);
    }

    pub fn getEditor(self: *const Config, hostname: []const u8, filepath: []const u8) []const u8 {
        _ = hostname;
        _ = filepath;
        return self.default_editor;
    }
};
