const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");
const resolve = @import("../resolve.zig");
const attachments = @import("../attachments.zig");
const http = @import("../http.zig");
const output = @import("../output.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) return list(context);
    if (std.mem.eql(u8, subcommand, "next")) return next(context);
    if (std.mem.eql(u8, subcommand, "get") or std.mem.eql(u8, subcommand, "show")) return get(context);
    if (std.mem.eql(u8, subcommand, "description-history")) return descriptionHistory(context);
    if (std.mem.eql(u8, subcommand, "description-restore")) return descriptionRestore(context);
    if (std.mem.eql(u8, subcommand, "context")) return taskContext(context);
    if (std.mem.eql(u8, subcommand, "tree")) return tree(context);
    if (std.mem.eql(u8, subcommand, "link")) return relationMutation(context, true);
    if (std.mem.eql(u8, subcommand, "unlink")) return relationMutation(context, false);
    if (std.mem.eql(u8, subcommand, "relations")) return relations(context);
    if (std.mem.eql(u8, subcommand, "related")) return related(context);
    if (std.mem.eql(u8, subcommand, "create")) return create(context);
    if (std.mem.eql(u8, subcommand, "update")) return update(context);
    if (std.mem.eql(u8, subcommand, "assign")) return assign(context, "assign");
    if (std.mem.eql(u8, subcommand, "unassign")) return assign(context, "unassign");
    if (std.mem.eql(u8, subcommand, "move-to-inbox")) return moveToInbox(context);
    if (std.mem.eql(u8, subcommand, "move")) return move(context);
    if (std.mem.eql(u8, subcommand, "move-board") or std.mem.eql(u8, subcommand, "move-project")) return moveBoard(context);
    if (std.mem.eql(u8, subcommand, "search")) return search(context, 2);
    return error.UnknownCommand;
}

pub fn globalSearch(context: *const Context) !void {
    try search(context, 1);
}

fn list(context: *const Context) !void {
    if (context.args.get("search") != null) return searchValue(context, context.args.get("search").?);
    var path = try query.Builder.init(context.allocator, "/mcp/tasks");
    defer path.deinit();
    const mappings = [_][2][]const u8{
        .{ "project", "project_id" }, .{ "created-by", "created_by" },
        .{ "sort-by", "sort_by" },    .{ "sort-order", "sort_order" },
        .{ "status", "status" },
    };
    for (mappings) |mapping| if (context.args.get(mapping[0])) |value| try path.add(mapping[1], value);
    for (try common.optionList(context, "assigned-to")) |value| try path.add("assigned_to", value);
    if (context.args.get("section")) |value| {
        if (context.args.get("project") == null) return error.MissingOption;
        try path.add("section", value);
    }
    for (try common.optionList(context, "priority")) |value| try path.add("priority", value);
    const label_inputs = try common.optionList(context, "labels");
    const project_id = if (context.args.get("project")) |value| try common.positiveInt(value, "project") else null;
    const label_ids = try resolveLabelIds(context, label_inputs, project_id, false);
    for (label_ids) |value| try path.add("labels", value);
    if (context.args.has("has-due-date")) try path.add("has_due_date", "true");
    try path.add("limit", context.args.get("limit") orelse "10");
    try path.add("offset", context.args.get("offset") orelse "0");
    try context.call(.GET, path.path(), null);
}

fn next(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/tasks/next");
    defer path.deinit();
    try path.add("project_id", try context.args.require("project"));
    if (context.args.get("label")) |value| try path.add("labels", value);
    try context.call(.GET, path.path(), null);
}

fn get(context: *const Context) !void {
    const identifier = try context.args.requirePositional(2, "ticket-or-task-id");
    var path = try query.Builder.init(context.allocator, "/mcp/tasks");
    defer path.deinit();
    try addIdentifierQuery(&path, context, identifier);
    try context.call(.GET, path.path(), null);
}

