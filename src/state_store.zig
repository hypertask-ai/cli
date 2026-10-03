const std = @import("std");

pub const State = struct {
    directory: []const u8,
    lock_path: []const u8,
    poll_lock_path: []const u8,
    tickets_lock_path: []const u8,
    seen_path: []const u8,
    tickets_path: []const u8,
    watermark_path: []const u8,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.directory);
        allocator.free(self.lock_path);
        allocator.free(self.poll_lock_path);
        allocator.free(self.tickets_lock_path);
        allocator.free(self.seen_path);
        allocator.free(self.tickets_path);
        allocator.free(self.watermark_path);
        self.* = undefined;
    }
};

pub const TicketCursors = struct {
    comment: i64 = 0,
    reaction: i64 = 0,
};

const CursorEntry = struct {
    ticket: []const u8,
    id: i64,
    reaction: bool,
};

pub fn ensureStateDirectory(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

pub fn acquireStateLock(state: State) !std.fs.File {
    return acquireFileLock(state.lock_path);
}

pub fn acquireFileLock(path: []const u8) !std.fs.File {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = false, .mode = 0o600 });
    errdefer file.close();
    try file.lock(.exclusive);
    return file;
}

pub fn releaseStateLock(file: *std.fs.File) void {
    file.unlock();
    file.close();
}

pub fn appendStateLine(allocator: std.mem.Allocator, path: []const u8, line: []const u8) !void {
    _ = allocator;
    var file = try std.fs.cwd().createFile(path, .{ .truncate = false, .mode = 0o600 });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
    try file.writeAll("\n");
}

pub fn writeLineSet(allocator: std.mem.Allocator, path: []const u8, values: *const std.StringHashMap(void)) !void {
    var contents: std.ArrayListUnmanaged(u8) = .{};
    defer contents.deinit(allocator);
    var iterator = values.keyIterator();
    while (iterator.next()) |value| {
        try contents.appendSlice(allocator, value.*);
        try contents.append(allocator, '\n');
    }
    try writeStateFile(allocator, path, std.mem.trimRight(u8, contents.items, "\r\n"));
}

pub fn writeStateFile(allocator: std.mem.Allocator, path: []const u8, value: []const u8) !void {
    const pending = try std.fmt.allocPrint(allocator, "{s}.next-{x}", .{ path, std.crypto.random.int(u64) });
    defer allocator.free(pending);
    defer std.fs.cwd().deleteFile(pending) catch {};
    {
        var file = try std.fs.cwd().createFile(pending, .{ .exclusive = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(value);
        try file.writeAll("\n");
    }
    try std.fs.cwd().rename(pending, path);
}

pub fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = (try readOptionalFile(allocator, path)) orelse return allocator.dupe(u8, "");
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

pub fn readLines(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMap(void) {
    var result = std.StringHashMap(void).init(allocator);
    errdefer deinitLineSet(allocator, &result);
    const raw = (try readOptionalFile(allocator, path)) orelse return result;
    defer allocator.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) try putLine(allocator, &result, trimmed);
    }
    return result;
}

pub fn putLine(allocator: std.mem.Allocator, values: *std.StringHashMap(void), value: []const u8) !void {
    if (values.contains(value)) return;
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try values.put(owned, {});
}

pub fn mergeLineSet(allocator: std.mem.Allocator, destination: *std.StringHashMap(void), source: *const std.StringHashMap(void)) !void {
    var iterator = source.keyIterator();
    while (iterator.next()) |value| try putLine(allocator, destination, value.*);
}

pub fn deinitLineSet(allocator: std.mem.Allocator, values: *std.StringHashMap(void)) void {
    var iterator = values.keyIterator();
    while (iterator.next()) |value| allocator.free(value.*);
    values.deinit();
}

pub fn stateKey(allocator: std.mem.Allocator, ticket: []const u8, middle: []const u8, id: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}{d}", .{ ticket, middle, id });
}

pub fn ticketCursors(seen: *const std.StringHashMap(void), ticket: []const u8) TicketCursors {
    var result = TicketCursors{};
    var iterator = seen.keyIterator();
    while (iterator.next()) |key| {
        const suffix = ticketStateSuffix(key.*, ticket) orelse continue;
        if (std.mem.startsWith(u8, suffix, "cursor:c:")) {
            result.comment = @max(result.comment, std.fmt.parseInt(i64, suffix[9..], 10) catch 0);
        } else if (std.mem.startsWith(u8, suffix, "cursor:r:")) {
            result.reaction = @max(result.reaction, std.fmt.parseInt(i64, suffix[9..], 10) catch 0);
        }
    }
    return result;
}

