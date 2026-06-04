//! A single-threaded, non-blocking HTTP/SSE client for an OpenAI-compatible
//! `/v1/chat/completions` endpoint (e.g. mlx-serve at http://127.0.0.1:11234).
//!
//! There are no threads and no mutex: the socket is set non-blocking and the
//! GUI event loop calls `poll()` once per frame while a request is in flight, so
//! every `State`/buffer mutation stays on the UI thread. `poll()` reads whatever
//! bytes are available, de-chunks the HTTP body if needed, and parses complete
//! `\n`-terminated SSE `data:` lines, appending each delta to the current
//! assistant message buffer (which marks the UI dirty and triggers a redraw).
//!
//! Networking uses libc sockets directly (Zig 0.16 moved the socket primitives
//! out of `std.posix` into the new `std.Io` model); the example links libc, so a
//! `@cImport` of the POSIX headers — the same approach the SDL backend uses — is
//! the simplest portable path.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/time.h");
    @cInclude("netinet/in.h");
    @cInclude("netdb.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});

/// Wall-clock milliseconds (std.time lost `milliTimestamp` in Zig 0.16; libc's
/// `gettimeofday` is the simplest replacement for the tok/s timing).
fn nowMs() i64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(i64, tv.tv_sec) * 1000 + @divTrunc(@as(i64, tv.tv_usec), 1000);
}

/// Sleep for `ms` milliseconds (std.time lost `sleep` in Zig 0.16). Used by the
/// headless `--stream` smoke loop to avoid a hot spin between polls.
pub fn sleepMs(ms: u32) void {
    _ = c.usleep(@as(c.useconds_t, ms) * 1000);
}

const stdc = std.c;

/// Token accounting reported in the final `usage` object.
pub const Usage = struct { prompt_tokens: u64 = 0, completion_tokens: u64 = 0 };

/// One message in the OpenAI request `messages` array.
pub const WireMessage = struct { role: []const u8, content: []const u8 };

/// Generation parameters for a request.
pub const Params = struct {
    model: []const u8,
    temperature: f32 = 0.7,
    max_tokens: u32 = 1024,
};

// --- JSON shapes (decode side; unknown fields ignored) ----------------------

const Delta = struct {
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
};
const StreamChoice = struct {
    delta: Delta = .{},
    finish_reason: ?[]const u8 = null,
};
const UsageWire = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
};
const StreamChunk = struct {
    choices: []StreamChoice = &.{},
    usage: ?UsageWire = null,
};

const FullMessage = struct { content: ?[]const u8 = null };
const FullChoice = struct { message: FullMessage = .{} };
const FullResponse = struct {
    choices: []FullChoice = &.{},
    usage: ?UsageWire = null,
};

// --- JSON shapes (encode side) ----------------------------------------------

const StreamOptions = struct { include_usage: bool = true };
const ChatRequest = struct {
    model: []const u8,
    messages: []const WireMessage,
    max_tokens: u32,
    temperature: f32,
    stream: bool,
    stream_options: ?StreamOptions = null,
};