fn descriptionHistory(context: *const Context) !void {
    const identifier = try context.args.requirePositional(2, "ticket-or-id");
    var path = try query.Builder.init(context.allocator, "/mcp/tasks/description-versions");
    defer path.deinit();
    try addIdentifierQuery(&path, context, identifier);
    try context.call(.GET, path.path(), null);
}

fn descriptionRestore(context: *const Context) !void {
    var body = try identifierBody(context, try context.args.requirePositional(2, "ticket-or-id"));
    defer body.deinit();
    try body.integer("version_id", try common.positiveInt(try context.args.require("version"), "version"));
    try context.call(.POST, "/mcp/tasks/description-restore", try body.finish());
}

fn taskContext(context: *const Context) !void {
    const found = try resolve.task(context, try context.args.requirePositional(2, "ticket-or-id"));
    if (context.args.get("project")) |project| if (try common.positiveInt(project, "project") != found.project_id) return error.InvalidProject;
    var path = try query.Builder.init(context.allocator, "/mcp/tasks/context");
    defer path.deinit();
    try path.addInt("task_id", found.id);
    try path.addInt("project_id", found.project_id);
    if (context.args.has("summary")) try path.add("summary", "true");
    try context.call(.GET, path.path(), null);
}

fn tree(context: *const Context) !void {
    if (context.args.get("ticket") == null and context.args.get("task-id") == null) return error.MissingOption;
    if (context.args.get("ticket") != null and context.args.get("task-id") != null) return error.InvalidOptions;
    var path = try query.Builder.init(context.allocator, "/mcp/tasks/tree");
    defer path.deinit();
    if (context.args.get("ticket")) |value| try path.add("ticket_number", try resolve.normalizedTicket(context.allocator, value));
    if (context.args.get("task-id")) |value| try path.add("task_id", value);
    if (context.args.get("depth")) |value| try path.add("depth", value);
    try context.call(.GET, path.path(), null);
}

fn relationMutation(context: *const Context, link: bool) !void {
    const source = try resolve.task(context, try context.args.requirePositional(2, "source"));
    const target = try resolve.task(context, try context.args.requirePositional(3, "target"));
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("source_task_id", source.id);
    try body.integer("target_task_id", target.id);
    if (link) {
        if (context.args.get("type")) |value| try body.string("relation_type", value) else try body.nullValue("relation_type");
    }
    try context.call(if (link) .POST else .DELETE, "/mcp/tasks/relations", try body.finish());
}

fn relations(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/tasks/relations");
    defer path.deinit();
    try addIdentifierQuery(&path, context, try context.args.requirePositional(2, "ticket-or-id"));
    try context.call(.GET, path.path(), null);
}

fn related(context: *const Context) !void {
    const found = try resolve.task(context, try context.args.requirePositional(2, "ticket-or-id"));
    var path = try query.Builder.init(context.allocator, "/mcp/tasks/related");
    defer path.deinit();
    try path.addInt("task_id", found.id);
    try context.call(.GET, path.path(), null);
}

fn create(context: *const Context) !void {
    const project = try common.positiveInt(try context.args.require("project"), "project");
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("project_id", project);
    try body.string("title", try context.args.require("title"));
    if (try descriptionValue(context)) |value| {
        try body.string("description", value);
        if (context.args.has("markdown")) try body.string("content_type", "markdown");
    }
    if (context.args.get("priority")) |value| try body.integer("priority", priority(value));
    if (context.args.get("estimate")) |value| try body.integer("estimate", try common.int(value, "estimate"));
    if (context.args.get("due")) |value| try body.string("due_date", value);
    if (context.args.get("section")) |value| try body.integer("section_id", try resolve.sectionId(context, project, value));
    if (context.args.get("parent-task")) |value| try body.integer("parent_task_id", (try resolve.task(context, value)).id);
    const labels = try resolveLabelIds(context, try common.optionList(context, "labels"), project, true);
    if (labels.len != 0) try body.identifiers("labels", labels);
    const assignees = try common.optionList(context, "assignee");
    if (assignees.len != 0) try body.integers("assignee", assignees);
    const attach_inputs = try common.optionList(context, "attach");
    var response = try context.fetch(.POST, "/mcp/tasks/create", try body.finish());
    defer response.deinit();
    const linked_body = try taskMutationBody(context, &response);
    if (attach_inputs.len == 0) return context.print(linked_body);
    const ticket = try responseTicket(context, response.body);
    const uploaded = try attachments.upload(context, ticket, null, attach_inputs);
    try context.print(try json.mergeRawField(context.allocator, linked_body, "attachments_uploaded", uploaded));
}

