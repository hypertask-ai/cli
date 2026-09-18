const std = @import("std");
const http = @import("http.zig");

pub fn print(body: []const u8) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try stdout.writeAll("\n");
}

pub fn printResponse(allocator: std.mem.Allocator, body: []const u8, json: bool) !void {
    if (json) return print(body);
    const formatted = try formatHuman(allocator, body);
    defer allocator.free(formatted);
    try print(formatted);
}

pub fn finish(response: *http.Response) !void {
    const code = @intFromEnum(response.status);
    try print(response.body);
    if (code < 200 or code >= 300) return apiError(response.status);
    if (responseReportsFailure(response.allocator, response.body)) return error.ApiFailure;
}

pub fn responseReportsFailure(allocator: std.mem.Allocator, body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const success = parsed.value.object.get("success") orelse return false;
    return success == .bool and !success.bool;
}

fn apiError(status: std.http.Status) anyerror {
    return switch (status) {
        .bad_request, .unprocessable_entity => error.ApiInvalidInput,
        .unauthorized, .forbidden => error.ApiAuthentication,
        .not_found => error.ApiNotFound,
        else => error.ApiFailure,
    };
}

pub fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.AmbiguousTaskIdentifier,
        error.ApiInvalidInput,
        error.ConfirmationRequired,
        error.ConflictingProjectChanges,
        error.FileNotFound,
        error.InvalidFilter,
        error.InvalidInteger,
        error.InvalidJsonObject,
        error.InvalidManifest,
        error.InvalidMethod,
        error.InvalidOptions,
        error.InvalidProject,
        error.InvalidTicket,
        error.MissingAgentIdentity,
        error.MissingArgument,
        error.MissingOption,
        error.MissingOptionValue,
        error.MissingProject,
        error.MissingProjectChanges,
        error.MissingSubcommand,
        error.MissingTask,
        error.MissingWebhookSecret,
        error.NoToken,
        error.UnknownOption,
        => 2,
        error.UnknownCommand => 1,
        error.ApiAuthentication,
        error.ApiFailure,
        error.ApiNotFound,
        error.AssigneeNotConfirmed,
        error.AssigneeNotRemoved,
        error.CapabilityAgentMismatch,
        error.CapabilityAgentOverride,
        error.CapabilityExpired,
        error.CapabilityTicketMismatch,
        error.CommandFailed,
        error.FieldNotFound,
        error.InvalidResponse,
        error.LabelNotFound,
        error.ModeMismatch,
        error.ProjectAccessDenied,
        error.ProjectNotFound,
        error.SectionNotFound,
        error.TaskNotFound,
        => 4,
        else => 1,
    };
}

pub fn printFailure(err: anyerror) void {
    const summary: ?[]const u8 = switch (err) {
        error.MissingAgentIdentity,
        error.MissingArgument,
        error.MissingOption,
        error.MissingOptionValue,
        error.MissingProject,
        error.MissingProjectChanges,
        error.MissingSubcommand,
        error.MissingTask,
        error.MissingWebhookSecret,
        => "required command input is missing",
        error.AmbiguousTaskIdentifier,
        error.ConflictingProjectChanges,
        error.FileNotFound,
        error.InvalidFilter,
        error.InvalidInteger,
        error.InvalidJsonObject,
        error.InvalidManifest,
        error.InvalidMethod,
        error.InvalidOptions,
        error.InvalidProject,
        error.InvalidTicket,
        => "command input is invalid",
        error.UnknownOption => "the command does not accept that option",
        error.UnknownCommand => "command not found",
        error.NoToken => "authentication token is missing",
        error.ApiAuthentication,
        error.CapabilityAgentMismatch,
        error.CapabilityAgentOverride,
        error.CapabilityExpired,
        error.CapabilityTicketMismatch,
        error.ProjectAccessDenied,
        => "this token does not have the required access",
        error.ApiNotFound, error.FieldNotFound, error.LabelNotFound, error.ProjectNotFound, error.SectionNotFound, error.TaskNotFound => "the requested item was not found",
        error.ApiInvalidInput => "the server rejected the command input",
        error.ApiFailure, error.AssigneeNotConfirmed, error.AssigneeNotRemoved, error.CommandFailed => "the server could not complete the command",
        error.InvalidResponse, error.ModeMismatch => "the server returned a response the CLI could not use",
        else => null,
    };
    if (summary) |message| {
        std.debug.print("hypertask: {s}\n", .{message});
    } else {
        std.debug.print("hypertask: command failed ({s})\n", .{@errorName(err)});
    }
    std.debug.print("Next: {s}\n", .{nextStep(err)});
}

