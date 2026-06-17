const std = @import("std");
const Io = std.Io;
const zio = @import("zio");

const ChatServer = @import("chat_server.zig");

const Config = struct {
    port: u16,
    address: []const u8
};

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const args = try init.args.toSlice(arena);
    const config = try parseServerAndPort(io, args);

    var server = ChatServer.init(io, allocator);

    var server_job = try Io.concurrent(io, startServer, .{ &server, config.address, config.port });
    server_job.await(io) catch {};
    
    var input_buffer: [1]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &input_buffer);
    _ = stdin_reader.interface.takeByte() catch {};

    server_job.cancel(io) catch {};
        
    server.deinit();
}

fn parseServerAndPort(io: Io, args: []const [:0]const u8) !Config {
    var address_opt: ?[]const u8 = null;
    var port_opt: ?u16 = null;

    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--address")) {
            if (i + 1 < args.len) {
                address_opt = args[i + 1];
            }
        }

        if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 < args.len) {
                port_opt = try std.fmt.parseInt(u16, args[i + 1], 10);
            }
        }
    }

    if (address_opt == null or port_opt == null) {
        try Io.File.stdout().writeStreamingAll(io, "Some parameter is missing. Please enter parameters in the following format: --address 127.0.0.1 --port 9999.");
        return error.OneArgIsNull;
    }

    return .{
        .address = address_opt.?,
        .port = port_opt.?
    };
}

fn startServer(server: *ChatServer, address:[]const u8, port: u16) !void {
    try server.run(address, port);
}