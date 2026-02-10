const std = @import("std");
const sdk = @import("paper_portal_sdk");
const display = sdk.display;
const ui = sdk.ui;
const ftp_service = @import("ftp_service.zig");

const allocator = std.heap.wasm_allocator;

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

const MainScene = struct {
    pending_tap: ?Tap = null,
    ftp: ftp_service.FtpService = .{},

    pub fn draw(self: *MainScene, ctx: *ui.Context) anyerror!void {
        const layout = compute_layout(ctx);

        try display.start_write();
        try display.fill_screen(display.colors.WHITE);

        try display.text.set_datum(.top_left);
        try display.text.set_color(display.colors.BLACK, display.colors.WHITE);

        try display.text.set_size(3.0, 3.0);
        try display.text.draw("File Server", layout.title_x, layout.title_y);

        try display.text.set_size(1.5, 1.5);
        const status_text = if (self.ftp.is_running()) "Server is running" else "Server is not running";
        try display.text.draw(status_text, layout.status_x, layout.status_y);

        const start_stop_label = if (self.ftp.is_running()) "Stop" else "Start";
        try draw_button(layout.start_stop_rect, start_stop_label);
        try draw_button(layout.exit_rect, "Exit");
        try display.end_write();
    }

    pub fn onGesture(self: *MainScene, ctx: *ui.Context, nav: *ui.Navigator, ev: ui.GestureEvent) anyerror!void {
        _ = ctx;
        _ = nav;
        if (ev.kind == .tap) {
            self.pending_tap = .{ .x = ev.x, .y = ev.y };
        }
    }

    pub fn tick(self: *MainScene, ctx: *ui.Context, nav: *ui.Navigator, now_ms: i32) anyerror!void {
        if (self.pending_tap) |tap| {
            self.pending_tap = null;
            const changed = try self.handle_tap(ctx, tap.x, tap.y);
            if (changed) {
                try nav.redraw();
            }
        }

        self.ftp.tick(now_ms);
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

    fn compute_layout(ctx: *const ui.Context) Layout {
        const screen_w = resolve_screen_width(ctx);
        const screen_h = resolve_screen_height(ctx);
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

    fn resolve_screen_width(ctx: *const ui.Context) i32 {
        if (ctx.screen_w > 0) return ctx.screen_w;
        const w = display.width();
        return if (w > 0) w else 320;
    }

    fn resolve_screen_height(ctx: *const ui.Context) i32 {
        if (ctx.screen_h > 0) return ctx.screen_h;
        const h = display.height();
        return if (h > 0) h else 240;
    }

    fn handle_tap(self: *MainScene, ctx: *const ui.Context, x: i32, y: i32) !bool {
        const layout = compute_layout(ctx);

        if (layout.start_stop_rect.contains(x, y)) {
            if (self.ftp.is_running()) {
                self.ftp.stop();
                return true;
            }

            try self.ftp.start();
            return true;
        }

        if (layout.exit_rect.contains(x, y)) {
            self.ftp.stop();
            sdk.core.exit_app() catch |err| {
                sdk.core.log.ferr("exit_app failed: {s}", .{@errorName(err)});
            };
            return false;
        }

        return false;
    }
};

var g_stack: ui.SceneStack = undefined;
var g_main: MainScene = .{};

pub export fn pp_init(api_version: i32, screen_w: i32, screen_h: i32, args_ptr: i32, args_len: i32) i32 {
    _ = api_version;
    _ = args_ptr;
    _ = args_len;

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

    display.epd.set_mode(display.epd.TEXT) catch {};
    display.text.set_font(1) catch {};
    display.text.set_wrap(false, false) catch {};

    g_stack = ui.SceneStack.init(allocator, screen_w, screen_h, 4);
    g_stack.setInitial(ui.Scene.from(MainScene, &g_main)) catch |err| {
        sdk.core.log.ferr("pp_init: setInitial failed: {s}", .{@errorName(err)});
        g_stack.deinit();
        return -1;
    };

    sdk.core.log.info("pp_init: File Server UI initialized");
    return 0;
}

pub export fn pp_tick(now_ms: i32) i32 {
    g_stack.tick(now_ms) catch |err| {
        sdk.core.log.ferr("pp_tick: ui tick failed: {s}", .{@errorName(err)});
    };

    return 0;
}

pub export fn pp_on_gesture(kind: i32, x: i32, y: i32, dx: i32, dy: i32, duration_ms: i32, now_ms: i32, flags: i32) i32 {
    g_stack.handleGestureFromArgs(kind, x, y, dx, dy, duration_ms, now_ms, flags) catch |err| {
        sdk.core.log.ferr("pp_on_gesture: handleGesture failed: {s}", .{@errorName(err)});
    };

    return 0;
}

pub export fn pp_shutdown() i32 {
    g_main.ftp.stop();
    g_stack.deinit();
    return 0;
}
