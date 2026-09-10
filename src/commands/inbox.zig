const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) return list(context);
    if (std.mem.eql(u8, subcommand, "composition")) {
        var path = try query.Builder.init(context.allocator, "/mcp/inbox/composition");
        defer path.deinit();
        try path.add("project_id", try context.args.require("project"));
        return context.call(.GET, path.path(), null);
    }
    if (std.mem.eql(u8, subcommand, "archive") or std.mem.eql(u8, subcommand, "unarchive")) {
        if (context.args.positional.len < 3) return error.MissingArgument;
        const ids = context.args.positional[2..];
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.integers("notification_ids", ids);
        return context.call(.POST, if (std.mem.eql(u8, subcommand, "archive")) "/mcp/inbox/archive" else "/mcp/inbox/unarchive", try body.finish());
    }
    return error.UnknownCommand;
}

fn list(context: *const Context) !void {
    var response = try context.fetch(.GET, "/mcp/inbox/list", null);
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return context.finish(&response);
    if (context.request_recorder != null) return;

    if (context.json) {
        const body = try formatInboxJson(context.allocator, response.body);
        defer context.allocator.free(body);
        try context.print(body);
        return;
    }

    const body = try formatInboxTsv(context.allocator, response.body);
    defer context.allocator.free(body);
    try context.print(body);
}

/// Rebuild the inbox JSON so notification row arrays are present and listed
/// before tab/index metadata (which alone looks like an empty inbox).
fn formatInboxJson(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const root = parsed.value.object;
    const user_rows = notificationArray(root, "user_notifications") orelse
        notificationArray(root, "notifications");
    const agent_rows = notificationArray(root, "agent_notifications");
    if (user_rows == null and agent_rows == null) return error.InvalidResponse;

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.writeAll("{\"success\":");
    try writeJsonBool(writer, root.get("success"));
    try writer.writeAll(",\"user_notifications\":");
    if (user_rows) |rows| {
        try writeJsonValue(allocator, writer, rows.*);
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"agent_notifications\":");
    if (agent_rows) |rows| {
        try writeJsonValue(allocator, writer, rows.*);
    } else {
        try writer.writeAll("[]");
    }

    var iterator = root.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "success") or
            std.mem.eql(u8, key, "user_notifications") or
            std.mem.eql(u8, key, "agent_notifications") or
            std.mem.eql(u8, key, "notifications"))
        {
            continue;
        }
        try writer.writeByte(',');
        try json.writeString(writer, key);
        try writer.writeByte(':');
        try writeJsonValue(allocator, writer, entry.value_ptr.*);
    }
    try writer.writeByte('}');
    return out.toOwnedSlice(allocator);
}

fn formatInboxTsv(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const root = parsed.value.object;
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.writeAll("id\ttype\tticket\tproject\tcreatedAt\tseen\tstatus\n");

    if (notificationArray(root, "user_notifications") orelse notificationArray(root, "notifications")) |rows| {
        try writeNotificationRows(writer, rows.array.items);
    }
    if (notificationArray(root, "agent_notifications")) |rows| {
        try writeNotificationRows(writer, rows.array.items);
    }
    return out.toOwnedSlice(allocator);
}

fn writeNotificationRows(writer: anytype, rows: []const std.json.Value) !void {
    for (rows) |row| {
        if (row != .object) continue;
        const object = row.object;
        try writeJsonCell(writer, object.get("id"));
        try writer.writeByte('\t');
        try writeJsonCell(writer, object.get("type"));
        try writer.writeByte('\t');
        try writeTextCell(writer, ticketOf(object));
        try writer.writeByte('\t');
        try writeTextCell(writer, projectOf(object));
        try writer.writeByte('\t');
        try writeJsonCell(writer, object.get("createdAt") orelse object.get("created_at"));
        try writer.writeByte('\t');
        try writeTextCell(writer, seenOf(object));
        try writer.writeByte('\t');
        try writeJsonCell(writer, object.get("status"));
        try writer.writeByte('\n');
    }
}

