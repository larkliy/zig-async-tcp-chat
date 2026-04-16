const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

const ChatServer = @import("chat_server.zig").ChatServer;
const logger = @import("logger.zig");

const logger_config_path = "server_config.json";

pub const Config = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 8080,

    log_file_path: []const u8 = "server.log",
    should_console_print: bool = true
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const config = Config{};

    var log_file = try Dir.cwd().createFile(
        io, 
        config.log_file_path, 
        .{ .truncate = false, .read = true }
    );

    defer log_file.close(io);

    var log_writer_buffer: [1024]u8 = undefined;
    var log_writer = log_file.writer(io, &log_writer_buffer);
    const current_size = try log_file.length(io);
    try log_writer.seekTo(current_size);

    var console_impl = logger.ConsoleLogger{};
    var file_impl = logger.FileLogger.init(io, &log_writer.interface);

    const logger_base = if (config.should_console_print) 
        console_impl.logger() 
            else
        file_impl.logger();

    var server = ChatServer.init(io, gpa, logger_base);
    var server_job = io.async(startServer, .{ &server, config.address, config.port });

    defer { 
        server_job.cancel(io);
        _ = server_job.await(io);
        
        server.deinit();
    }

    var input_buffer: [1]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &input_buffer);
    _ = stdin_reader.interface.takeByte() catch {};
}

fn startServer(server: *ChatServer, address:[]const u8, port: u16) void {
    server.run(address, port) catch |err| {
        server.logger.log_error("Server crashed: {s}", .{@errorName(err)}) catch {};
    };
}