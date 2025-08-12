const std = @import("std");
const build_options = @import("build_options");

pub fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("RMate Launcher {}\n", .{build_options.version});
    try stdout.writeAll(@embedFile("help.txt"));
}

pub fn parseArgs(allocator: std.mem.Allocator) !bool {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for help flag
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return true; // indicates help was shown, should exit
        }
    }

    return false; // continue normal execution
}
