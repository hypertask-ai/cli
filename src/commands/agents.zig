const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    const token = common.managementToken(context);
    if (std.mem.eql(u8, subcommand, "list")) {
        try context.callWithToken(token, .GET, "/mcp/admin/agents", null);
    } else if (std.mem.eql(u8, subcommand, "create")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("display_name", try context.args.require("name"));
        const projects = try common.optionList(context, "project");
        if (projects.len != 0) try body.integers("project_ids", projects);
        try body.string("role", context.args.get("role") orelse "write");
        try context.callWithToken(token, .POST, "/mcp/admin/agents", try body.finish());
    } else if (std.mem.eql(u8, subcommand, "update")) {
        const add_inputs = try common.optionList(context, "add-project");
        const remove_inputs = try common.optionList(context, "remove-project");
        var changes = try parseProjectChanges(context.allocator, add_inputs, remove_inputs);
        defer changes.deinit(context.allocator);

        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try writeProjectChanges(&body, &changes);
        const path = try agentPath(context.allocator, try context.args.require("id"));
        try context.callWithToken(token, .PATCH, path, try body.finish());
    } else if (std.mem.eql(u8, subcommand, "revoke")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("agent_id", try context.args.require("id"));
        try context.callWithToken(token, .DELETE, "/mcp/admin/agents", try body.finish());
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        try requireDeleteConfirmation(context.args.has("confirm"));
        const path = try agentPath(context.allocator, try context.args.require("id"));
        try context.callWithToken(token, .DELETE, path, null);
    } else if (std.mem.eql(u8, subcommand, "rotate-token")) {
        const id = try context.args.require("id");
        const path = try std.fmt.allocPrint(context.allocator, "/mcp/admin/agents/{s}/token", .{id});
        try context.callWithToken(token, .POST, path, null);
    } else if (std.mem.eql(u8, subcommand, "rename")) {
        const id = try context.args.require("id");
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("display_name", try context.args.require("name"));
        const path = try agentPath(context.allocator, id);
        try context.callWithToken(token, .PATCH, path, try body.finish());
    } else return error.UnknownCommand;
}

const ProjectChanges = struct {
    add: []i64,
    remove: []i64,

    fn deinit(self: *ProjectChanges, allocator: std.mem.Allocator) void {
        allocator.free(self.add);
        allocator.free(self.remove);
        self.* = undefined;
    }
};

fn parseProjectChanges(
    allocator: std.mem.Allocator,
    add_inputs: []const []const u8,
    remove_inputs: []const []const u8,
) !ProjectChanges {
    if (add_inputs.len == 0 and remove_inputs.len == 0) return error.MissingProjectChanges;

    const add = try uniqueProjectIds(allocator, add_inputs, "--add-project");
    errdefer allocator.free(add);
    const remove = try uniqueProjectIds(allocator, remove_inputs, "--remove-project");
    errdefer allocator.free(remove);

    var removed = std.AutoHashMap(i64, void).init(allocator);
    defer removed.deinit();
    for (remove) |project_id| try removed.put(project_id, {});
    for (add) |project_id| {
        if (removed.contains(project_id)) return error.ConflictingProjectChanges;
    }
    return .{ .add = add, .remove = remove };
}

fn writeProjectChanges(body: *json.Object, changes: *const ProjectChanges) !void {
    try body.integerValues("add_project_ids", changes.add);
    try body.integerValues("remove_project_ids", changes.remove);
}

fn uniqueProjectIds(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    label: []const u8,
) ![]i64 {
    var seen = std.AutoHashMap(i64, void).init(allocator);
    defer seen.deinit();
    var result: std.ArrayListUnmanaged(i64) = .{};
    errdefer result.deinit(allocator);
    for (inputs) |input| {
        const project_id = try common.positiveInt(input, label);
        const entry = try seen.getOrPut(project_id);
        if (!entry.found_existing) try result.append(allocator, project_id);
    }
    return result.toOwnedSlice(allocator);
}

fn requireDeleteConfirmation(confirmed: bool) !void {
    if (!confirmed) return error.ConfirmationRequired;
}

fn agentPath(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/mcp/agents/{s}", .{id});
}

test "agent project updates normalize IDs and reject unsafe changes" {
    const add = [_][]const u8{ "339", "0339", "42" };
    const remove = [_][]const u8{"2312"};
    var changes = try parseProjectChanges(std.testing.allocator, &add, &remove);
    defer changes.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(i64, &.{ 339, 42 }, changes.add);
    try std.testing.expectEqualSlices(i64, &.{2312}, changes.remove);
    var body = try json.Object.init(std.testing.allocator);
    defer body.deinit();
    try writeProjectChanges(&body, &changes);
    try std.testing.expectEqualStrings(
        "{\"add_project_ids\":[339,42],\"remove_project_ids\":[2312]}",
        try body.finish(),
    );

    try std.testing.expectError(
        error.MissingProjectChanges,
        parseProjectChanges(std.testing.allocator, &.{}, &.{}),
    );
    try std.testing.expectError(
        error.InvalidInteger,
        parseProjectChanges(std.testing.allocator, &.{"0"}, &.{}),
    );
    try std.testing.expectError(
        error.ConflictingProjectChanges,
        parseProjectChanges(std.testing.allocator, &.{"339"}, &.{"0339"}),
    );
}

test "agent mutations use the owned-agent endpoint" {
    try std.testing.expectError(error.ConfirmationRequired, requireDeleteConfirmation(false));
    try requireDeleteConfirmation(true);

    const path = try agentPath(std.testing.allocator, "agent-id");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/mcp/agents/agent-id", path);
}
