const std = @import("std");
const cstd = @cImport(@cInclude("stdlib.h"));
const limits = @cImport(@cInclude("limits.h"));
pub const system = cstd.system;

const Allocator = std.mem.Allocator;
const ByteList = std.ArrayList(u8);
const assert = std.debug.assert;
const stdout = std.io.getStdOut().writer();

///because realpathAlloc is not supported on openbsd
///the returned string is zero terminated
pub fn realpathAlloc(allocator: Allocator, pathname: []const u8) ![]u8 {
    var realpath = try allocator.alloc(u8, limits.PATH_MAX);
    const pathname_cstr = try cString(allocator, pathname);
    defer allocator.free(pathname_cstr);
    if (cstd.realpath(pathname_cstr, realpath.ptr) == 0)
        return error.RealpathFailed;
    const len = std.mem.indexOfScalar(u8, realpath, 0).?;
    realpath = try allocator.realloc(realpath, len + 1);
    return realpath;
}

pub fn cString(allocator: Allocator, str: []const u8) ![:0]u8 {
    const cstr = try allocator.alloc(u8, str.len + 1);
    @memcpy(cstr[0..str.len], str);
    cstr[str.len] = 0;
    return cstr[0..str.len :0];
}

fn leadingOnes(byte: *u8) u3 {
    var count: u3 = 0;
    var b = byte.*;
    while (count < 7) : (count += 1) {
        const res = @shlWithOverflow(b, 1);
        b = res[0];
        if (res[0] == 0 or res[1] == 0) break;
    }
    byte.* = b >> count + 1;
    return count;
}

pub const CodepointResult = struct {
    codepoint: u32,
    bytes: [4]u8,
    n: u8,
};

pub fn readCodepointUTF8(reader: anytype) !CodepointResult {
    var codepoint: u32 = 0;
    var bytes: [4]u8 = undefined;
    var byte = try reader.readByte();
    bytes[0] = byte;
    var following: u5 = @intCast(leadingOnes(&byte));
    const n = @max(following, 1);
    if (following > 0)
        following -= 1;
    while (following > 0) : (following -= 1) {
        codepoint |= @as(u32, byte) << (following * 6);
        byte = try reader.readByte();
        bytes[4 - following] = byte;
        if (leadingOnes(&byte) != 1)
            return error.InvalidUtf8;
    }
    codepoint |= @as(u32, byte) << (following * 6);
    return .{
        .codepoint = codepoint,
        .bytes = bytes,
        .n = n,
    };
}

pub fn encodeUTF8(codepoint: u32) !CodepointResult {
    // zig fmt: off
    const n: u3 = if (codepoint >= 1 << 21) return error.InvalidCodepoint
                  else if (codepoint >= 1 << 16) 4
                  else if (codepoint >= 1 << 11) 3
                  else if (codepoint >= 1 << 7) 2
                  else 1;
    // zig fmt: on
    var c = codepoint;
    var i: usize = 1;
    var bytes: [4]u8 = undefined;
    while (i <= n) : (i += 1) {
        const lower6: u8 = @intCast(c & 0x3f);
        bytes[n - i] = lower6;
        c >>= 6;
    }
    if (n > 1) {
        var leading: u8 = @bitCast(@as(i8, -128) >> (n - 1));
        bytes[0] |= leading;
        i = 1;
        while (i < n) : (i += 1) {
            bytes[i] |= 0x80;
        }
    } else {
        bytes[0] |= @intCast(codepoint & 0x40);
    }
    return .{
        .codepoint = codepoint,
        .bytes = bytes,
        .n = n,
    };
}

pub const StringUTF8 = struct {
    str: ByteList,
    str_lens: ByteList,

    pub fn init(allocator: Allocator) StringUTF8 {
        return .{
            .str = ByteList.init(allocator),
            .str_lens = ByteList.init(allocator),
        };
    }

    pub fn deinit(self: StringUTF8) void {
        self.str.deinit();
        self.str_lens.deinit();
    }

    pub fn append(self: *StringUTF8, result: CodepointResult) !void {
        const len = result.n;
        try self.str.appendSlice(result.bytes[0..len]);
        try self.str_lens.append(len);
    }

    pub fn removeLast(self: *StringUTF8) !void {
        if (self.str_lens.popOrNull()) |len| {
            self.str.resize(self.str.items.len - len) catch unreachable;
        } else return error.EmptyString;
    }

    pub fn clear(self: *StringUTF8) void {
        self.str.resize(0) catch unreachable;
        self.str_lens.resize(0) catch unreachable;
    }
};

pub fn codepointsFromStringUTF8(allocator: Allocator, str: []const u8) ![]u32 {
    var stream = std.io.fixedBufferStream(str);
    var reader = stream.reader();
    var buf = try allocator.alloc(u32, str.len);
    var i: usize = 0;
    while (readCodepointUTF8(reader)) |res| : (i += 1) {
        buf[i] = res.codepoint;
    } else |err| {
        switch (err) {
            error.InvalidUtf8 => return err,
            inline else => {},
        }
    }
    buf = try allocator.realloc(buf, i);
    return buf;
}

test "encodeUTF8" {
    var result = try encodeUTF8('A');
    assert(result.bytes[0] == 'A' and result.n == 1);
    result = try encodeUTF8('r');
    assert(result.bytes[0] == 'r' and result.n == 1);
    result = try encodeUTF8('愛');
    assert(std.mem.eql(u8, result.bytes[0..3], &[_]u8{ 0xe6, 0x84, 0x9b }) and result.n == 3);
}

test "sar" {
    var x: u8 = @bitCast(@as(i8, -128) >> 3);
    assert(x == 0xf0);
}

test "sentinel len???" {
    const allocator = std.testing.allocator;
    const s1 = try allocator.alloc(u8, 8);
    defer allocator.free(s1);
    s1[7] = 0;
    const s2: [:0]u8 = @ptrCast(s1);
    assert(s1.len == s2.len);
}
