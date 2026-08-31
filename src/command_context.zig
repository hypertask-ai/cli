const std = @import("std");
const args = @import("args.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const output = @import("output.zig");

pub const RequestRecorder = struct {
    allocator: std.mem.Allocator,
    method: ?std.http.Method = null,
    path: ?[]u8 = null,
    body: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) RequestRecorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RequestRecorder) void {
        if (self.path) |value| self.allocator.free(value);
        if (self.body) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn fetch(self: *RequestRecorder, method: std.http.Method, path: []const u8, body: ?[]const u8) !http.Response {
        const next_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(next_path);
        const next_body = if (body) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (next_body) |value| self.allocator.free(value);
        const response_body = try self.allocator.dupe(u8, "{}");
        errdefer self.allocator.free(response_body);

        if (self.path) |value| self.allocator.free(value);
        if (self.body) |value| self.allocator.free(value);
        self.method = method;
        self.path = next_path;
        self.body = next_body;
        return .{
            .status = .ok,
            .body = response_body,
            .allocator = self.allocator,
        };
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    args: *const args.Parsed,
    cfg: *const config.Config,
    json: bool,
    request_recorder: ?*RequestRecorder = null,

    pub fn requireAuth(self: *const Context) !void {
        try self.cfg.requireToken();
    }

    pub fn print(self: *const Context, body: []const u8) !void {
        if (self.request_recorder != null) return;
        try output.printResponse(self.allocator, body, self.json);
    }

    pub fn finish(self: *const Context, response: *http.Response) !void {
        if (self.request_recorder != null) {
            const code = @intFromEnum(response.status);
            if (code < 200 or code >= 300) return error.CommandFailed;
            return;
        }
        try output.finishResponse(self.allocator, response, self.json);
    }

    pub fn call(self: *const Context, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
        var response = try self.fetch(method, path, body);
        defer response.deinit();
        try self.finish(&response);
    }

    pub fn fetch(self: *const Context, method: std.http.Method, path: []const u8, body: ?[]const u8) !http.Response {
        try self.requireAuth();
        if (self.request_recorder) |recorder| return recorder.fetch(method, path, body);
        return http.request(self.allocator, self.cfg, method, path, body);
    }

    pub fn callWithToken(self: *const Context, token: []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
        if (token.len == 0) return error.NoToken;
        var response = try http.requestWithToken(self.allocator, self.cfg.api_url, token, method, path, body);
        defer response.deinit();
        try self.finish(&response);
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
