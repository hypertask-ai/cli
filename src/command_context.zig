const std = @import("std");
const args = @import("args.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const output = @import("output.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    args: *const args.Parsed,
    cfg: *const config.Config,
    json: bool,

    pub fn requireAuth(self: *const Context) !void {
        try self.cfg.requireToken();
    }

    pub fn call(self: *const Context, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
        var response = try self.fetch(method, path, body);
        defer response.deinit();
        try output.finish(&response);
    }

    pub fn fetch(self: *const Context, method: std.http.Method, path: []const u8, body: ?[]const u8) !http.Response {
        try self.requireAuth();
        return http.request(self.allocator, self.cfg, method, path, body);
    }

    pub fn callWithToken(self: *const Context, token: []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
        if (token.len == 0) return error.NoToken;
        var response = try http.requestWithToken(self.allocator, self.cfg.api_url, token, method, path, body);
        defer response.deinit();
        try output.finish(&response);
    }
};

pub fn int(value: []const u8, label: []const u8) !i64 {
    const parsed = std.fmt.parseInt(i64, value, 10) catch {
        std.debug.print("invalid integer for {s}: {s}\n", .{ label, value });
        return error.InvalidInteger;
    };
    return parsed;
}

pub fn positiveInt(value: []const u8, label: []const u8) !i64 {
    const parsed = try int(value, label);
    if (parsed <= 0) {
        std.debug.print("{s} must be a positive integer\n", .{label});
        return error.InvalidInteger;
    }
    return parsed;
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, limit) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// Expand repeated comma-separated options into one slice.
pub fn optionList(context: *const Context, name: []const u8) ![]const []const u8 {
    const repeated = try context.args.getAll(context.allocator, name);
    var result: std.ArrayListUnmanaged([]const u8) = .{};
    for (repeated) |entry| {
        var pieces = std.mem.splitScalar(u8, entry, ',');
        while (pieces.next()) |piece| {
            const trimmed = std.mem.trim(u8, piece, " \t\r\n");
            if (trimmed.len != 0) try result.append(context.allocator, trimmed);
        }
    }
    return result.toOwnedSlice(context.allocator);
}

pub fn managementToken(context: *const Context) []const u8 {
    return context.args.get("management-key") orelse context.cfg.managementToken();
}
