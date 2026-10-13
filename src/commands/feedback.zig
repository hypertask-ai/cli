const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const output = @import("../output.zig");

pub fn run(context: *const Context) !void {
    const note = try context.args.requirePositional(1, "note");
    const surface = context.args.get("surface") orelse "cli";
    if (!std.mem.eql(u8, surface, "cli") and !std.mem.eql(u8, surface, "agent")) {
        std.debug.print("valid surfaces: cli, agent\n", .{});
        return error.InvalidOptions;
    }

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("surface", surface);
    try body.string("client", "hypertask-cli");
    if (context.args.get("tool")) |value| try body.string("tool", value);
    if (context.args.get("status")) |value| {
        const status = try common.int(value, "status");
        if (status < 100 or status > 599) {
            std.debug.print("status must be an HTTP status from 100 to 599\n", .{});
            return error.InvalidInteger;
        }
        try body.integer("status", status);
    }
    if (context.args.get("error-code")) |value| try body.string("errorCode", value);
    if (context.args.get("error")) |value| try body.string("error", value);
    try body.string("note", note);

    var response = try context.fetchRaw(.POST, "/mcp/feedback", try body.finish());
    defer response.deinit();
    if (response.status == .not_found) return error.FeedbackNotEnabled;
    if (response.status == .too_many_requests) return error.FeedbackRateLimited;
    if (!response.isSuccess()) return context.finish(&response);
    if (output.responseReportsFailure(context.allocator, response.body)) {
        try context.finish(&response);
        return error.CommandFailed;
    }
    if (context.args.has("json")) {
        if (context.request_recorder == null) try output.print(response.body);
        return;
    }

    const Result = struct {
        success: bool,
        ticketNumber: []const u8,
        url: []const u8,
        deduped: bool,
        count: u64,
    };
    const parsed = std.json.parseFromSlice(Result, context.allocator, response.body, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    defer parsed.deinit();
    if (!parsed.value.success) return error.ApiFailure;
    const message = if (parsed.value.deduped)
        try std.fmt.allocPrint(context.allocator, "Added to {s} (seen {d} times): {s}", .{ parsed.value.ticketNumber, parsed.value.count, parsed.value.url })
    else
        try std.fmt.allocPrint(context.allocator, "Filed {s}: {s}", .{ parsed.value.ticketNumber, parsed.value.url });
    defer context.allocator.free(message);
    if (context.request_recorder == null) try output.print(message);
}
