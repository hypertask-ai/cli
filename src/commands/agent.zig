const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");
const query = @import("../query.zig");
const resolve = @import("../resolve.zig");

const State = struct {
    directory: []const u8,
    seen_path: []const u8,
    tickets_path: []const u8,
    watermark_path: []const u8,
};

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "say")) return say(context);
    if (std.mem.eql(u8, subcommand, "take")) return assignSelf(context, "assign");
    if (std.mem.eql(u8, subcommand, "drop")) return assignSelf(context, "unassign");
    if (std.mem.eql(u8, subcommand, "move")) return move(context);
    if (std.mem.eql(u8, subcommand, "poll")) return poll(context);
    if (std.mem.eql(u8, subcommand, "new-tickets")) return newTickets(context);
    if (std.mem.eql(u8, subcommand, "hand")) return hand(context);
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
    if (environment("HT_REPLY_TO_COMMENT_ID")) |value| try body.integer("reply_to_comment_id", try common.positiveInt(value, "reply comment id"));
    if (environment("HT_REPLY_TO_INVOCATION_ID")) |value| try body.integer("reply_to_invocation_id", try common.positiveInt(value, "reply invocation id"));

    var response = try context.fetch(.POST, "/mcp/comments", try body.finish());
    defer response.deinit();
    try requireSuccess(context, &response);
    if (commentId(response.body)) |id| {
        const state = try statePaths(context);
        try appendSeen(context, state, ticket, id);
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
        const agent = objectField(assignee, "agent") orelse continue;
        const agent_id = stringField(agent, "id") orelse stringField(agent, "agentId") orelse continue;
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
    const state = try statePaths(context);
    try ensureStateDirectory(state.directory);
    try migrateLegacyState(context, state);
    var seen = try readLines(context.allocator, state.seen_path);
    defer seen.deinit();
    const watermark = try readSmallFile(context.allocator, state.watermark_path);

    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(context.allocator);
    var newest: []const u8 = watermark;
    var offset: i64 = 0;
    var reached_watermark = false;

    while (!reached_watermark) {
        var path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer path.deinit();
        try path.addInt("project_id", project);
        try path.add("limit", "100");
        try path.addInt("offset", offset);
        try path.add("sort_by", "updatedAt");
        try path.add("sort_order", "desc");
        var response = try context.fetch(.GET, path.path(), null);
        defer response.deinit();
        try requireSuccess(context, &response);

        const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
        defer parsed.deinit();
        const tasks = arrayField(parsed.value, "tasks") orelse return error.InvalidResponse;
        for (tasks) |task| {
            const updated = stringField(task, "updatedAt") orelse "";
            if (updated.len != 0 and (newest.len == 0 or std.mem.order(u8, updated, newest) == .gt)) newest = try context.allocator.dupe(u8, updated);
            if (watermark.len != 0 and updated.len != 0 and std.mem.order(u8, updated, watermark) != .gt) {
                reached_watermark = true;
                break;
            }
            const ticket = stringField(task, "ticketNumber") orelse continue;
            try pollTicket(context, &seen, &result, ticket);
        }
        if (tasks.len < 100) break;
        offset += @intCast(tasks.len);
    }

    if (result.items.len != 0) try output.print(result.items);
    try writeLineSet(context.allocator, state.seen_path, &seen);
    if (newest.len != 0 and !std.mem.eql(u8, newest, watermark)) try writeStateFile(context.allocator, state.watermark_path, newest);
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
    const comments = arrayField(parsed.value, "comments") orelse return error.InvalidResponse;
    const agent_id = optionOrEnvironment(context, "agent-id", "HT_AGENT_ID") orelse return error.MissingAgentIdentity;
    const agent_name = optionOrEnvironment(context, "agent-name", "HT_AGENT_NAME") orelse "";
    const all = context.args.has("all");

    for (comments) |comment| {
        const id = integerField(comment, "id") orelse continue;
        const agent = objectField(comment, "agent");
        const ours = if (agent) |value| if (stringField(value, "id")) |id_value| std.mem.eql(u8, id_value, agent_id) else false else false;
        if (arrayField(comment, "reactions")) |reactions| {
            for (reactions) |reaction| {
                const reaction_id = integerField(reaction, "id") orelse continue;
                const reaction_key = try stateKey(context.allocator, ticket, "r:", reaction_id);
                if (seenContains(seen, ticket, reaction_key, reaction_id, true)) continue;
                try seen.put(reaction_key, {});
                if (ours) {
                    const emoji = stringField(reaction, "emoji") orelse "";
                    const html = stringField(comment, "text") orelse "";
                    try result.writer(context.allocator).print("REACTION {s} {s} on your comment: {s}\n", .{ ticket, emoji, boundedWhitespace(html, 160) });
                }
            }
        }

        const key = try stateKey(context.allocator, ticket, "", id);
        if (seenContains(seen, ticket, key, id, false)) continue;
        try seen.put(key, {});
        const html = stringField(comment, "text") orelse "";
        const addressed = addressesAgent(html, agent_id, agent_name);
        if (!all and !addressed) continue;
        const creator = objectField(comment, "creator");
        const author = if (creator) |value| stringField(value, "displayName") orelse "someone" else "someone";
        try result.writer(context.allocator).print("{s} {s} commentId={d} from {s}: {s}\n", .{
            if (addressed) "ADDRESSED" else "fyi",
            ticket,
            id,
            author,
            boundedWhitespace(html, 500),
        });
    }
}

