const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const config = @import("config.zig");
const Context = @import("command_context.zig").Context;
const http = @import("http.zig");
const output = @import("output.zig");
const router = @import("router.zig");
const json = @import("json_util.zig");
const helper_guard = @import("helper_guard.zig");

pub const endpoint = "/mcp/cli-error";
const deadline_ns = 1500 * std.time.ns_per_ms;
pub threadlocal var input_failure = false;

fn disabled(value: ?[]const u8) bool {
    const present = value orelse return false;
    return present.len != 0 and !std.mem.eql(u8, present, "0");
}

fn shouldReport(err: anyerror, status: ?u16) bool {
    if (output.isExpectedFailure(err)) return false;
    switch (err) {
        error.UnexpectedCharacter,
        error.UriMissingHost,
        error.UriHostTooLong,
        error.AddressInUse,
        error.AddressNotAvailable,
        error.InvalidFormat,
        error.InvalidPort,
        error.UnsupportedUriScheme,
        error.CorrectionTooLarge,
        error.NoCompletedTimeEntry,
        error.NonMinuteAlignedTimeEntry,
        error.HelperWriteForbidden,
        error.NoHome,
        error.AccessDenied,
        error.PermissionDenied,
        error.FileTooBig,
        error.NameTooLong,
        error.NotDir,
        error.IsDir,
        error.BadPathName,
        error.InvalidUtf8,
        error.InvalidWtf8,
        error.PathAlreadyExists,
        error.InvalidCharacter,
        error.Overflow,
        => return false,
        else => {},
    }
    if (status) |code| {
        if (code >= 400 and code < 500) return false;
        // A success:false envelope can describe input rejection, not a CLI bug.
        if ((err == error.ApiFailure or err == error.CommandFailed) and code < 500) return false;
    }
    // Reportable named errors: ApiFailure, CommandFailed (5xx or status unknown),
    // InvalidResponse, InvalidTimeReport, ModeMismatch, AssigneeNotConfirmed,
    // AssigneeNotRemoved, InvalidCapabilities, OutOfMemory; server JSON errors
    // SyntaxError, UnexpectedEndOfInput, BufferUnderrun, ValueTooLong,
    // InvalidNumber, DuplicateField, UnknownField, MissingField, LengthMismatch,
    // UnexpectedToken, InvalidEnumTag; plus otherwise-unknown/internal errors,
    // Known network/TLS/HTTP errors: ConnectionRefused, NetworkUnreachable,
    // ConnectionTimedOut, ConnectionResetByPeer, TemporaryNameServerFailure,
    // NameServerFailure, UnknownHostName, HostLacksNetworkAddresses,
    // UnexpectedConnectFailure, TlsInitializationFailed, CertificateBundleLoadFailure,
    // HttpHeadersOversize, HttpRequestTruncated, HttpConnectionClosing, ReadFailed,
    // HttpHeadersInvalid, TooManyHttpRedirects, RedirectRequiresResend,
    // HttpRedirectLocationMissing, HttpRedirectLocationOversize,
    // HttpRedirectLocationInvalid, HttpRedirectDowngrade, HttpContentEncodingUnsupported,
    // HttpChunkInvalid, HttpChunkTruncated, HttpTransferFailed, WriteFailed,
    // StreamTooLong, UnsupportedCompressionMethod, TlsAlert, TlsBadLength,
    // TlsBadRecordMac, TlsConnectionTruncated, TlsDecodeError, TlsRecordOverflow,
    // TlsUnexpectedMessage, TlsIllegalParameter, TlsSequenceOverflow, InputOutput,
    // SystemResources, OperationAborted, NotOpenForReading, SocketNotConnected,
    // WouldBlock, Canceled, ProcessNotFound, LockViolation, SocketNotBound,
    // MessageTooBig, NetworkSubsystemFailed, FastOpenAlreadyInProgress,
    // FileDescriptorNotASocket, AddressFamilyNotSupported, SymLinkLoop, Unexpected.
    // JSON scanner errors without a server response are not reportable.
    switch (err) {
        error.SyntaxError,
        error.UnexpectedEndOfInput,
        error.BufferUnderrun,
        error.ValueTooLong,
        error.InvalidNumber,
        error.DuplicateField,
        error.UnknownField,
        error.MissingField,
        error.LengthMismatch,
        error.UnexpectedToken,
        error.InvalidEnumTag,
        => return status != null,
        else => return true,
    }
}

