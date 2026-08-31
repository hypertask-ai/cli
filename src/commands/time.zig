const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

const Correction = union(enum) {
    update: struct { entry_id: i64, minutes: i64 },
    delete: i64,
};

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "running")) return context.call(.GET, "/mcp/time/running", null);
    if (std.mem.eql(u8, subcommand, "report")) return report(context);
    if (std.mem.eql(u8, subcommand, "log")) return log(context);
    if (std.mem.eql(u8, subcommand, "update") or std.mem.eql(u8, subcommand, "edit")) return update(context);
    if (std.mem.eql(u8, subcommand, "delete")) return delete(context);

    const valid = std.mem.eql(u8, subcommand, "start") or std.mem.eql(u8, subcommand, "stop") or std.mem.eql(u8, subcommand, "pause") or std.mem.eql(u8, subcommand, "resume") or std.mem.eql(u8, subcommand, "status");
    if (!valid) return error.UnknownCommand;
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("task", try context.args.requirePositional(2, "task"));
    try context.call(.POST, try std.fmt.allocPrint(context.allocator, "/mcp/time/{s}", .{subcommand}), try body.finish());
}

fn log(context: *const Context) !void {
    const task = try context.args.requirePositional(2, "task");
    const minutes = try common.int(try context.args.requirePositional(3, "minutes"), "minutes");
    if (minutes == 0) {
        std.debug.print("minutes must not be zero\n", .{});
        return error.InvalidInteger;
    }
    if (minutes < 0) return correctLatest(context, task, minutes);

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("task", task);
    try body.integer("minutes", minutes);
    try context.call(.POST, "/mcp/time/log", try body.finish());
}

fn update(context: *const Context) !void {
    const entry_id = try common.positiveInt(try context.args.requirePositional(2, "entry-id"), "entry-id");
    const minutes = try common.positiveInt(try context.args.require("minutes"), "minutes");
    const timezone_offset: ?i64 = if (context.args.get("timezone-offset-minutes")) |value| try common.int(value, "timezone-offset-minutes") else null;
    try updateEntry(
        context,
        entry_id,
        minutes,
        context.args.get("date"),
        timezone_offset,
        context.args.get("note"),
    );
}

fn delete(context: *const Context) !void {
    const entry_id = try common.positiveInt(try context.args.requirePositional(2, "entry-id"), "entry-id");
    try deleteEntry(context, entry_id);
}

fn correctLatest(context: *const Context, task: []const u8, minutes: i64) !void {
    if (minutes == std.math.minInt(i64)) {
        std.debug.print("minutes correction is too large\n", .{});
        return error.InvalidInteger;
    }

    var path = try query.Builder.init(context.allocator, "/mcp/time/report");
    defer path.deinit();
    try path.add("task", task);
    // A correction must never select another user's entry on a shared task.
    try path.add("user", "me");

    var response = try context.fetch(.GET, path.path(), null);
    defer response.deinit();
    const status = @intFromEnum(response.status);
    if (status < 200 or status >= 300) return context.finish(&response);

    const change = correctionPlan(context.allocator, response.body, -minutes) catch |err| {
        switch (err) {
            error.NoCompletedTimeEntry => std.debug.print("no completed time entry found for this task\n", .{}),
            error.CorrectionTooLarge => std.debug.print("correction exceeds the latest completed time entry; use time update or time delete with its entry id\n", .{}),
            error.NonMinuteAlignedTimeEntry => std.debug.print("the latest completed entry is not a whole number of minutes; use time update or time delete with its entry id\n", .{}),
            error.InvalidTimeReport => std.debug.print("time report did not contain a usable completed entry\n", .{}),
            else => return err,
        }
        return error.InvalidOptions;
    };

    switch (change) {
        .update => |value| try updateEntry(context, value.entry_id, value.minutes, null, null, null),
        .delete => |entry_id| try deleteEntry(context, entry_id),
    }
}

fn correctionPlan(allocator: std.mem.Allocator, report_body: []const u8, decrement: i64) !Correction {
    if (decrement <= 0) return error.InvalidInteger;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, report_body, .{}) catch return error.InvalidTimeReport;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTimeReport;
    const entries_value = parsed.value.object.get("entries") orelse return error.InvalidTimeReport;
    if (entries_value != .array) return error.InvalidTimeReport;

    for (entries_value.array.items) |entry_value| {
        if (entry_value != .object) continue;
        const ended_at = entry_value.object.get("endedAt") orelse continue;
        if (ended_at == .null) continue;
        const entry_id = integerField(entry_value.object, "id") orelse continue;
        const seconds = integerField(entry_value.object, "seconds") orelse continue;
        if (entry_id <= 0 or seconds < 0) continue;
        if (seconds == 0 or @rem(seconds, 60) != 0) return error.NonMinuteAlignedTimeEntry;

        const current_minutes = @divTrunc(seconds, 60);
        if (decrement > current_minutes) return error.CorrectionTooLarge;
        if (decrement == current_minutes) return .{ .delete = entry_id };
        return .{ .update = .{ .entry_id = entry_id, .minutes = current_minutes - decrement } };
    }
    return error.NoCompletedTimeEntry;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