pub fn compactTicketState(allocator: std.mem.Allocator, seen: *std.StringHashMap(void), ticket: []const u8, requested_cursors: TicketCursors) !void {
    const existing_cursors = ticketCursors(seen, ticket);
    const cursors = TicketCursors{
        .comment = @max(requested_cursors.comment, existing_cursors.comment),
        .reaction = @max(requested_cursors.reaction, existing_cursors.reaction),
    };
    var removals: std.ArrayListUnmanaged([]const u8) = .{};
    defer removals.deinit(allocator);
    var iterator = seen.keyIterator();
    while (iterator.next()) |key| {
        const suffix = ticketStateSuffix(key.*, ticket) orelse continue;
        if (ticketStateCoveredByCursor(suffix, cursors)) try removals.append(allocator, key.*);
    }
    for (removals.items) |key| {
        if (seen.fetchRemove(key)) |removed| allocator.free(removed.key);
    }
    if (cursors.comment > 0) {
        const key = try std.fmt.allocPrint(allocator, "{s}:cursor:c:{d}", .{ ticket, cursors.comment });
        defer allocator.free(key);
        try putLine(allocator, seen, key);
    }
    if (cursors.reaction > 0) {
        const key = try std.fmt.allocPrint(allocator, "{s}:cursor:r:{d}", .{ ticket, cursors.reaction });
        defer allocator.free(key);
        try putLine(allocator, seen, key);
    }
}

pub fn compactMergedCursorState(allocator: std.mem.Allocator, current: *std.StringHashMap(void), updates: *const std.StringHashMap(void)) !void {
    var tickets = std.StringHashMap(TicketCursors).init(allocator);
    defer tickets.deinit();
    var iterator = updates.keyIterator();
    while (iterator.next()) |key| {
        const entry = parseCursorEntry(key.*) orelse continue;
        const value = try tickets.getOrPut(entry.ticket);
        if (!value.found_existing) value.value_ptr.* = .{};
        if (entry.reaction) {
            value.value_ptr.reaction = @max(value.value_ptr.reaction, entry.id);
        } else {
            value.value_ptr.comment = @max(value.value_ptr.comment, entry.id);
        }
    }
    var ticket_iterator = tickets.iterator();
    while (ticket_iterator.next()) |entry| try compactTicketState(allocator, current, entry.key_ptr.*, entry.value_ptr.*);
}

fn parseCursorEntry(key: []const u8) ?CursorEntry {
    const comment_marker = ":cursor:c:";
    const reaction_marker = ":cursor:r:";
    const marker_index = std.mem.indexOf(u8, key, comment_marker) orelse
        std.mem.indexOf(u8, key, reaction_marker) orelse return null;
    const reaction = std.mem.startsWith(u8, key[marker_index..], reaction_marker);
    const marker = if (reaction) reaction_marker else comment_marker;
    const id = std.fmt.parseInt(i64, key[marker_index + marker.len ..], 10) catch return null;
    if (marker_index == 0 or id <= 0) return null;
    return .{ .ticket = key[0..marker_index], .id = id, .reaction = reaction };
}

fn ticketStateCoveredByCursor(suffix: []const u8, cursors: TicketCursors) bool {
    if (std.mem.startsWith(u8, suffix, "cursor:c:") or std.mem.startsWith(u8, suffix, "cursor:r:")) return true;
    if (std.mem.startsWith(u8, suffix, "r:")) {
        const id = std.fmt.parseInt(i64, suffix[2..], 10) catch return false;
        return id <= cursors.reaction;
    }
    const id = std.fmt.parseInt(i64, suffix, 10) catch return false;
    return id <= cursors.comment;
}

fn ticketStateSuffix(key: []const u8, ticket: []const u8) ?[]const u8 {
    if (key.len > ticket.len and std.mem.startsWith(u8, key, ticket) and key[ticket.len] == ':') return key[ticket.len + 1 ..];
    const separator = std.mem.lastIndexOfScalar(u8, ticket, '-') orelse return null;
    const legacy_ticket = ticket[separator + 1 ..];
    if (key.len > legacy_ticket.len and std.mem.startsWith(u8, key, legacy_ticket) and key[legacy_ticket.len] == ':') return key[legacy_ticket.len + 1 ..];
    return null;
}