fn nextStep(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownCommand, error.MissingSubcommand => "choose one of the valid commands listed above.",
        error.UnknownOption => "retry with one of the accepted flags listed above.",
        error.InvalidMethod => "retry with one of the valid methods listed above.",
        error.SectionNotFound => "retry with one of the sections listed above.",
        error.LabelNotFound => "retry with one of the labels listed above.",
        error.AmbiguousTaskIdentifier => "retry with the full ticket key or internal id described above.",
        error.NoToken => "run `hypertask login --token <jwt>`.",
        error.MissingAgentIdentity => "pass --agent-id or set HT_AGENT_ID, then retry.",
        error.MissingWebhookSecret => "set the webhook secret environment variable named above, then retry.",
        error.ApiAuthentication => "ask the project owner to add this token.",
        error.ProjectAccessDenied => "ask the project owner to add it.",
        error.CapabilityAgentMismatch,
        error.CapabilityAgentOverride,
        error.CapabilityExpired,
        error.CapabilityTicketMismatch,
        => "request a fresh capability for this agent and ticket.",
        error.ApiNotFound, error.FieldNotFound, error.ProjectNotFound, error.TaskNotFound => "check the requested identifier and retry.",
        error.AssigneeNotConfirmed, error.AssigneeNotRemoved => "read the task back, then retry only if its assignees are still wrong.",
        error.FileNotFound, error.InvalidJsonObject, error.InvalidManifest => "fix the file or JSON input named above, then retry.",
        error.ApiInvalidInput,
        error.ConfirmationRequired,
        error.ConflictingProjectChanges,
        error.InvalidFilter,
        error.InvalidInteger,
        error.InvalidOptions,
        error.InvalidProject,
        error.InvalidTicket,
        error.MissingArgument,
        error.MissingOption,
        error.MissingOptionValue,
        error.MissingProject,
        error.MissingProjectChanges,
        error.MissingTask,
        => "run the same command with --help.",
        else => "retry the same command once.",
    };
}

pub fn finishResponse(allocator: std.mem.Allocator, response: *http.Response, json: bool) !void {
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300 or responseReportsFailure(allocator, response.body)) return finish(response);
    try printResponse(allocator, response.body, json);
}

pub fn formatHuman(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return allocator.dupe(u8, body);
    };
    defer parsed.deinit();

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    try renderValue(allocator, result.writer(allocator), parsed.value, 0);
    while (result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
        _ = result.pop();
    }
    return result.toOwnedSlice(allocator);
}

fn renderValue(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value, indent: usize) anyerror!void {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try writeIndent(writer, indent);
                try writeSanitized(writer, entry.key_ptr.*);
                if (isScalar(entry.value_ptr.*)) {
                    try writer.writeAll(": ");
                    try writeCell(allocator, writer, entry.value_ptr.*);
                    try writer.writeByte('\n');
                } else {
                    try writer.writeAll(":\n");
                    try renderValue(allocator, writer, entry.value_ptr.*, indent + 2);
                }
            }
        },
        .array => |array| try renderArray(allocator, writer, array.items, indent),
        else => {
            try writeIndent(writer, indent);
            try writeCell(allocator, writer, value);
            try writer.writeByte('\n');
        },
    }
}

fn renderArray(allocator: std.mem.Allocator, writer: anytype, values: []const std.json.Value, indent: usize) anyerror!void {
    if (values.len == 0) {
        try writeIndent(writer, indent);
        try writer.writeAll("(none)\n");
        return;
    }

    if (canRenderTable(values)) return renderObjectTable(allocator, writer, values, indent);

    for (values) |value| {
        try writeIndent(writer, indent);
        try writer.writeByte('-');
        if (isScalar(value)) {
            try writer.writeByte(' ');
            try writeCell(allocator, writer, value);
            try writer.writeByte('\n');
        } else {
            try writer.writeByte('\n');
            try renderValue(allocator, writer, value, indent + 2);
        }
    }
}

fn canRenderTable(values: []const std.json.Value) bool {
    if (values.len == 0 or values[0] != .object) return false;
    const headers = values[0].object;
    for (values) |value| {
        if (value != .object or value.object.count() != headers.count()) return false;
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const cell = value.object.get(entry.key_ptr.*) orelse return false;
            if (!isScalar(cell)) return false;
        }
    }
    return true;
}