pub const ChatClient = struct {
    gpa: Allocator,

    // Connection + streaming state.
    fd: c_int = -1,
    streaming: bool = false,

    // Where decoded assistant text is appended (an app-owned Message buffer).
    target: ?*std.ArrayList(u8) = null,

    // Incremental parse state, all relative to `recv_buf`.
    recv_buf: std.ArrayList(u8) = .empty,
    decoded: std.ArrayList(u8) = .empty,
    header_len: ?usize = null,
    chunked: bool = false,
    raw_cursor: usize = 0, // bytes of recv_buf body consumed by de-chunking
    sse_cursor: usize = 0, // bytes of decoded scanned for SSE lines
    chunk_remaining: ?usize = null, // null => expecting a chunk-size line

    // Results + timing.
    usage: Usage = .{},
    finished: bool = false,
    started_ms: i64 = 0,
    elapsed_ms: i64 = 0, // wall time of the completed stream (for tok/s)

    pub fn init(gpa: Allocator) ChatClient {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ChatClient) void {
        self.closeSocket();
        self.recv_buf.deinit(self.gpa);
        self.decoded.deinit(self.gpa);
    }

    pub fn isStreaming(self: *const ChatClient) bool {
        return self.streaming;
    }

    fn closeSocket(self: *ChatClient) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    /// Reset the per-request parse buffers (keeps capacity).
    fn resetParse(self: *ChatClient) void {
        self.recv_buf.clearRetainingCapacity();
        self.decoded.clearRetainingCapacity();
        self.header_len = null;
        self.chunked = false;
        self.raw_cursor = 0;
        self.sse_cursor = 0;
        self.chunk_remaining = null;
        self.usage = .{};
        self.finished = false;
        self.started_ms = nowMs();
        self.elapsed_ms = 0;
    }

    /// Begin a streaming request, appending assistant text into `target`.
    /// On failure, writes a human-readable error into `target` and is not left
    /// streaming.
    pub fn start(
        self: *ChatClient,
        url: []const u8,
        target: *std.ArrayList(u8),
        messages: []const WireMessage,
        params: Params,
    ) void {
        self.cancel();
        self.resetParse();
        self.target = target;

        self.connectAndSend(url, messages, params, true) catch |err| {
            self.failInto(target, err);
            return;
        };
        self.streaming = true;
    }

    /// Cancel any in-flight stream and close the socket.
    pub fn cancel(self: *ChatClient) void {
        self.closeSocket();
        self.streaming = false;
        self.target = null;
    }

    fn failInto(self: *ChatClient, target: *std.ArrayList(u8), err: anyerror) void {
        self.closeSocket();
        self.streaming = false;
        const msg = std.fmt.allocPrint(self.gpa, "[error: {s} — is the server running at the configured URL?]", .{@errorName(err)}) catch {
            return;
        };
        defer self.gpa.free(msg);
        target.appendSlice(self.gpa, msg) catch {};
    }

    /// Open a connection, send the request, and (for streaming) switch the socket
    /// to non-blocking for the polled read phase.
    fn connectAndSend(
        self: *ChatClient,
        url: []const u8,
        messages: []const WireMessage,
        params: Params,
        stream: bool,
    ) !void {
        const ep = parseUrl(url);
        var host_buf: [256]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{ep.host}) catch return error.BadUrl;

        const fd = try tcpConnect(host_z, ep.port);
        errdefer _ = c.close(fd);

        const body = try buildRequestBody(self.gpa, messages, params, stream);
        defer self.gpa.free(body);

        const req = try std.fmt.allocPrint(self.gpa, "POST /v1/chat/completions HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n{s}", .{ ep.host, ep.port, body.len, body });
        defer self.gpa.free(req);

        // The request is small and the socket is still blocking, so this writes
        // fully without partial-write handling.
        try sendAll(fd, req);

        if (stream) setNonBlocking(fd);
        self.fd = fd;
    }

    /// Poll the socket for newly available bytes and process them. Call once per
    /// frame while `isStreaming()`. Returns true if new content was appended.
    pub fn poll(self: *ChatClient) bool {
        if (!self.streaming or self.fd < 0) return false;
        const target = self.target orelse return false;
        const before = target.items.len;

        var buf: [16 * 1024]u8 = undefined;
        var eof = false;
        while (true) {
            const n = c.recv(self.fd, @ptrCast(&buf), buf.len, 0);
            if (n > 0) {
                self.recv_buf.appendSlice(self.gpa, buf[0..@intCast(n)]) catch break;
                continue;
            }
            if (n == 0) {
                eof = true;
                break;
            }
            // n < 0: EAGAIN/EWOULDBLOCK means "no more right now".
            const e = stdc._errno().*;
            if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
            if (e == c.EINTR) continue;
            eof = true; // a real error: treat like the stream ending
            break;
        }

        self.process(target);

        if (eof or self.finished) {
            self.closeSocket();
            self.streaming = false;
            self.elapsed_ms = nowMs() - self.started_ms;
        }
        return target.items.len != before;
    }

    /// Parse HTTP headers once, de-chunk the body, then consume SSE lines.
    fn process(self: *ChatClient, target: *std.ArrayList(u8)) void {
        if (self.header_len == null) {
            const sep = std.mem.indexOf(u8, self.recv_buf.items, "\r\n\r\n") orelse return;
            const headers = self.recv_buf.items[0..sep];
            self.chunked = headerHasChunked(headers);
            self.header_len = sep + 4;
            self.raw_cursor = self.header_len.?;
        }

        self.dechunk();
        self.consumeLines(target);
    }

    /// Advance `raw_cursor` over recv_buf's body, appending decoded bytes to
    /// `decoded`. Handles chunked transfer-encoding incrementally; otherwise
    /// copies the body verbatim.
    fn dechunk(self: *ChatClient) void {
        const buf = self.recv_buf.items;
        if (!self.chunked) {
            if (self.raw_cursor < buf.len) {
                self.decoded.appendSlice(self.gpa, buf[self.raw_cursor..]) catch {};
                self.raw_cursor = buf.len;
            }
            return;
        }
        while (true) {
            if (self.chunk_remaining == null) {
                // Need a complete "<hex>\r\n" size line.
                const rel = std.mem.indexOf(u8, buf[self.raw_cursor..], "\r\n") orelse return;
                const line = buf[self.raw_cursor .. self.raw_cursor + rel];
                const size = parseChunkSize(line);
                self.raw_cursor += rel + 2;
                if (size == 0) {
                    self.finished = true; // last chunk; ignore trailers
                    return;
                }
                self.chunk_remaining = size;
            } else {
                var rem = self.chunk_remaining.?;
                const avail = buf.len - self.raw_cursor;
                if (rem > 0) {
                    const take = @min(rem, avail);
                    if (take == 0) return; // need more bytes
                    self.decoded.appendSlice(self.gpa, buf[self.raw_cursor .. self.raw_cursor + take]) catch {};
                    self.raw_cursor += take;
                    rem -= take;
                    self.chunk_remaining = rem;
                    if (rem > 0) return; // chunk not fully received yet
                }
                // Consume the trailing CRLF after the chunk data.
                if (buf.len - self.raw_cursor < 2) return;
                self.raw_cursor += 2;
                self.chunk_remaining = null;
            }
        }
    }

    /// Consume complete '\n'-terminated lines from `decoded`, handling each SSE
    /// `data:` line.
    fn consumeLines(self: *ChatClient, target: *std.ArrayList(u8)) void {
        while (std.mem.indexOfScalarPos(u8, self.decoded.items, self.sse_cursor, '\n')) |nl| {
            var line = self.decoded.items[self.sse_cursor..nl];
            self.sse_cursor = nl + 1;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            self.handleSseLine(line, target);
        }
    }

    fn handleSseLine(self: *ChatClient, line: []const u8, target: *std.ArrayList(u8)) void {
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const payload = std.mem.trim(u8, line["data:".len..], " \t");
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.finished = true;
            return;
        }
        const parsed = std.json.parseFromSlice(StreamChunk, self.gpa, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const chunk = parsed.value;
        if (chunk.choices.len > 0) {
            const d = chunk.choices[0].delta;
            if (d.content) |t| target.appendSlice(self.gpa, t) catch {};
            if (d.reasoning_content) |t| target.appendSlice(self.gpa, t) catch {};
        }
        if (chunk.usage) |u| {
            if (u.prompt_tokens) |p| self.usage.prompt_tokens = p;
            if (u.completion_tokens) |comp| self.usage.completion_tokens = comp;
        }
    }

    /// One-shot, non-streaming request: connect, send, read the whole response,
    /// de-chunk, and return `choices[0].message.content`. Caller owns the result.
    /// Used by the headless `--smoke` path.
    pub fn request(
        self: *ChatClient,
        url: []const u8,
        messages: []const WireMessage,
        params: Params,
    ) ![]u8 {
        self.resetParse();
        try self.connectAndSend(url, messages, params, false);
        defer self.closeSocket();

        // Blocking read to EOF (the server sends `Connection: close`).
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = c.recv(self.fd, @ptrCast(&buf), buf.len, 0);
            if (n > 0) {
                try self.recv_buf.appendSlice(self.gpa, buf[0..@intCast(n)]);
                continue;
            }
            if (n == 0) break;
            const e = stdc._errno().*;
            if (e == c.EINTR) continue;
            return error.RecvFailed;
        }

        // Split headers, de-chunk the body.
        const sep = std.mem.indexOf(u8, self.recv_buf.items, "\r\n\r\n") orelse return error.BadResponse;
        self.chunked = headerHasChunked(self.recv_buf.items[0..sep]);
        self.header_len = sep + 4;
        self.raw_cursor = self.header_len.?;
        self.dechunk();

        const parsed = try std.json.parseFromSlice(FullResponse, self.gpa, self.decoded.items, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        if (parsed.value.choices.len == 0) return error.NoChoices;
        const content = parsed.value.choices[0].message.content orelse return error.NoContent;
        if (parsed.value.usage) |u| {
            if (u.prompt_tokens) |p| self.usage.prompt_tokens = p;
            if (u.completion_tokens) |comp| self.usage.completion_tokens = comp;
        }
        return self.gpa.dupe(u8, content);
    }
};