fn newTickets(context: *const Context) !void {
    const project = try projectId(context);
    try guard(context, null);
    const state = try statePaths(context);
    try ensureStateDirectory(state.directory);
    try migrateLegacyState(context, state);
    var known = try readLines(context.allocator, state.tickets_path);
    defer known.deinit();

    const label = context.args.get("label") orelse context.args.positionalAt(2);
    var result: std.ArrayListUnmanaged(u8) = .{};
    defer result.deinit(context.allocator);
    var offset: i64 = 0;

    while (true) {
        var path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer path.deinit();
        try path.addInt("project_id", project);
        try path.add("limit", "100");
        try path.addInt("offset", offset);
        var response = try context.fetch(.GET, path.path(), null);
        defer response.deinit();
        try requireSuccess(context, &response);
        const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
        defer parsed.deinit();
        const tasks = arrayField(parsed.value, "tasks") orelse return error.InvalidResponse;

        for (tasks) |task| {
            if (label) |wanted| if (!taskHasLabel(task, wanted)) continue;
            const ticket = stringField(task, "ticketNumber") orelse continue;
            if (known.contains(ticket)) continue;
            try known.put(try context.allocator.dupe(u8, ticket), {});
            const section = stringField(task, "section") orelse "";
            const title = stringField(task, "title") orelse "";
            try result.writer(context.allocator).print("NEW {s} [{s}] {s}\n", .{ ticket, section, boundedWhitespace(title, 90) });
        }
        if (tasks.len < 100) break;
        offset += @intCast(tasks.len);
    }
    if (result.items.len != 0) try output.print(result.items);
    try writeLineSet(context.allocator, state.tickets_path, &known);
}

fn guard(context: *const Context, ticket: ?[]const u8) !void {
    const scoped_slug = environment("HT_CAPABILITY_AGENT_SLUG");
    const actual_slug = optionOrEnvironment(context, "slug", "HT_AGENT_SLUG");
    const scoped_ticket = environment("HT_CAPABILITY_TICKET");
    const expires = environment("HT_CAPABILITY_EXPIRES_AT");
    const expires_at = if (expires) |value| try std.fmt.parseInt(i64, value, 10) else null;
    try guardCapability(std.time.timestamp(), expires_at, scoped_slug, actual_slug, scoped_ticket, ticket);
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
    const value = context.args.get("project") orelse environment("HT_AGENT_PROJECT_ID") orelse return error.MissingProject;
    return common.positiveInt(value, "project");
}

