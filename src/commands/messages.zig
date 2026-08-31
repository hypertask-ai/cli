const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;

const Message = struct {
    id: i64,
    value: std.json.Value,
};

const PollResult = struct {
    success: bool = true,
    messages: []const std.json.Value,
    next_cursor: i64,
};

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (!std.mem.eql(u8, subcommand, "poll")) return error.UnknownCommand;

    const since = try common.int(context.args.get("since") orelse "0", "since");
    if (since < 0) {
        std.debug.print("since must be a non-negative integer\n", .{});
        return error.InvalidInteger;
    }

    var response = try context.fetch(.GET, "/mcp/inbox/list", null);
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return context.finish(&response);
    if (context.request_recorder != null) return;

    const result = try pollResponse(context.allocator, response.body, since);
    defer context.allocator.free(result);
    try context.print(result);
}

fn pollResponse(allocator: std.mem.Allocator, body: []const u8, since: i64) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const root = parsed.value.object;
    const notifications = root.get("agent_notifications") orelse
        root.get("user_notifications") orelse return error.InvalidResponse;
    if (notifications != .array) return error.InvalidResponse;

    var selected: std.ArrayListUnmanaged(Message) = .{};
    defer selected.deinit(allocator);
    var next_cursor = since;
    for (notifications.array.items) |notification| {
        const id = try notificationId(notification);
        next_cursor = @max(next_cursor, id);
        if (id > since) try selected.append(allocator, .{ .id = id, .value = notification });
    }
    std.mem.sort(Message, selected.items, {}, struct {
        fn lessThan(_: void, left: Message, right: Message) bool {
            return left.id < right.id;
        }
    }.lessThan);

    const messages = try allocator.alloc(std.json.Value, selected.items.len);
    defer allocator.free(messages);
    for (selected.items, 0..) |message, index| messages[index] = message.value;

    return std.json.Stringify.valueAlloc(allocator, PollResult{
        .messages = messages,
        .next_cursor = next_cursor,
    }, .{});
}

fn notificationId(notification: std.json.Value) !i64 {
    if (notification != .object) return error.InvalidResponse;
    const value = notification.object.get("id") orelse return error.InvalidResponse;
    const id = switch (value) {
        .integer => |integer| integer,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch return error.InvalidResponse,
        .string => |string| std.fmt.parseInt(i64, string, 10) catch return error.InvalidResponse,
        else => return error.InvalidResponse,
    };
    return id;
}

test "poll selects the agent boundary and returns an ascending cursor window" {
    const result = try pollResponse(std.testing.allocator,
        \\{"success":true,"user_notifications":[{"id":101,"type":"Mentioned"}],"agent_notifications":[{"id":"13","type":"Assigned"},{"id":10,"type":"Mentioned"},{"id":"-35688","type":"Synthetic"},{"id":12,"type":"Comment"}]}
    , 10);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\{"success":true,"messages":[{"id":12,"type":"Comment"},{"id":"13","type":"Assigned"}],"next_cursor":13}
    , result);
}

test "poll falls back to the user boundary when no agent stream exists" {
    const result = try pollResponse(std.testing.allocator,
        \\{"success":true,"user_notifications":[{"id":21,"type":"Mentioned"}]}
    , 0);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\{"success":true,"messages":[{"id":21,"type":"Mentioned"}],"next_cursor":21}
    , result);
}
