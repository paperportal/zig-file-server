const sdk = @import("paper_portal_sdk");
const ftp = @import("ftp_server");
const pp_net = @import("pp_net.zig");
const pp_fs = @import("pp_fs.zig");

const Server = ftp.server.FtpServer(pp_net.PpNet, pp_fs.PpFs);

pub const FtpService = struct {
    net: pp_net.PpNet = .{},
    fs: pp_fs.PpFs = .{},
    server: ?Server = null,

    command_buf: [ftp.limits.command_max]u8 = undefined,
    reply_buf: [ftp.limits.reply_max]u8 = undefined,
    transfer_buf: [ftp.limits.transfer_max]u8 = undefined,
    scratch_buf: [ftp.limits.scratch_max]u8 = undefined,
    storage: ftp.misc.Storage = undefined,

    pub fn isRunning(self: *const FtpService) bool {
        return self.server != null;
    }

    pub fn tick(self: *FtpService, now_ms: i32) void {
        if (self.server) |*server| {
            const now_u64: u64 = if (now_ms <= 0) 0 else @intCast(now_ms);
            server.tick(now_u64) catch |err| switch (err) {
                error.WouldBlock => {},
                else => sdk.core.log.ferr("ftp tick failed: {s}", .{@errorName(err)}),
            };
        }
    }

    pub fn start(self: *FtpService) !void {
        if (self.server != null) return;

        if (!sdk.net.isReady()) {
            try sdk.net.connect();
        }

        if (!sdk.fs.isMounted()) {
            try sdk.fs.mount();
        }

        self.net.init();
        const listener = try self.net.controlListen(.{ .ip = .{ 0, 0, 0, 0 }, .port = 21 });

        self.storage = ftp.misc.Storage.init(
            self.command_buf[0..],
            self.reply_buf[0..],
            self.transfer_buf[0..],
            self.scratch_buf[0..],
        );

        self.server = Server.initNoHeap(&self.net, &self.fs, listener, .{
            .user = "paper",
            .password = "paper",
            .banner = "Paper Portal FTP Ready",
        }, &self.storage);

        sdk.core.log.info("FTP server started on :21");
    }

    pub fn stop(self: *FtpService) void {
        if (self.server) |*server| {
            if (server.control_conn) |*conn| {
                self.net.closeConn(conn);
                server.control_conn = null;
            }

            if (server.data_conn) |*conn| {
                self.net.closeConn(conn);
                server.data_conn = null;
            }

            if (server.pasv_listener) |*listener| {
                self.net.closeListener(listener);
                server.pasv_listener = null;
            }

            if (server.list_iter) |*iter| {
                self.fs.dirClose(iter);
                server.list_iter = null;
            }

            if (server.file_reader) |*reader| {
                self.fs.closeRead(reader);
                server.file_reader = null;
            }

            if (server.file_writer) |*writer| {
                self.fs.closeWrite(writer);
                server.file_writer = null;
            }

            self.net.closeControlListener(&server.control_listener);
            self.server = null;
            sdk.core.log.info("FTP server stopped");
        }
    }
};
