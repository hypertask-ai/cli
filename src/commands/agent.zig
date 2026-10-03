const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const config = @import("../config.zig");
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");
const query = @import("../query.zig");
const resolve = @import("../resolve.zig");
const state_store = @import("../state_store.zig");
const State = state_store.State;
const TicketCursors = state_store.TicketCursors;
const html_util = @import("../html_util.zig");
const agent_dev = @import("agent_dev.zig");

const PollState = struct {
    seen: std.StringHashMap(void),
    watermark: []u8,
};

const EnvironmentValue = struct {
    value: ?[]const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *EnvironmentValue, allocator: std.mem.Allocator) void {
        if (self.owned) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "say")) return say(context);
    if (std.mem.eql(u8, subcommand, "take")) return assignSelf(context, "assign");
    if (std.mem.eql(u8, subcommand, "drop")) return assignSelf(context, "unassign");
    if (std.mem.eql(u8, subcommand, "move")) return move(context);
    if (std.mem.eql(u8, subcommand, "poll")) return poll(context);
    if (std.mem.eql(u8, subcommand, "new-tickets")) return newTickets(context);
    if (std.mem.eql(u8, subcommand, "hand")) return hand(context);
    if (std.mem.eql(u8, subcommand, "dev") or std.mem.eql(u8, subcommand, "replay")) return agent_dev.run(context, subcommand);
    return error.UnknownCommand;
}

fn say(context: *const Context) !void {
    const ticket = try normalizedTicketArgument(context, 2);
    const text = context.args.positionalAt(3) orelse context.args.get("text") orelse context.args.get("body") orelse return error.MissingOption;
    try guard(context, ticket);

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("ticket_number", ticket);
    try body.string("text", text);
    var reply_comment = try resolveEnvironment(context.allocator, "HT_REPLY_TO_COMMENT_ID");
    defer reply_comment.deinit(context.allocator);
    if (reply_comment.value) |value| try body.integer("reply_to_comment_id", try common.positiveInt(value, "reply comment id"));
    var reply_invocation = try resolveEnvironment(context.allocator, "HT_REPLY_TO_INVOCATION_ID");
    defer reply_invocation.deinit(context.allocator);
    if (reply_invocation.value) |value| try body.integer("reply_to_invocation_id", try common.positiveInt(value, "reply invocation id"));

    var response = try context.fetch(.POST, "/mcp/comments", try body.finish());
    defer response.deinit();
    try requireSuccess(context, &response);
    if (commentId(response.body)) |id| {
        // The comment already exists remotely, so local bookkeeping must not make a retry post it twice.
        if (statePaths(context)) |state_value| {
            var state = state_value;
            defer state.deinit(context.allocator);
            appendSeen(context, state, ticket, id) catch {};
        } else |_| {}
    }
    try context.print(response.body);
}

fn assignSelf(context: *const Context, intent: []const u8) !void {
    const ticket = try normalizedTicketArgument(context, 2);
    try guard(context, ticket);
    const task = try resolve.task(context, ticket);
    try claimLease(context, task.id);
    defer releaseLease(context, task.id) catch {};

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("ticket_number", ticket);
    try body.boolean("assign_self", true);
    try body.string("intent", intent);
    try context.call(.POST, "/mcp/assignees/assign", try body.finish());
}

fn move(context: *const Context) !void {
    const ticket = try normalizedTicketArgument(context, 2);
    const section = context.args.positionalAt(3) orelse context.args.get("section") orelse context.args.get("to") orelse return error.MissingOption;
    try guard(context, ticket);
    const task = try resolve.task(context, ticket);

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("ticket_number", ticket);
    try body.integer("sectionId", try resolve.sectionId(context, task.project_id, section));
    try context.call(.POST, "/mcp/tasks/update", try body.finish());
}

fn hand(context: *const Context) !void {
    const ticket = try normalizedTicketArgument(context, 2);
    const target = try context.args.requirePositional(3, "target-agent-id");
    try guard(context, ticket);
    const task = try resolve.task(context, ticket);
    try claimLease(context, task.id);
    defer releaseLease(context, task.id) catch {};

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("ticket_number", ticket);
    try body.string("agent_id", target);
    try body.string("intent", "assign");
    var response = try context.fetch(.POST, "/mcp/assignees/assign", try body.finish());
    defer response.deinit();
    try requireSuccess(context, &response);

    if (!context.args.has("add")) try removeOtherAgents(context, ticket, target, response.body);
    try context.print(response.body);
}

