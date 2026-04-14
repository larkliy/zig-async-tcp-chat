const std = @import("std");
const User = @import("user.zig").User;

const Io = std.Io;
const net = Io.net;
const File = Io.File;
const ConcurrentList = @import("threadsafe_list.zig").ConcurrentList;


var streams: ConcurrentList(net.Stream) = undefined;
var users: ConcurrentList(User) = undefined;

const ClientContext = struct { 
    user: *User, 
    reader: *net.Stream.Reader, 
    writer: *net.Stream.Writer, 
    stream: net.Stream
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const port = 8080;

    const ip = try net.IpAddress.parse("0.0.0.0", port);

    streams = .init(gpa);
    users = .init(gpa);

    var server = try ip.listen(io, .{});
    var client_group = Io.Group.init;

    defer {
        streams.deinit(io);


        for (users.list.items) |user| {
            if (user.name) |name|
                gpa.free(name);
        }
        users.deinit(io);


        server.deinit(io);
        client_group.cancel(io);
    }

    std.log.info("Server listening on 0.0.0.0:{d}", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("Accept error: {s}", .{@errorName(err)});
            continue;
        };

        streams.append(io, stream) catch |err| {
            std.log.err("Stream append error: {s}", .{@errorName(err)});
            continue;
        };

        client_group.async(io, handleClientSafe, .{ init, stream });
    }
}

fn handleClientSafe(init: std.process.Init, stream: net.Stream) void {
    handleClient(init, stream) catch |err| {
        std.log.err("Client handler error: {s}", .{@errorName(err)});
    };
}

fn handleClient(init: std.process.Init, current_stream: net.Stream) !void {
    const io = init.io;

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var user = User{};

    defer {
        current_stream.close(init.io);
        
        std.log.info("Client disconnected", .{});
    }

    var reader = current_stream.reader(io, &read_buf);
    var writer = current_stream.writer(io, &write_buf);

    var client_context = ClientContext{ 
        .reader = &reader, 
        .writer = &writer, 
        .user = &user, 
        .stream = current_stream,
    };

    std.log.info("New client connected", .{});

    while (true) {
        if (!user.is_authorized) {
            const auth_result = try handle_auth(init, &client_context);

            if (auth_result)
                std.log.info("You're authorized.", .{});

            continue;
        }

        try writer.interface.writeAll("[INFO] Enter the message text: ");
        try writer.interface.flush();

        reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const message = reader.interface.buffered();
        if (message.len == 0) continue;

        const trimmed_msg = std.mem.trimEnd(u8, message, "\r\n ");

        try sendToOthers(init, &client_context, trimmed_msg);

        reader.interface.toss(message.len);
    }
}

fn sendToOthers(init: std.process.Init, ctx: *ClientContext, message: []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;

    const streams_snapshot = try streams.getSnapshot(io);
    defer gpa.free(streams_snapshot);

    for (streams_snapshot) |stream| {
        if (ctx.stream.socket.handle == stream.socket.handle) continue;

        var write_other_buf: [4096]u8 = undefined;
        var other_writer = stream.writer(io, &write_other_buf);

        const formatted = try std.fmt.allocPrint(
            gpa, "[MESSAGE] {s}: {s}\n", 
            .{ ctx.user.name.?, message }
        );

        defer gpa.free(formatted);

        try other_writer.interface.writeAll(formatted);
        try other_writer.interface.flush();
    }
}

fn handle_auth(init: std.process.Init, ctx: *ClientContext) !bool {
    if (!ctx.user.is_authorized) {
        try ctx.writer.interface.writeAll("Enter your name: ");
        try ctx.writer.interface.flush();

        const raw_name = try ctx.reader.interface.takeDelimiter('\n');

        if (raw_name == null) return false;

        ctx.user.name = try init.gpa.dupe(u8, raw_name.?);
        ctx.user.is_authorized = true;

        return true;
    }

    return true;
}