fn update(context: *const Context) !void {
    const ticket = try context.args.requirePositional(2, "ticket-or-task-id");
    var body = try identifierBody(context, ticket);
    defer body.deinit();
    if (context.args.get("title")) |value| try body.string("title", value);
    if (try descriptionValue(context)) |value| {
        try body.string("description", value);
        if (context.args.has("markdown")) try body.string("content_type", "markdown");
    }
    if (context.args.get("pull-request")) |value| try body.string("pull_request_url", value);
    if (context.args.has("clear-due")) try body.nullValue("due_date") else if (context.args.get("due")) |value| try body.string("due_date", value);
    if (context.args.get("status")) |value| try body.string("status", value);
    if (context.args.get("priority")) |value| try body.integer("priority", priority(value));
    if (context.args.get("estimate")) |value| try body.integer("estimate", try common.int(value, "estimate"));
    if (context.args.get("section")) |value| {
        const found = try resolve.task(context, ticket);
        const project = if (context.args.get("project")) |project_value| try common.positiveInt(project_value, "project") else found.project_id;
        try body.integer("sectionId", try resolve.sectionId(context, project, value));
    }
    if (context.args.has("clear-parent")) try body.nullValue("parent_task_id") else if (context.args.get("parent-task")) |value| try body.integer("parent_task_id", (try resolve.task(context, value)).id);
    const label_inputs = try common.optionList(context, "labels");
    const add_label_inputs = try common.optionList(context, "add-labels");
    const remove_label_inputs = try common.optionList(context, "remove-labels");
    if (label_inputs.len != 0 or add_label_inputs.len != 0 or remove_label_inputs.len != 0) {
        const task_row = try resolve.task(context, ticket);
        if (label_inputs.len != 0) {
            const labels = try resolveLabelIds(context, label_inputs, task_row.project_id, true);
            try body.identifiers("labels", labels);
        }
        if (add_label_inputs.len != 0) {
            const labels = try resolveLabelIds(context, add_label_inputs, task_row.project_id, true);
            try body.identifiers("add_labels", labels);
        }
        if (remove_label_inputs.len != 0) {
            const labels = try resolveLabelIds(context, remove_label_inputs, task_row.project_id, true);
            try body.identifiers("remove_labels", labels);
        }
    }
    const assignees = try common.optionList(context, "assignee");
    if (assignees.len != 0) try body.integers("assignee", assignees);
    const attach_inputs = try common.optionList(context, "attach");
    var response = if (hasUpdateOptions(context))
        try context.fetch(.POST, "/mcp/tasks/update", try body.finish())
    else blk: {
        var path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer path.deinit();
        try addIdentifierQuery(&path, context, ticket);
        break :blk try context.fetch(.GET, path.path(), null);
    };
    defer response.deinit();
    const linked_body = try taskMutationBody(context, &response);
    if (attach_inputs.len == 0) return context.print(linked_body);
    const uploaded = try attachments.upload(context, ticket, null, attach_inputs);
    try context.print(try json.mergeRawField(context.allocator, linked_body, "attachments_uploaded", uploaded));
}