fn removeOtherAgents(context: *const Context, ticket: []const u8, target: []const u8, response_body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response_body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const assignees = parsed.value.object.get("assignees") orelse return;
    if (assignees != .array) return error.InvalidResponse;
    for (assignees.array.items) |assignee| {
        const agent = json.objectField(assignee, "agent") orelse continue;
        const agent_id = json.stringField(agent, "id") orelse json.stringField(agent, "agentId") orelse continue;
        if (std.mem.eql(u8, agent_id, target)) continue;
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("ticket_number", ticket);
        try body.string("agent_id", agent_id);
        try body.string("intent", "unassign");
        var response = try context.fetch(.POST, "/mcp/assignees/assign", try body.finish());
        defer response.deinit();
        try requireSuccess(context, &response);
    }
}

fn poll(context: *const Context) !void {
    const project = try projectId(context);
    try guard(context, null);
    var state = try statePaths(context);
    defer state.deinit(context.allocator);
    try state_store.ensureStateDirectory(state.directory);
    var operation_lock = try state_store.acquireFileLock(state.poll_lock_path);
    defer state_store.releaseStateLock(&operation_lock);
    var stored = try loadPollState(context, state);
    defer state_store.deinitLineSet(context.allocator, &stored.seen);
    defer context.allocator.free(stored.watermark);
    const watermark = stored.watermark;
    const seen = &stored.seen;

    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(context.allocator);
    var newest = try context.allocator.dupe(u8, watermark);
    defer context.allocator.free(newest);
    var cursor = try context.allocator.dupe(u8, "");
    defer context.allocator.free(cursor);

    while (true) {
        var path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer path.deinit();
        try path.addInt("project_id", project);
        try path.add("limit", "100");
        try path.add("cursor", cursor);
        var response = try context.fetch(.GET, path.path(), null);
        defer response.deinit();
        try requireSuccess(context, &response);

        const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
        defer parsed.deinit();
        const tasks = json.arrayField(parsed.value, "tasks") orelse return error.InvalidResponse;
        for (tasks) |task| {
            const updated = json.stringField(task, "updatedAt") orelse "";
            if (updated.len != 0 and (newest.len == 0 or std.mem.order(u8, updated, newest) == .gt)) {
                const next = try context.allocator.dupe(u8, updated);
                context.allocator.free(newest);
                newest = next;
            }
            if (predatesWatermark(updated, watermark)) continue;
            const ticket = json.stringField(task, "ticketNumber") orelse continue;
            try pollTicket(context, seen, &result, ticket);
        }
        const next_cursor = json.stringField(parsed.value, "nextCursor") orelse break;
        if (next_cursor.len == 0 or std.mem.eql(u8, next_cursor, cursor)) break;
        const next = try context.allocator.dupe(u8, next_cursor);
        context.allocator.free(cursor);
        cursor = next;
    }

    if (result.items.len != 0) try output.print(result.items);
    try commitPollState(context, state, seen, newest);
}

