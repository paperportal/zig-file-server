const std = @import("std");
const sdk = @import("paper_portal_sdk");
const ftp = @import("ftp_server");
const pp_net = @import("pp_net.zig");
const pp_fs = @import("pp_fs.zig");

const allocator = std.heap.wasm_allocator;
const display = sdk.display;
const Server = ftp.server.FtpServer(pp_net.PpNet, pp_fs.PpFs);

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
};

const Layout = struct {
    title_x: i32,
    title_y: i32,
    status_x: i32,
    status_y: i32,
    start_stop_rect: Rect,
    exit_rect: Rect,
};

const Tap = struct {
    x: i32,
    y: i32,
};

var g_initialized: bool = false;
var g_needs_redraw: bool = false;
var g_pending_tap: ?Tap = null;
var g_screen_w: i32 = 0;
var g_screen_h: i32 = 0;
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

    if (g_initialized) return 0;

    sdk.core.begin() catch |err| {
        sdk.core.log.ferr("pp_init: core.begin failed: {s}", .{@errorName(err)});
        return -1;
    };

    const runtime_features_raw = sdk.core.api_features();
    const features: u64 = @bitCast(runtime_features_raw);
    sdk.core.log.finfo("pp_init: runtime features=0x{x}", .{features});

    const required = sdk.core.Feature.fs |
        sdk.core.Feature.socket |
        sdk.core.Feature.display_basics |
        sdk.core.Feature.display_text;
    if ((features & required) != required) {
        sdk.core.log.err("pp_init: missing fs/socket/display host features");
        return -1;
    }

    g_screen_w = if (screen_w > 0) screen_w else 0;
    g_screen_h = if (screen_h > 0) screen_h else 0;

    display.epd.set_mode(display.epd.TEXT) catch {};
    display.text.set_font(1) catch {};
    display.text.set_wrap(false, false) catch {};

    g_initialized = true;
    g_needs_redraw = true;
    sdk.core.log.info("pp_init: File Server UI initialized");
    return 0;
}

pub export fn pp_tick(now_ms: i32) i32 {
    if (!g_initialized) return 0;

    if (g_pending_tap) |tap| {
        g_pending_tap = null;
        handle_tap(tap.x, tap.y);
    }

    if (g_server) |*server| {
        const now_u64: u64 = if (now_ms <= 0) 0 else @intCast(now_ms);
        server.tick(now_u64) catch |err| switch (err) {
            error.WouldBlock => {},
            else => sdk.core.log.ferr("pp_tick: ftp tick failed: {s}", .{@errorName(err)}),
        };
    }

    if (g_needs_redraw) {
        g_needs_redraw = false;
        render_ui() catch |err| {
            sdk.core.log.ferr("pp_tick: render failed: {s}", .{@errorName(err)});
        };
    }

    return 0;
}

pub export fn pp_on_gesture(kind: i32, x: i32, y: i32, dx: i32, dy: i32, duration_ms: i32, now_ms: i32, flags: i32) i32 {
    _ = dx;
    _ = dy;
    _ = duration_ms;
    _ = now_ms;
    _ = flags;

    if (kind == 1) {
        g_pending_tap = .{ .x = x, .y = y };
    }

    return 0;
}

fn render_ui() display.Error!void {
    const layout = compute_layout();

    try display.fill_screen(display.colors.WHITE);

    try display.text.set_datum(.top_left);
    try display.text.set_color(display.colors.BLACK, display.colors.WHITE);

    try display.text.set_size(3.0, 3.0);
    try display.text.draw("File Server", layout.title_x, layout.title_y);

    try display.text.set_size(1.5, 1.5);
    const status_text = if (is_running()) "Server is running" else "Server is not running";
    try display.text.draw(status_text, layout.status_x, layout.status_y);

    const start_stop_label = if (is_running()) "Stop" else "Start";
    try draw_button(layout.start_stop_rect, start_stop_label);
    try draw_button(layout.exit_rect, "Exit");

    try display.update();
    display.wait_update();
}

