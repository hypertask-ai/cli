const std = @import("std");

pub const BoardColumnRole = enum {
    intake,
    backlog,
    ready,
    @"in-progress",
    @"ai-review",
    @"human-review",
    done,
    other,
};

const KeywordRole = struct {
    role: BoardColumnRole,
    keywords: []const []const u8,
};

const ROLE_KEYWORDS = [_]KeywordRole{
    .{ .role = .intake, .keywords = &.{ "triage", "inbox", "intake" } },
    .{ .role = .backlog, .keywords = &.{ "backlog" } },
    .{ .role = .ready, .keywords = &.{ "ready" } },
    .{ .role = .@"in-progress", .keywords = &.{ "in progress", "doing", "wip" } },
    .{ .role = .@"ai-review", .keywords = &.{ "ai review" } },
    .{ .role = .@"human-review", .keywords = &.{ "valentin review", "review", "qa" } },
    .{ .role = .done, .keywords = &.{ "done", "complete", "shipped" } },
};

fn normalizedTitle(title: []const u8, dest: []u8) []const u8 {
    var used: usize = 0;
    if (used < dest.len) {
        dest[used] = ' ';
        used += 1;
    }
    for (title) |byte| {
        if (used >= dest.len - 1) break;
        const out: u8 = if (std.ascii.isAlphanumeric(byte)) std.ascii.toLower(byte) else ' ';
        if (used > 0 and dest[used - 1] == ' ' and out == ' ') continue;
        dest[used] = out;
        used += 1;
    }
    if (used < dest.len) {
        dest[used] = ' ';
        used += 1;
    }
    return dest[0..used];
}

pub fn columnRole(title: []const u8) BoardColumnRole {
    var buf: [256]u8 = undefined;
    const normalized = normalizedTitle(title, &buf);
    for (ROLE_KEYWORDS) |entry| {
        for (entry.keywords) |keyword| {
            var needle: [128]u8 = undefined;
            const pattern = blk: {
                var n: usize = 0;
                if (n < needle.len) {
                    needle[n] = ' ';
                    n += 1;
                }
                for (keyword) |byte| {
                    if (n >= needle.len) break;
                    needle[n] = byte;
                    n += 1;
                }
                if (n < needle.len) {
                    needle[n] = ' ';
                    n += 1;
                }
                break :blk needle[0..n];
            };
            if (std.mem.indexOf(u8, normalized, pattern) != null) return entry.role;
        }
    }
    return .other;
}

pub fn columnRoleFor(title: []const u8, is_done: ?bool) BoardColumnRole {
    if (is_done == true) return .done;
    const name_based = columnRole(title);
    if (is_done == false and name_based == .done) return .other;
    return name_based;
}

pub fn roleLabel(role: BoardColumnRole) []const u8 {
    return switch (role) {
        .intake => "intake",
        .backlog => "backlog",
        .ready => "ready",
        .@"in-progress" => "in-progress",
        .@"ai-review" => "ai-review",
        .@"human-review" => "human-review",
        .done => "done",
        .other => "other",
    };
}

pub fn isReviewRole(role: BoardColumnRole) bool {
    return role == .@"ai-review" or role == .@"human-review";
}

test "column roles match Hypertask board titles" {
    try std.testing.expectEqual(columnRoleFor("QA", false), .@"human-review");
    try std.testing.expectEqual(columnRoleFor("AI Review", false), .@"ai-review");
    try std.testing.expectEqual(columnRoleFor("Valentin Review", false), .@"human-review");
    try std.testing.expectEqual(columnRoleFor("In Progress", false), .@"in-progress");
    try std.testing.expect(isReviewRole(.@"ai-review"));
    try std.testing.expect(!isReviewRole(.@"in-progress"));
}