fn pollTicket(context: *const Context, seen: *std.StringHashMap(void), result: *std.ArrayListUnmanaged(u8), ticket: []const u8) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/comments");
    defer path.deinit();
    try path.add("ticket_number", ticket);
    var response = try context.fetch(.GET, path.path(), null);
    defer response.deinit();
    try requireSuccess(context, &response);
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const comments = json.arrayField(parsed.value, "comments") orelse return error.InvalidResponse;
    var agent_id_value = try resolveOptionOrEnvironment(context, "agent-id", "HT_AGENT_ID");
    defer agent_id_value.deinit(context.allocator);
    const agent_id = agent_id_value.value orelse return error.MissingAgentIdentity;
    var agent_name_value = try resolveOptionOrEnvironment(context, "agent-name", "HT_AGENT_NAME");
    defer agent_name_value.deinit(context.allocator);
    const agent_name = agent_name_value.value orelse "";
    const all = context.args.has("all");
    const previous_cursors = state_store.ticketCursors(seen, ticket);
    var cursors = previous_cursors;

    for (comments) |comment| {
        const id = json.integerField(comment, "id", true) orelse continue;
        const agent = json.objectField(comment, "agent");
        const ours = if (agent) |value| if (json.stringField(value, "id")) |id_value| std.mem.eql(u8, id_value, agent_id) else false else false;
        if (json.arrayField(comment, "reactions")) |reactions| {
            for (reactions) |reaction| {
                const reaction_id = json.integerField(reaction, "id", true) orelse continue;
                const reaction_key = try state_store.stateKey(context.allocator, ticket, "r:", reaction_id);
                defer context.allocator.free(reaction_key);
                const already_seen = reaction_id <= previous_cursors.reaction or state_store.seenContains(seen, ticket, reaction_key, reaction_id, true);
                cursors.reaction = @max(cursors.reaction, reaction_id);
                if (already_seen) continue;
                if (ours) {
                    const emoji = try boundedText(context.allocator, json.stringField(reaction, "emoji") orelse "", 32);
                    defer context.allocator.free(emoji);
                    const html = try boundedText(context.allocator, json.stringField(comment, "text") orelse "", 160);
                    defer context.allocator.free(html);
                    try result.writer(context.allocator).print("REACTION {s} {s} on your comment: {s}\n", .{ ticket, emoji, html });
                }
            }
        }

        const key = try state_store.stateKey(context.allocator, ticket, "", id);
        defer context.allocator.free(key);
        const already_seen = id <= previous_cursors.comment or state_store.seenContains(seen, ticket, key, id, false);
        cursors.comment = @max(cursors.comment, id);
        if (already_seen) continue;
        const html = json.stringField(comment, "text") orelse "";
        const addressed = html_util.addressesAgent(html, agent_id, agent_name);
        if (!all and !addressed) continue;
        const creator = json.objectField(comment, "creator");
        const author = try boundedText(context.allocator, if (creator) |value| json.stringField(value, "displayName") orelse "someone" else "someone", 100);
        defer context.allocator.free(author);
        const text = try boundedText(context.allocator, html, 500);
        defer context.allocator.free(text);
        try result.writer(context.allocator).print("{s} {s} commentId={d} from {s}: {s}\n", .{
            if (addressed) "ADDRESSED" else "fyi",
            ticket,
            id,
            author,
            text,
        });
    }
    try state_store.compactTicketState(context.allocator, seen, ticket, cursors);
}

fn newTickets(context: *const Context) !void {
    const project = try projectId(context);
    try guard(context, null);
    var state = try statePaths(context);
    defer state.deinit(context.allocator);
    try state_store.ensureStateDirectory(state.directory);
    var operation_lock = try state_store.acquireFileLock(state.tickets_lock_path);
    defer state_store.releaseStateLock(&operation_lock);
    var known = try loadLineState(context, state, state.tickets_path);
    defer state_store.deinitLineSet(context.allocator, &known);

    const label = context.args.get("label") orelse context.args.positionalAt(2);
    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(context.allocator);
    var cursor = try context.allocator.dupe(u8, "");
    defer context.allocator.free(cursor);

    while (true) {
        var path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer path.deinit();
        try path.addInt("project_id", project);
        try path.add("limit", "100");
        try path.add("cursor", cursor);
        var response = try context.fetch(.GET, path.path(), null);
        defer response.deinit();
        try requireSuccess(context, &response);
        const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
        defer parsed.deinit();
        const tasks = json.arrayField(parsed.value, "tasks") orelse return error.InvalidResponse;

        for (tasks) |task| {
            if (label) |wanted| if (!taskHasLabel(task, wanted)) continue;
            const ticket = json.stringField(task, "ticketNumber") orelse continue;
            if (known.contains(ticket)) continue;
            try state_store.putLine(context.allocator, &known, ticket);
            const section = try boundedText(context.allocator, json.stringField(task, "section") orelse "", 100);
            defer context.allocator.free(section);
            const title = try boundedText(context.allocator, json.stringField(task, "title") orelse "", 90);
            defer context.allocator.free(title);
            try result.writer(context.allocator).print("NEW {s} [{s}] {s}\n", .{ ticket, section, title });
        }
        const next_cursor = json.stringField(parsed.value, "nextCursor") orelse break;
        if (next_cursor.len == 0 or std.mem.eql(u8, next_cursor, cursor)) break;
        const next = try context.allocator.dupe(u8, next_cursor);
        context.allocator.free(cursor);
        cursor = next;
    }
    if (result.items.len != 0) try output.print(result.items);
    try commitLineState(context, state, state.tickets_path, &known);
}