fn draw_button(rect: Rect, label: []const u8) display.Error!void {
    try display.fill_rect(rect.x, rect.y, rect.w, rect.h, display.colors.WHITE);
    try display.draw_rect(rect.x, rect.y, rect.w, rect.h, display.colors.BLACK);

    try display.text.set_size(1.8, 1.8);
    try display.text.set_color(display.colors.BLACK, display.colors.WHITE);
    try display.text.set_datum(.middle_center);
    try display.text.draw(label, rect.x + @divTrunc(rect.w, 2), rect.y + @divTrunc(rect.h, 2));
    try display.text.set_datum(.top_left);
}

fn compute_layout() Layout {
    const screen_w = resolve_screen_width();
    const screen_h = resolve_screen_height();
    const margin: i32 = 16;
    const gap: i32 = 18;
    const button_h: i32 = 56;
    const max_button_w: i32 = 220;

    var button_w = screen_w - (margin * 2);
    if (button_w > max_button_w) button_w = max_button_w;
    if (button_w < 120) button_w = 120;

    const column_x = @divTrunc(screen_w - button_w, 2);
    const title_x = column_x;
    const title_y: i32 = 14;
    const status_x = column_x;
    const status_y = title_y + 62;

    var start_y = status_y + 24;
    const exit_y = start_y + button_h + gap;
    const bottom_limit = screen_h - margin;
    if (exit_y + button_h > bottom_limit) {
        start_y = bottom_limit - (button_h * 2) - gap;
    }

    return .{
        .title_x = title_x,
        .title_y = title_y,
        .status_x = status_x,
        .status_y = status_y,
        .start_stop_rect = .{ .x = column_x, .y = start_y, .w = button_w, .h = button_h },
        .exit_rect = .{ .x = column_x, .y = exit_y, .w = button_w, .h = button_h },
    };
}

fn resolve_screen_width() i32 {
    if (g_screen_w > 0) return g_screen_w;
    const w = display.width();
    return if (w > 0) w else 320;
}

fn resolve_screen_height() i32 {
    if (g_screen_h > 0) return g_screen_h;
    const h = display.height();
    return if (h > 0) h else 240;
}

fn is_running() bool {
    return g_server != null;
}

fn handle_tap(x: i32, y: i32) void {
    const layout = compute_layout();

    if (layout.start_stop_rect.contains(x, y)) {
        if (is_running()) {
            stop_server();
            g_needs_redraw = true;
            return;
        }

        start_server() catch |err| {
            sdk.core.log.ferr("start_server failed: {s}", .{@errorName(err)});
        };
        g_needs_redraw = true;
        return;
    }

    if (layout.exit_rect.contains(x, y)) {
        stop_server();
        sdk.core.exit_app() catch |err| {
            sdk.core.log.ferr("exit_app failed: {s}", .{@errorName(err)});
        };
        return;
    }
}

fn start_server() !void {
    if (g_server != null) return;

    if (!sdk.net.is_ready()) {
        try sdk.net.connect();
    }

    if (!sdk.fs.is_mounted()) {
        try sdk.fs.mount();
    }

    g_net.init();
    const listener = try g_net.controlListen(.{ .ip = .{ 0, 0, 0, 0 }, .port = 21 });

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

    sdk.core.log.info("FTP server started on :21");
}

fn stop_server() void {
    if (g_server) |*server| {
        if (server.control_conn) |*conn| {
            g_net.closeConn(conn);
            server.control_conn = null;
        }

        if (server.data_conn) |*conn| {
            g_net.closeConn(conn);
            server.data_conn = null;
        }

        if (server.pasv_listener) |*listener| {
            g_net.closeListener(listener);
            server.pasv_listener = null;
        }

        if (server.list_iter) |*iter| {
            g_fs.dirClose(iter);
            server.list_iter = null;
        }

        if (server.file_reader) |*reader| {
            g_fs.closeRead(reader);
            server.file_reader = null;
        }

        if (server.file_writer) |*writer| {
            g_fs.closeWrite(writer);
            server.file_writer = null;
        }

        g_net.closeControlListener(&server.control_listener);
        g_server = null;
        sdk.core.log.info("FTP server stopped");
    }
}
