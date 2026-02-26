const std = @import("std");
const sdk = @import("paper_portal_sdk");
const wds = @import("webdav_server");

const webdav = wds.webdav;

pub const WebDavService = struct {
    running: bool = false,
    listen_socket: ?sdk.socket.Socket = null,

    io_state: PortalIoState = .{},
    fs: PortalFs = .{},
    sys: PortalSys = .{},
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

        PortalIo.ensureInitialized();

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

const PortalIoState = struct {
    allocator: std.mem.Allocator = std.heap.wasm_allocator,
    dir_rel_paths: std.AutoHashMapUnmanaged(i32, []u8) = .{},

    fn deinit(self: *PortalIoState) void {
        var it = self.dir_rel_paths.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.dir_rel_paths.deinit(self.allocator);
    }

    fn registerDir(self: *PortalIoState, handle: i32, rel: []const u8) !void {
        if (handle < 0) return error.InvalidArgument;
        const buf = try self.allocator.alloc(u8, rel.len);
        errdefer self.allocator.free(buf);
        @memcpy(buf, rel);

        const gop = try self.dir_rel_paths.getOrPut(self.allocator, handle);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = buf;
    }

    fn unregisterDir(self: *PortalIoState, handle: i32) void {
        if (handle < 0) return;
        const removed = self.dir_rel_paths.fetchRemove(handle) orelse return;
        self.allocator.free(removed.value);
    }

    fn relForDir(self: *PortalIoState, handle: i32) ?[]const u8 {
        return self.dir_rel_paths.get(handle);
    }
};

const PortalIo = struct {
    var initialized: bool = false;
    var vtable: std.Io.VTable = undefined;

    fn ensureInitialized() void {
        if (initialized) return;
        vtable = undefined;

        vtable.operate = operate;
        vtable.fileReadPositional = fileReadPositional;
        vtable.fileWritePositional = fileWritePositional;
        vtable.fileSeekBy = fileSeekBy;
        vtable.fileSeekTo = fileSeekTo;
        vtable.fileClose = fileClose;

        vtable.dirRead = dirRead;
        vtable.dirClose = dirClose;

        initialized = true;
    }

    fn io(state: *PortalIoState) std.Io {
        ensureInitialized();
        return .{ .userdata = state, .vtable = &vtable };
    }

    fn operate(_: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        return switch (operation) {
            .file_read_streaming => |o| .{ .file_read_streaming = fileReadStreaming(o.file, o.data) },
            .file_write_streaming => |o| .{ .file_write_streaming = fileWriteStreaming(o.file, o.header, o.data, o.splat) },
            .device_io_control => unreachable,
        };
    }

    fn fileReadStreaming(file: std.Io.File, data: []const []u8) std.Io.Operation.FileReadStreaming.Result {
        if (data.len == 0) return 0;
        var portal_file: sdk.fs.File = .{ .handle = @intCast(file.handle) };
        var total: usize = 0;
        for (data) |dest| {
            if (dest.len == 0) continue;
            const n = portal_file.read(dest) catch |err| return switch (err) {
                sdk.fs.Error.InvalidArgument => error.NotOpenForReading,
                sdk.fs.Error.NotReady => error.SystemResources,
                sdk.fs.Error.Internal => error.InputOutput,
                sdk.fs.Error.NotFound => error.NotOpenForReading,
                sdk.fs.Error.Unknown => error.InputOutput,
            };
            if (n == 0) {
                if (total == 0) return error.EndOfStream;
                return total;
            }
            total += n;
            if (n < dest.len) return total;
        }
        return total;
    }

    fn fileWriteStreaming(
        file: std.Io.File,
        header: []const u8,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Operation.FileWriteStreaming.Result {
        if (header.len == 0 and data.len == 0) return 0;
        var portal_file: sdk.fs.File = .{ .handle = @intCast(file.handle) };
        var total: usize = 0;

        total += try writeSome(&portal_file, header);
        if (total < header.len) return total;

        if (data.len == 0) return total;

        for (data[0 .. data.len - 1]) |bytes| {
            const n = try writeSome(&portal_file, bytes);
            total += n;
            if (n < bytes.len) return total;
        }

        const pattern = data[data.len - 1];
        if (pattern.len == 0) return total;
        for (0..splat) |_| {
            const n = try writeSome(&portal_file, pattern);
            total += n;
            if (n < pattern.len) return total;
        }

        return total;
    }

    fn writeSome(file: *sdk.fs.File, bytes: []const u8) std.Io.Operation.FileWriteStreaming.Result {
        if (bytes.len == 0) return 0;
        return file.write(bytes) catch |err| switch (err) {
            sdk.fs.Error.InvalidArgument => error.NotOpenForWriting,
            sdk.fs.Error.NotReady => error.NoDevice,
            sdk.fs.Error.Internal => error.InputOutput,
            sdk.fs.Error.NotFound => error.NotOpenForWriting,
            sdk.fs.Error.Unknown => error.InputOutput,
        };
    }

    fn fileReadPositional(_: ?*anyopaque, _: std.Io.File, _: []const []u8, _: u64) std.Io.File.ReadPositionalError!usize {
        return error.Unseekable;
    }

    fn fileWritePositional(
        _: ?*anyopaque,
        _: std.Io.File,
        _: []const u8,
        _: []const []const u8,
        _: usize,
        _: u64,
    ) std.Io.File.WritePositionalError!usize {
        return error.Unseekable;
    }

    fn fileSeekBy(_: ?*anyopaque, _: std.Io.File, _: i64) std.Io.File.SeekError!void {
        return error.Unseekable;
    }

    fn fileSeekTo(_: ?*anyopaque, _: std.Io.File, _: u64) std.Io.File.SeekError!void {
        return error.Unseekable;
    }

    fn fileClose(_: ?*anyopaque, files: []const std.Io.File) void {
        for (files) |f| {
            var portal_file: sdk.fs.File = .{ .handle = @intCast(f.handle) };
            portal_file.close() catch {};
        }
    }

    fn dirRead(userdata: ?*anyopaque, r: *std.Io.Dir.Reader, out: []std.Io.Dir.Entry) std.Io.Dir.Reader.Error!usize {
        const state: *PortalIoState = @ptrCast(@alignCast(userdata orelse return error.SystemResources));
        if (out.len == 0) return 0;

        if (r.state == .reset) {
            const old_handle: i32 = @intCast(r.dir.handle);
            const rel = state.relForDir(old_handle) orelse return error.SystemResources;

            var rel_copy_buf: [256]u8 = undefined;
            if (rel.len > rel_copy_buf.len) return error.SystemResources;
            @memcpy(rel_copy_buf[0..rel.len], rel);
            const rel_copy = rel_copy_buf[0..rel.len];

            var old_dir: sdk.fs.Dir = .{ .handle = old_handle };
            old_dir.close() catch {};
            state.unregisterDir(old_handle);

            var abs_buf: [256]u8 = undefined;
            const abs = absPathZ(&abs_buf, rel_copy);
            var new_dir = sdk.fs.Dir.open(abs) catch return error.SystemResources;
            errdefer new_dir.close() catch {};
            state.registerDir(new_dir.handle, rel_copy) catch return error.SystemResources;

            r.dir.handle = @intCast(new_dir.handle);
            r.state = .reading;
        }

        var portal_dir: sdk.fs.Dir = .{ .handle = @intCast(r.dir.handle) };
        const buf_bytes: []u8 = @as([*]u8, @ptrCast(r.buffer.ptr))[0..r.buffer.len];
        const name_len_opt = portal_dir.readName(buf_bytes) catch return error.SystemResources;
        const name_len = name_len_opt orelse {
            r.state = .finished;
            return 0;
        };
        const name = buf_bytes[0..name_len];

        var kind: std.Io.File.Kind = .unknown;
        if (state.relForDir(@intCast(r.dir.handle))) |dir_rel| {
            var child_rel_buf: [256]u8 = undefined;
            const child_rel = joinRel(&child_rel_buf, dir_rel, name) catch null;
            if (child_rel) |rel| {
                if (metadataFromRel(rel)) |md| {
                    kind = if (md.is_dir) .directory else .file;
                } else |_| {}
            }
        }

        out[0] = .{ .name = name, .kind = kind, .inode = 0 };
        return 1;
    }

    fn dirClose(userdata: ?*anyopaque, dirs: []const std.Io.Dir) void {
        const state: *PortalIoState = @ptrCast(@alignCast(userdata orelse return));
        for (dirs) |d| {
            const handle: i32 = @intCast(d.handle);
            state.unregisterDir(handle);
            var portal_dir: sdk.fs.Dir = .{ .handle = handle };
            portal_dir.close() catch {};
        }
    }
};

const PortalFs = struct {
    io_state: *PortalIoState = undefined,

    pub fn getIo(self: *PortalFs) std.Io {
        return PortalIo.io(self.io_state);
    }

    pub fn stat(_: *PortalFs, rel: []const u8) !?std.Io.File.Stat {
        const md = metadataFromRel(rel) catch |err| switch (err) {
            sdk.fs.Error.NotFound => return null,
            else => return err,
        };

        const mtime_s = mtimeFromRel(rel) catch 0;
        const ts = std.Io.Timestamp.fromNanoseconds(@as(i96, @intCast(mtime_s)) * std.time.ns_per_s);

        return std.Io.File.Stat{
            .inode = 0,
            .nlink = 1,
            .size = md.size,
            .permissions = if (md.is_dir) std.Io.File.Permissions.default_dir else std.Io.File.Permissions.default_file,
            .kind = if (md.is_dir) .directory else .file,
            .atime = null,
            .mtime = ts,
            .ctime = ts,
            .block_size = 1,
        };
    }

    pub fn openRead(_: *PortalFs, rel: []const u8) !std.Io.File {
        var abs_buf: [256]u8 = undefined;
        const abs = absPathZ(&abs_buf, rel);
        const file = sdk.fs.File.open(abs, sdk.fs.FS_READ) catch |err| return mapFsToIoError(err);
        return .{ .handle = @intCast(file.handle), .flags = .{ .nonblocking = false } };
    }

    pub fn openDirIter(self: *PortalFs, rel: []const u8) !std.Io.Dir {
        var abs_buf: [256]u8 = undefined;
        const abs = absPathZ(&abs_buf, rel);
        var dir = sdk.fs.Dir.open(abs) catch |err| return mapFsToIoError(err);
        errdefer dir.close() catch {};
        try self.io_state.registerDir(dir.handle, rel);
        return .{ .handle = @intCast(dir.handle) };
    }

    pub fn createFile(_: *PortalFs, rel: []const u8, truncate: bool) !std.Io.File {
        var abs_buf: [256]u8 = undefined;
        const abs = absPathZ(&abs_buf, rel);
        var flags: i32 = sdk.fs.FS_WRITE | sdk.fs.FS_CREATE;
        if (truncate) flags |= sdk.fs.FS_TRUNC;
        const file = sdk.fs.File.open(abs, flags) catch |err| return mapFsToIoError(err);
        return .{ .handle = @intCast(file.handle), .flags = .{ .nonblocking = false } };
    }

    pub fn makeDir(_: *PortalFs, rel: []const u8) !void {
        var abs_buf: [256]u8 = undefined;
        const abs = absPathZ(&abs_buf, rel);
        sdk.fs.Dir.mkdir(abs) catch |err| return mapFsToIoError(err);
    }

    pub fn deleteFile(_: *PortalFs, rel: []const u8) !void {
        var abs_buf: [256]u8 = undefined;
        const abs = absPathZ(&abs_buf, rel);
        sdk.fs.remove(abs) catch |err| return mapFsToIoError(err);
    }

    pub fn deleteDir(_: *PortalFs, rel: []const u8) !void {
        if (!isDirEmpty(rel)) return error.DirNotEmpty;
        var abs_buf: [256]u8 = undefined;
        const abs = absPathZ(&abs_buf, rel);
        sdk.fs.Dir.rmdir(abs) catch |err| return mapFsToIoError(err);
    }

    pub fn rename(_: *PortalFs, from: []const u8, to: []const u8) !void {
        // Try portal-native rename first for MOVE efficiency/atomicity.
        // On any failure, request handler fallback (copy+delete).
        var from_abs_buf: [256]u8 = undefined;
        var to_abs_buf: [256]u8 = undefined;
        const from_abs = absPathZ(&from_abs_buf, from);
        const to_abs = absPathZ(&to_abs_buf, to);
        sdk.fs.rename(from_abs, to_abs) catch return error.CrossDevice;
    }
};

const PortalSys = struct {
    pub fn nowUtcSeconds(_: *PortalSys) i64 {
        if (!sdk.rtc.isEnabled()) return 0;
        const dt = sdk.rtc.getDatetime() catch return 0;
        return dateTimeToUnix(dt);
    }
};

fn handleConnection(self: *WebDavService, client: *sdk.socket.Socket) !void {
    const handler = blk: {
        if (self.handler) |*h| break :blk h;
        return;
    };
    var conn = Connection.init(client);

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

        const method_s, const target_s = parseRequestLine(req_line) catch {
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

        var close_after_response = requestWantsClose(req_headers);

        var body = Body.init(&conn, req_headers);
        const body_reader = webdav.BodyReader{ .ctx = &body, .readFn = Body.readFn };

        var res_ctx = ResponseCtx{ .conn = &conn, .close_after_response = close_after_response };
        var res = webdav.ResponseWriter{
            .ctx = &res_ctx,
            .writeHeadFn = ResponseCtx.writeHeadFn,
            .writeAllFn = ResponseCtx.writeAllFn,
            .writeChunkFn = ResponseCtx.writeChunkFn,
            .finishFn = ResponseCtx.finishFn,
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
        drainBody(&body) catch {};

        if (close_after_response) return;
    }
}

const Connection = struct {
    sock: *sdk.socket.Socket,
    buf: [16 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn init(sock: *sdk.socket.Socket) Connection {
        return .{ .sock = sock };
    }

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

    fn readByte(self: *Connection, timeout_ms: i32) !u8 {
        if (self.start == self.end) {
            try self.fill(timeout_ms);
        }
        const b = self.buf[self.start];
        self.start += 1;
        return b;
    }

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

    fn readLineInto(self: *Connection, storage: []u8, used: *usize, timeout_ms: i32) ![]const u8 {
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

    fn readLine(self: *Connection, buf: []u8, timeout_ms: i32) ![]const u8 {
        var used: usize = 0;
        const line = try self.readLineInto(buf, &used, timeout_ms);
        return line;
    }

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

    fn sendBadRequest(self: *Connection) !void {
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

fn parseRequestLine(line: []const u8) !struct { []const u8, []const u8 } {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadRequest;
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse return error.BadRequest;
    return .{ line[0..sp1], line[sp1 + 1 .. sp2] };
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

fn requestWantsClose(headers: []const webdav.Header) bool {
    const v = webdav.types.headerValue(headers, "connection") orelse return false;
    var it = std.mem.tokenizeAny(u8, v, ",");
    while (it.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(t, "close")) return true;
    }
    return false;
}

const Body = struct {
    conn: *Connection,
    mode: Mode,

    const Mode = union(enum) {
        none,
        content_length: u64,
        chunked: Chunked,
    };

    const Chunked = struct {
        remaining_in_chunk: u64 = 0,
        done: bool = false,
    };

    fn init(conn: *Connection, headers: []const webdav.Header) Body {
        if (webdav.types.headerValue(headers, "transfer-encoding")) |te| {
            if (std.mem.indexOf(u8, te, "chunked") != null or std.mem.indexOf(u8, te, "Chunked") != null) {
                return .{ .conn = conn, .mode = .{ .chunked = .{} } };
            }
        }
        if (webdav.types.headerValue(headers, "content-length")) |cl| {
            const len = std.fmt.parseInt(u64, cl, 10) catch 0;
            return .{ .conn = conn, .mode = .{ .content_length = len } };
        }
        return .{ .conn = conn, .mode = .none };
    }

    fn readFn(ctx: *anyopaque, dest: []u8) anyerror!usize {
        const self: *Body = @ptrCast(@alignCast(ctx));
        return self.read(dest);
    }

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

fn drainBody(body: *Body) !void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try body.read(&buf);
        if (n == 0) return;
    }
}

const ResponseCtx = struct {
    conn: *Connection,
    close_after_response: bool = false,
    wrote_head: bool = false,
    chunked: bool = false,
    finished: bool = false,

    fn writeHeadFn(ctx: *anyopaque, status: u16, headers: []const webdav.Header, body_mode: webdav.BodyMode) anyerror!void {
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

    fn writeAllFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ResponseCtx = @ptrCast(@alignCast(ctx));
        if (!self.wrote_head) return error.MissingResponseHead;
        if (self.finished) return error.ResponseFinished;
        if (self.chunked) return writeChunkFn(ctx, bytes);
        try self.conn.sendAll(bytes);
    }

    fn writeChunkFn(ctx: *anyopaque, bytes: []const u8) anyerror!void {
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

    fn finishFn(ctx: *anyopaque) anyerror!void {
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

fn absPathZ(buf: []u8, rel: []const u8) [:0]const u8 {
    std.debug.assert(buf.len >= 2);
    std.debug.assert(rel.len <= 254);
    buf[0] = '/';
    if (rel.len == 0) {
        buf[1] = 0;
        return buf[0..1 :0];
    }
    @memcpy(buf[1 .. 1 + rel.len], rel);
    buf[1 + rel.len] = 0;
    return buf[0 .. 1 + rel.len :0];
}

fn joinRel(buf: []u8, base: []const u8, name: []const u8) ![]const u8 {
    if (base.len == 0) {
        if (name.len > buf.len) return error.PathTooLong;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const need = base.len + 1 + name.len;
    if (need > buf.len) return error.PathTooLong;
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '/';
    @memcpy(buf[base.len + 1 .. need], name);
    return buf[0..need];
}

fn metadataFromRel(rel: []const u8) sdk.fs.Error!sdk.fs.Metadata {
    var abs_buf: [256]u8 = undefined;
    const abs = absPathZ(&abs_buf, rel);
    return sdk.fs.metadata(abs);
}

fn mtimeFromRel(rel: []const u8) sdk.fs.Error!i64 {
    var abs_buf: [256]u8 = undefined;
    const abs = absPathZ(&abs_buf, rel);
    return sdk.fs.mtime(abs);
}

fn isDirEmpty(rel: []const u8) bool {
    var abs_buf: [256]u8 = undefined;
    const abs = absPathZ(&abs_buf, rel);
    var dir = sdk.fs.Dir.open(abs) catch return true;
    defer dir.close() catch {};

    var name_buf: [256]u8 = undefined;
    while (true) {
        const n_opt = dir.readName(&name_buf) catch return true;
        const n = n_opt orelse return true;
        const name = name_buf[0..n];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        return false;
    }
}

fn mapFsToIoError(err: sdk.fs.Error) anyerror {
    return switch (err) {
        sdk.fs.Error.NotFound => error.FileNotFound,
        sdk.fs.Error.InvalidArgument => error.InvalidArgument,
        sdk.fs.Error.NotReady => error.NotReady,
        sdk.fs.Error.Internal => error.InputOutput,
        sdk.fs.Error.Unknown => error.InputOutput,
    };
}

fn dateTimeToUnix(dt: sdk.rtc.DateTime) i64 {
    // Gregorian calendar to Unix timestamp, UTC. (Valid for years >= 1970.)
    const year: i32 = dt.year;
    const month: i32 = dt.month;
    const day: i32 = dt.day;
    const hour: i32 = dt.hour;
    const minute: i32 = dt.minute;
    const second: i32 = dt.second;

    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }

    const era = @divTrunc(y, 400);
    const yoe = y - era * 400;
    const doy = @divTrunc(153 * (m - 3) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days_since_1970: i64 = @intCast(era * 146097 + doe - 719468);
    return days_since_1970 * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}