fn guard(context: *const Context, ticket: ?[]const u8) !void {
    var scoped_slug_value = try resolveEnvironment(context.allocator, "HT_CAPABILITY_AGENT_SLUG");
    defer scoped_slug_value.deinit(context.allocator);
    const scoped_slug = scoped_slug_value.value;
    var environment_slug = try resolveEnvironment(context.allocator, "HT_AGENT_SLUG");
    defer environment_slug.deinit(context.allocator);
    const actual_slug = try guardedAgentSlug(scoped_slug, context.args.get("slug"), environment_slug.value);
    var scoped_ticket_value = try resolveEnvironment(context.allocator, "HT_CAPABILITY_TICKET");
    defer scoped_ticket_value.deinit(context.allocator);
    var expires_value = try resolveEnvironment(context.allocator, "HT_CAPABILITY_EXPIRES_AT");
    defer expires_value.deinit(context.allocator);
    const expires_at = if (expires_value.value) |value| try std.fmt.parseInt(i64, value, 10) else null;
    try guardCapability(std.time.timestamp(), expires_at, scoped_slug, actual_slug, scoped_ticket_value.value, ticket);
}

fn guardedAgentSlug(scoped_slug: ?[]const u8, option_slug: ?[]const u8, environment_slug: ?[]const u8) !?[]const u8 {
    if (scoped_slug != null and option_slug != null) return error.CapabilityAgentOverride;
    return if (scoped_slug != null) environment_slug else option_slug orelse environment_slug;
}

fn guardCapability(now: i64, expires_at: ?i64, scoped_slug: ?[]const u8, actual_slug: ?[]const u8, scoped_ticket: ?[]const u8, ticket: ?[]const u8) !void {
    if (expires_at) |value| if (now > value) return error.CapabilityExpired;
    if (scoped_slug) |expected| {
        const actual = actual_slug orelse return error.CapabilityAgentMismatch;
        if (!std.mem.eql(u8, expected, actual)) return error.CapabilityAgentMismatch;
    }
    if (scoped_ticket) |expected| {
        const actual = ticket orelse return error.CapabilityTicketMismatch;
        if (!std.mem.eql(u8, expected, actual)) return error.CapabilityTicketMismatch;
    }
}

fn normalizedTicketArgument(context: *const Context, index: usize) ![]const u8 {
    return resolve.normalizedTicket(context.allocator, try context.args.requirePositional(index, "ticket"));
}

fn projectId(context: *const Context) !i64 {
    if (context.args.get("project")) |value| return common.positiveInt(value, "project");
    var environment_value = try resolveEnvironment(context.allocator, "HT_AGENT_PROJECT_ID");
    defer environment_value.deinit(context.allocator);
    return common.positiveInt(environment_value.value orelse return error.MissingProject, "project");
}

fn statePaths(context: *const Context) !State {
    var state_directory = try resolveOptionOrEnvironment(context, "state-dir", "HT_AGENT_STATE_DIR");
    defer state_directory.deinit(context.allocator);
    var home_value = try resolveEnvironment(context.allocator, "HOME");
    defer home_value.deinit(context.allocator);
    var slug_value = try resolveOptionOrEnvironment(context, "slug", "HT_AGENT_SLUG");
    defer slug_value.deinit(context.allocator);
    var agent_id_value = try resolveOptionOrEnvironment(context, "agent-id", "HT_AGENT_ID");
    defer agent_id_value.deinit(context.allocator);
    var project_value = try resolveEnvironment(context.allocator, "HT_AGENT_PROJECT_ID");
    defer project_value.deinit(context.allocator);

    const directory = if (state_directory.value) |path|
        try context.allocator.dupe(u8, path)
    else blk: {
        const home = home_value.value orelse return error.NoHome;
        const identity = slug_value.value orelse agent_id_value.value orelse return error.MissingAgentIdentity;
        const project = context.args.get("project") orelse project_value.value orelse "global";
        var endpoint_buffer: [16]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{x}", .{std.hash.Wyhash.hash(0, context.cfg.api_url)});
        break :blk try std.fs.path.join(context.allocator, &.{ home, ".local", "state", "hypertask-agent", endpoint, project, identity });
    };
    errdefer context.allocator.free(directory);
    const lock_path = try std.fs.path.join(context.allocator, &.{ directory, "state.lock" });
    errdefer context.allocator.free(lock_path);
    const poll_lock_path = try std.fs.path.join(context.allocator, &.{ directory, "poll.lock" });
    errdefer context.allocator.free(poll_lock_path);
    const tickets_lock_path = try std.fs.path.join(context.allocator, &.{ directory, "new-tickets.lock" });
    errdefer context.allocator.free(tickets_lock_path);
    const seen_path = try std.fs.path.join(context.allocator, &.{ directory, "seen" });
    errdefer context.allocator.free(seen_path);
    const tickets_path = try std.fs.path.join(context.allocator, &.{ directory, "tickets" });
    errdefer context.allocator.free(tickets_path);
    return .{
        .directory = directory,
        .lock_path = lock_path,
        .poll_lock_path = poll_lock_path,
        .tickets_lock_path = tickets_lock_path,
        .seen_path = seen_path,
        .tickets_path = tickets_path,
        .watermark_path = try std.fs.path.join(context.allocator, &.{ directory, "watermark" }),
    };
}

