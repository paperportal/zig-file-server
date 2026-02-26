const std = @import("std");
const sdk = @import("paper_portal_sdk");
const wds = @import("webdav_server");
const http = @import("http.zig");
const portal = @import("portal.zig");

/// Runs a WebDAV server bound to TCP port 8080 using Portal filesystem adapters.
pub const WebDavService = struct {
    /// Whether the service is currently running.
    running: bool = false,
    /// The server's listening socket, if started.
    listen_socket: ?sdk.socket.Socket = null,

    /// Shared I/O state used by the Portal filesystem adapter.
    io_state: portal.PortalIoState = .{},
    /// WebDAV filesystem adapter backed by the Portal host filesystem.
    fs: portal.PortalFs = .{},
    /// WebDAV system adapter (time/clock) backed by Portal RTC.
    sys: portal.PortalSys = .{},
    /// WebDAV request handler instance (initialized on `start`).
    handler: ?wds.webdav.Handler = null,

    /// Returns whether the server is currently running.
    pub fn isRunning(self: *const WebDavService) bool {
        return self.running;
    }

    /// Accepts and services at most one pending connection.
    pub fn tick(self: *WebDavService, now_ms: i32) void {
        _ = now_ms;
        if (!self.running) return;

        if (self.listen_socket) |*listener| {
            const accepted = listener.acceptWithTimeout(0) catch |err| switch (err) {
                sdk.socket.Error.NotReady => return,
                else => {
                    sdk.core.log.ferr("webdav: accept failed: {s}", .{@errorName(err)});
                    return;
                },
            };

            var client = accepted.socket;
            defer client.close() catch {};

            handleConnection(self, &client) catch |err| {
                sdk.core.log.ferr("webdav: connection error: {s}", .{@errorName(err)});
            };
        }
    }

    /// Starts the WebDAV server and begins listening on `:8080`.
    pub fn start(self: *WebDavService) !void {
        if (self.running) return;

        if (!sdk.net.isReady()) {
            try sdk.net.connect();
        }
        if (!sdk.fs.isMounted()) {
            try sdk.fs.mount();
        }

        const runtime_features_raw = sdk.core.apiFeatures();
        const features: u64 = @bitCast(runtime_features_raw);
        if ((features & sdk.core.Feature.rtc) != 0) {
            sdk.rtc.begin() catch {};
        }

        portal.PortalIo.ensureInitialized();

        self.io_state = .{ .allocator = std.heap.wasm_allocator };
        self.fs = .{ .io_state = &self.io_state };
        self.sys = .{};

        const config: wds.webdav.Config = .{
            // Portal host path buffer is 256 bytes including leading '/' + NUL.
            .max_path_bytes = 254,
        };
        self.handler = try wds.webdav.Handler.init(std.heap.wasm_allocator, &self.fs, &self.sys, config);

        var sock = try sdk.socket.Socket.tcp();
        errdefer sock.close() catch {};
        try sock.bind(sdk.socket.SocketAddr.any(8080));
        try sock.listen(4);
        self.listen_socket = sock;

        self.running = true;

        const ip = sdk.net.getIpv4() catch .{ 0, 0, 0, 0 };
        sdk.core.log.finfo("webdav: listening on http://{d}.{d}.{d}.{d}:8080/", .{ ip[0], ip[1], ip[2], ip[3] });
    }

    /// Stops the WebDAV server and releases any held resources.
    pub fn stop(self: *WebDavService) void {
        if (!self.running) return;
        self.running = false;

        if (self.listen_socket) |*s| s.close() catch {};
        self.listen_socket = null;

        if (self.handler) |*h| h.deinit(std.heap.wasm_allocator);
        self.handler = null;

        self.io_state.deinit();

        sdk.core.log.info("webdav: stopped");
    }
};

/// Services requests on a single accepted client socket until completion/close.
fn handleConnection(self: *WebDavService, client: *sdk.socket.Socket) !void {
    const handler = blk: {
        if (self.handler) |*h| break :blk h;
        return;
    };
    var conn = http.Connection.init(client);

    while (true) {
        var header_bytes: [16 * 1024]u8 = undefined;
        var headers: [64]wds.webdav.Header = undefined;
        var header_used: usize = 0;
        var headers_len: usize = 0;

        const req_line = conn.readLineInto(&header_bytes, &header_used, 5_000) catch |err| switch (err) {
            error.UnexpectedEndOfStream => return,
            else => {
                try conn.sendBadRequest();
                return;
            },
        };
        if (req_line.len == 0) return;

        const method_s, const target_s = http.parseRequestLine(req_line) catch {
            try conn.sendBadRequest();
            return;
        };
        const method = parseMethod(method_s);

        var target_buf: [1024]u8 = undefined;
        if (target_s.len > target_buf.len) {
            try conn.sendBadRequest();
            return;
        }
        @memcpy(target_buf[0..target_s.len], target_s);
        const raw_target = target_buf[0..target_s.len];
        const path = raw_target[0..(std.mem.indexOfScalar(u8, raw_target, '?') orelse raw_target.len)];

        while (true) {
            const line = conn.readLineInto(&header_bytes, &header_used, 5_000) catch {
                try conn.sendBadRequest();
                return;
            };
            if (line.len == 0) break;
            if (headers_len >= headers.len) {
                try conn.sendBadRequest();
                return;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            headers[headers_len] = .{ .name = name, .value = value };
            headers_len += 1;
        }
        const req_headers = headers[0..headers_len];

        var close_after_response = http.requestWantsClose(req_headers);

        var body = http.Body.init(&conn, req_headers);
        const body_reader = wds.webdav.BodyReader{ .ctx = &body, .readFn = http.Body.readFn };

        var res_ctx = http.ResponseCtx{ .conn = &conn, .close_after_response = close_after_response };
        var res = wds.webdav.ResponseWriter{
            .ctx = &res_ctx,
            .writeHeadFn = http.ResponseCtx.writeHeadFn,
            .writeAllFn = http.ResponseCtx.writeAllFn,
            .writeChunkFn = http.ResponseCtx.writeChunkFn,
            .finishFn = http.ResponseCtx.finishFn,
        };

        const req = wds.webdav.Request{
            .method = method,
            .raw_target = raw_target,
            .path = path,
            .headers = req_headers,
            .body = body_reader,
        };

        handler.handle(req, &res) catch {
            close_after_response = true;
            res_ctx.close_after_response = true;
        };

        res.finish() catch {};
        http.drainBody(&body) catch {};

        if (close_after_response) return;
    }
}

/// Maps an HTTP method string to the WebDAV server method enum.
fn parseMethod(method: []const u8) wds.webdav.Method {
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return .options;
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .get;
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .head;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .put;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .delete;
    if (std.ascii.eqlIgnoreCase(method, "MKCOL")) return .mkcol;
    if (std.ascii.eqlIgnoreCase(method, "COPY")) return .copy;
    if (std.ascii.eqlIgnoreCase(method, "MOVE")) return .move;
    if (std.ascii.eqlIgnoreCase(method, "PROPFIND")) return .propfind;
    if (std.ascii.eqlIgnoreCase(method, "PROPPATCH")) return .proppatch;
    return .other;
}