fn statePaths(context: *const Context) !State {
    const directory = optionOrEnvironment(context, "state-dir", "HT_AGENT_STATE_DIR") orelse blk: {
        const home = environment("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(context.allocator, &.{ home, ".local", "state", "hypertask-agent" });
    };
    return .{
        .directory = directory,
        .seen_path = try std.fs.path.join(context.allocator, &.{ directory, "seen" }),
        .tickets_path = try std.fs.path.join(context.allocator, &.{ directory, "tickets" }),
        .watermark_path = try std.fs.path.join(context.allocator, &.{ directory, "watermark" }),
    };
}

fn ensureStateDirectory(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn appendSeen(context: *const Context, state: State, ticket: []const u8, id: i64) !void {
    try ensureStateDirectory(state.directory);
    try migrateLegacyState(context, state);
    const key = try stateKey(context.allocator, ticket, "", id);
    try appendStateLine(context.allocator, state.seen_path, key);
}

fn migrateLegacyState(context: *const Context, state: State) !void {
    const home = environment("HOME") orelse return;
    const slug = optionOrEnvironment(context, "slug", "HT_AGENT_SLUG") orelse return;
    const legacy_directory = try std.fs.path.join(context.allocator, &.{ home, ".config", "hypertask-agents" });
    const names = [_][2][]const u8{
        .{ "seen", state.seen_path },
        .{ "tickets", state.tickets_path },
        .{ "watermark", state.watermark_path },
    };
    for (names) |entry| {
        if (std.fs.cwd().access(entry[1], .{})) |_| continue else |err| if (err != error.FileNotFound) return err;
        const source = try std.fmt.allocPrint(context.allocator, "{s}/{s}.{s}", .{ legacy_directory, slug, entry[0] });
        const raw = std.fs.cwd().readFileAlloc(context.allocator, source, 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try writeStateFile(context.allocator, entry[1], std.mem.trimRight(u8, raw, "\r\n"));
    }
}

fn appendStateLine(allocator: std.mem.Allocator, path: []const u8, line: []const u8) !void {
    _ = allocator;
    var file = try std.fs.cwd().createFile(path, .{ .truncate = false, .mode = 0o600 });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
    try file.writeAll("\n");
}

fn writeLineSet(allocator: std.mem.Allocator, path: []const u8, values: *const std.StringHashMap(void)) !void {
    var contents: std.ArrayListUnmanaged(u8) = .{};
    defer contents.deinit(allocator);
    var iterator = values.keyIterator();
    while (iterator.next()) |value| {
        try contents.appendSlice(allocator, value.*);
        try contents.append(allocator, '\n');
    }
    try writeStateFile(allocator, path, std.mem.trimRight(u8, contents.items, "\r\n"));
}

fn writeStateFile(allocator: std.mem.Allocator, path: []const u8, value: []const u8) !void {
    const pending = try std.fmt.allocPrint(allocator, "{s}.next", .{path});
    defer allocator.free(pending);
    var file = try std.fs.cwd().createFile(pending, .{ .truncate = true, .mode = 0o600 });
    try file.writeAll(value);
    try file.writeAll("\n");
    file.close();
    try std.fs.cwd().rename(pending, path);
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return "",
        else => return err,
    };
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn readLines(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMap(void) {
    var result = std.StringHashMap(void).init(allocator);
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) try result.put(trimmed, {});
    }
    return result;
}

fn stateKey(allocator: std.mem.Allocator, ticket: []const u8, middle: []const u8, id: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}{d}", .{ ticket, middle, id });
}

fn seenContains(seen: *const std.StringHashMap(void), ticket: []const u8, full_key: []const u8, id: i64, reaction: bool) bool {
    if (seen.contains(full_key)) return true;
    const separator = std.mem.lastIndexOfScalar(u8, ticket, '-') orelse return false;
    var legacy_buffer: [128]u8 = undefined;
    const legacy = std.fmt.bufPrint(&legacy_buffer, "{s}:{s}{d}", .{ ticket[separator + 1 ..], if (reaction) "r:" else "", id }) catch return false;
    return seen.contains(legacy);
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
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return context.finish(response);
}

fn commentId(response_body: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response_body, .{}) catch return null;
    defer parsed.deinit();
    const comment = objectField(parsed.value, "comment") orelse return null;
    return integerField(comment, "id");
}

