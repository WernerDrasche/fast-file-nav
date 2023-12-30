const std = @import("std");
const term = @import("terminal.zig");
const util = @import("util.zig");

const PDF = "zathura";
const TEXT = "nvim";

const Allocator = std.mem.Allocator;
const DirEntry = std.fs.IterableDir.Entry;
const IterableDir = std.fs.IterableDir;
const NodeMap = std.AutoHashMap(u32, *Node);
const ElementList = std.ArrayList(Element);
const StringUTF8 = util.StringUTF8;
const assert = std.debug.assert;
var stdin = std.io.getStdIn().reader();
var stdout = std.io.getStdOut().writer();
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const Element = struct {
    entry: DirEntry,
    index: ?*Index = null,
};

const Node = struct {
    next: NodeMap,
    prev: ?*Node = null,
    idx: ?usize = null,

    fn init(allocator: Allocator) Node {
        return .{
            .next = NodeMap.init(allocator),
        };
    }

    fn deinit(self: *Node, allocator: Allocator) void {
        var succs = self.next.valueIterator();
        while (succs.next()) |node| {
            node.*.deinit(allocator);
        }
        self.next.deinit();
        allocator.destroy(self);
    }

    const SearchResult = struct {
        node: *Node,
        rest: []const u32,
    };

    fn search(self: *Node, str: []const u32) SearchResult {
        const result = SearchResult{ .node = self, .rest = str };
        if (str.len == 0) return result;
        const c = str[0];
        const next = self.next.get(c) orelse return result;
        return next.search(str[1..]);
    }

    fn add(self: *Node, allocator: Allocator, str: []const u32, idx: usize) !void {
        const result = self.search(str);
        if (result.rest.len == 0) {
            if (result.node.idx != null) return error.DuplicateKey;
            result.node.idx = idx;
            return;
        }
        try result.node._add(allocator, result.rest, idx);
    }

    fn _add(self: *Node, allocator: Allocator, str: []const u32, idx: usize) !void {
        const c = str[0];
        const node = try allocator.create(Node);
        node.* = Node.init(allocator);
        node.prev = self;
        try self.next.putNoClobber(c, node);
        if (str.len > 1) {
            try node._add(allocator, str[1..], idx);
        } else {
            node.idx = idx;
        }
    }

    fn skip_to_junction(self: *Node, skipped: *StringUTF8) !*Node {
        if (self.next.count() != 1 or self.idx != null) return self;
        var entries = self.next.iterator();
        const entry = entries.next().?;
        const codepoint = entry.key_ptr.*;
        const result = try util.encodeUTF8(codepoint);
        try skipped.append(result);
        const node = entry.value_ptr.*;
        return node.skip_to_junction(skipped);
    }
};

const Index = struct {
    parent: ?*Index = null,
    root: *Node,
    buf: ElementList,

    fn init(allocator: Allocator, iter_dir: IterableDir) !Index {
        const root = try allocator.create(Node);
        root.* = Node.init(allocator);
        var index = Index{
            .root = root,
            .buf = ElementList.init(allocator),
        };
        var iterator = iter_dir.iterate();
        while (try iterator.next()) |entry| {
            const name = try allocator.alloc(u8, entry.name.len);
            @memcpy(name, entry.name);
            var entry_copy = IterableDir.Entry{
                .kind = entry.kind,
                .name = name,
            };
            try index.add(allocator, entry_copy);
        }
        return index;
    }

    fn deinit(self: *Index, allocator: Allocator) void {
        if (self.parent) |parent|
            return parent.deinit(allocator);
        self._deinit(allocator);
    }

    fn _deinit(self: *Index, allocator: Allocator) void {
        for (self.buf.items) |elem| {
            allocator.free(elem.entry.name);
            if (elem.index) |index| {
                index._deinit(allocator);
            }
        }
        self.buf.deinit();
        self.root.deinit(allocator);
        allocator.destroy(self);
    }

    fn add(self: *Index, allocator: Allocator, entry: DirEntry) !void {
        const codepoints = try util.codepointsFromStringUTF8(allocator, entry.name);
        defer allocator.free(codepoints);
        const idx = self.buf.items.len;
        try self.root.add(allocator, codepoints, idx);
        try self.buf.append(.{ .entry = entry });
    }

    fn print(self: Index, writer: anytype) !void {
        for (self.buf.items) |elem| {
            try writer.writeAll(elem.entry.name);
            try term.newline(writer);
        }
    }
};

fn openFile(allocator: Allocator, name: []const u8) void {
    // zig fmt: off
    const argv: []const []const u8 = if (std.mem.endsWith(u8, name, ".pdf")) &[_][]const u8{PDF, name}
                                     else &[_][]const u8{TEXT, name};
    // zig fmt: on
    std.process.execv(allocator, argv) catch unreachable;
}

