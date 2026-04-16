const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const json = std.json;

pub const Config = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 8080,

    log_file_path: []const u8 = "server.log",
    should_console_print: bool = true,

    pub fn load(io: Io, allocator: std.mem.Allocator, file_name: []const u8) !json.Parsed(Config) {

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const aa = arena.allocator();

        const content = try Dir.cwd().readFileAlloc(
            io, file_name, 
            aa, .unlimited
        );
        
        const value = try json.parseFromSliceLeaky(
            Config, aa, content, 
            .{ .ignore_unknown_fields = true }
        );

        return json.Parsed(Config){
            .arena = arena,
            .value = value,
        };
    }

    pub fn save(self: Config, io: Io, file_name: []const u8) !void {
        var file = try Dir.cwd().createFile(
            io, file_name, 
            .{ .truncate = true }
        );

        defer file.close(io);

        var write_buf: [1024]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);

        try json.Stringify.value(
            self, .{ .whitespace = .indent_4 }, 
            &file_writer.interface
        );

        try file_writer.flush();
    }

    pub fn checkIfExists(io: Io, file_name: []const u8) !bool {
        Dir.cwd().access(io, file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};