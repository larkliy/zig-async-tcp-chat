const std = @import("std");

pub fn build(b: *std.Build) void {
    
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "mini-tcp-chat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize
        }),
    });

    if (exe.root_module.optimize != .Debug) {
        exe.root_module.strip = false;
        exe.root_module.single_threaded = false;
        exe.root_module.unwind_tables = .none;
        
        // exe.lto = .full;
    }

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