const Context = struct {
    allocator: Allocator,
    index: *Index,
    cwd: IterableDir,

    fn init(allocator: Allocator) !Context {
        const index = try allocator.create(Index);
        const cwd = try std.fs.cwd().openIterableDir(".", .{});
        index.* = try Index.init(allocator, cwd);
        return .{
            .allocator = allocator,
            .index = index,
            .cwd = cwd,
        };
    }

    fn deinit(self: *Context) void {
        self.index.deinit(self.allocator);
        self.cwd.close();
    }

    fn chdir(self: *Context, name: []const u8) !void {
        try std.os.chdir(name);
        self.cwd.close();
        self.cwd = try std.fs.cwd().openIterableDir(".", .{});
    }

    ///node == null does cd ..
    fn open(self: *Context, node: ?*const Node) !void {
        if (node) |n| {
            const elem = &self.index.buf.items[n.idx.?];
            switch (elem.entry.kind) {
                .directory => {
                    try self.chdir(elem.entry.name);
                    if (elem.index) |new| {
                        self.index = new;
                    } else {
                        var new = try self.allocator.create(Index);
                        new.* = try Index.init(self.allocator, self.cwd);
                        new.parent = self.index;
                        elem.index = new;
                        self.index = new;
                    }
                },
                //TODO: read the symlink, change the elem to a directory with new name and open again
                .sym_link => return error.Unsupported,
                .file => openFile(self.allocator, elem.entry.name),
                else => return,
            }
        } else {
            if (self.index.parent) |new| {
                self.index = new;
                try self.chdir("..");
            } else {
                const path = try util.realpathAlloc(self.allocator, ".");
                defer self.allocator.free(path);
                const last_delim = std.mem.lastIndexOfScalar(u8, path, '/').?;
                const first_null = std.mem.indexOfScalar(u8, path, 0).?;
                const name = path[last_delim + 1 .. first_null :0];
                try self.chdir("..");
                var new = try self.allocator.create(Index);
                self.index.parent = new;
                new.* = try Index.init(self.allocator, self.cwd);
                for (new.buf.items, 0..) |elem, i| {
                    if (std.mem.eql(u8, elem.entry.name, name)) {
                        new.buf.items[i].index = self.index;
                        break;
                    }
                }
                self.index = new;
            }
        }
    }
};

pub fn main() !void {
    const allocator = gpa.allocator();
    term.enableRawMode();
    defer term.disableRawMode();
    const dest = try std.fs.createFileAbsolute("/tmp/dest", .{});
    defer dest.close();
    var input = util.StringUTF8.init(allocator);
    defer input.deinit();
    var ctx = try Context.init(allocator);
    defer ctx.deinit();
    next_dir: while (true) {
        try term.clear(stdout);
        try ctx.index.print(stdout);
        input.clear();
        var current = ctx.index.root;
        while (true) {
            const result = util.readCodepointUTF8(stdin) catch continue;
            const c = result.codepoint;
            switch (c) {
                //C-q
                17 => break :next_dir,
                //C-s
                19 => continue :next_dir,
                //C-h
                8 => {
                    try ctx.open(null);
                    continue :next_dir;
                },
                //backspace
                127 => {
                    if (current.prev) |prev| {
                        current = prev;
                        input.removeLast() catch unreachable;
                    }
                },
                //enter
                13 => {
                    if (current.idx != null) {
                        try ctx.open(current);
                        continue :next_dir;
                    }
                },
                else => {
                    if (current.next.get(c)) |node| {
                        try input.append(result);
                        current = node;
                        if (current.next.count() == 0) {
                            try ctx.open(current);
                            continue :next_dir;
                        }
                        current = try current.skip_to_junction(&input);
                    }
                },
            }
            try term.deleteLine(stdout);
            try stdout.writeAll(input.str.items);
        }
    }
    const path = try util.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    try dest.writeAll(path);
    try dest.sync();
}

//test "memleak" {
//    const allocator = std.testing.allocator;
//    var ctx = try Context.init(allocator);
//    defer ctx.deinit();
//    var dummy_map = NodeMap.init(allocator);
//    defer dummy_map.deinit();
//    var dummy_node = Node{ .next = dummy_map, .prev = null, .idx = 0 };
//    try ctx.open(null);
//    try ctx.open(&dummy_node);
//    try ctx.open(null);
//    dummy_node.idx = 3;
//    try ctx.open(&dummy_node);
//}

test "main" {
    const allocator = std.testing.allocator;
    term.enableRawMode();
    defer term.disableRawMode();
    const dest = try std.fs.createFileAbsolute("/tmp/dest", .{});
    defer dest.close();
    var input = util.StringUTF8.init(allocator);
    defer input.deinit();
    var ctx = try Context.init(allocator);
    defer ctx.deinit();
    next_dir: while (true) {
        try term.clear(stdout);
        try ctx.index.print(stdout);
        input.clear();
        var current = ctx.index.root;
        while (true) {
            const result = util.readCodepointUTF8(stdin) catch continue;
            const c = result.codepoint;
            switch (c) {
                //C-q
                17 => break :next_dir,
                //C-s
                19 => continue :next_dir,
                //C-h
                8 => {
                    try ctx.open(null);
                    continue :next_dir;
                },
                //backspace
                127 => {
                    if (current.prev) |prev| {
                        current = prev;
                        input.removeLast() catch unreachable;
                    }
                },
                //enter
                13 => {
                    if (current.idx != null) {
                        try ctx.open(current);
                        continue :next_dir;
                    }
                },
                else => {
                    if (current.next.get(c)) |node| {
                        try input.append(result);
                        current = node;
                        if (current.next.count() == 0) {
                            try ctx.open(current);
                            continue :next_dir;
                        }
                        current = try current.skip_to_junction(&input);
                    }
                },
            }
            try term.deleteLine(stdout);
            try stdout.writeAll(input.str.items);
        }
    }
    const path = try util.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    try dest.writeAll(path);
    try dest.sync();
}
