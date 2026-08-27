const std = @import("std");
const http = @import("http.zig");

pub fn print(body: []const u8) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try stdout.writeAll("\n");
}

pub fn finish(response: *http.Response) !void {
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) {
        try std.fs.File.stderr().writeAll(response.body);
        if (response.body.len == 0 or response.body[response.body.len - 1] != '\n') {
            try std.fs.File.stderr().writeAll("\n");
        }
        return error.CommandFailed;
    }
    try print(response.body);
}

pub fn fail(message: []const u8) noreturn {
    std.fs.File.stderr().writeAll(message) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}

pub fn failFmt(allocator: std.mem.Allocator, comptime format: []const u8, values: anytype) noreturn {
    const message = std.fmt.allocPrint(allocator, format, values) catch fail("error");
    defer allocator.free(message);
    fail(message);
}
