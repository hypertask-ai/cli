const std = @import("std");
const json = @import("json_util.zig");

pub const default_api_url = "https://api.hypertask.ai/api";
const legacy_api_url = "https://app.hypertask.ai/api";

pub const Config = struct {
    token: []const u8 = "",
    management_key: []const u8 = "",
    api_url: []const u8 = default_api_url,
    allocator: std.mem.Allocator,
    owned_token: ?[]u8 = null,
    owned_management_key: ?[]u8 = null,
    owned_api_url: ?[]u8 = null,

    pub fn deinit(self: *Config) void {
        if (self.owned_token) |value| self.allocator.free(value);
        if (self.owned_management_key) |value| self.allocator.free(value);
        if (self.owned_api_url) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn requireToken(self: *const Config) !void {
        if (self.token.len == 0) {
            std.debug.print("no token: run `hypertask login --token <jwt>` or pass --token / HT_TOKEN\n", .{});
            return error.NoToken;
        }
    }

    pub fn managementToken(self: *const Config) []const u8 {
        return if (self.management_key.len != 0) self.management_key else self.token;
    }
};

const FileConfig = struct {
    token: ?[]const u8 = null,
    managementKey: ?[]const u8 = null,
    apiUrl: ?[]const u8 = null,
};

pub fn load(allocator: std.mem.Allocator, token_override: ?[]const u8, api_url_override: ?[]const u8, management_override: ?[]const u8) !Config {
    var result = Config{ .allocator = allocator };
    errdefer result.deinit();

    const path = try configPath(allocator);
    defer allocator.free(path);
    if (std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024)) |raw| {
        defer allocator.free(raw);
        const parsed = std.json.parseFromSlice(FileConfig, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch null;
        if (parsed) |document| {
            defer document.deinit();
            if (document.value.token) |value| try setOwned(allocator, &result.owned_token, &result.token, value);
            if (document.value.managementKey) |value| try setOwned(allocator, &result.owned_management_key, &result.management_key, value);
            if (document.value.apiUrl) |value| try setOwned(allocator, &result.owned_api_url, &result.api_url, value);
        }
    } else |_| {}

    if (std.mem.eql(u8, result.api_url, legacy_api_url)) {
        try setOwned(allocator, &result.owned_api_url, &result.api_url, default_api_url);
    }
    if (std.posix.getenv("HYPERTASKS_JWT_TOKEN")) |value| try setOwned(allocator, &result.owned_token, &result.token, value);
    if (std.posix.getenv("HT_TOKEN")) |value| try setOwned(allocator, &result.owned_token, &result.token, value);
    if (std.posix.getenv("HYPERTASK_MANAGEMENT_KEY")) |value| try setOwned(allocator, &result.owned_management_key, &result.management_key, value);
    if (std.posix.getenv("HYPERTASKS_API_URL")) |value| try setOwned(allocator, &result.owned_api_url, &result.api_url, value);
    if (token_override) |value| try setOwned(allocator, &result.owned_token, &result.token, value);
    if (management_override) |value| try setOwned(allocator, &result.owned_management_key, &result.management_key, value);
    if (api_url_override) |value| try setOwned(allocator, &result.owned_api_url, &result.api_url, value);

    while (result.api_url.len > 0 and result.api_url[result.api_url.len - 1] == '/') {
        const trimmed = result.api_url[0 .. result.api_url.len - 1];
        try setOwned(allocator, &result.owned_api_url, &result.api_url, trimmed);
    }
    if (result.token.len == 0) return error.NoToken;
    return result;
}

fn setOwned(allocator: std.mem.Allocator, owned: *?[]u8, target: *[]const u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    if (owned.*) |old| allocator.free(old);
    owned.* = replacement;
    target.* = replacement;
}

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".hypertask", "config.json" });
}

pub fn saveToken(allocator: std.mem.Allocator, token: []const u8, api_url: ?[]const u8) !void {
    var existing = try load(allocator, null, null, null);
    defer existing.deinit();
    try writeConfig(allocator, token, existing.management_key, api_url orelse existing.api_url);
}

pub fn saveManagementKey(allocator: std.mem.Allocator, management_key: []const u8) !void {
    var existing = try load(allocator, null, null, null);
    defer existing.deinit();
    try writeConfig(allocator, existing.token, management_key, existing.api_url);
}

pub fn clear(allocator: std.mem.Allocator) !void {
    try writeConfig(allocator, "", "", default_api_url);
}

fn writeConfig(allocator: std.mem.Allocator, token: []const u8, management_key: []const u8, api_url: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const directory = try std.fs.path.join(allocator, &.{ home, ".hypertask" });
    defer allocator.free(directory);
    std.fs.makeDirAbsolute(directory) catch |err| if (err != error.PathAlreadyExists) return err;
    const path = try configPath(allocator);
    defer allocator.free(path);

    var object = try json.Object.init(allocator);
    defer object.deinit();
    if (token.len != 0) try object.string("token", token);
    if (management_key.len != 0) try object.string("managementKey", management_key);
    try object.string("apiUrl", api_url);
    const body = try object.finish();

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(body);
    try file.writeAll("\n");
}
