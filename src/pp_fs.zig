const std = @import("std");
const sdk = @import("paper_portal_sdk");
const ftp = @import("ftp_server");
const interfaces_fs = ftp.interfaces_fs;

const root_path = "/sdcard";
const cwd_path_max: usize = ftp.limits.path_max;
const host_path_max: usize = root_path.len + ftp.limits.path_max + 2;
const dir_name_max: usize = 255;

pub const PpFs = struct {
    pub const Cwd = struct {
        path: [cwd_path_max]u8 = [_]u8{0} ** cwd_path_max,
        len: usize = 1,
    };

    pub const FileReader = struct {
        file: sdk.fs.File,
    };

    pub const FileWriter = struct {
        file: sdk.fs.File,
    };

    pub const DirIter = struct {
        dir: sdk.fs.Dir,
        base_host: [host_path_max]u8 = [_]u8{0} ** host_path_max,
        base_host_len: usize = 0,
        name_buf: [dir_name_max + 1]u8 = [_]u8{0} ** (dir_name_max + 1),
        child_path_buf: [host_path_max]u8 = [_]u8{0} ** host_path_max,
    };

    pub fn cwdInit(_: *PpFs) interfaces_fs.FsError!Cwd {
        var cwd: Cwd = .{};
        cwd.path[0] = '/';
        cwd.len = 1;
        return cwd;
    }

    pub fn cwdPwd(_: *PpFs, cwd: *const Cwd, out: []u8) interfaces_fs.FsError![]const u8 {
        if (out.len < cwd.len) return error.InvalidPath;
        std.mem.copyForwards(u8, out[0..cwd.len], cwd.path[0..cwd.len]);
        return out[0..cwd.len];
    }

    pub fn cwdChange(self: *PpFs, cwd: *Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        _ = self;
        var next_ftp: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, next_ftp[0..]);

        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        const meta = sdk.fs.metadata(host_path) catch |err| return map_fs_error(err);
        if (!meta.is_dir) return error.NotDir;

        std.mem.copyForwards(u8, cwd.path[0..ftp_path.len], ftp_path);
        cwd.len = ftp_path.len;
    }

    pub fn cwdUp(self: *PpFs, cwd: *Cwd) interfaces_fs.FsError!void {
        try self.cwdChange(cwd, "..");
    }

    pub fn dirOpen(self: *PpFs, cwd: *const Cwd, path: ?[]const u8) interfaces_fs.FsError!DirIter {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = if (path) |p|
            try normalize_ftp_path(cwd, p, ftp_buf[0..])
        else blk: {
            if (cwd.len > ftp_buf.len) return error.InvalidPath;
            std.mem.copyForwards(u8, ftp_buf[0..cwd.len], cwd.path[0..cwd.len]);
            break :blk ftp_buf[0..cwd.len];
        };

        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        const dir = sdk.fs.Dir.open(host_path) catch |err| return map_fs_error(err);

        var iter: DirIter = .{
            .dir = dir,
        };
        std.mem.copyForwards(u8, iter.base_host[0..host_path.len], host_path);
        iter.base_host_len = host_path.len;
        return iter;
    }

    pub fn dirNext(self: *PpFs, iter: *DirIter) interfaces_fs.FsError!?interfaces_fs.DirEntry {
        _ = self;
        while (true) {
            const maybe_name_len = iter.dir.read_name(iter.name_buf[0..]) catch |err| return map_fs_error(err);
            if (maybe_name_len == null) return null;

            const name_len = maybe_name_len.?;
            if (name_len == 0) continue;
            const name = iter.name_buf[0..name_len];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const child_path = try join_child_path(iter.base_host[0..iter.base_host_len], name, iter.child_path_buf[0..]);
            const meta = sdk.fs.metadata(child_path) catch |err| return map_fs_error(err);
            const kind: interfaces_fs.PathKind = if (meta.is_dir) .dir else .file;

            return .{
                .name = name,
                .kind = kind,
                .size = if (meta.is_dir) null else meta.size,
                .mtime_unix = null,
            };
        }
    }

    pub fn dirClose(self: *PpFs, iter: *DirIter) void {
        _ = self;
        iter.dir.close() catch {};
    }

    pub fn openRead(self: *PpFs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!FileReader {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, ftp_buf[0..]);

        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        const meta = sdk.fs.metadata(host_path) catch |err| return map_fs_error(err);
        if (meta.is_dir) return error.IsDir;

        const file = sdk.fs.File.open(host_path, sdk.fs.FS_READ) catch |err| return map_fs_error(err);
        return .{ .file = file };
    }

    pub fn openWriteTrunc(self: *PpFs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!FileWriter {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, ftp_buf[0..]);

        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        const file = sdk.fs.File.open(host_path, sdk.fs.FS_WRITE | sdk.fs.FS_CREATE | sdk.fs.FS_TRUNC) catch |err| return map_fs_error(err);
        return .{ .file = file };
    }

    pub fn readFile(self: *PpFs, reader: *FileReader, out: []u8) interfaces_fs.FsError!usize {
        _ = self;
        return reader.file.read(out) catch |err| map_fs_error(err);
    }

    pub fn writeFile(self: *PpFs, writer: *FileWriter, src: []const u8) interfaces_fs.FsError!usize {
        _ = self;
        return writer.file.write(src) catch |err| map_fs_error(err);
    }

    pub fn closeRead(self: *PpFs, reader: *FileReader) void {
        _ = self;
        reader.file.close() catch {};
    }

    pub fn closeWrite(self: *PpFs, writer: *FileWriter) void {
        _ = self;
        writer.file.close() catch {};
    }

    pub fn delete(self: *PpFs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, ftp_buf[0..]);
        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        sdk.fs.remove(host_path) catch |err| return map_fs_error(err);
    }

    pub fn rename(self: *PpFs, cwd: *const Cwd, from_path: []const u8, to_path: []const u8) interfaces_fs.FsError!void {
        _ = self;
        var from_ftp_buf: [cwd_path_max]u8 = undefined;
        var to_ftp_buf: [cwd_path_max]u8 = undefined;
        const from_ftp = try normalize_ftp_path(cwd, from_path, from_ftp_buf[0..]);
        const to_ftp = try normalize_ftp_path(cwd, to_path, to_ftp_buf[0..]);

        var from_host_buf: [host_path_max]u8 = undefined;
        var to_host_buf: [host_path_max]u8 = undefined;
        const from_host = try host_path_from_ftp(from_ftp, from_host_buf[0..]);
        const to_host = try host_path_from_ftp(to_ftp, to_host_buf[0..]);
        sdk.fs.rename(from_host, to_host) catch |err| return map_fs_error(err);
    }

    pub fn makeDir(self: *PpFs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, ftp_buf[0..]);
        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        sdk.fs.Dir.mkdir(host_path) catch |err| return map_fs_error(err);
    }

    pub fn removeDir(self: *PpFs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, ftp_buf[0..]);
        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        sdk.fs.Dir.rmdir(host_path) catch |err| return map_fs_error(err);
    }

    pub fn fileSize(self: *PpFs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!u64 {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, ftp_buf[0..]);
        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        const meta = sdk.fs.metadata(host_path) catch |err| return map_fs_error(err);
        if (meta.is_dir) return error.IsDir;
        return meta.size;
    }

    pub fn fileMtime(self: *PpFs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!i64 {
        _ = self;
        var ftp_buf: [cwd_path_max]u8 = undefined;
        const ftp_path = try normalize_ftp_path(cwd, user_path, ftp_buf[0..]);
        var host_buf: [host_path_max]u8 = undefined;
        const host_path = try host_path_from_ftp(ftp_path, host_buf[0..]);
        return sdk.fs.mtime(host_path) catch |err| map_fs_error(err);
    }
};

