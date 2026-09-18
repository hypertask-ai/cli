const std = @import("std");
const args = @import("args.zig");
const query = @import("query.zig");

/// Shared HTPR-6530 list flags: --query, --filter, --sort, --fields, --limit, --cursor.
pub fn addListQuery(path: *query.Builder, parsed: *const args.Parsed, allocator: std.mem.Allocator) !void {
    if (parsed.get("query")) |value| try path.add("query", value);
    if (parsed.get("sort")) |value| try path.add("sort", value);
    if (parsed.get("fields")) |value| try path.add("fields", value);
    if (parsed.get("limit")) |value| try path.add("limit", value);
    if (parsed.get("cursor")) |value| try path.add("cursor", value);

    const filters = try parsed.getAll(allocator, "filter");
    defer allocator.free(filters);
    for (filters) |value| {
        if (value.len > 0 and value[0] == '{') {
            try path.add("filter", value);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidFilter;
        const key = value[0..eq];
        const filter_value = value[eq + 1 ..];
        if (key.len == 0 or filter_value.len == 0) return error.InvalidFilter;
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "filter.{s}", .{key});
        try path.add(name, filter_value);
    }
}

test "list query flags become shared query params" {
    var parsed = try args.parse(std.testing.allocator, &.{
        "hypertask",
        "tasks",
        "list",
        "--query",
        "review",
        "--filter",
        "section=AI Review",
        "--filter",
        "has_pr=red",
        "--fields",
        "title,url",
        "--sort",
        "updatedAt:desc",
        "--limit",
        "20",
        "--cursor",
        "abc",
    });
    defer parsed.deinit();
    var path = try query.Builder.init(std.testing.allocator, "/mcp/tasks");
    defer path.deinit();
    try addListQuery(&path, &parsed, std.testing.allocator);
    try std.testing.expectEqualStrings(
        "/mcp/tasks?query=review&sort=updatedAt%3Adesc&fields=title%2Curl&limit=20&cursor=abc&filter.section=AI%20Review&filter.has_pr=red",
        path.path(),
    );
}