fn payload(context: *const Context, err: anyerror, status: ?u16, version: []const u8, opt_out: ?[]const u8) !?[]u8 {
    if (input_failure or !shouldReport(err, status) or disabled(opt_out) or
        !context.cfg.error_reports or context.cfg.token.len == 0) return null;
    const root = context.args.positionalAt(0) orelse return null;
    if (std.mem.eql(u8, root, "feedback")) return null;
    const command = try router.reportCommandPath(context.allocator, context.args.positional) orelse return null;
    defer context.allocator.free(command);

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("command", command);
    try body.string("error", @errorName(err));
    // The app accepts a bare semver and an omitted status, never "0.2.17 (zig)" or null.
    if (status) |code| try body.integer("status", code);
    try body.string("version", version[0 .. std.mem.indexOfScalar(u8, version, ' ') orelse version.len]);
    try body.string("os", switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "other",
    });
    return try context.allocator.dupe(u8, try body.finish());
}

fn send(context: *const Context, body: []const u8) void {
    var response = context.fetchRaw(.POST, endpoint, body) catch return;
    response.deinit();
}

const Job = struct {
    arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    body: []const u8,
    done: std.Thread.Semaphore = .{},

    fn run(self: *Job) void {
        var client = std.http.Client{ .allocator = std.heap.page_allocator };
        defer client.deinit();
        var parsed = args.parse(self.arena.allocator(), &.{}) catch {
            self.done.post();
            return;
        };
        defer parsed.deinit();
        const context = Context{
            .client = &client,
            .allocator = self.arena.allocator(),
            .args = &parsed,
            .cfg = &self.cfg,
            .json = true,
        };
        send(&context, self.body);
        self.done.post();
    }

    fn deinit(self: *Job) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

pub fn report(allocator: std.mem.Allocator, parsed: *const args.Parsed, cfg: *const config.Config, err: anyerror, version: []const u8) void {
    reportFallible(allocator, parsed, cfg, err, version) catch {};
}

fn reportFallible(allocator: std.mem.Allocator, parsed: *const args.Parsed, cfg: *const config.Config, err: anyerror, version: []const u8) !void {
    var timer = try std.time.Timer.start();
    // Existing helper policy forbids POST writes and exits noisily. Do not
    // invoke that path from a best-effort reporter.
    if (helper_guard.isHelper(allocator)) return;
    const opt_out = std.process.getEnvVarOwned(allocator, "HYPERTASK_NO_ERROR_REPORTS") catch |read_err| switch (read_err) {
        error.EnvironmentVariableNotFound => null,
        else => return read_err,
    };
    defer if (opt_out) |value| allocator.free(value);
    var unused_client = std.http.Client{ .allocator = allocator };
    const context = Context{ .client = &unused_client, .allocator = allocator, .args = parsed, .cfg = cfg, .json = true };
    const body = try payload(&context, err, http.last_status, version, opt_out) orelse return;
    defer allocator.free(body);

    const job = try std.heap.page_allocator.create(Job);
    job.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .cfg = undefined, .body = undefined };
    errdefer job.deinit();
    const owned = job.arena.allocator();
    job.cfg = .{
        .allocator = owned,
        .token = try owned.dupe(u8, cfg.token),
        .api_url = try owned.dupe(u8, cfg.api_url),
    };
    job.body = try owned.dupe(u8, body);
    const elapsed = timer.read();
    if (elapsed >= deadline_ns) {
        job.deinit();
        return;
    }
    const worker = try std.Thread.spawn(.{}, Job.run, .{job});
    job.done.timedWait(deadline_ns - elapsed) catch {
        // The CLI exits immediately after this call. A stalled DNS/connect/TLS
        // or response worker owns all its memory until process exit; never join
        // or free its state on timeout, and never retry the request.
        worker.detach();
        return;
    };
    worker.join();
    job.deinit();
}

test "error report classification excludes expected failures" {
    for ([_]anyerror{
        error.ApiFailure,              error.CommandFailed,          error.InvalidResponse,    error.InvalidTimeReport,
        error.ModeMismatch,            error.AssigneeNotConfirmed,   error.AssigneeNotRemoved, error.InvalidCapabilities,
        error.OutOfMemory,             error.ConnectionRefused,      error.NetworkUnreachable, error.ConnectionTimedOut,
        error.TlsInitializationFailed, error.HttpRequestTruncated,   error.SyntaxError,        error.UnexpectedEndOfInput,
        error.UnexpectedToken,         error.UnknownInternalFailure,
    }) |err| try std.testing.expect(shouldReport(err, 503));
    for ([_]anyerror{
        error.BrokenPipe,           error.UnknownCommand,     error.MissingSubcommand,  error.UnknownOption,
        error.InvalidOptions,       error.InvalidInteger,     error.InvalidJsonObject,  error.InvalidManifest,
        error.ApiInvalidInput,      error.ApiAuthentication,  error.ApiNotFound,        error.NoToken,
        error.ProjectAccessDenied,  error.CapabilityExpired,  error.TaskNotFound,       error.LabelNotFound,
        error.FeedbackRateLimited,  error.FeedbackNotEnabled, error.CorrectionTooLarge, error.NonMinuteAlignedTimeEntry,
        error.NoCompletedTimeEntry, error.FileNotFound,       error.AccessDenied,       error.FileTooBig,
        error.InvalidFormat,        error.InvalidPort,        error.InvalidCharacter,   error.Overflow,
        error.HelperWriteForbidden,
    }) |err| try std.testing.expect(!shouldReport(err, 503));
    for ([_]u16{ 400, 401, 403, 404, 409, 422, 429 }) |code| {
        try std.testing.expect(!shouldReport(error.ApiFailure, code));
        try std.testing.expect(!shouldReport(error.InvalidResponse, code));
    }
    try std.testing.expect(!shouldReport(error.ApiFailure, 200));
    try std.testing.expect(!shouldReport(error.SyntaxError, null));
    try std.testing.expect(shouldReport(error.SyntaxError, 200));
    try std.testing.expect(shouldReport(error.ConnectionRefused, null));
}

