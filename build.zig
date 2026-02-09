const std = @import("std");
const sdk = @import("paper_portal_sdk");

pub fn build(b: *std.Build) void {
    const app = sdk.addPortalApp(b, .{
        .local_sdk_path = "../zig-sdk",
        .export_symbol_names = &.{
            "pp_contract_version",
            "pp_init",
            "pp_tick",
            "pp_alloc",
            "pp_free",
            "pp_on_gesture",
        },
    });

    _ = sdk.addPortalPackage(b, app.exe, .{
        .manifest = .{
            .id = "716ed6a0-ec9f-459b-82ee-e98026c6bd75",
            .name = "File Server",
            .version = "0.1.0",
        },
    });

    const ftp_dep = b.dependency("zig_ftp_server", .{});
    app.exe.root_module.addImport("ftp_server", ftp_dep.module("ftp_server"));
}
