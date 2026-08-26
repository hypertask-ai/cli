const std = @import("std");
const config_mod = @import("config.zig");

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn request(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    method: std.http.Method,
    path_and_query: []const u8,
    body: ?[]const u8,
) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ cfg.api_url, path_and_query });
    defer allocator.free(url);

    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.token});
    defer allocator.free(auth);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var headers_buf: [2]std.http.Header = undefined;
    var header_count: usize = 1;
    headers_buf[0] = .{ .name = "Authorization", .value = auth };
    if (body != null) {
        headers_buf[1] = .{ .name = "Content-Type", .value = "application/json" };
        header_count = 2;
    }

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .extra_headers = headers_buf[0..header_count],
        .response_writer = &aw.writer,
    });

    const copied = try allocator.dupe(u8, aw.written());
    return .{
        .status = result.status,
        .body = copied,
        .allocator = allocator,
    };
}

pub fn get(allocator: std.mem.Allocator, cfg: *const config_mod.Config, path_and_query: []const u8) !Response {
    return request(allocator, cfg, .GET, path_and_query, null);
}

pub fn post(allocator: std.mem.Allocator, cfg: *const config_mod.Config, path: []const u8, body: []const u8) !Response {
    return request(allocator, cfg, .POST, path, body);
}
