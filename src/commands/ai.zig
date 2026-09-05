const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const resolve = @import("../resolve.zig");
const query = @import("../query.zig");
const output = @import("../output.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "improve")) return improve(context);
    if (std.mem.eql(u8, subcommand, "write")) return write(context);
    return error.UnknownCommand;
}

fn improve(context: *const Context) !void {
    const text = context.args.positionalAt(2) orelse try std.fs.File.stdin().readToEndAlloc(context.allocator, 2 * 1024 * 1024);
    var project: i64 = undefined;
    if (context.args.get("task")) |ticket| {
        project = (try resolve.task(context, ticket)).project_id;
    } else project = try common.positiveInt(try context.args.require("project"), "project");
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("project_id", project);
    try body.string("text", text);
    try body.string("command", improveCommand(context.args.get("command") orelse "improve-readability"));
    try context.call(.POST, "/mcp/ai/improve", try body.finish());
}

fn write(context: *const Context) !void {
    const prompt = try context.args.requirePositional(2, "prompt");
    var task_ids: []const []const u8 = &.{};
    var one_task_id: [1][]const u8 = undefined;
    var task_id: ?i64 = null;
    var task_title: []const u8 = "";
    var task_description: []const u8 = "";
    var project: i64 = undefined;
    if (context.args.get("task")) |ticket| {
        var path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer path.deinit();
        try resolve.addTaskIdentifierQueryForProject(&path, context.allocator, ticket, context.args.get("project"));
        var task_response = try context.fetch(.GET, path.path(), null);
        defer task_response.deinit();
        const task_document = try std.json.parseFromSlice(std.json.Value, context.allocator, task_response.body, .{});
        defer task_document.deinit();
        const rows = task_document.value.object.get("tasks") orelse return error.InvalidResponse;
        if (rows.array.items.len != 1) return error.TaskNotFound;
        const task_value = rows.array.items[0];
        task_id = integerField(task_value, "id") orelse return error.InvalidResponse;
        project = integerField(task_value, "projectId") orelse return error.InvalidResponse;
        if (task_value.object.get("title")) |value| {
            if (value == .string) task_title = try context.allocator.dupe(u8, value.string);
        }
        if (task_value.object.get("description")) |value| {
            if (value == .string) task_description = try context.allocator.dupe(u8, value.string);
        }
        one_task_id[0] = try std.fmt.allocPrint(context.allocator, "{d}", .{task_id.?});
        task_ids = &one_task_id;
    } else project = try common.positiveInt(try context.args.require("project"), "project");
    if (context.args.has("apply") and task_id == null) return error.MissingTask;
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("project_id", project);
    try body.string("prompt", prompt);
    const mode = context.args.get("mode") orelse "task-writer";
    try body.string("mode", if (std.mem.eql(u8, mode, "write-with-ai")) "write_with_ai" else "task_writer");
    try body.integers("task_ids", task_ids);
    try body.string("task_title", task_title);
    try body.string("task_description", task_description);
    try body.string("custom_instructions", context.args.get("instructions") orelse "");
    if (!context.args.has("apply")) return context.call(.POST, "/mcp/ai/task-writer", try body.finish());
    var generated = try context.fetch(.POST, "/mcp/ai/task-writer", try body.finish());
    defer generated.deinit();
    const generated_code = @intFromEnum(generated.status);
    if (generated_code < 200 or generated_code >= 300) return output.finish(&generated);
    const document = try std.json.parseFromSlice(std.json.Value, context.allocator, generated.body, .{});
    defer document.deinit();
    const produced_mode = stringField(document.value, "mode") orelse return error.InvalidResponse;
    const requested_mode = if (std.mem.eql(u8, mode, "write-with-ai")) "write_with_ai" else "task_writer";
    if (!std.mem.eql(u8, produced_mode, requested_mode)) return error.ModeMismatch;
    var apply_body = try json.Object.init(context.allocator);
    defer apply_body.deinit();
    try apply_body.integer("task_id", task_id.?);
    const html = stringField(document.value, "html") orelse "";
    const apply_path = if (std.mem.eql(u8, produced_mode, "write_with_ai")) "/mcp/comments" else "/mcp/tasks/update";
    if (std.mem.eql(u8, produced_mode, "write_with_ai")) {
        try apply_body.string("text", html);
    } else {
        if (html.len != 0) try apply_body.string("description", html);
        if (stringField(document.value, "title")) |value| try apply_body.string("title", value);
        if (integerField(document.value, "priority")) |value| try apply_body.integer("priority", value);
        if (integerField(document.value, "estimate")) |value| try apply_body.integer("estimate", value);
    }
    var applied = try context.fetch(.POST, apply_path, try apply_body.finish());
    defer applied.deinit();
    const applied_code = @intFromEnum(applied.status);
    if (applied_code < 200 or applied_code >= 300) return output.finish(&applied);
    try context.print(try json.mergeRawField(context.allocator, generated.body, "applied", "true"));
}

fn improveCommand(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "fix-spelling")) return "FixSpellingAndGrammar";
    if (std.mem.eql(u8, value, "summarize")) return "Summarize";
    if (std.mem.eql(u8, value, "make-shorter")) return "MakeShorter";
    return "ImproveReadability";
}

fn integerField(value: std.json.Value, name: []const u8) ?i64 {
    const field = value.object.get(name) orelse return null;
    return if (field == .integer) field.integer else null;
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}
