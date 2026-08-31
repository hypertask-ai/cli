const std = @import("std");

pub const Option = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// A small Commander-compatible parser. It preserves repeated options and lets
/// global options appear before or after a subcommand.
pub const Parsed = struct {
    positional: []const []const u8,
    options: []const Option,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.positional);
        self.allocator.free(self.options);
        self.* = undefined;
    }

    pub fn has(self: *const Parsed, name: []const u8) bool {
        for (self.options) |option| {
            if (std.mem.eql(u8, option.name, name)) return true;
        }
        return false;
    }

    /// Return the last value, matching Commander's behavior for ordinary
    /// single-value options.
    pub fn get(self: *const Parsed, name: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.options) |option| {
            if (std.mem.eql(u8, option.name, name) and option.value != null) {
                result = option.value;
            }
        }
        return result;
    }

    pub fn count(self: *const Parsed, name: []const u8) usize {
        var result: usize = 0;
        for (self.options) |option| {
            if (std.mem.eql(u8, option.name, name) and option.value != null) result += 1;
        }
        return result;
    }

    pub fn getAll(self: *const Parsed, allocator: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var values: std.ArrayListUnmanaged([]const u8) = .{};
        for (self.options) |option| {
            if (std.mem.eql(u8, option.name, name)) {
                if (option.value) |value| try values.append(allocator, value);
            }
        }
        return values.toOwnedSlice(allocator);
    }

    pub fn require(self: *const Parsed, name: []const u8) ![]const u8 {
        return self.get(name) orelse return missingOption(name);
    }

    pub fn positionalAt(self: *const Parsed, index: usize) ?[]const u8 {
        return if (index < self.positional.len) self.positional[index] else null;
    }

    pub fn requirePositional(self: *const Parsed, index: usize, label: []const u8) ![]const u8 {
        return self.positionalAt(index) orelse return missingArgument(label);
    }
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Parsed {
    var positional: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer positional.deinit(allocator);
    var options: std.ArrayListUnmanaged(Option) = .{};
    errdefer options.deinit(allocator);

    var i: usize = 0;
    var positional_only = false;
    while (i < argv.len) : (i += 1) {
        const value = argv[i];
        if (positional_only or !std.mem.startsWith(u8, value, "-") or std.mem.eql(u8, value, "-") or isNegativeInteger(value)) {
            try positional.append(allocator, value);
            continue;
        }
        if (std.mem.eql(u8, value, "--")) {
            positional_only = true;
            continue;
        }

        const prefix_len: usize = if (std.mem.startsWith(u8, value, "--")) 2 else 1;
        const raw = value[prefix_len..];
        if (std.mem.indexOfScalar(u8, raw, '=')) |equals| {
            try options.append(allocator, .{
                .name = canonicalName(raw[0..equals]),
                .value = raw[equals + 1 ..],
            });
            continue;
        }

        const name = canonicalName(raw);
        if (isBoolean(name)) {
            try options.append(allocator, .{ .name = name, .value = null });
            continue;
        }
        if (i + 1 >= argv.len) return missingOptionValue(name);
        i += 1;
        try options.append(allocator, .{ .name = name, .value = argv[i] });
    }

    return .{
        .positional = try positional.toOwnedSlice(allocator),
        .options = try options.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn isNegativeInteger(value: []const u8) bool {
    if (value.len < 2 or value[0] != '-') return false;
    for (value[1..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn canonicalName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "h")) return "help";
    if (std.mem.eql(u8, name, "V")) return "version";
    return name;
}

fn isBoolean(name: []const u8) bool {
    const names = [_][]const u8{
        "help",              "version",   "json",         "human",
        "force",             "all",       "all-boards",   "enabled",
        "disabled",          "confirm",   "clear",        "restore",
        "stdin",             "off",       "has-due-date", "summary",
        "markdown",          "clear-due", "clear-parent", "comment",
        "html",              "canvas",    "dry-run",      "apply",
        "clear-description", "running",   "default",      "clear-labels",
        "clear-assignees",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn missingOption(name: []const u8) error{MissingOption} {
    std.debug.print("required option: --{s}\n", .{name});
    return error.MissingOption;
}

fn missingOptionValue(name: []const u8) error{MissingOptionValue} {
    std.debug.print("missing value for --{s}\n", .{name});
    return error.MissingOptionValue;
}

fn missingArgument(label: []const u8) error{MissingArgument} {
    std.debug.print("required argument: {s}\n", .{label});
    return error.MissingArgument;
}

test "parse repeated and global options" {
    const argv = [_][]const u8{ "task", "list", "--label", "bug", "--label=urgent", "--json" };
    var parsed = try parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.positional.len);
    try std.testing.expectEqualStrings("urgent", parsed.get("label").?);
    try std.testing.expectEqual(@as(usize, 2), parsed.count("label"));
    try std.testing.expect(parsed.has("json"));
}

test "negative integers remain positional arguments" {
    const argv = [_][]const u8{ "time", "log", "RINT-32", "-30" };
    var parsed = try parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.positional.len);
    try std.testing.expectEqualStrings("-30", parsed.positional[3]);
}
