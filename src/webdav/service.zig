const std = @import("std");
const sdk = @import("paper_portal_sdk");
const wds = @import("webdav_server");

const Http = @import("http.zig");
const Portal = @import("portal.zig");

const webdav = wds.webdav;

pub const WebDavService = struct {
    running: bool = false,
    listen_socket: ?sdk.socket.Socket = null,

    io_state: Portal.PortalIoState = .{},
    fs: Portal.PortalFs = .{},
    sys: Portal.PortalSys = .{},
    handler: ?webdav.Handler = null,

    pub fn isRunning(self: *const WebDavService) bool {
        return self.running;
    }

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

        Portal.PortalIo.ensureInitialized();

        self.io_state = .{ .allocator = std.heap.wasm_allocator };
        self.fs = .{ .io_state = &self.io_state };
        self.sys = .{};

        const config: webdav.Config = .{
            // Portal host path buffer is 256 bytes including leading '/' + NUL.
            .max_path_bytes = 254,
        };
        self.handler = try webdav.Handler.init(std.heap.wasm_allocator, &self.fs, &self.sys, config);

        var sock = try sdk.socket.Socket.tcp();
        errdefer sock.close() catch {};
        try sock.bind(sdk.socket.SocketAddr.any(8080));
        try sock.listen(4);
        self.listen_socket = sock;

        self.running = true;

        const ip = sdk.net.getIpv4() catch .{ 0, 0, 0, 0 };
        sdk.core.log.finfo("webdav: listening on http://{d}.{d}.{d}.{d}:8080/", .{ ip[0], ip[1], ip[2], ip[3] });
    }

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

fn handleConnection(self: *WebDavService, client: *sdk.socket.Socket) !void {
    const handler = blk: {
        if (self.handler) |*h| break :blk h;
        return;
    };
    var conn = Http.Connection.init(client);

    while (true) {
        var header_bytes: [16 * 1024]u8 = undefined;
        var headers: [64]webdav.Header = undefined;
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

        const method_s, const target_s = Http.parseRequestLine(req_line) catch {
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

        var close_after_response = Http.requestWantsClose(req_headers);

        var body = Http.Body.init(&conn, req_headers);
        const body_reader = webdav.BodyReader{ .ctx = &body, .readFn = Http.Body.readFn };

        var res_ctx = Http.ResponseCtx{ .conn = &conn, .close_after_response = close_after_response };
        var res = webdav.ResponseWriter{
            .ctx = &res_ctx,
            .writeHeadFn = Http.ResponseCtx.writeHeadFn,
            .writeAllFn = Http.ResponseCtx.writeAllFn,
            .writeChunkFn = Http.ResponseCtx.writeChunkFn,
            .finishFn = Http.ResponseCtx.finishFn,
        };

        const req = webdav.Request{
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
        Http.drainBody(&body) catch {};

        if (close_after_response) return;
    }
}

fn parseMethod(method: []const u8) webdav.Method {
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
