const std = @import("std");
const dprint = std.debug.print;
const Io = std.Io;

const MAX_FILE_SIZE = 1_000_000;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    dprint("Hello, world!\n", .{});

    // This is appropriate for anything that lives as long as the process.
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
    var f_reader = file.reader(io, &buf);

    const contents = try f_reader.interface.allocRemaining(arena, Io.Limit.limited(MAX_FILE_SIZE));
    dprint("{s}\n", .{contents[0..30]});
    f_reader.pos = 0;
    // var line_iterator = std.mem.tokenizeAny(u8, contents, "\r\n");

    // // Print 3 lines
    // dprint("First 3 lines:\n", .{});
    // for (0..2) |_| {
    //     dprint("{s}\n", .{line_iterator.next().?});
    // }
    // line_iterator.reset();

    // Loop setup
    var parsing = true;
    parsing = true;
    var loops: u64 = 0;
    var depth: u64 = 0;

    try parse: while (parsing == true) : (loops += 1) {

        // Begin to parse, looking for <
        _ = f_reader.interface.takeDelimiterInclusive('<') catch break;

        const next_char = f_reader.interface.peek(1) catch break ParseError.BadTag;
        var tag_type: TagType = switch (next_char[0]) {
            '?' => .ProcessInstruction,
            '/' => .Close,
            '!' => blk: {
                const check_comment = f_reader.interface.peek(3) catch break :parse ParseError.BadTag;
                if (std.mem.eql(u8, check_comment, "!--")) break :blk .Comment;
                const check_data = f_reader.interface.peek(8) catch break :blk .Declaration;
                if (std.mem.eql(u8, check_data, "![CDATA[")) break :blk .Data;
                break :blk .Declaration;
            },
            else => .Open,
        };

        const tag: []u8 = try switch (tag_type) {
            // TODO: Enforce proper ending of all tag types
            else => f_reader.interface.takeDelimiterExclusive('>') catch ParseError.Unclosed,
        };

        if (tag.len < 1) break ParseError.BadTag;
        if (tag[tag.len - 1] == '/') tag_type = .OpenClose;

        if (tag_type == .Open) depth += 1;
        if (tag_type == .Close) depth -= 1;

        dprint("D: {d}, Type: {any}, Len {d}, chars: {s}\n", .{ depth, tag_type, tag.len, tag });

        if (loops > 1000) {
            dprint("TOO MANY LOOPS!\n", .{});
            break ParseError.Overflow;
        }
    };

    if (depth != 0) return ParseError.Unclosed;
}

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
};
