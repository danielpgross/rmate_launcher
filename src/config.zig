const std = @import("std");

const log = std.log.scoped(.rmate_config);

pub const Config = struct {
    allocator: std.mem.Allocator,
    default_editor: []const u8,
    // Network configuration - either Unix socket or TCP
    socket_path: ?[]const u8, // If present, use Unix socket
    port: ?u16, // If socket_path is null, use TCP with these
    ip: ?[]const u8, // If socket_path is null, use TCP with these
    base_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Config {
        const editor = std.process.getEnvVarOwned(allocator, "RMATE_EDITOR") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                log.err("RMATE_EDITOR environment variable is not set. Please set it to your preferred editor command (e.g., 'export RMATE_EDITOR=\"code --wait\"')", .{});
                return error.EditorNotConfigured;
            },
            else => return err,
        };

        const port: u16 = blk: {
            if (std.process.getEnvVarOwned(allocator, "RMATE_PORT")) |port_str| {
                defer allocator.free(port_str);
                break :blk std.fmt.parseUnsigned(u16, port_str, 10) catch |err| {
                    log.warn("Invalid RMATE_PORT value '{s}', using default port 52698. Error: {any}", .{ port_str, err });
                    break :blk 52698;
                };
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => break :blk 52698,
                else => return err,
            }
        };

        // Check if user explicitly wants TCP mode by setting RMATE_IP or RMATE_PORT
        const has_ip_config = if (std.process.getEnvVarOwned(allocator, "RMATE_IP")) |ip_test| blk: {
            allocator.free(ip_test);
            break :blk true;
        } else |_| false;

        const has_port_config = if (std.process.getEnvVarOwned(allocator, "RMATE_PORT")) |port_test| blk: {
            allocator.free(port_test);
            break :blk true;
        } else |_| false;

        const has_socket_config = if (std.process.getEnvVarOwned(allocator, "RMATE_SOCKET")) |sock_test| blk: {
            allocator.free(sock_test);
            break :blk true;
        } else |_| false;

        const use_tcp = (has_ip_config or has_port_config) and !has_socket_config;

        const socket_path = if (!use_tcp) blk: {
            break :blk std.process.getEnvVarOwned(allocator, "RMATE_SOCKET") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => try getDefaultSocketPath(allocator),
                else => return err,
            };
        } else null;

        const ip = if (use_tcp) blk: {
            const ip_val = std.process.getEnvVarOwned(allocator, "RMATE_IP") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => try allocator.dupe(u8, "127.0.0.1"),
                else => return err,
            };
            break :blk ip_val;
        } else null;

        if (socket_path) |path| {
            log.info("Using Unix socket: {s}", .{path});
        } else {
            log.info("Using TCP socket: {s}:{d}", .{ ip.?, port });
        }

        // Determine base directory for temp files
        const base_dir = blk: {
            if (std.process.getEnvVarOwned(allocator, "RMATE_BASE_DIR")) |bd| {
                break :blk bd;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
                    defer allocator.free(home);
                    break :blk try std.fmt.allocPrint(allocator, "{s}/.rmate_launcher", .{home});
                },
                else => return err,
            }
        };

        return .{
            .allocator = allocator,
            .default_editor = editor,
            .socket_path = socket_path,
            .port = if (use_tcp) port else null,
            .ip = ip,
            .base_dir = base_dir,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.default_editor);
        if (self.ip) |ip| {
            self.allocator.free(ip);
        }
        if (self.socket_path) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.base_dir);
    }

    pub fn isUnixSocket(self: *const Config) bool {
        return self.socket_path != null;
    }

    pub fn getDefaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/.rmate_launcher/rmate.sock", .{home});
    }

    pub fn getEditor(self: *const Config, hostname: []const u8, filepath: []const u8) []const u8 {
        _ = hostname;
        _ = filepath;
        return self.default_editor;
    }
};
