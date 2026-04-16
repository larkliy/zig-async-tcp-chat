const std = @import("std");
const logger = @import("logger.zig");
const Io = std.Io;
const Dir = Io.Dir;

const ChatServer = @import("chat_server.zig").ChatServer;
const Config = @import("config.zig").Config;

const logger_config_path = "server_config.json";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var config: Config = undefined;

    var config_parsed: ?std.json.Parsed(Config) = null;
    defer if (config_parsed) |*p| p.deinit();

    if (!try Config.checkIfExists(io, logger_config_path)) {
        std.debug.print("Config file not found, creating default config file...\n", .{});
        config = .{};
        try config.save(io, logger_config_path);
    } else {
        std.debug.print("Config file found, loading...\n", .{});
        config_parsed = try Config.load(io, gpa, logger_config_path);
        config = config_parsed.?.value;
    }

    var console_impl = logger.ConsoleLogger{};
    var file_impl = try logger.FileLogger.init(io, config);

    var logger_base = if (config.should_console_print) 
        console_impl.logger() 
            else
        file_impl.logger();

    var server = ChatServer.init(io, gpa, logger_base);

    var server_job = io.async(
        startServer, 
        .{ &server, config.address, config.port }
    );

    var input_buffer: [1]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &input_buffer);
    _ = stdin_reader.interface.takeByte() catch {};

    if (@import("builtin").mode == .Debug) {

        try server_job.cancel(io);
        try server_job.await(io);

    } else {

        server_job.cancel(io) catch {};
        server_job.await(io) catch |err| {
            logger_base.logError("Server await error: {s}", .{@errorName(err)}) catch {};
        };

    }
        
    server.deinit();
}

fn startServer(server: *ChatServer, address:[]const u8, port: u16) !void {
    try server.run(address, port);
}