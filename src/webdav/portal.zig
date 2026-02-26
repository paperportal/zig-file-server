const std = @import("std");
const sdk = @import("paper_portal_sdk");

pub const PortalIoState = struct {
    allocator: std.mem.Allocator = std.heap.wasm_allocator,
    dir_rel_paths: std.AutoHashMapUnmanaged(i32, []u8) = .{},

    pub fn deinit(self: *PortalIoState) void {
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

pub const PortalIo = struct {
    var initialized: bool = false;
    var vtable: std.Io.VTable = undefined;

    pub fn ensureInitialized() void {
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

pub const PortalFs = struct {
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

pub const PortalSys = struct {
    pub fn nowUtcSeconds(_: *PortalSys) i64 {
        if (!sdk.rtc.isEnabled()) return 0;
        const dt = sdk.rtc.getDatetime() catch return 0;
        return dateTimeToUnix(dt);
    }
};

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