/// A blocking `GET /health` probe driving the server-status dot. Returns true if
/// the server answers `200`/`{"status":...}`; false if it is down or errors.
/// Fast against localhost (a refused connection fails immediately).
pub fn checkHealth(url: []const u8) bool {
    const ep = parseUrl(url);
    var host_buf: [256]u8 = undefined;
    const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{ep.host}) catch return false;
    const fd = tcpConnect(host_z, ep.port) catch return false;
    defer _ = c.close(fd);

    var req_buf: [320]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET /health HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ ep.host, ep.port }) catch return false;
    sendAll(fd, req) catch return false;

    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.recv(fd, @ptrCast(buf[total..].ptr), buf.len - total, 0);
        if (n > 0) {
            total += @intCast(n);
            continue;
        }
        if (n == 0) break;
        if (stdc._errno().* == c.EINTR) continue;
        break;
    }
    const resp = buf[0..total];
    return std.mem.indexOf(u8, resp, " 200 ") != null or std.mem.indexOf(u8, resp, "\"status\"") != null;
}

// --- helpers ----------------------------------------------------------------

const Endpoint = struct { host: []const u8, port: u16 };

/// Parse `http://host:port[/path]` (scheme and path optional) into host+port.
fn parseUrl(url: []const u8) Endpoint {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "http://")) rest = rest["http://".len..];
    if (std.mem.startsWith(u8, rest, "https://")) rest = rest["https://".len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| rest = rest[0..i];
    var host = rest;
    var port: u16 = 11234;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
        host = rest[0..i];
        port = std.fmt.parseInt(u16, rest[i + 1 ..], 10) catch 11234;
    }
    if (host.len == 0) host = "127.0.0.1";
    return .{ .host = host, .port = port };
}

