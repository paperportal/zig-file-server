const std = @import("std");
const sdk = @import("paper_portal_sdk");
const display = sdk.display;
const microtask = sdk.microtask;
const ui = sdk.ui;
const wd = @import("webdav_service.zig");

const Layout = struct {
    title_x: i32,
    title_y: i32,
    status_x: i32,
    status_y: i32,
    start_stop_rect: ui.Rect,
    exit_rect: ui.Rect,
};

const Tap = struct {
    x: i32,
    y: i32,
};

const MainScene = struct {
    webdav: wd.WebDavService = .{},

    pub fn draw(self: *MainScene, ctx: *ui.Context) anyerror!void {
        _ = ctx;
        const layout = computeLayout();

        try display.startWrite();
        try display.fillScreen(display.colors.WHITE);

        try display.text.setDatum(.top_left);
        try display.text.setColor(display.colors.BLACK, display.colors.WHITE);

        try display.text.setSize(3.0, 3.0);
        try display.text.draw("File Server", layout.title_x, layout.title_y);

        try display.text.setSize(1.5, 1.5);
        const status_text = if (self.webdav.isRunning()) "Server is running" else "Server is not running";
        try display.text.draw(status_text, layout.status_x, layout.status_y);

        const start_stop_label = if (self.webdav.isRunning()) "Stop" else "Start";
        try drawButton(layout.start_stop_rect, start_stop_label);
        try drawButton(layout.exit_rect, "Exit");
        try display.endWrite();
    }

    pub fn onGesture(self: *MainScene, ctx: *ui.Context, nav: *ui.Navigator, ev: ui.GestureEvent) anyerror!void {
        _ = ctx;
        _ = nav;
        if (ev.kind == .tap) {
            const changed = self.handleTap(ev.x, ev.y) catch |err| blk: {
                sdk.core.log.ferr("handle tap failed: {s}", .{@errorName(err)});
                break :blk false;
            };
            if (changed) {
                ui.scene.redraw() catch |err| {
                    sdk.core.log.ferr("ui.scene.redraw failed: {s}", .{@errorName(err)});
                };
            }
        }
    }

    fn drawButton(rect: ui.Rect, label: []const u8) display.Error!void {
        try display.fillRect(rect.x, rect.y, rect.w, rect.h, display.colors.WHITE);
        try display.drawRect(rect.x, rect.y, rect.w, rect.h, display.colors.BLACK);

        try display.text.setSize(1.8, 1.8);
        try display.text.setColor(display.colors.BLACK, display.colors.WHITE);
        try display.text.setDatum(.middle_center);
        try display.text.draw(label, rect.x + @divTrunc(rect.w, 2), rect.y + @divTrunc(rect.h, 2));
        try display.text.setDatum(.top_left);
    }

    fn computeLayout() Layout {
        const screen_w = display.width();
        const screen_h = display.height();
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

    fn handleTap(self: *MainScene, x: i32, y: i32) !bool {
        const layout = computeLayout();

        if (layout.start_stop_rect.contains(x, y)) {
            if (self.webdav.isRunning()) {
                self.webdav.stop();
                return true;
            }

            try self.webdav.start();
            return true;
        }

        if (layout.exit_rect.contains(x, y)) {
            self.webdav.stop();
            sdk.core.exitApp() catch |err| {
                sdk.core.log.ferr("exit_app failed: {s}", .{@errorName(err)});
            };
            return false;
        }

        return false;
    }
};

var g_main: MainScene = .{};

const UiLoopTask = struct {
    pub fn step(self: *UiLoopTask, now_ms: u32) anyerror!microtask.Action {
        _ = self;
        const now_ms_i32: i32 = if (now_ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(now_ms);
        g_main.webdav.tick(now_ms_i32);
        return microtask.Action.sleepMs(33);
    }
};

var g_ui_loop_task: UiLoopTask = .{};

pub fn main() void {
    sdk.core.begin() catch |err| {
        sdk.core.log.ferr("main: core.begin failed: {s}", .{@errorName(err)});
        return;
    };

    const runtime_features_raw = sdk.core.apiFeatures();
    const features: u64 = @bitCast(runtime_features_raw);
    sdk.core.log.finfo("main: runtime features=0x{x}", .{features});

    const required = sdk.core.Feature.fs |
        sdk.core.Feature.socket |
        sdk.core.Feature.display_basics |
        sdk.core.Feature.display_text;
    if ((features & required) != required) {
        sdk.core.log.err("main: missing fs/socket/display host features");
        return;
    }

    display.epd.setMode(display.epd.TEXT) catch {};
    display.text.setFont(1) catch {};
    display.text.setWrap(false, false) catch {};

    ui.scene.set(ui.Scene.from(MainScene, &g_main)) catch |err| {
        sdk.core.log.ferr("main: ui.scene.set failed: {s}", .{@errorName(err)});
        ui.scene.deinitStack();
        return;
    };

    _ = microtask.start(microtask.Task.from(UiLoopTask, &g_ui_loop_task), 33, 0) catch |err| {
        sdk.core.log.ferr("main: microtask.start failed: {s}", .{@errorName(err)});
        ui.scene.deinitStack();
        return;
    };

    sdk.core.log.info("main: File Server UI initialized");
    return;
}

pub export fn ppShutdown() i32 {
    g_main.webdav.stop();
    ui.scene.deinitStack();
    return 0;
}