fn updateEntry(
    context: *const Context,
    entry_id: i64,
    minutes: i64,
    date: ?[]const u8,
    timezone_offset: ?i64,
    note: ?[]const u8,
) !void {
    const body = try updateBody(context.allocator, entry_id, minutes, date, timezone_offset, note);
    defer context.allocator.free(body);
    try context.call(.POST, "/mcp/time/update", body);
}

fn deleteEntry(context: *const Context, entry_id: i64) !void {
    const body = try deleteBody(context.allocator, entry_id);
    defer context.allocator.free(body);
    try context.call(.POST, "/mcp/time/delete", body);
}

fn updateBody(
    allocator: std.mem.Allocator,
    entry_id: i64,
    minutes: i64,
    date: ?[]const u8,
    timezone_offset: ?i64,
    note: ?[]const u8,
) ![]u8 {
    var body = try json.Object.init(allocator);
    defer body.deinit();
    try body.integer("entry_id", entry_id);
    try body.integer("minutes", minutes);
    if (date) |value| try body.string("date", value);
    if (timezone_offset) |value| try body.integer("timezone_offset_minutes", value);
    if (note) |value| try body.string("note", value);
    return allocator.dupe(u8, try body.finish());
}

fn deleteBody(allocator: std.mem.Allocator, entry_id: i64) ![]u8 {
    var body = try json.Object.init(allocator);
    defer body.deinit();
    try body.integer("entry_id", entry_id);
    return allocator.dupe(u8, try body.finish());
}

fn report(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/time/report");
    defer path.deinit();
    const fields = [_][]const u8{ "board", "task", "user", "from", "to" };
    for (fields) |field| if (context.args.get(field)) |value| try path.add(field, value);
    if (context.args.has("running")) try path.add("running", "1");
    try context.call(.GET, path.path(), null);
}

test "negative correction updates or deletes the latest completed entry" {
    const body =
        \\{"success":true,"entries":[{"id":120,"seconds":60,"endedAt":null},{"id":119,"seconds":1800,"endedAt":"2026-08-29T11:21:16.117Z"}]}
    ;

    const update_plan = try correctionPlan(std.testing.allocator, body, 10);
    switch (update_plan) {
        .update => |value| {
            try std.testing.expectEqual(@as(i64, 119), value.entry_id);
            try std.testing.expectEqual(@as(i64, 20), value.minutes);
        },
        else => return error.TestUnexpectedResult,
    }

    const delete_plan = try correctionPlan(std.testing.allocator, body, 30);
    switch (delete_plan) {
        .delete => |entry_id| try std.testing.expectEqual(@as(i64, 119), entry_id),
        else => return error.TestUnexpectedResult,
    }
}

test "negative correction rejects over-correction and missing entries" {
    try std.testing.expectError(
        error.CorrectionTooLarge,
        correctionPlan(std.testing.allocator,
            \\{"success":true,"entries":[{"id":119,"seconds":1800,"endedAt":"2026-08-29T11:21:16.117Z"}]}
        , 31),
    );
    try std.testing.expectError(
        error.NoCompletedTimeEntry,
        correctionPlan(std.testing.allocator,
            \\{"success":true,"entries":[{"id":120,"seconds":60,"endedAt":null}]}
        , 1),
    );
    try std.testing.expectError(
        error.NonMinuteAlignedTimeEntry,
        correctionPlan(std.testing.allocator,
            \\{"success":true,"entries":[{"id":119,"seconds":90,"endedAt":"2026-08-29T11:21:16.117Z"}]}
        , 1),
    );
}

test "entry mutation bodies use the MCP route fields" {
    const update_body = try updateBody(std.testing.allocator, 119, 25, "2026-08-29", -60, "corrected");
    defer std.testing.allocator.free(update_body);
    try std.testing.expectEqualStrings(
        "{\"entry_id\":119,\"minutes\":25,\"date\":\"2026-08-29\",\"timezone_offset_minutes\":-60,\"note\":\"corrected\"}",
        update_body,
    );

    const delete_body = try deleteBody(std.testing.allocator, 119);
    defer std.testing.allocator.free(delete_body);
    try std.testing.expectEqualStrings("{\"entry_id\":119}", delete_body);
}
