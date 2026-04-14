const std = @import("std");
const Io = std.Io;
const net = Io.net;
const File = Io.File;

const thread_safe = @import("threadsafe_list.zig");

const User = @import("user.zig").User;

var streams: thread_safe.ConcurrentList(net.Stream) = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const port = 8080;

    const ip = try net.IpAddress.parse("0.0.0.0", port);

    streams = .init(init.gpa);

    var server = try ip.listen(io, .{});
    defer server.deinit(io);

    var client_group = Io.Group.init;
    defer client_group.cancel(io);

    std.log.info("Server listening on 0.0.0.0:{d}", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("Accept error: {s}", .{@errorName(err)});
            continue;
        };
        
        try streams.append(io, stream);

        client_group.async(io, handleClientSafe, .{ init, stream });
    }
}

fn handleClientSafe(init: std.process.Init, stream: net.Stream) void {
    handleClient(init, stream) catch |err| {
        std.log.err("Client handler error: {s}", .{@errorName(err)});
    };
}

fn handleClient(init: std.process.Init, current_stream: net.Stream) !void {
    defer current_stream.close(init.io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var user = User{};
    
    var reader = current_stream.reader(init.io, &read_buf);
    var writer = current_stream.writer(init.io, &write_buf);

    std.log.info("New client connected", .{});

    while (true) {
        if (!user.is_authorized) {
            if (handle_auth(init, &user, &reader, &writer) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err
            }) {
                std.log.info("You're authorized.\n", .{});
            }

            continue;
        }

        try writer.interface.writeAll("[INFO] Enter the message text: ");

        reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err
        };
        
        const message = reader.interface.buffered();
        if (message.len == 0) continue;

        for (streams.list.items) |other_stream| {
            if (current_stream.socket.handle == other_stream.socket.handle) continue;

            var write_other_buf: [4096]u8 = undefined;
            var other_writer = other_stream.writer(init.io, &write_other_buf);

            const formatted = try std.fmt.allocPrint(
                init.gpa, "[MESSAGE] {s}: {s}\n", .{ user.name.?, message }
            );

            defer init.gpa.free(formatted);

            try other_writer.interface.writeAll(formatted);
            try other_writer.interface.flush();
        }
        
        reader.interface.toss(message.len);
    }

    std.log.info("Client disconnected", .{});
}

fn handle_auth(init: std.process.Init, user: *User, reader: *net.Stream.Reader, writer: *net.Stream.Writer) !bool {
    if (!user.is_authorized) {
        try writer.interface.writeAll("Enter your name: ");
        try writer.interface.flush();

        try reader.interface.fillMore();

        const buffered = reader.interface.buffered();
        if (buffered.len == 0) return false;

        user.name = try init.gpa.dupe(u8, buffered);
        user.is_authorized = true;

        reader.interface.toss(buffered.len);

        return true;
    }

    return true;
}