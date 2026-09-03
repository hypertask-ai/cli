const std = @import("std");
const json = @import("json_util.zig");

pub const default_api_url = "https://api.hypertask.ai/api";
const legacy_api_url = "https://app.hypertask.ai/api";

pub const TokenSource = enum {
    saved,
    environment,
    argument,
};

pub const Config = struct {
    token: []const u8 = "",
    token_source: TokenSource = .saved,
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

    pub fn replaceToken(self: *Config, token: []const u8) !void {
        try setOwned(self.allocator, &self.owned_token, &self.token, token);
        self.token_source = .saved;
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
    try loadFile(allocator, path, &result);

    if (std.mem.eql(u8, result.api_url, legacy_api_url)) {
        try setOwned(allocator, &result.owned_api_url, &result.api_url, default_api_url);
    }
    if (try applyEnvironmentVariable(allocator, &result.owned_token, &result.token, "HYPERTASKS_JWT_TOKEN")) result.token_source = .environment;
    if (try applyEnvironmentVariable(allocator, &result.owned_token, &result.token, "HT_AGENT_TOKEN")) result.token_source = .environment;
    if (try applyEnvironmentVariable(allocator, &result.owned_token, &result.token, "HT_TOKEN")) result.token_source = .environment;
    if (try environmentVariable(allocator, "HYPERTASK_MANAGEMENT_KEY")) |value| {
        defer allocator.free(value);
        try setOwned(allocator, &result.owned_management_key, &result.management_key, value);
    }
    _ = try applyEnvironmentVariable(allocator, &result.owned_api_url, &result.api_url, "HYPERTASKS_API_URL");
    if (token_override) |value| {
        try setOwned(allocator, &result.owned_token, &result.token, value);
        result.token_source = .argument;
    }
    if (management_override) |value| try setOwned(allocator, &result.owned_management_key, &result.management_key, value);
    if (api_url_override) |value| try setOwned(allocator, &result.owned_api_url, &result.api_url, value);

    while (result.api_url.len > 0 and result.api_url[result.api_url.len - 1] == '/') {
        const trimmed = result.api_url[0 .. result.api_url.len - 1];
        try setOwned(allocator, &result.owned_api_url, &result.api_url, trimmed);
    }
    if (result.token.len == 0) return error.NoToken;
    return result;
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, result: *Config) !void {
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    defer allocator.free(raw);
    const parsed = std.json.parseFromSlice(FileConfig, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    if (parsed.value.token) |value| try setOwned(allocator, &result.owned_token, &result.token, value);
    if (parsed.value.managementKey) |value| try setOwned(allocator, &result.owned_management_key, &result.management_key, value);
    if (parsed.value.apiUrl) |value| try setOwned(allocator, &result.owned_api_url, &result.api_url, value);
}

fn environmentVariable(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn applyEnvironmentVariable(allocator: std.mem.Allocator, owned: *?[]u8, target: *[]const u8, name: []const u8) !bool {
    const value = try environmentVariable(allocator, name);
    defer if (value) |present| allocator.free(present);
    return applyEnvironmentOverride(allocator, owned, target, value);
}

fn applyEnvironmentOverride(allocator: std.mem.Allocator, owned: *?[]u8, target: *[]const u8, value: ?[]const u8) !bool {
    const present = value orelse return false;
    if (present.len == 0) return false;
    try setOwned(allocator, owned, target, present);
    return true;
}

pub fn hasEnvironmentToken(allocator: std.mem.Allocator) !bool {
    for ([_][]const u8{ "HT_TOKEN", "HYPERTASKS_JWT_TOKEN" }) |name| {
        const value = try environmentVariable(allocator, name);
        defer if (value) |present| allocator.free(present);
        if (value) |present| if (present.len != 0) return true;
    }
    return false;
}

fn setOwned(allocator: std.mem.Allocator, owned: *?[]u8, target: *[]const u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    if (owned.*) |old| allocator.free(old);
    owned.* = replacement;
    target.* = replacement;
}

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try homeDirectory(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".hypertask", "config.json" });
}

fn homeDirectory(allocator: std.mem.Allocator) ![]u8 {
    for ([_][]const u8{ "HOME", "USERPROFILE" }) |name| {
        const value = try environmentVariable(allocator, name);
        if (value) |present| {
            if (present.len != 0) return present;
            allocator.free(present);
        }
    }
    return error.NoHome;
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
    const path = try configPath(allocator);
    defer allocator.free(path);
    const directory = std.fs.path.dirname(path) orelse return error.NoHome;
    try secureConfigDirectory(directory);
    try writeConfigFile(allocator, path, token, management_key, api_url);
}

fn secureConfigDirectory(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| if (err != error.PathAlreadyExists) return err;
    if (comptime std.fs.has_executable_bit) {
        var directory = try std.fs.openDirAbsolute(path, .{ .iterate = true, .no_follow = true });
        defer directory.close();
        try directory.chmod(0o700);
    }
}

fn writeConfigFile(allocator: std.mem.Allocator, path: []const u8, token: []const u8, management_key: []const u8, api_url: []const u8) !void {
    var object = try json.Object.init(allocator);
    defer object.deinit();
    if (token.len != 0) try object.string("token", token);
    if (management_key.len != 0) try object.string("managementKey", management_key);
    try object.string("apiUrl", api_url);
    const body = try object.finish();

    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ path, std.crypto.random.int(u64) });
    defer allocator.free(temporary_path);
    errdefer std.fs.deleteFileAbsolute(temporary_path) catch {};

    var file = try std.fs.cwd().createFile(temporary_path, .{ .exclusive = true, .mode = 0o600 });
    var file_open = true;
    defer if (file_open) file.close();
    if (comptime std.fs.has_executable_bit) try file.chmod(0o600);
    try file.writeAll(body);
    try file.writeAll("\n");
    try file.sync();
    file.close();
    file_open = false;
    try std.fs.renameAbsolute(temporary_path, path);
}

