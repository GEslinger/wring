const std = @import("std");
const dprint = std.debug.print;
const Io = std.Io;
const Idx = u32;

const MAX_FILE_SIZE = 100_000_000;

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
    var buf: [65536]u8 = undefined;

    var file = try Io.Dir.openFile(Io.Dir.cwd(), io, args[1], .{});
    defer file.close(io);
    var f_reader = file.reader(io, &buf);

    const contents = try f_reader.interface.allocRemaining(arena, Io.Limit.limited(MAX_FILE_SIZE));
    //dprint("{s}\n", .{contents[0..30]});
    // var line_iterator = std.mem.tokenizeAny(u8, contents, "\r\n");

    var scope_list: [1000000]Scope = undefined;
    var scopes: []Scope = scope_list[0..0];

    {
        var stack: [65536]Idx = undefined;
        var stack_len: u64 = 0;

        // Loop setup
        var loops: u64 = 0;
        var depth: u64 = 0;
        var head: u64 = 0;
        var tail: u64 = 0;

        try while (true) : (loops += 1) {
            head = tail + (std.mem.find(u8, contents[tail..], "<") orelse break);

            const fmt_char = if (head + 1 < contents.len) contents[head + 1] else break ParseError.BadTag;
            const check = contents[head..];

            const open_type: TagType = switch (fmt_char) {
                '/' => .Close,
                '?' => .ProcessInstruction,
                '!' => blk: {
                    if (check.len < 4) break :blk .Declaration;
                    if (std.mem.eql(u8, check[0..3], "<!--")) break :blk .Comment;
                    if (check.len < 9) break :blk .Declaration;
                    if (std.mem.eql(u8, check[0..9], "<![CDATA[")) break :blk .Data;
                    break :blk .Declaration;
                },
                else => .Open,
            };

            tail = head + switch (open_type) {
                .Data => 3 + (std.mem.find(u8, check, "]]>") orelse break ParseError.Unclosed),
                .Comment => 3 + (std.mem.find(u8, check, "-->") orelse break ParseError.Unclosed),
                .ProcessInstruction => 2 + (std.mem.find(u8, check, "?>") orelse break ParseError.Unclosed),
                else => 1 + (std.mem.find(u8, check, ">") orelse break ParseError.Unclosed),
            };

            const tag_type = if (open_type == .Open and contents[tail - 2] == '/') .OpenClose else open_type;

            if (tag_type == .Open) depth += 1;
            if (tag_type == .Close) depth -= 1;

            const element = switch (tag_type) {
                .Data => contents[head + 9 .. tail - 3],
                .Comment => contents[head + 4 .. tail - 3],
                .ProcessInstruction => contents[head + 2 .. tail - 2],
                .Open => contents[head + 1 .. tail - 1],
                .Close => contents[head + 2 .. tail - 1],
                .OpenClose => contents[head + 1 .. tail - 2],
                .Declaration => contents[head + 1 .. tail - 2],
            };

            //dprint("Type: {any}, Stack Len: {d}, Scopes: {d}, Slice {d}-{d}, {s}\n", .{ tag_type, stack_len, scopes.len, head, tail, element });
            switch (tag_type) {
                .Open, .OpenClose => {
                    var attribute_iterator = std.mem.tokenizeAny(u8, element, " ");
                    const name = attribute_iterator.next().?;

                    scopes.len += 1;
                    scopes[scopes.len - 1] = Scope{
                        .name = name,
                        .parent = if (stack_len > 0) stack[stack_len - 1] else null,
                    };

                    if (tag_type == .Open) { // Push
                        stack[stack_len] = @truncate(scopes.len - 1);
                        stack_len += 1;
                    }

                    while (attribute_iterator.next()) |pair| { // Do stuff
                        _ = pair;
                    }

                    // Tags
                    if (std.mem.eql(u8, name, "Tag")) {}
                },
                .Close => { // Pop
                    if (stack_len == 0) break ParseError.BadClose;
                    if (!std.mem.eql(u8, element, scopes[stack[stack_len - 1]].name)) {
                        printScope(stack[stack_len - 1], scopes);
                        break ParseError.BadClose;
                    }
                    stack_len -= 1;
                },
                else => {},
            }

            //if (loops > 100000) break ParseError.Overflow;
        };

        if (depth != 0) return ParseError.Unclosed;
    }

    // ??
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
