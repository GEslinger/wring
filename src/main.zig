const std = @import("std");
const dprint = std.debug.print;
const Io = std.Io;
const Idx = u32; // No files over 4G
const ByteChunk = 32; // Vector size for SIMD

const MAX_FILE_SIZE = 100_000_000;

pub fn main(init: std.process.Init) !void {
    dprint("Hello, world!\n", .{});

    // TODO: Refactor to general purpose allocator
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // const stdout_writer = &stdout_file_writer.interface;

    // try stdout_writer.flush(); // Don't forget to flush!
    var buf: [1024]u8 = undefined;

    var file = try Io.Dir.openFile(Io.Dir.cwd(), io, args[1], .{});
    defer file.close(io);
    var file_reader = file.reader(io, &buf);

    const contents = try file_reader.interface.allocRemaining(arena, Io.Limit.limited(MAX_FILE_SIZE));
    dprint("{s}\n", .{contents[0..30]});
    file_reader.pos = 0; // Reset the reader

    var tag_list: [1000]Tag = undefined;

    var open = [_]*const [3:0]u8{
        "/..",
        "?..",
        "!--",
        "![C",
        "...",
        "...",
    };

    var close = [_]*const [3:0]u8{
        "...",
        "..?",
        ".--",
        ".]]",
        "../",
        "...",
    };

    var zero: usize = 0;
    _ = &zero;
    const parser = Find{
        .start = '<',
        .end = '>',
        .open = open[zero..open.len],
        .close = close[zero..close.len],
    };
    try wringReadXML(&file_reader.interface, parser, tag_list[0..]);
}

const Find = struct {
    start: u8,
    end: u8,
    open: []*const [3:0]u8,
    close: []*const [3:0]u8,
};

fn wringReadXML(reader: *std.Io.Reader, pat: Find, tags: []Tag) !void {
    _ = tags;
    var search_char = pat.start;
    _ = &search_char;

    var search: @Vector(ByteChunk, u8) = @splat(pat.start);
    _ = &search;

    const equal: @Vector(ByteChunk, u8) = @splat('=');
    const quote: @Vector(ByteChunk, u8) = @splat('"');
    const idx: @Vector(ByteChunk, i8) = blk: {
        var vec: [ByteChunk]i8 = undefined;
        var i: i8 = 0;
        while (i < ByteChunk) : (i += 1) vec[@intCast(i)] = i;
        break :blk vec;
    };
    const neg_one: @Vector(ByteChunk, i8) = @splat(-1);
    _ = equal;
    _ = quote;

    var loops: u64 = 0;
    var pos: Idx = 0;
    var chunk: @Vector(ByteChunk, u8) = undefined;

    while (loops < 1_000_000) : (loops += 1) {
        // Read chunk
        var buf: [ByteChunk]u8 = undefined;
        const bytes_read: Idx = @truncate(try reader.readSliceShort(buf[0..]));
        chunk = @bitCast(buf);

        // Make sure not reading too much and track pos
        const next_pos: Idx = try blk: {
            var added: Idx = 0;
            var overflow: u1 = 0;
            added, overflow = @addWithOverflow(pos, bytes_read);
            if (overflow == 1) break :blk ParseError.Overflow;
            break :blk added;
        };

        // Find characters of interest
        const found = @select(i8, chunk == search, idx, neg_one);

        dprint(
            "Current pos: {d}\tChunk len {d}\t Contents: \n{s}\n",
            .{ pos, bytes_read, buf[0..bytes_read] },
        );

        inline for (0..ByteChunk) |offset| {
            if (found[offset] >= 0) dprint("{d} ", .{found[offset]});
        }
        dprint("\n", .{});

        pos = next_pos;
        if (bytes_read < ByteChunk) break;
    } else return ParseError.Overflow;
}

fn printScope(start_idx: usize, scopes: []Scope) void {
    var scope = scopes[start_idx];
    var i: u64 = 0;
    while (scope.parent) |next| : (scope = scopes[next]) {
        dprint("{s}\\", .{scope.name});
        if (i > 10) break;
        i += 1;
    }
    dprint("{s}\n", .{scope.name});
}

const Tag = struct {
    scope: Idx,
    parent: ?Idx,
    start: Idx,
    type: u16,
    flags: TagFlags,
};

const TagFlags = enum(u16) {};

const Scope = struct {
    parent: ?Idx = null,
    name: []const u8,
};

const TagType = enum {
    Open,
    Close,
    OpenClose,
    ProcessInstruction,
    Comment,
    Data,
    Declaration,
};

const ParseError = error{
    Overflow,
    Unclosed,
    BadTag,
    BadClose,
};