fn notificationArray(root: std.json.ObjectMap, key: []const u8) ?*const std.json.Value {
    const value = root.getPtr(key) orelse return null;
    return if (value.* == .array) value else null;
}

fn ticketOf(object: std.json.ObjectMap) []const u8 {
    if (object.get("task")) |task| {
        if (task == .object) {
            if (textOf(task.object.get("ticketNumber"))) |ticket| {
                if (ticket.len != 0) return ticket;
            }
        }
    }
    return textOf(object.get("ticketNumber")) orelse "";
}

fn projectOf(object: std.json.ObjectMap) []const u8 {
    if (object.get("project")) |project| {
        if (project == .object) {
            if (textOf(project.object.get("title"))) |title| {
                if (title.len != 0) return title;
            }
            if (textOf(project.object.get("name"))) |name| {
                if (name.len != 0) return name;
            }
        }
    }
    return "";
}

fn seenOf(object: std.json.ObjectMap) []const u8 {
    const value = object.get("seen") orelse return "";
    return switch (value) {
        .bool => |seen| if (seen) "seen" else "unseen",
        else => textOf(value) orelse "",
    };
}

fn textOf(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .null => "",
        .string => |string| string,
        .number_string => |number| number,
        else => null,
    };
}

fn writeTextCell(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        try writer.writeByte(switch (byte) {
            '\t', '\r', '\n' => ' ',
            else => byte,
        });
    }
}

fn writeJsonCell(writer: anytype, value: ?std.json.Value) !void {
    const present = value orelse return;
    switch (present) {
        .null => {},
        .bool => |boolean| try writeTextCell(writer, if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .number_string => |number| try writeTextCell(writer, number),
        .string => |string| try writeTextCell(writer, string),
        .object, .array => {},
    }
}

fn writeJsonBool(writer: anytype, value: ?std.json.Value) !void {
    const present = value orelse {
        try writer.writeAll("true");
        return;
    };
    switch (present) {
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        else => try writer.writeAll("true"),
    }
}

fn writeJsonValue(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value) !void {
    const raw = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(raw);
    try writer.writeAll(raw);
}

test "inbox JSON puts notification rows before tab indexes" {
    const body =
        \\{"success":true,"user_structured_data":{"tabs":[{"idx":0}],"data":[[0]]},"user_notifications":[{"id":9,"type":"Comment","seen":false,"status":"Normal","createdAt":"2026-09-10T00:00:00.000Z","project":{"title":"Board"},"task":{"ticketNumber":"HTPR-1"}}],"agent_notifications":[]}
    ;
    const formatted = try formatInboxJson(std.testing.allocator, body);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\"user_notifications\":[") != null);
    const user_at = std.mem.indexOf(u8, formatted, "\"user_notifications\"").?;
    const structured_at = std.mem.indexOf(u8, formatted, "\"user_structured_data\"").?;
    try std.testing.expect(user_at < structured_at);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, formatted, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("user_notifications").?.array;
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(i64, 9), rows.items[0].object.get("id").?.integer);
}

test "inbox human mode prints one TSV row per notification" {
    const body =
        \\{"success":true,"user_structured_data":{"tabs":[{"idx":0}],"data":[[0]]},"user_notifications":[{"id":9,"type":"Comment","seen":false,"status":"Normal","createdAt":"2026-09-10T00:00:00.000Z","project":{"title":"Board"},"task":{"ticketNumber":"HTPR-1"}}],"agent_notifications":[{"id":3,"type":"Assigned","seen":true,"status":"Normal","createdAt":"2026-09-09T00:00:00.000Z","project":{"title":"Board"},"task":{"ticketNumber":"HTPR-2"}}]}
    ;
    const formatted = try formatInboxTsv(std.testing.allocator, body);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(
        "id\ttype\tticket\tproject\tcreatedAt\tseen\tstatus\n" ++
            "9\tComment\tHTPR-1\tBoard\t2026-09-10T00:00:00.000Z\tunseen\tNormal\n" ++
            "3\tAssigned\tHTPR-2\tBoard\t2026-09-09T00:00:00.000Z\tseen\tNormal\n",
        formatted,
    );
}