fn taskHasLabel(task: std.json.Value, wanted: []const u8) bool {
    const labels = arrayField(task, "labels") orelse return false;
    for (labels) |label| {
        const name = stringField(label, "name") orelse continue;
        if (std.ascii.eqlIgnoreCase(name, wanted)) return true;
    }
    return false;
}

fn addressesAgent(html: []const u8, agent_id: []const u8, agent_name: []const u8) bool {
    var remaining = html;
    while (std.mem.indexOf(u8, remaining, "<span")) |start| {
        remaining = remaining[start..];
        const end = std.mem.indexOfScalar(u8, remaining, '>') orelse return false;
        const chip = remaining[0 .. end + 1];
        if (std.mem.indexOf(u8, chip, "data-type=\"mention\"") != null) {
            const label = attributeValue(chip, "data-label");
            const display_name = attributeValue(chip, "data-id");
            if ((label != null and std.mem.startsWith(u8, label.?, "agent-") and std.mem.eql(u8, label.?[6..], agent_id)) or
                (display_name != null and agent_name.len != 0 and std.mem.eql(u8, display_name.?, agent_name))) return true;
        }
        remaining = remaining[end + 1 ..];
    }
    return false;
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    const name_start = std.mem.indexOf(u8, tag, name) orelse return null;
    const suffix = tag[name_start + name.len ..];
    if (!std.mem.startsWith(u8, suffix, "=\"")) return null;
    const value = suffix[2..];
    const end = std.mem.indexOfScalar(u8, value, '"') orelse return null;
    return value[0..end];
}

fn boundedWhitespace(value: []const u8, limit: usize) []const u8 {
    const end = @min(value.len, limit);
    return std.mem.trim(u8, value[0..end], " \t\r\n");
}

fn optionOrEnvironment(context: *const Context, option: []const u8, name: []const u8) ?[]const u8 {
    return context.args.get(option) orelse environment(name);
}

fn environment(name: []const u8) ?[]const u8 {
    const value = std.posix.getenv(name) orelse return null;
    return if (value.len == 0) null else value;
}

fn arrayField(value: std.json.Value, name: []const u8) ?[]const std.json.Value {
    const field = if (value == .object) value.object.get(name) else null;
    return if (field != null and field.? == .array) field.?.array.items else null;
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const field = if (value == .object) value.object.get(name) else null;
    return if (field != null and field.? == .object) field.? else null;
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = if (value == .object) value.object.get(name) else null;
    return if (field != null and field.? == .string) field.?.string else null;
}

fn integerField(value: std.json.Value, name: []const u8) ?i64 {
    const field = if (value == .object) value.object.get(name) else null;
    if (field == null) return null;
    return switch (field.?) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

test "capability guards reject expired and cross-ticket operations" {
    try std.testing.expectError(error.CapabilityExpired, guardCapability(11, 10, null, null, null, null));
    try std.testing.expectError(error.CapabilityAgentMismatch, guardCapability(10, 10, "dev-3", "dev-2", null, null));
    try std.testing.expectError(error.CapabilityTicketMismatch, guardCapability(10, null, null, null, "HTPR-1", "HTPR-2"));
    try std.testing.expectError(error.CapabilityTicketMismatch, guardCapability(10, null, null, null, "HTPR-1", null));
    try guardCapability(10, 10, "dev-3", "dev-3", "HTPR-1", "HTPR-1");
}

test "mention matching only accepts exact mention identifiers" {
    try std.testing.expect(addressesAgent("<p><span data-type=\"mention\" data-id=\"Dev\" data-label=\"agent-agent-1\">@Dev</span></p>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<p>agent-1 without a mention chip</p>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span data-type=\"mention\" data-id=\"Other\" data-label=\"agent-agent-10\">@Other</span>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span data-type=\"mention\" data-other=\"agent-1\" data-id=\"Other\">@Other</span>", "agent-1", "Dev"));
}

test "legacy seen keys remain compatible with ht-agent state" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    try seen.put("5778:123", {});
    try seen.put("5778:r:456", {});
    try std.testing.expect(seenContains(&seen, "HTPR-5778", "HTPR-5778:123", 123, false));
    try std.testing.expect(seenContains(&seen, "HTPR-5778", "HTPR-5778:r:456", 456, true));
}