fn assign(context: *const Context, intent: []const u8) !void {
    const self_flag = context.args.has("self");
    const assignee = context.args.get("assignee");
    if (self_flag and assignee != null) output.fail("Error: use either --self or --assignee, not both");
    if (!self_flag and assignee == null) output.fail("Error: provide --assignee <id> or --self");
    const identifier = try context.args.requirePositional(2, "ticket-or-task-id");
    if (!self_flag and std.mem.eql(u8, intent, "unassign") and resolve.isNumeric(assignee.?)) {
        return unassignById(context, identifier, assignee.?);
    }
    var body = try identifierBody(context, identifier);
    defer body.deinit();
    if (self_flag) {
        try body.boolean("assign_self", true);
    } else if (resolve.isNumeric(assignee.?)) {
        try body.integer("user_id", try common.positiveInt(assignee.?, "assignee"));
    } else {
        try body.string("agent_id", assignee.?);
    }
    try body.string("intent", intent);
    var response = try context.fetch(.POST, "/mcp/assignees/assign", try body.finish());
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return context.finish(&response);
    // HTPR-6311: an agent id request must be confirmed by that exact agent id
    // in the resulting assignees, so a wrong or stuck attachment cannot pass
    // silently (the response's top-level `agent` field is the calling session,
    // not the assignee, and must never be read as one).
    if (!self_flag and assignee != null and !resolve.isNumeric(assignee.?)) {
        var arena = std.heap.ArenaAllocator.init(context.allocator);
        defer arena.deinit();
        const present = agentInAssignees(arena.allocator(), response.body, assignee.?);
        if (std.mem.eql(u8, intent, "assign")) {
            if (present != true) return unconfirmedAgent(assignee.?);
        } else {
            if (present == true) return stuckAssigneeAgent(assignee.?);
        }
    }
    try context.print(response.body);
}

const AssigneeTarget = union(enum) {
    agent_id: []const u8,
    user_id: i64,
};

