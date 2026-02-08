const std = @import("std");
const ppsdk = @import("paper_portal_sdk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
    });
    const optimize = std.builtin.OptimizeMode.ReleaseSmall;

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    root_mod.export_symbol_names = &.{
        "pp_contract_version",
        "pp_init",
        "pp_tick",
        "pp_alloc",
        "pp_free",
        "pp_on_gesture",
    };

    const exe = b.addExecutable(.{ .name = "main", .root_module = root_mod });
    exe.entry = .disabled;

    _ = ppsdk.addWasmUpload(b, exe, .{});

    _ = ppsdk.addWasmPortalPackage(b, exe, .{
        .manifest = .{
            .id = "716ed6a0-ec9f-459b-82ee-e98026c6bd75",
            .name = "File Server",
            .version = "0.1.0",
        },
    });

    const sdk_dep = if (dirExists(b, "../zig-sdk"))
        (b.lazyDependency("paper_portal_sdk_local", .{}) orelse @panic("paper_portal_sdk_local missing"))
    else
        b.dependency("paper_portal_sdk", .{});
    const sdk = b.createModule(.{
        .root_source_file = sdk_dep.path("sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("paper_portal_sdk", sdk);

    const ftp_dep = b.dependency("zig_ftp_server", .{});
    const ftp = ftp_dep.module("ftp_server");
    exe.root_module.addImport("ftp_server", ftp);

    exe.entry = .disabled;
    exe.stack_size = 32 * 1024;
    exe.initial_memory = 512 * 1024;
    exe.max_memory = 1024 * 1024;
    b.installArtifact(exe);
}

fn dirExists(b: *std.Build, rel: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, rel, .{}) catch return false;
    return true;
}