fn normalize_ftp_path(cwd: *const PpFs.Cwd, user_path: []const u8, out: []u8) interfaces_fs.FsError![]const u8 {
    if (user_path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, user_path, 0) != null) return error.InvalidPath;

    var next_len: usize = 0;
    if (user_path[0] == '/') {
        out[0] = '/';
        next_len = 1;
    } else {
        if (cwd.len > out.len) return error.InvalidPath;
        std.mem.copyForwards(u8, out[0..cwd.len], cwd.path[0..cwd.len]);
        next_len = cwd.len;
    }

    var i: usize = 0;
    while (i < user_path.len) {
        while (i < user_path.len and user_path[i] == '/') : (i += 1) {}
        if (i >= user_path.len) break;

        const start = i;
        while (i < user_path.len and user_path[i] != '/') : (i += 1) {}
        const segment = user_path[start..i];
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;

        if (std.mem.eql(u8, segment, "..")) {
            if (next_len > 1) {
                var back = next_len - 1;
                while (back > 0 and out[back] != '/') : (back -= 1) {}
                next_len = if (back == 0) 1 else back;
            }
            continue;
        }

        if (next_len == 1 and out[0] == '/') {
            if (next_len + segment.len > out.len) return error.InvalidPath;
            std.mem.copyForwards(u8, out[next_len .. next_len + segment.len], segment);
            next_len += segment.len;
        } else {
            if (next_len + 1 + segment.len > out.len) return error.InvalidPath;
            out[next_len] = '/';
            next_len += 1;
            std.mem.copyForwards(u8, out[next_len .. next_len + segment.len], segment);
            next_len += segment.len;
        }
    }

    if (next_len == 0) {
        out[0] = '/';
        next_len = 1;
    }
    return out[0..next_len];
}