/// HTPR-6311: `tasks get` shows every assignee row under its numeric user id,
/// but a user_id unassign only matches plain rows and silently no-ops on
/// agent-linked rows. Unassign each displayed row with the id that actually
/// identifies it: agent-linked rows via their agent id, plain rows via user_id.
fn unassignById(context: *const Context, identifier: []const u8, user_id_text: []const u8) !void {
    const user_id = try common.positiveInt(user_id_text, "assignee");
    var list_path = try query.Builder.init(context.allocator, "/mcp/tasks");
    defer list_path.deinit();
    try addIdentifierQuery(&list_path, context, identifier);
    var list_response = try context.fetch(.GET, list_path.path(), null);
    defer list_response.deinit();
    const list_code = @intFromEnum(list_response.status);
    if (list_code < 200 or list_code >= 300) return context.finish(&list_response);

    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = std.json.parseFromSliceLeaky(std.json.Value, allocator, list_response.body, .{}) catch return error.InvalidResponse;
    var agent_ids: std.ArrayListUnmanaged([]const u8) = .{};
    var has_plain = false;
    if (document == .object) {
        if (document.object.get("tasks")) |tasks_value| {
            if (tasks_value == .array and tasks_value.array.items.len > 0 and tasks_value.array.items[0] == .object) {
                if (tasks_value.array.items[0].object.get("assignees")) |assignees_value| {
                    if (assignees_value == .array) {
                        for (assignees_value.array.items) |row| {
                            if (row != .object) continue;
                            if (rowUserId(row)) |row_user| {
                                if (row_user != user_id) continue;
                                if (agentIdOfRow(row)) |agent_id| {
                                    try agent_ids.append(allocator, agent_id);
                                } else {
                                    has_plain = true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var final_body: ?[]const u8 = null;
    for (agent_ids.items) |agent_id| {
        final_body = try postAssigneeMutation(context, allocator, identifier, .{ .agent_id = agent_id });
    }
    if (has_plain or agent_ids.items.len == 0) {
        // No displayed row matched (or a plain row matched): the plain call is
        // either the removal itself or the old idempotent no-op.
        final_body = try postAssigneeMutation(context, allocator, identifier, .{ .user_id = user_id });
    }
    const body = final_body orelse return;
    for (agent_ids.items) |agent_id| {
        if (agentInAssignees(allocator, body, agent_id) == true) return stuckAssigneeAgent(agent_id);
    }
    if (has_plain and userRowInAssignees(allocator, body, user_id) == true) {
        return stuckAssigneeUser(user_id);
    }
    try context.print(body);
}

fn postAssigneeMutation(
    context: *const Context,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    target: AssigneeTarget,
) ![]const u8 {
    var body = try identifierBody(context, identifier);
    defer body.deinit();
    switch (target) {
        .agent_id => |value| try body.string("agent_id", value),
        .user_id => |value| try body.integer("user_id", value),
    }
    try body.string("intent", "unassign");
    var response = try context.fetch(.POST, "/mcp/assignees/assign", try body.finish());
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) {
        try context.finish(&response);
        return error.CommandFailed;
    }
    return allocator.dupe(u8, response.body);
}

/// True when the response's assignees list contains a row linked to `agent_id`.
/// Null when the response carries no readable assignees list, so a shape
/// change degrades to the old pass-through instead of a false failure.
fn agentInAssignees(allocator: std.mem.Allocator, response_body: []const u8, agent_id: []const u8) ?bool {
    const document = std.json.parseFromSliceLeaky(std.json.Value, allocator, response_body, .{}) catch return null;
    const assignees = assigneesOfDocument(document) orelse return null;
    for (assignees) |row| {
        if (agentIdOfRow(row)) |row_agent| {
            if (std.mem.eql(u8, row_agent, agent_id)) return true;
        }
    }
    return false;
}

/// True when the response still shows a plain (not agent-linked) row for `user_id`.
fn userRowInAssignees(allocator: std.mem.Allocator, response_body: []const u8, user_id: i64) ?bool {
    const document = std.json.parseFromSliceLeaky(std.json.Value, allocator, response_body, .{}) catch return null;
    const assignees = assigneesOfDocument(document) orelse return null;
    for (assignees) |row| {
        if (agentIdOfRow(row) != null) continue;
        if (rowUserId(row)) |row_user| {
            if (row_user == user_id) return true;
        }
    }
    return false;
}

fn assigneesOfDocument(document: std.json.Value) ?[]std.json.Value {
    if (document != .object) return null;
    const assignees = document.object.get("assignees") orelse return null;
    if (assignees != .array) return null;
    return assignees.array.items;
}

/// Assignee rows use `userId` in mutation responses and `id` (the user id) in
/// task rows from GET /mcp/tasks.
fn rowUserId(row: std.json.Value) ?i64 {
    if (row != .object) return null;
    var field = row.object.get("userId");
    if (field == null) field = row.object.get("id");
    const value = field orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn agentIdOfRow(row: std.json.Value) ?[]const u8 {
    if (row != .object) return null;
    const agent = row.object.get("agent") orelse return null;
    if (agent != .object) return null;
    const id = agent.object.get("id") orelse return null;
    if (id != .string or id.string.len == 0) return null;
    return id.string;
}

fn unconfirmedAgent(agent_id: []const u8) error{AssigneeNotConfirmed} {
    std.debug.print("Error: response did not confirm agent {s} in the task assignees\n", .{agent_id});
    return error.AssigneeNotConfirmed;
}

fn stuckAssigneeAgent(agent_id: []const u8) error{AssigneeNotRemoved} {
    std.debug.print("Error: agent {s} is still in the task assignees after unassign\n", .{agent_id});
    return error.AssigneeNotRemoved;
}

fn stuckAssigneeUser(user_id: i64) error{AssigneeNotRemoved} {
    std.debug.print("Error: user {d} is still in the task assignees after unassign\n", .{user_id});
    return error.AssigneeNotRemoved;
}

fn moveToInbox(context: *const Context) !void {
    var body = try identifierBody(context, try context.args.requirePositional(2, "ticket-or-task-id"));
    defer body.deinit();
    if (context.args.get("user")) |value| try body.integer("user_id", try common.positiveInt(value, "user"));
    try context.call(.POST, "/mcp/inbox/move", try body.finish());
}

fn move(context: *const Context) !void {
    const identifier = try context.args.requirePositional(2, "ticket-or-task-id");
    const section = context.args.get("section") orelse context.args.get("to") orelse context.args.get("to-section") orelse return error.MissingOption;
    const found = try resolve.task(context, identifier);
    var body = try identifierBody(context, identifier);
    defer body.deinit();
    try body.integer("sectionId", try resolve.sectionId(context, found.project_id, section));
    var response = try context.fetch(.POST, "/mcp/tasks/update", try body.finish());
    defer response.deinit();
    try context.print(try taskMutationBody(context, &response));
}

fn moveBoard(context: *const Context) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("task_id", try common.positiveInt(try context.args.requirePositional(2, "task-id"), "task-id"));
    try body.integer("target_project_id", try common.positiveInt(try context.args.require("target-project"), "target-project"));
    if (context.args.get("target-section")) |value| try body.integer("target_section_id", try common.positiveInt(value, "target-section"));
    try context.call(.POST, "/mcp/tasks/move", try body.finish());
}

fn search(context: *const Context, positional_index: usize) !void {
    try searchValue(context, try context.args.requirePositional(positional_index, "query"));
}

fn searchValue(context: *const Context, value: []const u8) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/tasks/search");
    defer path.deinit();
    try path.add("q", value);
    try path.add("limit", context.args.get("limit") orelse "10");
    if (context.args.get("project")) |project| try path.add("project_id", project);

    var response = try context.fetch(.GET, path.path(), null);
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return context.finish(&response);

    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document = try std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{});
    if (document != .object) return error.InvalidResponse;
    const tasks = document.object.getPtr("tasks") orelse return error.InvalidResponse;
    if (tasks.* != .array) return error.InvalidResponse;

    for (tasks.array.items) |*task| {
        if (hasDescription(task.*)) {
            try addSearchTaskLink(allocator, task);
            continue;
        }
        if (task.* != .object) return error.InvalidResponse;
        const id_value = task.object.get("id") orelse return error.InvalidResponse;
        if (id_value != .integer) return error.InvalidResponse;
        const id = try std.fmt.allocPrint(context.allocator, "{d}", .{id_value.integer});
        defer context.allocator.free(id);
        var detail_path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer detail_path.deinit();
        try detail_path.add("task_id", id);
        var detail_response = try context.fetch(.GET, detail_path.path(), null);
        defer detail_response.deinit();
        const detail_code = @intFromEnum(detail_response.status);
        if (detail_code < 200 or detail_code >= 300) return context.finish(&detail_response);
        try mergeSearchTask(allocator, task, detail_response.body);
    }

    const enriched = try std.json.Stringify.valueAlloc(context.allocator, document, .{});
    defer context.allocator.free(enriched);
    try context.print(enriched);
}

fn addIdentifierQuery(path: *query.Builder, context: *const Context, identifier: []const u8) !void {
    try resolve.addTaskIdentifierQueryForProject(path, context.allocator, identifier, context.args.get("project"));
}

fn identifierBody(context: *const Context, identifier: []const u8) !json.Object {
    var body = try json.Object.init(context.allocator);
    errdefer body.deinit();
    try resolve.addTaskIdentifierBodyForProject(&body, context.allocator, identifier, context.args.get("project"));
    return body;
}

fn priority(value: []const u8) i64 {
    if (std.ascii.eqlIgnoreCase(value, "urgent")) return 1;
    if (std.ascii.eqlIgnoreCase(value, "high")) return 2;
    if (std.ascii.eqlIgnoreCase(value, "medium")) return 3;
    if (std.ascii.eqlIgnoreCase(value, "low")) return 4;
    return 0;
}

fn hasUpdateOptions(context: *const Context) bool {
    const names = [_][]const u8{
        "title", "description", "description-file", "pull-request", "priority", "estimate", "due", "clear-due", "status", "section", "assignee", "labels", "add-labels", "remove-labels", "parent-task", "clear-parent",
    };
    for (names) |name| if (context.args.has(name)) return true;
    return false;
}

/// Reads --description-file if given (taking precedence), otherwise returns --description.
fn descriptionValue(context: *const Context) !?[]const u8 {
    if (context.args.get("description-file")) |path| return try common.readFile(context.allocator, path, 2 * 1024 * 1024);
    return context.args.get("description");
}

fn responseTicket(context: *const Context, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, body, .{});
    defer parsed.deinit();
    const task_value = parsed.value.object.get("task") orelse return error.InvalidResponse;
    const ticket_value = task_value.object.get("ticketNumber") orelse return error.InvalidResponse;
    if (ticket_value != .string) return error.InvalidResponse;
    return context.allocator.dupe(u8, ticket_value.string);
}

fn resolveLabelIds(context: *const Context, inputs: []const []const u8, project_id: ?i64, always_fetch: bool) ![]const []const u8 {
    if (inputs.len == 0) return &.{};
    var needs_lookup = always_fetch;
    for (inputs) |value| if (!isLabelId(value)) {
        needs_lookup = true;
        break;
    };
    if (!needs_lookup) return inputs;
    const project = project_id orelse return error.MissingProject;
    var path = try query.Builder.init(context.allocator, "/mcp/projects");
    defer path.deinit();
    try path.add("limit", "100");
    try path.add("offset", "0");
    var response = try context.fetch(.GET, path.path(), null);
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return error.CommandFailed;
    const document = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer document.deinit();
    const projects = document.value.object.get("projects") orelse return error.InvalidResponse;
    var available: ?std.json.Value = null;
    for (projects.array.items) |candidate| {
        const id = candidate.object.get("id") orelse continue;
        if (id == .integer and id.integer == project) {
            available = candidate.object.get("labels") orelse return error.LabelNotFound;
            break;
        }
    }
    const labels = available orelse return error.LabelNotFound;
    var result: std.ArrayListUnmanaged([]const u8) = .{};
    for (inputs) |input| {
        if (isLabelId(input)) {
            try result.append(context.allocator, input);
            continue;
        }
        var match: ?[]const u8 = null;
        for (labels.array.items) |label| {
            const name = label.object.get("name") orelse continue;
            const id = label.object.get("id") orelse continue;
            if (name == .string and std.ascii.eqlIgnoreCase(name.string, input)) {
                match = switch (id) {
                    .string => |value| try context.allocator.dupe(u8, value),
                    .integer => |value| try std.fmt.allocPrint(context.allocator, "{d}", .{value}),
                    else => null,
                };
                break;
            }
        }
        try result.append(context.allocator, match orelse return error.LabelNotFound);
    }
    return result.toOwnedSlice(context.allocator);
}

fn isLabelId(value: []const u8) bool {
    if (resolve.isNumeric(value)) return true;
    return value.len == 36 and value[8] == '-' and value[13] == '-' and value[18] == '-' and value[23] == '-';
}

fn hasDescription(task: std.json.Value) bool {
    if (task != .object) return false;
    const description = task.object.get("description") orelse return false;
    return description == .string and description.string.len != 0;
}

fn mergeSearchTask(allocator: std.mem.Allocator, task: *std.json.Value, detail_body: []const u8) !void {
    const detail = try std.json.parseFromSliceLeaky(std.json.Value, allocator, detail_body, .{});
    if (detail != .object) return error.InvalidResponse;
    const detail_tasks = detail.object.get("tasks") orelse return error.InvalidResponse;
    if (detail_tasks != .array or detail_tasks.array.items.len == 0) return error.InvalidResponse;
    const detail_task = detail_tasks.array.items[0];
    if (detail_task != .object) return error.InvalidResponse;
    const description = detail_task.object.get("description") orelse return error.InvalidResponse;
    if (description != .string) return error.InvalidResponse;
    try task.object.put("description", .{ .string = try allocator.dupe(u8, description.string) });
    try addSearchTaskLink(allocator, task);
}

fn taskMutationBody(context: *const Context, response: *http.Response) ![]u8 {
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) {
        try output.finish(response);
        return error.CommandFailed;
    }
    return addTaskLinkToResponse(context.allocator, response.body);
}

fn addTaskLinkToResponse(allocator: std.mem.Allocator, response_body: []const u8) ![]u8 {
    var document = try std.json.parseFromSliceLeaky(std.json.Value, allocator, response_body, .{});
    if (document != .object) return error.InvalidResponse;
    if (document.object.getPtr("task")) |task| try addSearchTaskLink(allocator, task);
    return std.json.Stringify.valueAlloc(allocator, document, .{});
}

fn addSearchTaskLink(allocator: std.mem.Allocator, task: *std.json.Value) !void {
    if (task.* != .object) return error.InvalidResponse;
    const ticket_value = task.object.get("ticketNumber") orelse return;
    const project_value = task.object.get("projectId") orelse return;
    if (ticket_value != .string or project_value != .integer) return;
    const unique_index = if (task.object.get("uniqueIndex")) |value| blk: {
        if (value != .integer) return;
        break :blk value.integer;
    } else blk: {
        const separator = std.mem.lastIndexOfScalar(u8, ticket_value.string, '-') orelse return;
        if (separator + 1 >= ticket_value.string.len) return;
        break :blk std.fmt.parseInt(i64, ticket_value.string[separator + 1 ..], 10) catch return;
    };
    if (unique_index <= 0 or project_value.integer <= 0) return;

    const url = try std.fmt.allocPrint(
        allocator,
        "https://app.hypertask.ai/detail/project-{d}/{d}",
        .{ project_value.integer, unique_index },
    );
    var link = std.json.ObjectMap.init(allocator);
    try link.put("url", .{ .string = url });
    try link.put("format", .{ .string = "https://app.hypertask.ai/detail/project-{projectId}/{uniqueIndex}" });
    try link.put("example", .{ .string = url });
    try task.object.put("link", .{ .object = link });
}

test "search response restores description and link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var task = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"id":32507,"ticketNumber":"HTPR-5658","title":"Status bar","description":"","projectId":15}
    , .{});
    try mergeSearchTask(allocator, &task,
        \\{"success":true,"tasks":[{"id":32507,"ticketNumber":"HTPR-5658","description":"<p>Full description</p>","projectId":15}]}
    );

    try std.testing.expectEqualStrings("<p>Full description</p>", task.object.get("description").?.string);
    const link = task.object.get("link").?.object;
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-15/5658", link.get("url").?.string);
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-{projectId}/{uniqueIndex}", link.get("format").?.string);
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-15/5658", link.get("example").?.string);
}

test "write responses include the control task link shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = try addTaskLinkToResponse(allocator,
        \\{"success":true,"task":{"ticketNumber":"HTPR-5827","projectId":15}}
    );
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    const link = parsed.object.get("task").?.object.get("link").?.object;
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-15/5827", link.get("url").?.string);
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-{projectId}/{uniqueIndex}", link.get("format").?.string);
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-15/5827", link.get("example").?.string);
}

test "task links prefer the unique index after a board move" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = try addTaskLinkToResponse(allocator,
        \\{"success":true,"task":{"ticketNumber":"INAI-19","uniqueIndex":1668,"projectId":339}}
    );
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    const link = parsed.object.get("task").?.object.get("link").?.object;
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-339/1668", link.get("url").?.string);
    try std.testing.expectEqualStrings("https://app.hypertask.ai/detail/project-339/1668", link.get("example").?.string);
}
