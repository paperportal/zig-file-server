const sdk = @import("paper_portal_sdk");

pub const WebDavService = struct {
    running: bool = false,

    pub fn isRunning(self: *const WebDavService) bool {
        return self.running;
    }

    pub fn tick(self: *WebDavService, now_ms: i32) void {
        _ = self;
        _ = now_ms;
    }

    pub fn start(self: *WebDavService) !void {
        if (self.running) return;

        if (!sdk.net.isReady()) {
            try sdk.net.connect();
        }
        if (!sdk.fs.isMounted()) {
            try sdk.fs.mount();
        }

        // TODO: wire up the WebDAV server implementation.

        self.running = true;
        sdk.core.log.info("WebDAV server started");
    }

    pub fn stop(self: *WebDavService) void {
        if (!self.running) return;
        self.running = false;

        // TODO: stop server and release resources

        sdk.core.log.info("WebDAV server stopped");
    }
};
