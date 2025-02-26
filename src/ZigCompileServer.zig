//! modified version of https://github.com/ziglang/zig/blob/master/lib/std/zig/Server.zig
//! I don't know why but this code seems to work
//! zig binary serialization library in stdlib, when?

in: std.fs.File,
out: std.fs.File,
pooler: std.io.Poller(StreamEnum),

const StreamEnum = enum { in };

pub const Options = struct {
    gpa: Allocator,
    in: std.fs.File,
    out: std.fs.File,
};

pub fn init(options: Options) Client {
    var s: Client = .{
        .in = options.in,
        .out = options.out,
        .pooler = std.io.poll(options.gpa, StreamEnum, .{ .in = options.in }),
    };
    return s;
}

pub fn deinit(s: *Client) void {
    s.pooler.deinit();
    s.* = undefined;
}

pub fn receiveMessage(client: *Client) !InMessage.Header {
    const Header = InMessage.Header;
    const fifo = client.pooler.fifo(.in);

    while (try client.pooler.poll()) {
        const buf = fifo.readableSlice(0);
        assert(fifo.readableLength() == buf.len);
        if (buf.len >= @sizeOf(Header)) {
            // workaround for https://github.com/ziglang/zig/issues/14904
            const bytes_len = bswap_and_workaround_u32(buf[4..][0..4]);
            const tag = bswap_and_workaround_tag(buf[0..][0..4]);

            if (buf.len - @sizeOf(Header) >= bytes_len) {
                fifo.discard(@sizeOf(Header));
                return .{
                    .tag = tag,
                    .bytes_len = bytes_len,
                };
            } else {
                const needed = bytes_len - (buf.len - @sizeOf(Header));
                const write_buffer = try fifo.writableWithSize(needed);
                const amt = try client.in.readAll(write_buffer);
                fifo.update(amt);
                continue;
            }
        }

        const write_buffer = try fifo.writableWithSize(256);
        const amt = try client.in.read(write_buffer);
        fifo.update(amt);
    }
    return error.Timeout;
}

pub fn receiveEmitBinPath(client: *Client) !InMessage.EmitBinPath {
    const reader = client.pooler.fifo(.in).reader();
    return reader.readStruct(InMessage.EmitBinPath);
}

pub fn receiveErrorBundle(client: *Client) !InMessage.ErrorBundle {
    const reader = client.pooler.fifo(.in).reader();
    return .{
        .extra_len = try reader.readIntLittle(u32),
        .string_bytes_len = try reader.readIntLittle(u32),
    };
}

pub fn receiveBytes(client: *Client, allocator: std.mem.Allocator, len: usize) ![]u8 {
    const reader = client.pooler.fifo(.in).reader();
    const result = try reader.readAllAlloc(allocator, len);
    if (result.len != len) return error.UnexpectedEOF;
    return result;
}

pub fn receiveIntArray(client: *Client, allocator: std.mem.Allocator, len: usize) ![]u32 {
    const reader = client.pooler.fifo(.in).reader();
    var array_list = std.ArrayListAligned(u8, 4).init(allocator);
    errdefer array_list.deinit();
    try reader.readAllArrayListAligned(4, &array_list, len);
    const bytes = try array_list.toOwnedSlice();
    const result = std.mem.bytesAsSlice(u32, bytes);
    if (need_bswap) {
        bswap_u32_array(result);
    }
    return result;
}

pub fn serveMessage(
    client: *const Client,
    header: OutMessage.Header,
    bufs: []const []const u8,
) !void {
    var iovecs: [10]std.os.iovec_const = undefined;
    const header_le = bswap(header);
    iovecs[0] = .{
        .iov_base = @ptrCast([*]const u8, &header_le),
        .iov_len = @sizeOf(OutMessage.Header),
    };
    for (bufs, iovecs[1 .. bufs.len + 1]) |buf, *iovec| {
        iovec.* = .{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        };
    }
    try client.out.writevAll(iovecs[0 .. bufs.len + 1]);
}

fn bswap(x: anytype) @TypeOf(x) {
    if (!need_bswap) return x;

    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .Enum => return @intToEnum(T, @byteSwap(@enumToInt(x))),
        .Int => return @byteSwap(x),
        .Struct => |info| switch (info.layout) {
            .Extern => {
                var result: T = undefined;
                inline for (info.fields) |field| {
                    @field(result, field.name) = bswap(@field(x, field.name));
                }
                return result;
            },
            .Packed => {
                const I = info.backing_integer.?;
                return @bitCast(T, @byteSwap(@bitCast(I, x)));
            },
            .Auto => @compileError("auto layout struct"),
        },
        else => @compileError("bswap on type " ++ @typeName(T)),
    }
}

fn bswap_u32_array(slice: []u32) void {
    comptime assert(need_bswap);
    for (slice) |*elem| elem.* = @byteSwap(elem.*);
}

/// workaround for https://github.com/ziglang/zig/issues/14904
fn bswap_and_workaround_u32(bytes_ptr: *const [4]u8) u32 {
    return std.mem.readIntLittle(u32, bytes_ptr);
}

/// workaround for https://github.com/ziglang/zig/issues/14904
fn bswap_and_workaround_tag(bytes_ptr: *const [4]u8) InMessage.Tag {
    const int = std.mem.readIntLittle(u32, bytes_ptr);
    return @intToEnum(InMessage.Tag, int);
}

const OutMessage = std.zig.Client.Message;
const InMessage = std.zig.Server.Message;

const Client = @This();
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const native_endian = builtin.target.cpu.arch.endian();
const need_bswap = native_endian != .Little;