fn buildRequestBody(gpa: Allocator, messages: []const WireMessage, params: Params, stream: bool) ![]u8 {
    const req = ChatRequest{
        .model = params.model,
        .messages = messages,
        .max_tokens = params.max_tokens,
        .temperature = params.temperature,
        .stream = stream,
        .stream_options = if (stream) .{} else null,
    };
    return std.json.Stringify.valueAlloc(gpa, req, .{ .emit_null_optional_fields = false });
}

fn headerHasChunked(headers: []const u8) bool {
    // Case-insensitive scan for "transfer-encoding: chunked".
    var buf: [512]u8 = undefined;
    const n = @min(headers.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], headers[0..n]);
    return std.mem.indexOf(u8, lower, "transfer-encoding: chunked") != null or
        std.mem.indexOf(u8, lower, "transfer-encoding:chunked") != null;
}

fn parseChunkSize(line: []const u8) usize {
    // A chunk-size line may carry extensions after ';'; take the hex prefix.
    var end: usize = 0;
    while (end < line.len and line[end] != ';' and line[end] != '\r') : (end += 1) {}
    return std.fmt.parseInt(usize, std.mem.trim(u8, line[0..end], " \t"), 16) catch 0;
}

fn tcpConnect(host: [:0]const u8, port: u16) !c_int {
    var hints: c.addrinfo = std.mem.zeroes(c.addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;
    var port_buf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.BadUrl;

    var res: [*c]c.addrinfo = null;
    if (c.getaddrinfo(host.ptr, port_z.ptr, &hints, &res) != 0) return error.DnsFailed;
    defer c.freeaddrinfo(res);

    var ai: [*c]c.addrinfo = res;
    while (ai != null) : (ai = ai.*.ai_next) {
        const fd = c.socket(ai.*.ai_family, ai.*.ai_socktype, ai.*.ai_protocol);
        if (fd < 0) continue;
        if (c.connect(fd, ai.*.ai_addr, ai.*.ai_addrlen) == 0) return fd;
        _ = c.close(fd);
    }
    return error.ConnectFailed;
}

fn setNonBlocking(fd: c_int) void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return;
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
}

fn sendAll(fd: c_int, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.send(fd, @ptrCast(data.ptr + off), data.len - off, 0);
        if (n <= 0) {
            const e = stdc._errno().*;
            if (n < 0 and e == c.EINTR) continue;
            return error.SendFailed;
        }
        off += @intCast(n);
    }
}

// --- tests ------------------------------------------------------------------
// (Compiled only when this file is the test root; the library suite stays
// headless. These cover the pure parsing helpers without a socket.)

const testing = std.testing;

test "parseUrl: scheme/host/port/path variants" {
    const a = parseUrl("http://127.0.0.1:11234");
    try testing.expectEqualStrings("127.0.0.1", a.host);
    try testing.expectEqual(@as(u16, 11234), a.port);
    const b = parseUrl("http://localhost:8080/v1/chat/completions");
    try testing.expectEqualStrings("localhost", b.host);
    try testing.expectEqual(@as(u16, 8080), b.port);
    const d = parseUrl("example.com");
    try testing.expectEqualStrings("example.com", d.host);
    try testing.expectEqual(@as(u16, 11234), d.port);
}

test "parseChunkSize: hex with optional extension" {
    try testing.expectEqual(@as(usize, 0x1a), parseChunkSize("1a"));
    try testing.expectEqual(@as(usize, 0x10), parseChunkSize("10;ext=1"));
    try testing.expectEqual(@as(usize, 0), parseChunkSize("0"));
}

test "headerHasChunked: case-insensitive detection" {
    try testing.expect(headerHasChunked("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n"));
    try testing.expect(!headerHasChunked("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"));
}
