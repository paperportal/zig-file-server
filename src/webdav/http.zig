const std = @import("std");
const sdk = @import("paper_portal_sdk");
const wds = @import("webdav_server");

/// Buffered socket connection utilities for parsing and responding to HTTP-like requests.
pub const Connection = struct {
    /// Underlying Portal socket.
    sock: *sdk.socket.Socket,
    /// Scratch buffer used for incremental reads (header parsing, chunked decoding).
    buf: [16 * 1024]u8 = undefined,
    /// Start offset of unread bytes within `buf`.
    start: usize = 0,
    /// End offset of unread bytes within `buf`.
    end: usize = 0,

    /// Initializes a buffered connection wrapper for `sock`.
    pub fn init(sock: *sdk.socket.Socket) Connection {
        return .{ .sock = sock };
    }

    /// Reads more data into the internal buffer, compacting when needed.
    fn fill(self: *Connection, timeout_ms: i32) !void {
        if (self.start > 0 and self.start == self.end) {
            self.start = 0;
            self.end = 0;
        } else if (self.start > 0 and self.end == self.buf.len) {
            const remaining = self.buf[self.start..self.end];
            @memmove(self.buf[0..remaining.len], remaining);
            self.start = 0;
            self.end = remaining.len;
        }

        if (self.end == self.buf.len) return error.BufferFull;
        const n = self.sock.recv(self.buf[self.end..], timeout_ms) catch |err| switch (err) {
            sdk.socket.Error.NotReady => return error.UnexpectedEndOfStream,
            else => return err,
        };
        if (n == 0) return error.UnexpectedEndOfStream;
        self.end += n;
    }

    /// Reads a single byte, blocking up to `timeout_ms`.
    fn readByte(self: *Connection, timeout_ms: i32) !u8 {
        if (self.start == self.end) {
            try self.fill(timeout_ms);
        }
        const b = self.buf[self.start];
        self.start += 1;
        return b;
    }

    /// Reads up to `dest.len` bytes, blocking up to `timeout_ms`.
    fn readInto(self: *Connection, dest: []u8, timeout_ms: i32) !usize {
        if (dest.len == 0) return 0;

        if (self.start < self.end) {
            const available = self.buf[self.start..self.end];
            const n = @min(dest.len, available.len);
            @memcpy(dest[0..n], available[0..n]);
            self.start += n;
            return n;
        }

        const n = self.sock.recv(dest, timeout_ms) catch |err| switch (err) {
            sdk.socket.Error.NotReady => return error.UnexpectedEndOfStream,
            else => return err,
        };
        return n;
    }

    /// Reads a single CRLF-terminated line into `storage`, appending after `used.*`.
    pub fn readLineInto(self: *Connection, storage: []u8, used: *usize, timeout_ms: i32) ![]const u8 {
        const start = used.*;
        while (true) {
            if (used.* >= storage.len) return error.LineTooLong;
            const b = try self.readByte(timeout_ms);
            if (b == '\n') break;
            storage[used.*] = b;
            used.* += 1;
        }

        var end = used.*;
        if (end > start and storage[end - 1] == '\r') end -= 1;
        return storage[start..end];
    }

    /// Reads a single CRLF-terminated line into `buf`.
    fn readLine(self: *Connection, buf: []u8, timeout_ms: i32) ![]const u8 {
        var used: usize = 0;
        const line = try self.readLineInto(buf, &used, timeout_ms);
        return line;
    }

    /// Sends all bytes, retrying until completion or socket error.
    fn sendAll(self: *Connection, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = self.sock.send(bytes[off..], 10_000) catch |err| switch (err) {
                sdk.socket.Error.NotReady => return error.UnexpectedEndOfStream,
                else => return err,
            };
            if (n == 0) return error.UnexpectedEndOfStream;
            off += n;
        }
    }

    /// Writes a minimal HTTP 400 response and closes the connection.
    pub fn sendBadRequest(self: *Connection) !void {
        const body = "bad request\n";
        var head_buf: [256]u8 = undefined;
        const head = try std.fmt.bufPrint(
            &head_buf,
            "HTTP/1.1 400 Bad Request\r\n" ++
                "Connection: close\r\n" ++
                "Content-Type: text/plain; charset=utf-8\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n",
            .{body.len},
        );
        try self.sendAll(head);
        try self.sendAll(body);
    }
};

