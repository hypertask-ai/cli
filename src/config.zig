const std = @import("std");

pub const Config = struct {
    token: []const u8,
    api_url: []const u8,
    owned_token: ?[]u8 = null,
    owned_api_url: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        if (self.owned_token) |t| self.allocator.free(t);
        if (self.owned_api_url) |u| self.allocator.free(u);
        self.* = undefined;
    }
};

const FileConfig = struct {
    token: ?[]const u8 = null,
    apiUrl: ?[]const u8 = null,
};

pub fn load(allocator: std.mem.Allocator, token_override: ?[]const u8, api_url_override: ?[]const u8) !Config {
    var cfg = Config{
        .token = "",
        .api_url = "https://api.hypertask.ai/api",
        .allocator = allocator,
    };

    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try std.fs.path.join(allocator, &.{ home, ".hypertask", "config.json" });
    defer allocator.free(path);

    if (std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024)) |raw| {
        defer allocator.free(raw);
        const parsed = try std.json.parseFromSlice(FileConfig, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        if (parsed.value.token) |t| {
            cfg.owned_token = try allocator.dupe(u8, t);
            cfg.token = cfg.owned_token.?;
        }
        if (parsed.value.apiUrl) |u| {
            cfg.owned_api_url = try allocator.dupe(u8, u);
            cfg.api_url = cfg.owned_api_url.?;
        }
    } else |_| {}

    if (std.posix.getenv("HT_TOKEN")) |t| {
        if (cfg.owned_token) |old| allocator.free(old);
        cfg.owned_token = try allocator.dupe(u8, t);
        cfg.token = cfg.owned_token.?;
    } else if (std.posix.getenv("HYPERTASKS_JWT_TOKEN")) |t| {
        if (cfg.owned_token) |old| allocator.free(old);
        cfg.owned_token = try allocator.dupe(u8, t);
        cfg.token = cfg.owned_token.?;
    }

    if (std.posix.getenv("HYPERTASKS_API_URL")) |u| {
        if (cfg.owned_api_url) |old| allocator.free(old);
        cfg.owned_api_url = try allocator.dupe(u8, u);
        cfg.api_url = cfg.owned_api_url.?;
    }

    if (token_override) |t| {
        if (cfg.owned_token) |old| allocator.free(old);
        cfg.owned_token = try allocator.dupe(u8, t);
        cfg.token = cfg.owned_token.?;
    }
    if (api_url_override) |u| {
        if (cfg.owned_api_url) |old| allocator.free(old);
        cfg.owned_api_url = try allocator.dupe(u8, u);
        cfg.api_url = cfg.owned_api_url.?;
    }

    if (cfg.token.len == 0) return error.NoToken;
    // strip trailing slash
    while (std.mem.endsWith(u8, cfg.api_url, "/")) {
        if (cfg.owned_api_url) |owned| {
            cfg.owned_api_url = try allocator.realloc(owned, owned.len - 1);
            cfg.api_url = cfg.owned_api_url.?;
        } else break;
    }
    return cfg;
}