fn loadPollState(context: *const Context, state: State) !PollState {
    var state_lock = try state_store.acquireStateLock(state);
    defer state_store.releaseStateLock(&state_lock);
    try migrateLegacyState(context, state);
    var seen = try state_store.readLines(context.allocator, state.seen_path);
    errdefer state_store.deinitLineSet(context.allocator, &seen);
    return .{
        .seen = seen,
        .watermark = try state_store.readSmallFile(context.allocator, state.watermark_path),
    };
}

fn loadLineState(context: *const Context, state: State, path: []const u8) !std.StringHashMap(void) {
    var state_lock = try state_store.acquireStateLock(state);
    defer state_store.releaseStateLock(&state_lock);
    try migrateLegacyState(context, state);
    return state_store.readLines(context.allocator, path);
}

fn commitPollState(context: *const Context, state: State, seen: *const std.StringHashMap(void), newest: []const u8) !void {
    var state_lock = try state_store.acquireStateLock(state);
    defer state_store.releaseStateLock(&state_lock);
    var current = try state_store.readLines(context.allocator, state.seen_path);
    defer state_store.deinitLineSet(context.allocator, &current);
    try state_store.mergeLineSet(context.allocator, &current, seen);
    try state_store.compactMergedCursorState(context.allocator, &current, seen);
    try state_store.writeLineSet(context.allocator, state.seen_path, &current);

    const watermark = try state_store.readSmallFile(context.allocator, state.watermark_path);
    defer context.allocator.free(watermark);
    if (newest.len != 0 and (watermark.len == 0 or std.mem.order(u8, newest, watermark) == .gt)) {
        try state_store.writeStateFile(context.allocator, state.watermark_path, newest);
    }
}

fn commitLineState(context: *const Context, state: State, path: []const u8, values: *const std.StringHashMap(void)) !void {
    var state_lock = try state_store.acquireStateLock(state);
    defer state_store.releaseStateLock(&state_lock);
    var current = try state_store.readLines(context.allocator, path);
    defer state_store.deinitLineSet(context.allocator, &current);
    try state_store.mergeLineSet(context.allocator, &current, values);
    try state_store.writeLineSet(context.allocator, path, &current);
}

fn appendSeen(context: *const Context, state: State, ticket: []const u8, id: i64) !void {
    try state_store.ensureStateDirectory(state.directory);
    var state_lock = try state_store.acquireStateLock(state);
    defer state_store.releaseStateLock(&state_lock);
    try migrateLegacyState(context, state);
    const key = try state_store.stateKey(context.allocator, ticket, "", id);
    defer context.allocator.free(key);
    try state_store.appendStateLine(context.allocator, state.seen_path, key);
}