fn renderObjectTable(allocator: std.mem.Allocator, writer: anytype, values: []const std.json.Value, indent: usize) !void {
    const headers = values[0].object;
    try writeIndent(writer, indent);
    var header_iterator = headers.iterator();
    var first = true;
    while (header_iterator.next()) |entry| {
        if (!first) try writer.writeByte('\t');
        first = false;
        try writeSanitized(writer, entry.key_ptr.*);
    }
    try writer.writeByte('\n');

    for (values) |value| {
        try writeIndent(writer, indent);
        header_iterator = headers.iterator();
        first = true;
        while (header_iterator.next()) |entry| {
            if (!first) try writer.writeByte('\t');
            first = false;
            if (value.object.get(entry.key_ptr.*)) |cell| {
                try writeCell(allocator, writer, cell);
            } else {
                try writer.writeByte('-');
            }
        }
        try writer.writeByte('\n');
    }
}

fn isScalar(value: std.json.Value) bool {
    return switch (value) {
        .object, .array => false,
        else => true,
    };
}

fn writeCell(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeByte('-'),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .number_string => |number| try writer.writeAll(number),
        .string => |string| try writeSanitized(writer, string),
        .object, .array => {
            const raw = try std.json.Stringify.valueAlloc(allocator, value, .{});
            defer allocator.free(raw);
            try writeSanitized(writer, raw);
        },
    }
}

fn writeIndent(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn writeSanitized(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        try writer.writeByte(switch (byte) {
            '\t', '\r', '\n' => ' ',
            else => byte,
        });
    }
}

pub fn invalidOptions(message: []const u8) error{InvalidOptions} {
    std.debug.print("{s}\n", .{message});
    return error.InvalidOptions;
}

pub fn unknownCommand(message: []const u8) error{UnknownCommand} {
    std.debug.print("{s}\n", .{message});
    return error.UnknownCommand;
}

test "success false is a failure even with a successful HTTP status" {
    try std.testing.expect(responseReportsFailure(std.testing.allocator, "{\"success\":false,\"error\":\"not done\"}"));
    try std.testing.expect(!responseReportsFailure(std.testing.allocator, "{\"success\":true}"));
    try std.testing.expect(!responseReportsFailure(std.testing.allocator, "{\"tasks\":[]}"));
}

test "exit codes document command input and server failures" {
    try std.testing.expectEqual(@as(u8, 1), exitCode(error.UnknownCommand));
    try std.testing.expectEqual(@as(u8, 2), exitCode(error.MissingOptionValue));
    try std.testing.expectEqual(@as(u8, 2), exitCode(error.MissingTask));
    try std.testing.expectEqual(@as(u8, 2), exitCode(error.NoToken));
    try std.testing.expectEqual(@as(u8, 4), exitCode(error.ProjectAccessDenied));
    try std.testing.expectEqual(@as(u8, 4), exitCode(error.InvalidResponse));
}

test "human output formats status fields without JSON syntax" {
    const formatted = try formatHuman(std.testing.allocator,
        \\{"authenticated":true,"hasToken":true,"apiUrl":"https://api.hypertask.ai/api"}
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(
        \\authenticated: true
        \\hasToken: true
        \\apiUrl: https://api.hypertask.ai/api
    , formatted);
}

test "human output formats object arrays as tabular rows" {
    const formatted = try formatHuman(std.testing.allocator,
        \\{"success":true,"tasks":[{"ticketNumber":"HTPR-1","title":"First"},{"ticketNumber":"HTPR-2","title":"Second"}]}
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(
        "success: true\ntasks:\n  ticketNumber\ttitle\n  HTPR-1\tFirst\n  HTPR-2\tSecond",
        formatted,
    );
}

test "human output expands nested list fields without raw JSON cells" {
    const formatted = try formatHuman(std.testing.allocator,
        \\{"tasks":[{"ticketNumber":"HTPR-1","labels":[{"name":"Bug"}]}]}
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(
        \\tasks:
        \\  -
        \\    ticketNumber: HTPR-1
        \\    labels:
        \\      name
        \\      Bug
    , formatted);
}

test "human output preserves non-JSON responses" {
    const formatted = try formatHuman(std.testing.allocator, "plain text");
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("plain text", formatted);
}
