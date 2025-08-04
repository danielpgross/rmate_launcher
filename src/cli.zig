const std = @import("std");
const build_options = @import("build_options");

pub fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("RMate Server {}\n", .{build_options.version});
    try stdout.print("A server implementation of the RMate protocol that allows editing remote files\n", .{});
    try stdout.print("using a local editor of the user's choice.\n\n", .{});

    try stdout.print("USAGE:\n", .{});
    try stdout.print("    rmate_server [OPTIONS]\n\n", .{});

    try stdout.print("OPTIONS:\n", .{});
    try stdout.print("    --help, -h    Show this help message and exit\n\n", .{});

    try stdout.print("ENVIRONMENT VARIABLES:\n", .{});
    try stdout.print("    RMATE_EDITOR  Editor command to use (REQUIRED)\n", .{});
    try stdout.print("                  The command will receive the temp file path as an argument\n", .{});
    try stdout.print("                  Example: export RMATE_EDITOR=\"code --wait\"\n", .{});
    try stdout.print("                  Example: export RMATE_EDITOR=\"vim\"\n\n", .{});

    try stdout.print("    RMATE_PORT    Port to listen on (default: 52698)\n", .{});
    try stdout.print("                  Example: export RMATE_PORT=52699\n\n", .{});

    try stdout.print("    RMATE_IP      IP address to bind to (default: 127.0.0.1)\n", .{});
    try stdout.print("                  Example: export RMATE_IP=0.0.0.0\n\n", .{});

    try stdout.print("HOW IT WORKS:\n", .{});
    try stdout.print("1. User opens remote file in SSH session using an RMate client\n", .{});
    try stdout.print("2. Client connects through SSH tunnel to RMate server running on local machine\n", .{});
    try stdout.print("3. RMate server saves file content to temporary file on disk\n", .{});
    try stdout.print("4. RMate server begins watching for changes to tempfile using OS-level file watching\n", .{});
    try stdout.print("5. RMate server spawns local editor process to edit the newly-created temporary file\n", .{});
    try stdout.print("6. On changes to the temp file, RMate server sends 'save' command to client\n", .{});
    try stdout.print("7. On close of the local editor process, RMate server sends 'close' command to client\n\n", .{});

    try stdout.print("The server supports multiple files opened concurrently.\n\n", .{});
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
