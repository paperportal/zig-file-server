const std = @import("std");
const sdk = @import("paper_portal_sdk");
const ftp = @import("ftp_server");
const pp_net = @import("pp_net.zig");
const pp_fs = @import("pp_fs.zig");

const allocator = std.heap.wasm_allocator;
const Server = ftp.server.FtpServer(pp_net.PpNet, pp_fs.PpFs);

var g_initialized: bool = false;
var g_net: pp_net.PpNet = .{};
var g_fs: pp_fs.PpFs = .{};
var g_server: ?Server = null;

var g_command_buf: [ftp.limits.command_max]u8 = undefined;
var g_reply_buf: [ftp.limits.reply_max]u8 = undefined;
var g_transfer_buf: [ftp.limits.transfer_max]u8 = undefined;
var g_scratch_buf: [ftp.limits.scratch_max]u8 = undefined;
var g_storage: ftp.misc.Storage = undefined;

pub export fn pp_contract_version() i32 {
    return 1;
}

pub export fn pp_alloc(len: i32) i32 {
    if (len <= 0) return 0;
    const size: usize = @intCast(len);
    const buf = allocator.alloc(u8, size) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

pub export fn pp_free(ptr: i32, len: i32) void {
    if (ptr == 0 or len <= 0) return;
    const size: usize = @intCast(len);
    const addr: usize = @intCast(ptr);
    const buf = @as([*]u8, @ptrFromInt(addr))[0..size];
    allocator.free(buf);
}

pub export fn pp_init(api_version: i32, screen_w: i32, screen_h: i32) i32 {
    _ = api_version;
    _ = screen_w;
    _ = screen_h;

    if (g_initialized) return 0;

    sdk.core.begin() catch |err| {
        sdk.core.log.ferr("pp_init: core.begin failed: {s}", .{@errorName(err)});
        return -1;
    };

    const runtime_features_raw = sdk.core.api_features();
    const features: u64 = @bitCast(runtime_features_raw);
    sdk.core.log.finfo("pp_init: runtime features=0x{x}", .{features});
    if ((features & sdk.core.Feature.fs) == 0 or (features & sdk.core.Feature.socket) == 0) {
        sdk.core.log.err("pp_init: missing fs/socket host features");
        return -1;
    }

    if (!sdk.net.is_ready()) {
        sdk.net.connect() catch |err| {
            sdk.core.log.ferr("pp_init: net.connect failed: {s}", .{@errorName(err)});
            return -1;
        };
    }

    if (!sdk.fs.is_mounted()) {
        sdk.fs.mount() catch |err| {
            sdk.core.log.ferr("pp_init: fs.mount failed: {s}", .{@errorName(err)});
            return -1;
        };
    }

    g_net.init();
    const listener = g_net.controlListen(.{ .ip = .{ 0, 0, 0, 0 }, .port = 21 }) catch |err| {
        sdk.core.log.ferr("pp_init: controlListen failed: {s}", .{@errorName(err)});
        return -1;
    };

    g_storage = ftp.misc.Storage.init(
        g_command_buf[0..],
        g_reply_buf[0..],
        g_transfer_buf[0..],
        g_scratch_buf[0..],
    );
    g_server = Server.initNoHeap(&g_net, &g_fs, listener, .{
        .user = "paper",
        .password = "paper",
        .banner = "Paper Portal FTP Ready",
    }, &g_storage);

    g_initialized = true;
    sdk.core.log.info("pp_init: FTP server initialized on :21");
    return 0;
}

pub export fn pp_tick(now_ms: i32) i32 {
    const server = &(g_server orelse return 0);
    const now_u64: u64 = if (now_ms <= 0) 0 else @intCast(now_ms);
    server.tick(now_u64) catch |err| switch (err) {
        error.WouldBlock => {},
        else => sdk.core.log.ferr("pp_tick: ftp tick failed: {s}", .{@errorName(err)}),
    };
    return 0;
}

pub export fn pp_on_gesture(kind: i32, x: i32, y: i32, dx: i32, dy: i32, duration_ms: i32, now_ms: i32, flags: i32) i32 {
    _ = kind;
    _ = x;
    _ = y;
    _ = dx;
    _ = dy;
    _ = duration_ms;
    _ = now_ms;
    _ = flags;
    return 0;
}