fn host_path_from_ftp(ftp_path: []const u8, out: []u8) interfaces_fs.FsError![:0]const u8 {
    if (ftp_path.len == 0 or ftp_path[0] != '/') return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, ftp_path, 0) != null) return error.InvalidPath;

    if (ftp_path.len == 1) {
        if (root_path.len + 1 > out.len) return error.InvalidPath;
        std.mem.copyForwards(u8, out[0..root_path.len], root_path);
        out[root_path.len] = 0;
        return out[0..root_path.len :0];
    }

    const total_len = root_path.len + ftp_path.len;
    if (total_len + 1 > out.len) return error.InvalidPath;
    std.mem.copyForwards(u8, out[0..root_path.len], root_path);
    std.mem.copyForwards(u8, out[root_path.len..total_len], ftp_path);
    out[total_len] = 0;
    return out[0..total_len :0];
}

fn join_child_path(base: []const u8, name: []const u8, out: []u8) interfaces_fs.FsError![:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidPath;
    const need_slash = base.len == 0 or base[base.len - 1] != '/';
    const total_len = base.len + (if (need_slash) @as(usize, 1) else 0) + name.len;
    if (total_len + 1 > out.len) return error.InvalidPath;
    std.mem.copyForwards(u8, out[0..base.len], base);
    var idx = base.len;
    if (need_slash) {
        out[idx] = '/';
        idx += 1;
    }
    std.mem.copyForwards(u8, out[idx .. idx + name.len], name);
    idx += name.len;
    out[idx] = 0;
    return out[0..idx :0];
}

fn map_fs_error(err: sdk.errors.Error) interfaces_fs.FsError {
    return switch (err) {
        error.InvalidArgument => error.InvalidPath,
        error.NotFound => error.NotFound,
        error.NotReady => error.Io,
        error.Internal, error.Unknown => error.Io,
    };
}

test "normalize_ftp_path clamps parent traversal at root" {
    var cwd: PpFs.Cwd = .{};
    cwd.path[0] = '/';
    cwd.path[1] = 'a';
    cwd.path[2] = '/';
    cwd.path[3] = 'b';
    cwd.len = 4;

    var out: [cwd_path_max]u8 = undefined;
    const path = try normalize_ftp_path(&cwd, "../../../etc", out[0..]);
    try std.testing.expectEqualStrings("/etc", path);
}

test "normalize_ftp_path rejects nul bytes" {
    var fs: PpFs = .{};
    var cwd = try PpFs.cwdInit(&fs);
    var out: [cwd_path_max]u8 = undefined;
    const bad = [_]u8{ 'a', 0, 'b' };
    try std.testing.expectError(error.InvalidPath, normalize_ftp_path(&cwd, bad[0..], out[0..]));
}

test "host_path_from_ftp maps root to /sdcard" {
    var out: [host_path_max]u8 = undefined;
    const host = try host_path_from_ftp("/", out[0..]);
    try std.testing.expectEqualStrings("/sdcard", host);
}

test "map_fs_error maps sdk errors" {
    try std.testing.expectEqual(error.InvalidPath, map_fs_error(error.InvalidArgument));
    try std.testing.expectEqual(error.NotFound, map_fs_error(error.NotFound));
    try std.testing.expectEqual(error.Io, map_fs_error(error.NotReady));
}

test "fileMtime path normalization works" {
    var fs: PpFs = .{};
    var cwd = try PpFs.cwdInit(&fs);
    cwd.path[0] = '/';
    cwd.path[1] = 'd';
    cwd.path[2] = 'i';
    cwd.path[3] = 'r';
    cwd.len = 4;

    var ftp_buf: [cwd_path_max]u8 = undefined;
    const ftp_path = try normalize_ftp_path(&cwd, "../settings.bin", ftp_buf[0..]);
    try std.testing.expectEqualStrings("/settings.bin", ftp_path);
}