/// Parses an HTTP request line into `(method, target)`.
pub fn parseRequestLine(line: []const u8) !struct { []const u8, []const u8 } {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadRequest;
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse return error.BadRequest;
    return .{ line[0..sp1], line[sp1 + 1 .. sp2] };
}

/// Returns true if the request includes `Connection: close`.
pub fn requestWantsClose(headers: []const wds.webdav.Header) bool {
    const v = wds.webdav.types.headerValue(headers, "connection") orelse return false;
    var it = std.mem.tokenizeAny(u8, v, ",");
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(t, "close")) return true;
    }
    return false;
}

/// HTTP request body reader supporting fixed-length and chunked transfer encoding.
pub const Body = struct {
    /// Connection used to read body bytes.
    conn: *Connection,
    /// Selected body decoding mode derived from request headers.
    mode: Mode,

    /// Body decoding mode.
    const Mode = union(enum) {
        /// No request body.
        none,
        /// Read exactly the given number of bytes.
        content_length: u64,
        /// Read chunked transfer encoding.
        chunked: Chunked,
    };

    /// Chunked transfer decoding state.
    const Chunked = struct {
        /// Remaining unread bytes in the current chunk.
        remaining_in_chunk: u64 = 0,
        /// Whether the terminal `0` chunk has been consumed.
        done: bool = false,
    };

    /// Initializes a body decoder from request headers.
    pub fn init(conn: *Connection, headers: []const wds.webdav.Header) Body {
        if (wds.webdav.types.headerValue(headers, "transfer-encoding")) |te| {
            if (std.mem.indexOf(u8, te, "chunked") != null or std.mem.indexOf(u8, te, "Chunked") != null) {
                return .{ .conn = conn, .mode = .{ .chunked = .{} } };
            }
        }
        if (wds.webdav.types.headerValue(headers, "content-length")) |cl| {
            const len = std.fmt.parseInt(u64, cl, 10) catch 0;
            return .{ .conn = conn, .mode = .{ .content_length = len } };
        }
        return .{ .conn = conn, .mode = .none };
    }

    /// `webdav.BodyReader` adapter: reads body bytes into `dest`.
    pub fn readFn(ctx: *anyopaque, dest: []u8) anyerror!usize {
        const self: *Body = @ptrCast(@alignCast(ctx));
        return self.read(dest);
    }

    /// Reads up to `dest.len` bytes from the request body.
    fn read(self: *Body, dest: []u8) anyerror!usize {
        if (dest.len == 0) return 0;
        return switch (self.mode) {
            .none => 0,
            .content_length => |*remaining| {
                if (remaining.* == 0) return 0;
                const want: usize = @intCast(@min(@as(u64, dest.len), remaining.*));
                const n = try self.conn.readInto(dest[0..want], 10_000);
                if (n == 0) return error.UnexpectedEndOfStream;
                remaining.* -= n;
                return n;
            },
            .chunked => |*st| try self.readChunked(dest, st),
        };
    }

    /// Reads from a `Transfer-Encoding: chunked` body.
    fn readChunked(self: *Body, dest: []u8, st: *Chunked) anyerror!usize {
        if (st.done) return 0;

        if (st.remaining_in_chunk == 0) {
            var line_buf: [128]u8 = undefined;
            var line = try self.conn.readLine(&line_buf, 10_000);
            line = std.mem.trimEnd(u8, line, "\r");
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const size_text = std.mem.trim(u8, line[0..semi], " \t");
            const chunk_size = std.fmt.parseInt(u64, size_text, 16) catch return error.BadChunkedEncoding;
            if (chunk_size == 0) {
                // trailers
                while (true) {
                    line = try self.conn.readLine(&line_buf, 10_000);
                    line = std.mem.trimEnd(u8, line, "\r");
                    if (line.len == 0) break;
                }
                st.done = true;
                return 0;
            }
            st.remaining_in_chunk = chunk_size;
        }

        const want: usize = @intCast(@min(@as(u64, dest.len), st.remaining_in_chunk));
        const n = try self.conn.readInto(dest[0..want], 10_000);
        if (n == 0) return error.UnexpectedEndOfStream;
        st.remaining_in_chunk -= n;
        if (st.remaining_in_chunk == 0) {
            var crlf: [2]u8 = undefined;
            _ = self.conn.readInto(&crlf, 10_000) catch {};
        }
        return n;
    }
};

