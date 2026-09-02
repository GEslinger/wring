const std = @import("std");
const dprint = std.debug.print;
const Io = std.Io;
const Idx = u32; // No files over 4G
const width = 32; // Vector size for SIMD

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
    for (0..1_000) |_| {
        x += try wringReadXML(&file_reader.interface, tag_list[0..], 20_000_000);
        loaded_reader.seek = 0;
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

/// Fills the chunk vector with peeked bytes from the reader,
/// returning the number of bytes read.
fn wringFillChunk(reader: *std.Io.Reader, chunk: *@Vector(width, u8)) !usize {
    var buf: [width]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const bytes_read = reader.stream(
        &w,
        Io.Limit.limited(width),
    ) catch |err| switch (err) {
        Io.Reader.Error.EndOfStream => reader.seek,
        else => return err,
    };

    chunk.* = @bitCast(buf);
    return bytes_read;
}

const idx_vec = idxVec(width, u8);
const wd_vec = splatVec(width, u8, width);
const zero_vec = splatVec(width, u8, 0);

fn wringReadXML(reader: *std.Io.Reader, tags: []Tag, max_iters: usize) !i64 {
    _ = tags;
    var mode = Mode.FindOpen;
    var iters: usize = 0;
    var pos: usize = 0;

    var buf: [width]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    _ = &w;
    var chunk: @Vector(width, u8) = undefined;
    var end_of_stream = false;
    var tag_type: TagType = .Close;

    var foo: i64 = 0;
    foo += 0;

    var tag_start: usize = 0;
    var tag_end: usize = 0;

    while (iters < max_iters) : (iters += 1) {
        // Stream from reader into buffer
        // reader.streamExact(
        //     &w,
        //     width - bytes_read,
        // ) catch |err| switch (err) {
        //     Io.Reader.Error.EndOfStream => end_of_stream = true,
        //     else => return err,
        // };
        dprint("e:{d} s:{d}\n", .{ reader.end, reader.seek });
        const res_arr = reader.peekArray(width) catch return foo;
        const bytes_read = reader.bufferedLen();
        end_of_stream = bytes_read == 0;

        // SIMD: Load the bytes
        chunk = @bitCast(res_arr.*);

        // SIMD: Exclude stale bytes past the end of the valid buffer length
        // Maybe can eliminate? we have bytes_read after all...
        chunk = @select(
            u8,
            (idxVec(width, u8) <
                splatVec(width, u8, @as(u8, @truncate(bytes_read)))), // width < 255
            chunk,
            zero_vec,
        );

        // Print
        dprint("Foo: {d}, Mode {any}, Tag {any}, Chunk: ", .{ bytes_read, mode, (if (mode == .FindClose) tag_type else null) });
        inline for (0..width) |i| dprint("{c}", .{chunk[i]});
        dprint("\n", .{});
        dprint("e:{d} s:{d}\n\n", .{ reader.end, reader.seek });

        // Init
        var tag_confirmed = false;

        // XML tag state machine
        const consumed: usize = sw: switch (mode) {
            .FindOpen => {
                //foo += @reduce(.Add, @intFromBool(chunk == splatVec(width, u8, '<')));

                const match_open = (chunk == splatVec(width, u8, '<'));
                const open_idx = @select(
                    u8,
                    match_open,
                    idx_vec,
                    wd_vec,
                );
                const first_open = @reduce(.Min, open_idx);

                if (first_open < width) mode = .OpenType;
                break :sw first_open + 1;
            },
            .OpenType => {
                const open_chars = @Vector(8, u8){ 1, 1, buf[1], buf[1], 1, buf[0], buf[0], buf[0] };
                const match_first = opens == open_chars;
                const match_code: u8 = @bitCast(match_first);
                tag_type = @enumFromInt(match_code);

                mode = .FindClose;
                tag_start = pos;
                break :sw 0;
            },
            .FindClose => {
                //foo -= @reduce(.Add, @intFromBool(chunk == splatVec(width, u8, '>')));

                const match_close = (chunk == splatVec(width, u8, '>'));
                const close_idx = @select(
                    u8,
                    match_close,
                    idx_vec,
                    wd_vec,
                );
                const first_close = @reduce(.Min, close_idx);

                if (first_close > 1 and first_close < width) {
                    const pre1 = buf[first_close - 1];

                    switch (tag_type) {
                        .ProcessInstruction => {
                            if (pre1 == '?') tag_confirmed = true;
                        },
                        .Comment => {
                            const pre2 = buf[first_close - 2];
                            if (pre1 == '-' and pre2 == '-') tag_confirmed = true;
                        },
                        .Data => {
                            const pre2 = buf[first_close - 2];
                            if (pre1 == ']' and pre2 == ']') tag_confirmed = true;
                        },
                        else => {
                            if (pre1 == '/') {
                                tag_type = .OpenClose;
                            }
                            tag_confirmed = true;
                        },
                    }
                }

                if (tag_confirmed) {
                    mode = .FindOpen;
                    tag_end = pos + first_close - 1;
                }

                if (bytes_read == 0 and end_of_stream) return ParseError.Unclosed;

                // Advance slower to not miss the close
                break :sw @min(width - 3, first_close + 1);
            },
        };

        if (tag_confirmed) {
            //dprint("{any} : {d} : {d}\n", .{ tag_type, tag_start, tag_end });
            foo += 1;
        }

        pos += consumed;
        //_ = w.consume(consumed);
        reader.toss(consumed);
        if (bytes_read == 0 and end_of_stream) break;
    } else return ParseError.Overflow;

    //dprint("foo {d}\n", .{foo});
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
    OpenClose = 1,
    Close = 32,
    ProcessInstruction = 64,
    Declaration = 128,
    Comment = 136,
    Data = 132,
    _, // Open
};

const Mode = enum {
    FindOpen,
    OpenType,
    FindClose,
};

const ParseError = error{
    Overflow,
    Unclosed,
    BadTag,
    BadClose,
};