fn migrateLegacyState(context: *const Context, state: State) !void {
    var home_value = try resolveEnvironment(context.allocator, "HOME");
    defer home_value.deinit(context.allocator);
    const home = home_value.value orelse return;
    var slug_value = try resolveOptionOrEnvironment(context, "slug", "HT_AGENT_SLUG");
    defer slug_value.deinit(context.allocator);
    const slug = slug_value.value orelse return;
    const legacy_directory = try std.fs.path.join(context.allocator, &.{ home, ".config", "hypertask-agents" });
    defer context.allocator.free(legacy_directory);
    if (!try legacyScopeMatches(context, legacy_directory, slug)) return;
    const names = [_][2][]const u8{
        .{ "seen", state.seen_path },
        .{ "tickets", state.tickets_path },
        .{ "watermark", state.watermark_path },
    };
    for (names) |entry| {
        if (std.fs.cwd().access(entry[1], .{})) |_| continue else |err| if (err != error.FileNotFound) return err;
        const source = try std.fmt.allocPrint(context.allocator, "{s}/{s}.{s}", .{ legacy_directory, slug, entry[0] });
        defer context.allocator.free(source);
        const raw = (try state_store.readOptionalFile(context.allocator, source)) orelse continue;
        defer context.allocator.free(raw);
        try state_store.writeStateFile(context.allocator, entry[1], std.mem.trimRight(u8, raw, "\r\n"));
    }
}

fn legacyScopeMatches(context: *const Context, directory: []const u8, slug: []const u8) !bool {
    if (!std.mem.eql(u8, context.cfg.api_url, config.default_api_url)) return false;
    var agent_id_value = try resolveOptionOrEnvironment(context, "agent-id", "HT_AGENT_ID");
    defer agent_id_value.deinit(context.allocator);
    const agent_id = agent_id_value.value orelse return false;
    var project_value = try resolveEnvironment(context.allocator, "HT_AGENT_PROJECT_ID");
    defer project_value.deinit(context.allocator);
    const project = context.args.get("project") orelse project_value.value orelse return false;
    const path = try std.fmt.allocPrint(context.allocator, "{s}/{s}.env", .{ directory, slug });
    defer context.allocator.free(path);
    const raw = (try state_store.readOptionalFile(context.allocator, path)) orelse return false;
    defer context.allocator.free(raw);
    return legacyScopeFieldsMatch(raw, agent_id, project);
}

fn legacyScopeFieldsMatch(raw: []const u8, agent_id: []const u8, project: []const u8) bool {
    const legacy_agent_id = legacyEnvironmentValue(raw, "HT_AGENT_ID") orelse return false;
    const projects = legacyEnvironmentValue(raw, "HT_AGENT_PROJECTS") orelse return false;
    const first_project = if (std.mem.indexOfScalar(u8, projects, ',')) |index| projects[0..index] else projects;
    return std.mem.eql(u8, legacy_agent_id, agent_id) and std.mem.eql(u8, std.mem.trim(u8, first_project, " \t"), project);
}

fn legacyEnvironmentValue(raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, name) or trimmed.len <= name.len or trimmed[name.len] != '=') continue;
        var value = std.mem.trim(u8, trimmed[name.len + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
            value = value[1 .. value.len - 1];
        }
        return value;
    }
    return null;
}

fn predatesWatermark(updated: []const u8, watermark: []const u8) bool {
    return updated.len != 0 and watermark.len != 0 and std.mem.order(u8, updated, watermark) == .lt;
}

fn claimLease(context: *const Context, task_id: i64) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("task_id", task_id);
    try body.integer("ttl_seconds", 120);
    var response = try context.fetch(.POST, "/mcp/tasks/lease/claim", try body.finish());
    defer response.deinit();
    try requireSuccess(context, &response);
}

fn releaseLease(context: *const Context, task_id: i64) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("task_id", task_id);
    var response = try context.fetch(.POST, "/mcp/tasks/lease/release", try body.finish());
    defer response.deinit();
    try requireSuccess(context, &response);
}

fn requireSuccess(context: *const Context, response: *http.Response) !void {
    if (!response.isSuccess()) return context.finish(response);
}

fn commentId(response_body: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response_body, .{}) catch return null;
    defer parsed.deinit();
    const comment = json.objectField(parsed.value, "comment") orelse return null;
    return json.integerField(comment, "id", true);
}

fn taskHasLabel(task: std.json.Value, wanted: []const u8) bool {
    const labels = json.arrayField(task, "labels") orelse return false;
    for (labels) |label| {
        const name = json.stringField(label, "name") orelse continue;
        if (std.ascii.eqlIgnoreCase(name, wanted)) return true;
    }
    return false;
}