/// Reads and discards any remaining request body bytes.
pub fn drainBody(body: *Body) !void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try body.read(&buf);
        if (n == 0) return;
    }
}

/// `webdav.ResponseWriter` adapter that writes HTTP/1.1 responses to a `Connection`.
pub const ResponseCtx = struct {
    /// Connection used to send response bytes.
    conn: *Connection,
    /// Whether the response should close the connection.
    close_after_response: bool = false,
    /// Whether response headers have been written.
    wrote_head: bool = false,
    /// Whether the response is using chunked transfer encoding.
    chunked: bool = false,
    /// Whether the response has been finalized.
    finished: bool = false,

    /// Writes the response status line + headers, and configures body mode.
    pub fn writeHeadFn(ctx: *anyopaque, status: u16, headers: []const wds.webdav.Header, body_mode: wds.webdav.BodyMode) anyerror!void {
        const self: *ResponseCtx = @ptrCast(@alignCast(ctx));
        if (self.wrote_head) return;
        self.wrote_head = true;

        var line_buf: [128]u8 = undefined;
        const status_line = try std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status, reasonPhrase(status) });
        try self.conn.sendAll(status_line);
        try self.conn.sendAll("Server: zig-file-server\r\n");
        try self.conn.sendAll(if (self.close_after_response) "Connection: close\r\n" else "Connection: keep-alive\r\n");

        for (headers) |h| {
            var hb: [256]u8 = undefined;
            const s = try std.fmt.bufPrint(&hb, "{s}: {s}\r\n", .{ h.name, h.value });
            try self.conn.sendAll(s);
        }

        switch (body_mode) {
            .none => try self.conn.sendAll("Content-Length: 0\r\n"),
            .known_length => |n| {
                var cl: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&cl, "Content-Length: {d}\r\n", .{n});
                try self.conn.sendAll(s);
            },
            .chunked => {
                self.chunked = true;
                try self.conn.sendAll("Transfer-Encoding: chunked\r\n");
            },
        }

        try self.conn.sendAll("\r\n");
    }

    /// Writes the full response body buffer.
    pub fn writeAllFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ResponseCtx = @ptrCast(@alignCast(ctx));
        if (!self.wrote_head) return error.MissingResponseHead;
        if (self.finished) return error.ResponseFinished;
        if (self.chunked) return writeChunkFn(ctx, bytes);
        try self.conn.sendAll(bytes);
    }

    /// Writes a single response body chunk (or raw bytes when not chunked).
    pub fn writeChunkFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ResponseCtx = @ptrCast(@alignCast(ctx));
        if (!self.wrote_head) return error.MissingResponseHead;
        if (self.finished) return error.ResponseFinished;
        if (!self.chunked) return self.conn.sendAll(bytes);
        if (bytes.len == 0) return;
        var hb: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&hb, "{x}\r\n", .{bytes.len});
        try self.conn.sendAll(prefix);
        try self.conn.sendAll(bytes);
        try self.conn.sendAll("\r\n");
    }

    /// Finalizes the response, writing any required terminators.
    pub fn finishFn(ctx: *anyopaque) anyerror!void {
        const self: *ResponseCtx = @ptrCast(@alignCast(ctx));
        if (self.finished) return;
        self.finished = true;
        if (!self.wrote_head) {
            try writeHeadFn(ctx, 500, &.{}, .none);
        }
        if (self.chunked) {
            try self.conn.sendAll("0\r\n\r\n");
        }
    }
};

/// Returns an HTTP reason phrase for common status codes.
fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        207 => "Multi-Status",
        301 => "Moved Permanently",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        412 => "Precondition Failed",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        else => "OK",
    };
}
