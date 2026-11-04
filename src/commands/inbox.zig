const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) {
        if (context.args.has("waiting-on") or context.args.has("user")) return blockers(context);
        if (context.args.has("project") or context.args.has("state")) return error.InvalidOptions;
        return list(context);
    }
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

pub fn blockers(context: *const Context) !void {
    const explicit_users = try context.args.getAll(context.allocator, "user");
    defer context.allocator.free(explicit_users);
    const users = try context.args.getAll(context.allocator, "waiting-on");
    defer context.allocator.free(users);
    if (users.len + explicit_users.len > 1) return error.InvalidOptions;
    for (explicit_users) |user| {
        if (!std.mem.eql(u8, user, "me")) try validateId(user, "--user");
    }
    for (users) |user| {
        if (!std.mem.eql(u8, user, "me")) try validateId(user, "--waiting-on");
    }
    const projects = try context.args.getAll(context.allocator, "project");
    defer context.allocator.free(projects);
    for (projects) |project| try validateId(project, "--project");
    const states = try context.args.getAll(context.allocator, "state");
    defer context.allocator.free(states);
    if (states.len > 1) return error.InvalidOptions;
    for (states) |state| {
        if (!std.mem.eql(u8, state, "waiting") and !std.mem.eql(u8, state, "answered") and !std.mem.eql(u8, state, "no-question")) {
            std.debug.print("--state must be waiting, answered, or no-question\n", .{});
            return error.InvalidOptions;
        }
    }

    var path = try query.Builder.init(context.allocator, "/mcp/inbox/blockers");
    defer path.deinit();
    try path.add("user", context.args.get("user") orelse context.args.get("waiting-on") orelse "me");
    for (projects) |project| try path.add("projectId", project);
    if (context.args.get("state")) |state| try path.add("state", state);

    var response = try context.fetchRaw(.GET, path.path(), null);
    defer response.deinit();
    if (!response.isSuccess() or @import("../output.zig").responseReportsFailure(context.allocator, response.body) or context.json) return context.finish(&response);
    if (context.request_recorder != null) return;
    const body = try formatBlockers(context.allocator, response.body);
    defer context.allocator.free(body);
    try context.print(body);
}

fn validateId(value: []const u8, label: []const u8) !void {
    if (value.len == 0) return error.InvalidInteger;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidInteger;
    _ = try common.positiveInt(value, label);
}

fn formatBlockers(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const rows = parsed.value.object.get("blockers") orelse return error.InvalidResponse;
    if (rows != .array) return error.InvalidResponse;
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.writeAll("ticket\tstate\tboardTitle\tsection\tpriority\twaitingSince\tage\tquestion\trecommendation\turl\n");
    for (rows.array.items) |row| {
        if (row != .object) return error.InvalidResponse;
        try writeJsonCell(writer, row.object.get("ticketNumber"));
        try writer.writeByte('\t');
        try writeJsonCell(writer, row.object.get("state"));
        try writer.writeByte('\t');
        inline for (.{ "boardTitle", "section", "priority", "waitingSince" }) |field| {
            try writeJsonCell(writer, row.object.get(field));
            try writer.writeByte('\t');
        }
        try writeAge(writer, textOf(row.object.get("waitingSince")) orelse "");
        try writer.writeByte('\t');
        try writeBriefCell(writer, textOf(row.object.get("question")) orelse "", 60);
        try writer.writeByte('\t');
        try writeBriefCell(writer, textOf(row.object.get("recommendation")) orelse "", 40);
        try writer.writeByte('\t');
        try writeJsonCell(writer, row.object.get("url"));
        try writer.writeByte('\n');
    }
    return out.toOwnedSlice(allocator);
}

