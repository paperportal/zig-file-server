const std = @import("std");
const sdk = @import("paper_portal_sdk");
const ftp = @import("ftp_server");
const interfaces_net = ftp.interfaces_net;

pub const PpNet = struct {
    const Self = @This();

    pub const Address = struct {
        ip: [4]u8 = .{ 0, 0, 0, 0 },
        port: u16 = 0,
    };

    pub const ControlListener = struct {
        socket: sdk.socket.Socket,
        local: Address,
    };

    pub const PasvListener = struct {
        socket: sdk.socket.Socket,
        local: Address,
    };

    pub const ConnKind = enum {
        control,
        data,
    };

    pub const Conn = struct {
        socket: sdk.socket.Socket,
        kind: ConnKind,
        peer: Address,
    };

    pasv_port_min: u16 = 50000,
    pasv_port_max: u16 = 50100,
    next_pasv_port: u16 = 50000,
    cached_ip: [4]u8 = .{ 0, 0, 0, 0 },

    pub fn init(self: *Self) void {
        if (self.next_pasv_port < self.pasv_port_min or self.next_pasv_port > self.pasv_port_max) {
            self.next_pasv_port = self.pasv_port_min;
        }
        self.cached_ip = sdk.net.getIpv4() catch self.cached_ip;
    }

    pub fn controlListen(self: *Self, address: Address) interfaces_net.NetError!ControlListener {
        _ = self;
        var socket = sdk.socket.Socket.tcp() catch |err| return mapSocketError(err);
        errdefer socket.close() catch {};
        try bindAndListen(&socket, address);
        return .{ .socket = socket, .local = address };
    }

    pub fn acceptControl(self: *Self, listener: *ControlListener) interfaces_net.NetError!?Conn {
        _ = self;
        const accepted = listener.socket.acceptWithTimeout(0) catch |err| switch (err) {
            error.NotReady => return null,
            else => return mapSocketError(err),
        };
        const conn: Conn = .{
            .socket = accepted.socket,
            .kind = .control,
            .peer = socketAddrToAddress(accepted.addr),
        };
        logConnEvent("connected", &conn);
        return conn;
    }

    pub fn pasvListen(self: *Self, hint: interfaces_net.PasvBindHint(Address)) interfaces_net.NetError!PasvListener {
        var bind_ip: [4]u8 = .{ 0, 0, 0, 0 };
        if (hint.control_local) |control_addr| {
            bind_ip = control_addr.ip;
        }

        const attempts: usize = @as(usize, self.pasv_port_max) - @as(usize, self.pasv_port_min) + 1;
        var tries: usize = 0;
        while (tries < attempts) : (tries += 1) {
            const port = self.claimPasvPort();
            var socket = sdk.socket.Socket.tcp() catch |err| return mapSocketError(err);
            errdefer socket.close() catch {};
            bindAndListen(&socket, .{ .ip = bind_ip, .port = port }) catch continue;

            return .{
                .socket = socket,
                .local = .{
                    .ip = self.currentIp(bind_ip),
                    .port = port,
                },
            };
        }

        return error.AddrUnavailable;
    }

    pub fn pasvLocalAddr(self: *Self, listener: *PasvListener) interfaces_net.NetError!Address {
        _ = self;
        return listener.local;
    }

    pub fn formatPasvAddress(address: *const Address, out: []u8) interfaces_net.NetError![]const u8 {
        const p1: u16 = address.port / 256;
        const p2: u16 = address.port % 256;
        return std.fmt.bufPrint(out, "{d},{d},{d},{d},{d},{d}", .{
            address.ip[0],
            address.ip[1],
            address.ip[2],
            address.ip[3],
            p1,
            p2,
        }) catch error.Io;
    }

    pub fn acceptData(self: *Self, listener: *PasvListener) interfaces_net.NetError!?Conn {
        _ = self;
        const accepted = listener.socket.acceptWithTimeout(0) catch |err| switch (err) {
            error.NotReady => return null,
            else => return mapSocketError(err),
        };
        const conn: Conn = .{
            .socket = accepted.socket,
            .kind = .data,
            .peer = socketAddrToAddress(accepted.addr),
        };
        logConnEvent("connected", &conn);
        return conn;
    }

    pub fn read(self: *Self, conn: *Conn, out: []u8) interfaces_net.NetError!usize {
        _ = self;
        const n = conn.socket.recv(out, 0) catch |err| switch (err) {
            error.NotReady => return error.WouldBlock,
            else => return mapSocketError(err),
        };
        if (n == 0) return error.Closed;
        maybeLogFtpPayload("recv", out[0..n]);
        return n;
    }

    pub fn write(self: *Self, conn: *Conn, data: []const u8) interfaces_net.NetError!usize {
        _ = self;
        const n = conn.socket.send(data, 0) catch |err| switch (err) {
            error.NotReady => return error.WouldBlock,
            else => return mapSocketError(err),
        };
        if (n == 0) return error.Closed;
        maybeLogFtpPayload("send", data[0..n]);
        return n;
    }

    pub fn closeConn(self: *Self, conn: *Conn) void {
        _ = self;
        logConnEvent("disconnected", conn);
        conn.socket.close() catch {};
    }

    pub fn closeListener(self: *Self, listener: *PasvListener) void {
        _ = self;
        listener.socket.close() catch {};
    }

    pub fn closeControlListener(self: *Self, listener: *ControlListener) void {
        _ = self;
        listener.socket.close() catch {};
    }

    fn claimPasvPort(self: *Self) u16 {
        const port = self.next_pasv_port;
        self.next_pasv_port = if (self.next_pasv_port >= self.pasv_port_max)
            self.pasv_port_min
        else
            self.next_pasv_port + 1;
        return port;
    }

    fn currentIp(self: *Self, fallback: [4]u8) [4]u8 {
        const ip = sdk.net.getIpv4() catch return if (isZeroIp(self.cached_ip)) fallback else self.cached_ip;
        self.cached_ip = ip;
        return ip;
    }
};

