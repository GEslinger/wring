const std = @import("std");
const dprint = std.debug.print;
const Io = std.Io;
const Idx = u32; // No files over 4G
const width = 64; // Vector size for SIMD

const MAX_FILE_SIZE = 100_000_000;
const v_zero: @Vector(width, u8) = @splat(0);

fn splatVec(len: comptime_int, comptime T: type, val: anytype) @Vector(len, T) {
    return @splat(val);
}

fn idxVec(len: comptime_int, comptime T: type) @Vector(len, T) {
    var out: @Vector(len, T) = undefined;
    inline for (0..len) |i| out[i] = @truncate(i);
    return out;
}

fn anyVec(
    len: comptime_int,
    comptime T: type,
    default: anytype,
    data: anytype,
) @Vector(len, T) {
    var out: @Vector(len, T) = @splat(default);
    inline for (data, 0..) |val, i| {
        out[i] = val;
    }
}

pub fn main(init: std.process.Init) !void {
    dprint("Hello, world!\n", .{});

    // TODO: Refactor to general purpose allocator
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const iters = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 1;

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // const stdout_writer = &stdout_file_writer.interface;

    // try stdout_writer.flush(); // Don't forget to flush!
    var buf: [100]u8 = undefined;

    var file = try Io.Dir.openFile(Io.Dir.cwd(), io, args[1], .{});
    defer file.close(io);
    var file_reader = file.reader(io, &buf);

    const contents = try file_reader.interface.allocRemaining(arena, Io.Limit.limited(4_000_000_000));
    var loaded_reader: Io.Reader = .fixed(contents);

    file_reader.pos = 0; // Reset the reader

    var tag_list: [1000]Tag = undefined;

    //try wringReadXML(&file_reader.interface, tag_list[0..], 20_000_000);
    var x: i64 = 0;
    for (0..iters) |_| {
        x += try wringReadXML(&loaded_reader, tag_list[0..], 20_000_000);
        loaded_reader.seek = 0;
        file_reader.pos = 0;
    }
    dprint("{d}\n", .{x});
}

const Open = struct {
    close: *Close,
};

const Close = struct {
    result: TagType,
    chars: [2]u8,
    len: u2,
};

//const opens = @Vector(8, u8){ '!', '?', '/', 0, '-', '[', 0, 0 };
const opens = @Vector(8, u8){ 0, 0, '[', '-', 0, '/', '?', '!' };

comptime {
    const raw_delims = .{ // Priority highest to lowest
        .{ "!-", "--", TagType.Comment },
        .{ "![", "]]", TagType.Data },
        .{ "!", "", TagType.Declaration },
        .{ "?", "?", TagType.ProcessInstruction },
        .{ "/", "", TagType.Close },
        .{ "", "/", TagType.OpenClose },
    };

    if (raw_delims.len >= 32) @compileError("Too many delimiter definitions!");

    for (raw_delims) |delim_group| {
        //@compileLog(@typeName(@TypeOf(delim_group)));
        const this_type: TagType = delim_group.@"2";

        var len: usize = 0;
        for (delim_group.@"0") |char| {
            //@compileLog(char);
            _ = char;
            len += 1;
        }
        //@compileLog(this_type);
        _ = this_type;
    }
}

const Find = struct {
    start: u8,
    end: u8,
    open: []*const [3:0]u8,
    close: []*const [3:0]u8,
};

const idx_vec = idxVec(width, u8);
const wd_vec = splatVec(width, u8, width);
const zero_vec = splatVec(width, u8, 0);
const space_vec = splatVec(width, u8, ' '); // DEBUG ONLY

fn wringReadXML(reader: *std.Io.Reader, tags: []Tag, max_iters: usize) !i64 {
    _ = tags;
    var mode = Mode.FindOpen;
    var iters: usize = 0;
    var pos: usize = 0;
    pos += 0;

    var buf: [width]u8 = undefined;
    var res_arr: *[width]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    _ = &w;
    var chunk: @Vector(width, u8) = undefined;
    var tag_type: TagType = .Close;

    var foo: i64 = 0;
    foo += 0;

    var caret: u8 = width;
    const advance = width - 3;
    caret += 0;

    while (iters < max_iters) : ({
        iters += 1;
    }) {
        if (caret >= advance) {
            // Reset caret
            caret = 0;

            // Toss old bytes
            reader.toss(@min(reader.bufferedLen(), advance));

            // Read bytes
            res_arr = reader.peekArray(width) catch |err| blk: {
                switch (err) {
                    Io.Reader.Error.EndOfStream => {
                        buf = @splat(0);
                        @memcpy(buf[0..reader.bufferedLen()], reader.buffered());
                        break :blk buf[0..width];
                    },
                    else => return err,
                }
            };

            // SIMD: Load the bytes
            chunk = @bitCast(res_arr.*);
        }

        //dprint("^{d}\t{any}\t{any}\t: ", .{ caret, mode, tag_type });
        //inline for (0..width) |i| dprint("{c}", .{chunk[i]});
        //dprint("\n", .{});

        // Init
        var tag_confirmed = false;
        tag_confirmed = false;

        const match_sentinel = switch (mode) {
            .FindOpen => chunk == splatVec(width, u8, '<'),
            .FindClose => chunk == splatVec(width, u8, '>'),
        };
        const sentinel_idx = @select(
            u8,
            match_sentinel,
            idx_vec,
            wd_vec,
        );
        const first_sentinel = @reduce(.Min, sentinel_idx);

        // XML tag state machine

        if (mode == .FindClose and first_sentinel < advance) {
            const open_first: [4]u8 = @splat(res_arr[first_sentinel + 1]);
            const open_second: [4]u8 = @splat(res_arr[first_sentinel + 2]);

            const match_code: u8 = @bitCast(opens == (open_second ++ open_first));
            //dprint("{s} : {d}\n", .{ open_first ++ open_second, match_code });

            tag_type = @enumFromInt(match_code);
            mode = .FindClose;
        }

        // const closer = splatVec(
        //     width,
        //     u8,
        //     @as(u8, switch (tag_type) {
        //         .ProcessInstruction => '?',
        //         .OpenClose => '/',
        //         .Data => ']',
        //         else => ' ',
        //     }),
        // );
        // _ = closer;

        if (mode == .FindClose and first_sentinel < width) {
            mode = .FindOpen;
            tag_confirmed = true;
        }

        caret = first_sentinel + 1;

        // SIMD: Null out bytes before caret
        chunk = @select(u8, (idx_vec >= splatVec(width, u8, caret)), chunk, space_vec);

        if (tag_confirmed) {
            foo += 1;
            tag_type = .None;
        }

        if (reader.end == reader.seek) break;
    } else return ParseError.Overflow;

    //dprint("foo {d}\n", .{foo});
    reader.seek = 0;
    return foo;
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

const TagType = enum(u8) {
    Open = 0,
    OpenClose = 1,
    Close = 32,
    ProcessInstruction = 64,
    Declaration = 128,
    Comment = 136,
    Data = 132,
    None,
    _, //Invalid
};

const Mode = enum {
    FindOpen,
    FindClose,
};

const ParseError = error{
    Overflow,
    Unclosed,
    BadTag,
    BadClose,
};