fn writeAge(writer: anytype, value: []const u8) !void {
    if (value.len < 20 or value[value.len - 1] != 'Z' or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return;
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return;
    if (year < 1970 or year > 9999 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += if (std.time.epoch.isLeapYear(y)) 366 else 365;
    const lengths = [_]u8{ 31, if (std.time.epoch.isLeapYear(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > lengths[month - 1]) return;
    for (lengths[0 .. month - 1]) |length| days += length;
    days += day - 1;
    const then = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
    const hours = @divFloor(@max(0, std.time.timestamp() - then), 3600);
    try writer.print("{d}d {d}h", .{ @divFloor(hours, 24), @mod(hours, 24) });
}

fn writeBriefCell(writer: anytype, value: []const u8, limit: usize) !void {
    var index: usize = 0;
    var count: usize = 0;
    while (index < value.len and count < limit) : (count += 1) {
        const length = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        const end = @min(index + length, value.len);
        try writeTextCell(writer, value[index..end]);
        index = end;
    }
    if (index < value.len) try writer.writeAll("...");
}

fn list(context: *const Context) !void {
    var response = try context.fetch(.GET, "/mcp/inbox/list", null);
    defer response.deinit();

    if (!response.isSuccess()) return context.finish(&response);
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
    if (agent_rows) |rows| {
        try writer.writeAll(",\"agent_notifications\":");
        try writeJsonValue(allocator, writer, rows.*);
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
    const user_rows = notificationArray(root, "user_notifications") orelse
        notificationArray(root, "notifications");
    const agent_rows = notificationArray(root, "agent_notifications");
    if (user_rows == null and agent_rows == null) return error.InvalidResponse;

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.writeAll("id\ttype\tticket\tproject\tcreatedAt\tseen\tstatus\n");

    if (user_rows) |rows| {
        try writeNotificationRows(writer, rows.array.items);
    }
    if (agent_rows) |rows| {
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
    var index: usize = 0;
    while (index < value.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        const end = index + sequence_length;
        const codepoint = if (end <= value.len) std.unicode.utf8Decode(value[index..end]) catch null else null;
        if (codepoint == null) {
            try writer.writeByte(' ');
            index += 1;
            continue;
        }
        // Replace C0, DEL, and Unicode C1 controls so titles cannot inject
        // ANSI/OSC sequences (including UTF-8-encoded CSI/OSC).
        const decoded = codepoint.?;
        if (decoded < 0x20 or decoded == 0x7f or (decoded >= 0x80 and decoded <= 0x9f)) {
            try writer.writeByte(' ');
        } else {
            try writer.writeAll(value[index..end]);
        }
        index = end;
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

test "inbox JSON omits agent_notifications when the API did not send it" {
    const body =
        \\{"success":true,"structuredData":{"tabs":[{"idx":0}],"data":[[0]]},"user_notifications":[{"id":9,"type":"Comment"}],"splitsNoImportant":[],"showImportantSplit":false}
    ;
    const formatted = try formatInboxJson(std.testing.allocator, body);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\"agent_notifications\"") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, formatted, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("user_notifications") != null);
    try std.testing.expect(parsed.value.object.get("structuredData") != null);
}

test "inbox human mode strips control bytes from TSV cells" {
    const body =
        \\{"success":true,"user_notifications":[{"id":1,"type":"Comment","seen":false,"status":"Normal","createdAt":"t","project":{"title":"Bo\u001b\u009bard"},"task":{"ticketNumber":"HT\tPR"}}],"agent_notifications":[]}
    ;
    const formatted = try formatInboxTsv(std.testing.allocator, body);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\xc2\x9b") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "\tPR") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Bo  ard") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "HT PR") != null);
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

test "blockers human output keeps full links and sanitizes text" {
    const body =
        \\{"success":true,"blockers":[{"ticketNumber":"HTPR-1","state":"waiting","boardTitle":"Board","section":"Doing","priority":"High","question":"Why?\nNow?","recommendation":"Yes","url":"https://app.hypertask.ai/detail/project-15/1"}],"total":1}
    ;
    const formatted = try formatBlockers(std.testing.allocator, body);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("ticket\tstate\tboardTitle\tsection\tpriority\twaitingSince\tage\tquestion\trecommendation\turl\nHTPR-1\twaiting\tBoard\tDoing\tHigh\t\t\tWhy? Now?\tYes\thttps://app.hypertask.ai/detail/project-15/1\n", formatted);
}

test "blockers human output retains all rows and bounds long text" {
    var body: std.ArrayListUnmanaged(u8) = .{};
    defer body.deinit(std.testing.allocator);
    const writer = body.writer(std.testing.allocator);
    try writer.writeAll("{\"blockers\":[");
    for (0..26) |i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"question\":\"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop\",\"url\":\"https://example.com/full-link\"}");
    }
    try writer.writeAll("]}");
    const formatted = try formatBlockers(std.testing.allocator, body.items);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqual(@as(usize, 27), std.mem.count(u8, formatted, "\n"));
    try std.testing.expectEqual(@as(usize, 26), std.mem.count(u8, formatted, "https://example.com/full-link"));
    try std.testing.expect(std.mem.indexOf(u8, formatted, "...") != null);
}
