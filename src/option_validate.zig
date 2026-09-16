const std = @import("std");
const args_mod = @import("args.zig");

const catalog_source = @embedFile("capabilities.json");

const CapabilityOption = struct {
    flags: []const u8,
};

const Capability = struct {
    name: []const u8 = "",
    aliases: []const []const u8 = &.{},
    options: []const CapabilityOption = &.{},
    commands: []const Capability = &.{},
};

const global_flag_names = [_][]const u8{
    "api-url", "help", "human", "json", "token", "version",
};

/// Reject options that the matched command (and globals) do not declare.
/// HTPR-6449: unknown flags used to be ignored with exit 0.
/// HTPR-6480: the error also lists the flags that command accepts.
pub fn rejectUnknownOptions(allocator: std.mem.Allocator, parsed: *const args_mod.Parsed) !void {
    const catalog = try std.json.parseFromSlice(Capability, allocator, catalog_source, .{ .ignore_unknown_fields = true });
    defer catalog.deinit();

    var allowed: std.StringHashMapUnmanaged(void) = .{};
    defer allowed.deinit(allocator);
    var command_flags: std.StringHashMapUnmanaged(void) = .{};
    defer command_flags.deinit(allocator);

    try allowName(&allowed, allocator, "help");
    try allowName(&allowed, allocator, "human");
    try addOptions(&allowed, allocator, catalog.value.options);

    var node: *const Capability = &catalog.value;
    var index: usize = 0;
    while (index < parsed.positional.len) : (index += 1) {
        const token = parsed.positional[index];
        const child = findChild(node, token) orelse break;
        node = child;
        try addOptions(&allowed, allocator, child.options);
        try addLongOptions(&command_flags, allocator, child.options);
        if (child.commands.len == 0) break;
    }

    for (parsed.options) |option| {
        if (allowed.contains(option.name)) continue;
        return unknownOption(allocator, option.name, &command_flags);
    }
}

fn findChild(parent: *const Capability, token: []const u8) ?*const Capability {
    for (parent.commands) |*child| {
        if (std.mem.eql(u8, child.name, token)) return child;
        for (child.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return child;
        }
    }
    return null;
}

fn addOptions(allowed: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator, options: []const CapabilityOption) !void {
    for (options) |option| {
        var parts = std.mem.splitScalar(u8, option.flags, ',');
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (std.mem.startsWith(u8, part, "--")) {
                try allowName(allowed, allocator, longOptionName(part[2..]));
            } else if (std.mem.startsWith(u8, part, "-") and part.len == 2) {
                try allowName(allowed, allocator, part[1..]);
                if (part[1] == 'V') try allowName(allowed, allocator, "version");
                if (part[1] == 'h') try allowName(allowed, allocator, "help");
            }
        }
    }
}

fn addLongOptions(allowed: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator, options: []const CapabilityOption) !void {
    for (options) |option| {
        var parts = std.mem.splitScalar(u8, option.flags, ',');
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (std.mem.startsWith(u8, part, "--")) {
                try allowName(allowed, allocator, longOptionName(part[2..]));
            }
        }
    }
}

fn longOptionName(raw: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, raw, " \t<")) |end| return raw[0..end];
    return raw;
}

fn allowName(allowed: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator, name: []const u8) !void {
    try allowed.put(allocator, name, {});
}

fn flagNameLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn formatAcceptedFlags(allocator: std.mem.Allocator, command_flags: *const std.StringHashMapUnmanaged(void)) ![]u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    defer names.deinit(allocator);
    if (command_flags.count() == 0) {
        for (global_flag_names) |name| try names.append(allocator, name);
    } else {
        var it = command_flags.keyIterator();
        while (it.next()) |key| try names.append(allocator, key.*);
    }
    std.mem.sort([]const u8, names.items, {}, flagNameLessThan);

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "accepted flags: ");
    for (names.items, 0..) |name, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try out.writer(allocator).print("--{s}", .{name});
    }
    return out.toOwnedSlice(allocator);
}

fn unknownOption(
    allocator: std.mem.Allocator,
    name: []const u8,
    command_flags: *const std.StringHashMapUnmanaged(void),
) error{ UnknownOption, OutOfMemory } {
    const accepted = try formatAcceptedFlags(allocator, command_flags);
    defer allocator.free(accepted);
    std.debug.print("unknown option: --{s}\n{s}\n", .{ name, accepted });
    return error.UnknownOption;
}

test "agents get --id is a known option" {
    const argv = [_][]const u8{ "agents", "get", "--id", "agent-1" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try rejectUnknownOptions(std.testing.allocator, &parsed);
}

test "unknown option on task get is rejected" {
    const argv = [_][]const u8{ "task", "get", "HYFA-70", "--zzznotaflag", "9" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectError(error.UnknownOption, rejectUnknownOptions(std.testing.allocator, &parsed));
}

test "project is rejected on task assign" {
    const argv = [_][]const u8{ "task", "assign", "HTPR-1", "--assignee", "6", "--project", "15" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectError(error.UnknownOption, rejectUnknownOptions(std.testing.allocator, &parsed));
}

test "project is rejected on task move" {
    const argv = [_][]const u8{ "task", "move", "HYFA-70", "--section", "In Progress", "--project", "5156" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectError(error.UnknownOption, rejectUnknownOptions(std.testing.allocator, &parsed));
}

test "accepted flags lists the command options in order" {
    var flags: std.StringHashMapUnmanaged(void) = .{};
    defer flags.deinit(std.testing.allocator);
    try flags.put(std.testing.allocator, "to-section", {});
    try flags.put(std.testing.allocator, "section", {});
    try flags.put(std.testing.allocator, "to", {});
    const line = try formatAcceptedFlags(std.testing.allocator, &flags);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("accepted flags: --section, --to, --to-section", line);
}

test "accepted flags falls back to globals when the command has none" {
    var flags: std.StringHashMapUnmanaged(void) = .{};
    defer flags.deinit(std.testing.allocator);
    const line = try formatAcceptedFlags(std.testing.allocator, &flags);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "accepted flags: --api-url, --help, --human, --json, --token, --version",
        line,
    );
}

test "tasks list --labels is a known option" {
    const argv = [_][]const u8{ "tasks", "list", "--project", "15", "--labels", "CLI" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try rejectUnknownOptions(std.testing.allocator, &parsed);
}

test "known options and aliases still pass" {
    const argv = [_][]const u8{ "tasks", "show", "HTPR-1", "--project", "15", "--json" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try rejectUnknownOptions(std.testing.allocator, &parsed);
}

test "global human is allowed" {
    const argv = [_][]const u8{ "status", "--human" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try rejectUnknownOptions(std.testing.allocator, &parsed);
}

test "unknown option is rejected even with only globals present" {
    const argv = [_][]const u8{ "--zzznotaflag", "x" };
    var parsed = try args_mod.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectError(error.UnknownOption, rejectUnknownOptions(std.testing.allocator, &parsed));
}
