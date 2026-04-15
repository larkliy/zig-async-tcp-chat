const std = @import("std");
const User = @import("user.zig").User;
const Helper = @import("herlpers.zig").Helper;

const Io = std.Io;
const net = Io.net;
const File = Io.File;
const ConcurrentList = @import("concurrent_list.zig").ConcurrentList;

const ClientContext = struct { 
    user: *User, 
    reader: *net.Stream.Reader, 
    writer: *net.Stream.Writer, 
    stream: net.Stream,

    pub fn send(self: *ClientContext, data: []const u8) !void {
        try self.writer.interface.writeAll(data);
        try self.writer.interface.flush();
    }

    pub fn readln(self: *ClientContext) !?[]const u8 {
        self.reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        const line = try self.reader.interface.takeDelimiter('\n');
        if (line == null) return null;

        return std.mem.trim(u8, line.?, "\r\n");
    }

    pub fn print(self: *ClientContext, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.interface.print(fmt, args);
        try self.writer.interface.flush();
    }
};


pub const ChatServer = struct {
    const Self = @This();

    io: Io,
    gpa: std.mem.Allocator,
    server: net.Server,
    client_group: Io.Group,
    is_debug: bool,
    streams: ConcurrentList(net.Stream),
    users: ConcurrentList(User),

    pub fn init(io: Io, gpa: std.mem.Allocator, is_debug: bool) ChatServer {
        return ChatServer{
            .io = io,
            .gpa = gpa,
            .server = undefined,
            .client_group = .init,
            .is_debug = is_debug,
            .streams = .init(gpa),
            .users = .init(gpa),
        };
    }

    pub fn run(self: *Self, address: []const u8, port: u16) !void {
        const ip_address = try net.IpAddress.parse(address, port);

        self.server = try ip_address.listen(self.io, .{});

        self.log_info("Chat server running on {s}:{d}", .{address, port});
        
        while (true) {
            const stream = self.server.accept(self.io) catch |err| {
                self.log_error("Accept error: {s}", .{@errorName(err)});
                continue;
            };

            self.streams.append(self.io, stream) catch |err| {
                self.log_error("Stream append error: {s}", .{@errorName(err)});
                continue;
            };

            self.client_group.async(self.io, handle_client, .{self, stream});
        }
    }

    fn handle_client(self: *Self, stream: net.Stream) void {
        handleClientInternal(self, stream) catch |err| {
            self.log_error("Client handling error: {s}", .{@errorName(err)});
        };
    }

    fn handleClientInternal(self: *Self, stream: net.Stream) !void {
        const io = self.io;

        var buf: [100]u8 = undefined;
        const ip_fmt = try std.fmt.bufPrint(&buf, "{f}", .{stream.socket.address}); 

        defer {
            self.log_info("Closing connection from {s}", .{ip_fmt});
            stream.close(self.io);
        }

        var writer_buf: [4096]u8 = undefined;
        var reader_buf: [4096]u8 = undefined;

        var user = User{
            .is_authorized = false,
            .name = null
        };

        var reader = stream.reader(io, &reader_buf);
        var writer = stream.writer(io, &writer_buf);

        var client_ctx = ClientContext{
            .user = &user,
            .reader = &reader,
            .writer = &writer,
            .stream = stream
        };

        self.log_info("Client connected from {s}", .{ip_fmt});

        while (true) {
            if (!client_ctx.user.is_authorized) {
                try self.handle_auth(&client_ctx);
                continue;
            } else {
                self.handle_commands(&client_ctx) catch |err| switch (err) {
                    error.UserExit => {
                        self.log_info("User {s} disconnected", .{client_ctx.user.name.?});
                        return;
                    },
                    else => return err,
                };
            }
        }
    }

    fn handle_auth(self: *Self, ctx: *ClientContext) !void {
        try ctx.send("Enter your name: ");

        const name = try ctx.readln();

        if (name == null) return;

        ctx.user.name = try self.gpa.dupe(u8, name.?);
        ctx.user.is_authorized = true;
        
        self.log_info("User {s} authenticated", .{name.?});
    }

    fn handle_commands(self: *Self, ctx: *ClientContext) !void {
        try ctx.send("Enter commands (type /exit to disconnect): ");

        const command = try ctx.readln();
        if (command == null) return;

        if (std.mem.startsWith(u8, command.?, "/exit")) {
            self.log_info("User {s} requested exit", .{ctx.user.name.?});
            return error.UserExit;
        } else {
            try self.sendToOthers(ctx, command.?);
        }
    }

    fn sendToOthers(self: *Self, ctx: *ClientContext, message: []const u8) !void {
        const io = self.io;
        const gpa = self.gpa;

        const streams_snapshot = try self.streams.getSnapshot(io);
        defer gpa.free(streams_snapshot);

        for (streams_snapshot) |stream| {
            if (ctx.stream.socket.handle == stream.socket.handle) continue;

            try Helper.send(
                io, stream, 
                "[MESSAGE] {s}: {s}\n", 
                .{ ctx.user.name.?, message }
            );
        }
    }

    pub fn deinit(self: *Self) void {

        self.streams.deinit(self.io) catch |err| {
            self.log_error("Streams deinit error: {s}", .{@errorName(err)});
        };

        for (self.users.list.items) |user| {
            if (user.name) |name|
                self.gpa.free(name);
        }

        self.users.deinit(self.io) catch |err| {
            self.log_error("Users deinit error: {s}", .{@errorName(err)});
        };

        self.server.deinit(self.io);
        self.client_group.cancel(self.io);
    }


    fn log_info(self: *Self, comptime msg: []const u8, args: anytype) void {
        if (self.is_debug) {
            std.log.info(msg, args);
        }
    }

    fn log_error(self: *Self, comptime msg: []const u8, args: anytype) void {
        if (self.is_debug) {
            std.log.err(msg, args);
        }
    }
};