pub fn seenContains(seen: *const std.StringHashMap(void), ticket: []const u8, full_key: []const u8, id: i64, reaction: bool) bool {
    if (seen.contains(full_key)) return true;
    const separator = std.mem.lastIndexOfScalar(u8, ticket, '-') orelse return false;
    var legacy_buffer: [128]u8 = undefined;
    const legacy = std.fmt.bufPrint(&legacy_buffer, "{s}:{s}{d}", .{ ticket[separator + 1 ..], if (reaction) "r:" else "", id }) catch return false;
    return seen.contains(legacy);
}

pub fn readOptionalFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

test "seen state compacts to per-ticket cursors" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer deinitLineSet(std.testing.allocator, &seen);
    try putLine(std.testing.allocator, &seen, "HTPR-5778:10");
    try putLine(std.testing.allocator, &seen, "5778:r:20");
    try putLine(std.testing.allocator, &seen, "HTPR-5778:cursor:c:5");
    try putLine(std.testing.allocator, &seen, "HTPR-5778:11");
    try putLine(std.testing.allocator, &seen, "HTPR-5778:r:21");
    try putLine(std.testing.allocator, &seen, "HTPR-9999:30");

    const cursors = ticketCursors(&seen, "HTPR-5778");
    try std.testing.expectEqual(@as(i64, 5), cursors.comment);
    try std.testing.expectEqual(@as(i64, 0), cursors.reaction);
    try compactTicketState(std.testing.allocator, &seen, "HTPR-5778", .{ .comment = 10, .reaction = 20 });
    try std.testing.expectEqual(@as(usize, 5), seen.count());
    try std.testing.expect(seen.contains("HTPR-5778:cursor:c:10"));
    try std.testing.expect(seen.contains("HTPR-5778:cursor:r:20"));
    try std.testing.expect(seen.contains("HTPR-5778:11"));
    try std.testing.expect(seen.contains("HTPR-5778:r:21"));
    try std.testing.expect(seen.contains("HTPR-9999:30"));
}

test "merged cursor state prunes covered keys and preserves concurrent additions" {
    var current = std.StringHashMap(void).init(std.testing.allocator);
    defer deinitLineSet(std.testing.allocator, &current);
    var updates = std.StringHashMap(void).init(std.testing.allocator);
    defer deinitLineSet(std.testing.allocator, &updates);
    try putLine(std.testing.allocator, &current, "HTPR-5778:cursor:c:5");
    try putLine(std.testing.allocator, &current, "HTPR-5778:7");
    try putLine(std.testing.allocator, &current, "HTPR-5778:11");
    try putLine(std.testing.allocator, &updates, "HTPR-5778:cursor:c:10");

    try mergeLineSet(std.testing.allocator, &current, &updates);
    try compactMergedCursorState(std.testing.allocator, &current, &updates);
    try std.testing.expectEqual(@as(usize, 2), current.count());
    try std.testing.expect(current.contains("HTPR-5778:cursor:c:10"));
    try std.testing.expect(current.contains("HTPR-5778:11"));
}

test "legacy seen keys remain compatible with ht-agent state" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    try seen.put("5778:123", {});
    try seen.put("5778:r:456", {});
    try std.testing.expect(seenContains(&seen, "HTPR-5778", "HTPR-5778:123", 123, false));
    try std.testing.expect(seenContains(&seen, "HTPR-5778", "HTPR-5778:r:456", 456, true));
}

test "optional reads distinguish missing files from empty state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "state" });
    defer std.testing.allocator.free(path);
    try std.testing.expect(try readOptionalFile(std.testing.allocator, path) == null);
    var values = try readLines(std.testing.allocator, path);
    defer deinitLineSet(std.testing.allocator, &values);
    try std.testing.expectEqual(@as(u32, 0), values.count());
    try writeStateFile(std.testing.allocator, path, "");
    const contents = (try readOptionalFile(std.testing.allocator, path)).?;
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("\n", contents);
    const trimmed = try readSmallFile(std.testing.allocator, path);
    defer std.testing.allocator.free(trimmed);
    try std.testing.expectEqualStrings("", trimmed);
}
