const std = @import("std");
const STDIN_FILENO = @cImport(@cInclude("unistd.h")).STDIN_FILENO;
const cstd = @cImport(@cInclude("stdlib.h"));
const perror = @cImport(@cInclude("stdio.h")).perror;
const term = @cImport(@cInclude("termios.h"));

const Allocator = std.mem.Allocator;
var orig_termios: term.termios = undefined;

fn exitErr(buf: [*c]const u8) void {
    perror(buf);
    std.c.exit(cstd.EXIT_FAILURE);
}

///this will leave c_lflag ECHO on
pub fn enableRawMode() void {
    var raw: term.termios = undefined;
    if (term.tcgetattr(STDIN_FILENO, &raw) == -1)
        exitErr("tcgetattr");
    orig_termios = raw;
    raw.c_oflag &= @bitCast(~(term.OPOST));
    raw.c_cflag &= @bitCast(~(term.CS8));
    raw.c_iflag &= @bitCast(~(term.IXON | term.ICRNL | term.BRKINT | term.INPCK | term.ISTRIP));
    raw.c_lflag &= @bitCast(~(term.ICANON | term.ISIG | term.IEXTEN));
    raw.c_cc[term.VMIN] = 0;
    raw.c_cc[term.VTIME] = 1;
    if (term.tcsetattr(STDIN_FILENO, term.TCSAFLUSH, &raw) == -1)
        exitErr("tcsetattr");
}

pub fn disableRawMode() void {
    if (term.tcsetattr(STDIN_FILENO, term.TCSAFLUSH, &orig_termios) == -1)
        exitErr("tcsetattr");
}

pub fn clear(writer: anytype) !void {
    try writer.writeAll("\x1b[H\x1b[0J");
}

pub fn newline(writer: anytype) !void {
    try writer.writeAll("\x1b[1E");
}

pub fn deleteLine(writer: anytype) !void {
    try writer.writeAll("\x1b[0G\x1b[0K");
}

pub fn backspace(writer: anytype, n: usize) !void {
    try writer.print("\x1b[{}D\x1b[0K", .{n});
}
