const std = @import("std");
const sdk = @import("paper_portal_sdk");

pub fn build(b: *std.Build) void {
    const app = sdk.addPortalApp(b, .{
        .local_sdk_path = "../zig-sdk",
        .export_symbol_names = &.{"ppShutdown"},
    });

    _ = sdk.addPortalPackage(b, app.exe, .{
        .manifest = .{
            .id = "716ed6a0-ec9f-459b-82ee-e98026c6bd75",
            .name = "File Server",
            .version = "0.1.0",
        },
    });

    const webdav_dep = b.dependency("zig_webdav_server", .{});
    app.exe.root_module.addImport("webdav_server", webdav_dep.module("zig_webdav_server"));
}
