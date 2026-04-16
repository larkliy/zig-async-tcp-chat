const std = @import("std");
const User = @import("user.zig").User;
const ClientContext = @import("client_context.zig").ClientContext;
const Helpers = @import("server_helpers.zig").Helpers;
const Logger = @import("logger.zig").Logger;

const Literals = @import("literals.zig");
const SystemLiterals = Literals.SystemLiterals;
const UserLiterals = Literals.UserLiterals;

const Io = std.Io;
const net = Io.net;
const ConcurrentList = @import("concurrent_list.zig").ConcurrentList;

pub const ChatServer = struct {
    const Self = @This();

    io: Io,
    gpa: std.mem.Allocator,
    server: net.Server,
    client_group: Io.Group,
    clients: ConcurrentList(*ClientContext),
    logger: Logger,

    pub fn init(io: Io, gpa: std.mem.Allocator, logger: Logger) ChatServer {
        return ChatServer{
            .io = io,
            .gpa = gpa,
            .server = undefined,
            .client_group = .init,
            .clients = .init(gpa),
            .logger = logger
        };
    }

    pub fn run(self: *Self, address:[]const u8, port: u16) !void {
        const ip_address = try net.IpAddress.parse(address, port);
        
        self.server = try ip_address.listen(self.io, .{});

        try self.logger.log_info("Chat server running on {s}:{d}", .{address, port});
        
        self.client_group.async(self.io, watchdogTask, .{self});

        while (true) {
            const stream = self.server.accept(self.io) catch |err| {

                if (err == error.Canceled) {
                    try self.logger.log_info("Accept canceled, shutting down loop...", .{});
                    break; 
                }

                try self.logger.logError("Accept error: {s}", .{@errorName(err)});
                continue;
            };

            self.client_group.async(self.io, handleClient, .{self, stream});
        }
        
        self.server.deinit(self.io);
    }

    fn handleClient(self: *Self, stream: net.Stream) void {
        handleClientInternal(self, stream) catch |err| {
            self.logger.logError("Client handling error: {s}", .{@errorName(err)}) catch {};
        };
    }

    fn handleClientInternal(self: *Self, stream: net.Stream) !void {
        const io = self.io;

        var buf:[100]u8 = undefined;
        const ip_fmt = try std.fmt.bufPrint(&buf, "{f}", .{stream.socket.address}); 

        const client_ctx = try self.gpa.create(ClientContext);
        const reader_buf = try self.gpa.alloc(u8, 1024);
        const writer_buf = try self.gpa.alloc(u8, 1024);

        client_ctx.* = ClientContext{
            .user = .{
                .is_authorized = false,
                .name = null
            },
            .reader = stream.reader(io, reader_buf),
            .writer = stream.writer(io, writer_buf),
            .stream = stream,
            .last_activity = .init(Io.Timestamp.now(io, .awake).toMilliseconds())
        };

        self.clients.append(self.io, client_ctx) catch |err| {
            try self.logger.logError("Client append error: {s}", .{@errorName(err)});
            self.gpa.free(reader_buf);
            self.gpa.free(writer_buf);
            self.gpa.destroy(client_ctx);
            stream.close(self.io);
            return err;
        };

        defer {
            self.logger.log_info("Closing connection from {s}", .{ip_fmt}) catch {};

            stream.close(self.io);

            self.clients.removeByValue(self.io, client_ctx) catch {};
            
            if (client_ctx.user.name) |name| self.gpa.free(name);
            self.gpa.free(reader_buf);
            self.gpa.free(writer_buf);
            self.gpa.destroy(client_ctx);
        }

        try self.logger.log_info("Client connected from {s}", .{ip_fmt});

        while (true) {
            if (!client_ctx.user.is_authorized) {
                self.handle_auth(client_ctx) catch |err| switch (err) {
                    error.WriteFailed,
                    error.ReadFailed => {
                        try self.logger.log_info("Connection dropped during auth for {s}", .{ip_fmt});
                        return;
                    },
                    else => return err,
                };
                continue;
            } else {
                self.handle_commands(client_ctx) catch |err| switch (err) {
                    error.UserExit => {
                        try self.logger.log_info("User {s} disconnected", .{client_ctx.user.name.?});
                        try self.sendToOthers(client_ctx, UserLiterals.Disconnected);
                        return;
                    },
                    error.Canceled, 
                    error.WriteFailed, 
                    error.ReadFailed => {
                        try self.logger.log_info("Connection dropped/timed out for {s}", .{ip_fmt});
                        return;
                    },
                    else => return err,
                };
            }
        }
    }

    fn handle_auth(self: *Self, ctx: *ClientContext) !void {
        try ctx.send(SystemLiterals.Welcome);

        const name = ctx.readln() catch |err| {
            if (err == error.StreamTooLong) {
                try ctx.send(SystemLiterals.MessageTooLong);
                return;
            }
            return err;
        };

        if (name == null) return;

        ctx.user.name = try self.gpa.dupe(u8, name.?);
        ctx.user.is_authorized = true;
        
        try self.logger.log_info("User {s} authenticated", .{name.?});

        try self.sendToOthers(ctx, UserLiterals.Joined);
    }

    fn handle_commands(self: *Self, ctx: *ClientContext) !void {
        try ctx.send(SystemLiterals.Help);
        
        const command = ctx.readln() catch |err| {
            if (err == error.StreamTooLong) {
                try ctx.send(SystemLiterals.MessageTooLong);
                return;
            }
            return err;
        };

        if (command == null) return;

        if (std.mem.startsWith(u8, command.?, "/exit")) {
            try self.logger.log_info("User {s} requested exit", .{ctx.user.name.?});
            return error.UserExit;
        } else if (std.mem.eql(u8, command.?, "/who")) {
            try self.sendInfoAboutOthers(ctx);
        } else if (std.mem.eql(u8, command.?, "/help")) {
            try ctx.send(SystemLiterals.Help);
        } else {
            try self.sendToOthers(ctx, command.?);
        }

        ctx.update_activity(self.io);
    }

    fn sendInfoAboutOthers(self: *Self, ctx: *ClientContext) !void {
        const clients_snapshot = try self.clients.getSnapshot(self.io);
        defer self.gpa.free(clients_snapshot);

        const client_count = clients_snapshot.len;

        try ctx.print(SystemLiterals.UsersOnline, .{client_count});

        var should_cut_info = false;

        if (client_count > 10)
            should_cut_info = true;

        for (clients_snapshot) |other_ctx| {

            if (ctx.stream.socket.handle == other_ctx.stream.socket.handle) {
                try ctx.print(" - You\n", .{});
                continue;
            }

            if (other_ctx.user.name) |name| {
                try ctx.print(" - {s}\n", .{ name });
            }

            if (should_cut_info) {
                try ctx.print("   ...\n", .{});
                break;
            }
        }
    }

    fn sendToOthers(self: *Self, ctx: *ClientContext, message:[]const u8) !void {
        const io = self.io;
        const gpa = self.gpa;

        const clients_snapshot = try self.clients.getSnapshot(io);
        defer gpa.free(clients_snapshot);

        for (clients_snapshot) |other_ctx| {
            if (ctx.stream.socket.handle == other_ctx.stream.socket.handle) continue;

            if (!other_ctx.user.is_authorized) continue;

            try Helpers.print(
                io, other_ctx.stream, 
                "\n[MESSAGE] {s}: {s}\n",
                .{ ctx.user.name.?, message }
            );
        }
    }

    fn watchdogTask(self: *Self) void {
        const timeout_ms: i64 = 60 * std.time.ms_per_s;

        while (true) {
            self.io.sleep(.fromSeconds(5), .awake) catch return;

            const now = Io.Timestamp.now(self.io, .awake).toMilliseconds();

            const clients_snapshot = self.clients.getSnapshot(self.io) catch continue;
            defer self.gpa.free(clients_snapshot);

            for (clients_snapshot) |ctx| {
                const last = ctx.last_activity.load(.monotonic);
                
                if (now - last > timeout_ms) {
                    self.logger.log_info("Kicking user due to inactivity", .{}) catch {};

                    Helpers.print(
                        self.io, ctx.stream, 
                        "[KICK] {s}", .{SystemLiterals.KickedByInactivity}
                    ) catch {};

                    ctx.stream.shutdown(self.io, .both) catch {};
                }
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.client_group.cancel(self.io);
        self.client_group.await(self.io) catch {};

        const clients_snapshot = self.clients.getSnapshot(self.io) catch |err| {
            self.logger.logError("Failed to get clients snapshot during deinit: {s}", .{@errorName(err)}) catch {};
            return;
        };

        for (clients_snapshot) |ctx| {
            ctx.stream.close(self.io);
        }

        self.clients.deinit(self.io) catch {};

        self.logger.log_info("Server resources cleared.", .{}) catch {};
    }
};