test "config file round trips saved values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "config.json" });
    defer std.testing.allocator.free(path);

    try writeConfigFile(std.testing.allocator, path, "saved-token", "management-key", "https://example.test/api");
    var loaded = Config{ .allocator = std.testing.allocator };
    defer loaded.deinit();
    try loadFile(std.testing.allocator, path, &loaded);

    try std.testing.expectEqualStrings("saved-token", loaded.token);
    try std.testing.expectEqualStrings("management-key", loaded.management_key);
    try std.testing.expectEqualStrings("https://example.test/api", loaded.api_url);
}

test "config writes repair permissive file and directory modes" {
    if (comptime !std.fs.has_executable_bit) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const directory_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".hypertask" });
    defer std.testing.allocator.free(directory_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "config.json" });
    defer std.testing.allocator.free(config_path);

    try std.fs.makeDirAbsolute(directory_path);
    var permissive_directory = try std.fs.openDirAbsolute(directory_path, .{ .iterate = true });
    try permissive_directory.chmod(0o777);
    permissive_directory.close();
    var permissive_file = try std.fs.cwd().createFile(config_path, .{ .mode = 0o666 });
    try permissive_file.chmod(0o666);
    permissive_file.close();

    try secureConfigDirectory(directory_path);
    try writeConfigFile(std.testing.allocator, config_path, "saved-token", "management-key", default_api_url);

    var secured_directory = try std.fs.openDirAbsolute(directory_path, .{ .iterate = true });
    defer secured_directory.close();
    const directory_stat = try secured_directory.stat();
    var secured_file = try std.fs.openFileAbsolute(config_path, .{});
    defer secured_file.close();
    const file_stat = try secured_file.stat();
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o700), directory_stat.mode & 0o777);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), file_stat.mode & 0o777);
}

test "environment overrides ignore empty values" {
    var owned: ?[]u8 = null;
    defer if (owned) |value| std.testing.allocator.free(value);
    var target: []const u8 = "saved";

    try std.testing.expect(!try applyEnvironmentOverride(std.testing.allocator, &owned, &target, ""));
    try std.testing.expectEqualStrings("saved", target);

    try std.testing.expect(try applyEnvironmentOverride(std.testing.allocator, &owned, &target, "replacement"));
    try std.testing.expectEqualStrings("replacement", target);
}
