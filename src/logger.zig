const std = @import("std");
const Io = std.Io;

pub const FileLogger = struct {
    const Self = @This();

    io: std.Io,
    writer: *std.Io.Writer,

    pub fn init(io: std.Io, writer: *std.Io.Writer) FileLogger {
        return .{
            .io = io,
            .writer = writer,
        };
    }

    fn writePrefix(self: *Self, level: []const u8) !void {
        const time = std.Io.Clock.real.now(self.io);

        const secs: u64 = @intCast(time.toSeconds());

        const es = std.time.epoch.EpochSeconds{ .secs = secs };
        const ed = es.getEpochDay();
        const yd = ed.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();

        try self.writer.print(
            "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] [{s}] ",
            .{
                yd.year,
                md.month.numeric(),
                md.day_index + 1,
                ds.getHoursIntoDay(),
                ds.getMinutesIntoHour(),
                ds.getSecondsIntoMinute(),
                level,
            },
        );
    }

    fn log_info_impl(ptr: *anyopaque, msg: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writePrefix("INFO") catch return;
        self.writer.print("{s}\n", .{msg}) catch return;
        self.writer.flush() catch return;
    }

    fn log_error_impl(ptr: *anyopaque, msg: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writePrefix("ERROR") catch return;
        self.writer.print("{s}\n", .{msg}) catch return;
        self.writer.flush() catch return;
    }

    pub fn logger(self: *Self) Logger {
        return .{
            .ptr = self,
            .vtable = &.{
                .log_info = log_info_impl,
                .log_error = log_error_impl,
            },
        };
    }
};

pub const ConsoleLogger = struct {
    const Self = @This();

    fn log_info_impl(_: *anyopaque, msg: []const u8) void {
        std.log.info("{s}", .{msg});
    }

    fn log_error_impl(_: *anyopaque, msg: []const u8) void {
        std.log.err("{s}", .{msg});
    }

    pub fn logger(self: *Self) Logger {
        _ = self;
        return .{
            .ptr = undefined,
            .vtable = &.{
                .log_info = log_info_impl,
                .log_error = log_error_impl,
            },
        };
    }
};

pub const Logger = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        log_info: *const fn (*anyopaque, []const u8) void,
        log_error: *const fn (*anyopaque, []const u8) void,
    };

    pub fn log_info(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        self.vtable.log_info(self.ptr, msg);
    }

    pub fn log_error(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        self.vtable.log_error(self.ptr, msg);
    }
};