test "report payload uses matched command only and existing request recorder" {
    input_failure = false;
    const Recorder = @import("command_context.zig").RequestRecorder;
    var parsed = try args.parse(std.testing.allocator, &.{ "task", "create", "--project", "12345", "--title", "FAKE PRIVATE TICKET TITLE", "--description", "PRIVATE BODY" });
    defer parsed.deinit();
    var cfg = config.Config{ .allocator = std.testing.allocator, .token = "test-token" };
    var client = std.http.Client{ .allocator = std.testing.allocator };
    defer client.deinit();
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const context = Context{ .allocator = std.testing.allocator, .client = &client, .args = &parsed, .cfg = &cfg, .json = true, .request_recorder = &recorder };
    const body = (try payload(&context, error.ApiFailure, 503, "test-version", null)).?;
    defer std.testing.allocator.free(body);
    send(&context, body);
    try std.testing.expectEqualStrings(endpoint, recorder.path.?);
    try std.testing.expectEqual(std.http.Method.POST, recorder.method.?);
    const document = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, recorder.body.?, .{});
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 5), document.value.object.count());
    for ([_][]const u8{ "command", "error", "status", "version", "os" }) |key| try std.testing.expect(document.value.object.contains(key));
    try std.testing.expectEqualStrings("task create", document.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("ApiFailure", document.value.object.get("error").?.string);
    try std.testing.expectEqual(@as(i64, 503), document.value.object.get("status").?.integer);
    for ([_][]const u8{ "12345", "FAKE PRIVATE TICKET TITLE", "PRIVATE BODY", "test-token" }) |secret| try std.testing.expect(std.mem.indexOf(u8, body, secret) == null);
    for ([_]?[]const u8{ "1", "true", "false", "anything" }) |value| try std.testing.expect((try payload(&context, error.ApiFailure, 503, "test-version", value)) == null);
    for ([_]?[]const u8{ null, "", "0" }) |value| try std.testing.expect(!disabled(value));
    // Unknown status is omitted and the version is bare semver, as the app schema requires.
    const bare = (try payload(&context, error.ConnectionRefused, null, "0.2.17 (zig)", null)).?;
    defer std.testing.allocator.free(bare);
    const bare_doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bare, .{});
    defer bare_doc.deinit();
    try std.testing.expect(!bare_doc.value.object.contains("status"));
    try std.testing.expectEqualStrings("0.2.17", bare_doc.value.object.get("version").?.string);
    cfg.error_reports = false;
    try std.testing.expect((try payload(&context, error.ApiFailure, 503, "test-version", null)) == null);
    cfg.error_reports = true;
    cfg.token = "";
    try std.testing.expect((try payload(&context, error.ApiFailure, 503, "test-version", null)) == null);
    try std.testing.expectEqual(@as(usize, 1), recorder.responses_index);
    cfg.token = "test-token";
    input_failure = true;
    defer input_failure = false;
    try std.testing.expect((try payload(&context, error.SyntaxError, 200, "test-version", null)) == null);
}

test "command path excludes positional arguments and handles aliases and nested commands" {
    const cases = [_]struct { path: []const []const u8, expected: []const u8 }{
        .{ .path = &.{ "search", "PRIVATE SEARCH" }, .expected = "search" },
        .{ .path = &.{ "tasks", "get", "PRIVATE-ID" }, .expected = "tasks get" },
        .{ .path = &.{ "feedback", "PRIVATE NOTE" }, .expected = "feedback" },
        .{ .path = &.{ "raw", "POST", "/private", "PRIVATE JSON" }, .expected = "raw" },
        .{ .path = &.{ "agents", "webhook", "configure" }, .expected = "agents webhook" },
    };
    for (cases) |case| {
        const command = (try router.reportCommandPath(std.testing.allocator, case.path)).?;
        defer std.testing.allocator.free(command);
        try std.testing.expectEqualStrings(case.expected, command);
    }
    try std.testing.expect((try router.reportCommandPath(std.testing.allocator, &.{"PRIVATE UNKNOWN"})) == null);
}