fn boundedText(allocator: std.mem.Allocator, value: []const u8, limit: usize) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    var index: usize = 0;
    var pending_space = false;

    while (index < value.len) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        const end = index + sequence_length;
        const codepoint = if (end <= value.len) std.unicode.utf8Decode(value[index..end]) catch null else null;
        if (codepoint == null) {
            if (pending_space and result.items.len != 0) {
                if (result.items.len + 1 >= limit) break;
                try result.append(allocator, ' ');
                pending_space = false;
            }
            if (result.items.len >= limit) break;
            try result.append(allocator, '?');
            index += 1;
            continue;
        }

        if (codepoint.? <= 0x20 or (codepoint.? >= 0x7f and codepoint.? <= 0x9f) or codepoint.? == 0x2028 or codepoint.? == 0x2029) {
            pending_space = result.items.len != 0;
            index = end;
            continue;
        }
        if (pending_space) {
            if (result.items.len + 1 + sequence_length > limit) break;
            try result.append(allocator, ' ');
            pending_space = false;
        }
        if (result.items.len + sequence_length > limit) break;
        try result.appendSlice(allocator, value[index..end]);
        index = end;
    }
    return result.toOwnedSlice(allocator);
}

fn resolveOptionOrEnvironment(context: *const Context, option: []const u8, name: []const u8) !EnvironmentValue {
    if (context.args.get(option)) |value| return .{ .value = value };
    return resolveEnvironment(context.allocator, name);
}

fn resolveEnvironment(allocator: std.mem.Allocator, name: []const u8) !EnvironmentValue {
    const owned = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return .{ .value = null },
        else => return err,
    };
    if (owned.len == 0) {
        allocator.free(owned);
        return .{ .value = null };
    }
    return .{ .value = owned, .owned = owned };
}

test "capability guards reject expired and cross-ticket operations" {
    try std.testing.expectError(error.CapabilityExpired, guardCapability(11, 10, null, null, null, null));
    try std.testing.expectError(error.CapabilityAgentMismatch, guardCapability(10, 10, "dev-3", "dev-2", null, null));
    try std.testing.expectError(error.CapabilityTicketMismatch, guardCapability(10, null, null, null, "HTPR-1", "HTPR-2"));
    try std.testing.expectError(error.CapabilityTicketMismatch, guardCapability(10, null, null, null, "HTPR-1", null));
    try guardCapability(10, 10, "dev-3", "dev-3", "HTPR-1", "HTPR-1");
}

test "scoped capability rejects command-line agent slug overrides" {
    try std.testing.expectError(error.CapabilityAgentOverride, guardedAgentSlug("dev-3", "dev-3", "dev-3"));
    try std.testing.expectEqualStrings("dev-3", (try guardedAgentSlug("dev-3", null, "dev-3")).?);
    try std.testing.expectEqualStrings("dev-2", (try guardedAgentSlug(null, "dev-2", "dev-3")).?);
}

test "bounded text produces one safe UTF-8 output line" {
    const sanitized = try boundedText(std.testing.allocator, " \nhello\tworld\x1b[31m\x7f! ", 100);
    defer std.testing.allocator.free(sanitized);
    try std.testing.expectEqualStrings("hello world [31m !", sanitized);
    try std.testing.expect(std.unicode.utf8ValidateSlice(sanitized));

    const truncated = try boundedText(std.testing.allocator, "éééé", 7);
    defer std.testing.allocator.free(truncated);
    try std.testing.expectEqualStrings("ééé", truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
}

test "poll processes tasks sharing the watermark timestamp" {
    try std.testing.expect(!predatesWatermark("2026-08-31T12:00:00.000Z", "2026-08-31T12:00:00.000Z"));
    try std.testing.expect(!predatesWatermark("2026-08-31T12:00:01.000Z", "2026-08-31T12:00:00.000Z"));
    try std.testing.expect(predatesWatermark("2026-08-31T11:59:59.000Z", "2026-08-31T12:00:00.000Z"));
}

test "legacy migration requires matching identity and first project" {
    const raw = "HT_AGENT_NAME=Dev 3\nHT_AGENT_ID=agent-3\nHT_AGENT_PROJECTS=15,16\n";
    try std.testing.expect(legacyScopeFieldsMatch(raw, "agent-3", "15"));
    try std.testing.expect(!legacyScopeFieldsMatch(raw, "agent-2", "15"));
    try std.testing.expect(!legacyScopeFieldsMatch(raw, "agent-3", "16"));
    try std.testing.expect(!legacyScopeFieldsMatch("HT_AGENT_ID=agent-3\n", "agent-3", "15"));
}