fn bindAndListen(socket: *sdk.socket.Socket, address: PpNet.Address) interfaces_net.NetError!void {
    socket.bind(.ipv4(address.ip, address.port)) catch |err| return mapSocketError(err);
    socket.listen(1) catch |err| return mapSocketError(err);
}

fn mapSocketError(err: sdk.errors.Error) interfaces_net.NetError {
    return switch (err) {
        error.NotReady => error.WouldBlock,
        error.NotFound => error.Closed,
        error.InvalidArgument, error.Internal, error.Unknown => error.Io,
    };
}

fn isZeroIp(ip: [4]u8) bool {
    return ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0;
}

fn socketAddrToAddress(addr: sdk.socket.SocketAddr) PpNet.Address {
    return .{
        .ip = addr.ip,
        .port = addr.port,
    };
}

fn connKindLabel(kind: PpNet.ConnKind) []const u8 {
    return switch (kind) {
        .control => "control",
        .data => "data",
    };
}

fn logConnEvent(event: []const u8, conn: *const PpNet.Conn) void {
    sdk.core.log.finfo("ftp client {s} ({s}) {d}.{d}.{d}.{d}:{d}", .{
        event,
        connKindLabel(conn.kind),
        conn.peer.ip[0],
        conn.peer.ip[1],
        conn.peer.ip[2],
        conn.peer.ip[3],
        conn.peer.port,
    });
}

fn maybeLogFtpPayload(direction: []const u8, payload: []const u8) void {
    // Keep logs focused on FTP control frames; skip likely data-transfer chunks.
    if (!looksLikeControlPayload(payload)) return;

    var escaped_buf: [220]u8 = undefined;
    const escaped = escapePayload(payload, escaped_buf[0..]);
    sdk.core.log.finfo("ftp {s} {d}B: \"{s}\"", .{ direction, payload.len, escaped });
}

fn looksLikeControlPayload(payload: []const u8) bool {
    if (payload.len == 0) return false;
    if (payload.len > 200) return false;
    if (std.mem.indexOfAny(u8, payload, "\r\n") == null) return false;

    for (payload) |b| {
        if (b == '\r' or b == '\n' or b == '\t') continue;
        if (b >= 0x20 and b <= 0x7e) continue;
        return false;
    }
    return true;
}

fn escapePayload(payload: []const u8, out: []u8) []const u8 {
    var j: usize = 0;
    var truncated = false;

    for (payload) |b| {
        const replacement: ?[]const u8 = switch (b) {
            '\r' => "\\r",
            '\n' => "\\n",
            '\t' => "\\t",
            '\\' => "\\\\",
            '"' => "\\\"",
            else => null,
        };

        if (replacement) |r| {
            if (j + r.len > out.len) {
                truncated = true;
                break;
            }
            std.mem.copyForwards(u8, out[j .. j + r.len], r);
            j += r.len;
            continue;
        }

        if (j + 1 > out.len) {
            truncated = true;
            break;
        }
        out[j] = b;
        j += 1;
    }

    if (truncated and j + 3 <= out.len) {
        out[j] = '.';
        out[j + 1] = '.';
        out[j + 2] = '.';
        j += 3;
    }

    return out[0..j];
}

test "formatPasvAddress writes RFC tuple" {
    var out: [32]u8 = undefined;
    const tuple = try PpNet.formatPasvAddress(&.{ .ip = .{ 192, 168, 4, 2 }, .port = 21 }, out[0..]);
    try std.testing.expectEqualStrings("192,168,4,2,0,21", tuple);
}

test "map_socket_error maps NotReady to WouldBlock" {
    try std.testing.expectEqual(error.WouldBlock, mapSocketError(error.NotReady));
    try std.testing.expectEqual(error.Io, mapSocketError(error.Internal));
    try std.testing.expectEqual(error.Closed, mapSocketError(error.NotFound));
}

test "claim_pasv_port wraps at upper bound" {
    var net: PpNet = .{
        .pasv_port_min = 50000,
        .pasv_port_max = 50001,
        .next_pasv_port = 50001,
    };
    try std.testing.expectEqual(@as(u16, 50001), net.claimPasvPort());
    try std.testing.expectEqual(@as(u16, 50000), net.claimPasvPort());
}

test "socket_addr_to_address keeps peer endpoint" {
    const addr = socketAddrToAddress(.ipv4(.{ 10, 20, 30, 40 }, 2121));
    try std.testing.expectEqual(@as(u8, 10), addr.ip[0]);
    try std.testing.expectEqual(@as(u8, 20), addr.ip[1]);
    try std.testing.expectEqual(@as(u8, 30), addr.ip[2]);
    try std.testing.expectEqual(@as(u8, 40), addr.ip[3]);
    try std.testing.expectEqual(@as(u16, 2121), addr.port);
}

test "conn_kind_label returns expected values" {
    try std.testing.expectEqualStrings("control", connKindLabel(.control));
    try std.testing.expectEqualStrings("data", connKindLabel(.data));
}

test "looks_like_control_payload accepts FTP lines and rejects binary chunks" {
    try std.testing.expect(looksLikeControlPayload("USER portal\r\n"));
    try std.testing.expect(looksLikeControlPayload("331 User name okay, need password\r\n"));

    const binary = [_]u8{ 0x00, 0x01, 0x02, 0xff };
    try std.testing.expect(!looksLikeControlPayload(binary[0..]));
}
