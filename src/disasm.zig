//! The disassembler.
//!
//! This module writes the bytes of a program as text a person can read. It is the
//! other direction of `encode`, and it takes the mnemonic and the operand kind of
//! each instruction from the same table that the assembler reads. Therefore a new
//! instruction appears here with no change to this file.
//!
//! The listing is for reading and not for assembling again. It names an address by
//! its number, because the bytes hold no label: a label is a name that the source
//! had and the container does not keep. Every operand is written in the form the
//! assembler accepts for that instruction, so a line can be copied into a source
//! file and changed by hand.
//!
//! A code region can hold a byte that no instruction reaches. The verifier ignores
//! such a byte and the VM never runs it, but a listing must show it rather than
//! stop. Therefore a byte that does not decode is written as its value and the
//! listing continues at the byte after it.

const std = @import("std");
const container = @import("container.zig");
const encode = @import("encode.zig");
const opcode = @import("opcode.zig");

const OpCode = opcode.OpCode;
const Writer = std.Io.Writer;

pub const Options = struct {
    /// Write the bytes of each instruction between the offset and the mnemonic. A
    /// listing that shows them says what the file holds as well as what it means,
    /// which is what a person comparing two builds needs.
    show_bytes: bool = true,
    /// Mark this offset as the place the program starts. A container names one, and
    /// a bare code region has none.
    entry_point: ?u32 = null,
    /// The names of the foreign imports, in the order of the import table. A
    /// `foreign_call` then names its import as the source did rather than by number.
    /// An index with no name here is written as a number.
    import_names: []const []const u8 = &.{},
};

/// Write the mnemonic and the operand of one instruction, with no offset and no
/// bytes. This is the text after the columns in a listing.
pub fn writeInstruction(
    writer: *Writer,
    instruction: encode.Instruction,
    options: Options,
) Writer.Error!void {
    try writer.writeAll(instruction.code.mnemonic());

    switch (instruction.operand) {
        .none => {},
        .signed => |value| try writer.print(" {d}", .{value}),
        .signed64 => |value| try writer.print(" {d}", .{value}),
        .data_address, .code_target => |address| try writer.print(" {d}", .{address}),
        .data_address64, .code_target64 => |address| try writer.print(" {d}", .{address}),
        .local_index => |index| try writer.print(" {d}", .{index}),
        .frame_shape => |shape| try writer.print(" {d} {d}", .{ shape.arguments, shape.locals }),
        .import_index => |index| {
            // The name is what the source wrote and what the assembler reads back.
            // A container whose import table this listing does not have leaves the
            // number, which is what the instruction holds.
            if (index < options.import_names.len) {
                try writer.print(" {s}", .{options.import_names[index]});
            } else {
                try writer.print(" {d}", .{index});
            }
        },
    }
}

/// Write `code` as a listing, one line for each instruction.
pub fn writeCode(writer: *Writer, code: []const u8, options: Options) Writer.Error!void {
    var offset: usize = 0;
    while (offset < code.len) {
        if (options.entry_point) |entry| {
            if (entry == offset) try writer.writeAll("        ; entry point\n");
        }

        const instruction = encode.decode(code, offset) catch {
            // The byte has no instruction, or the operand of one runs past the end of
            // the region. Either way this byte is not the start of something to
            // decode, so the listing shows the byte itself and goes on to the next.
            try writeOffset(writer, offset);
            if (options.show_bytes) try writeBytes(writer, code[offset..][0..1]);
            try writer.print("i8 {d}\n", .{code[offset]});
            offset += 1;
            continue;
        };

        try writeOffset(writer, offset);
        if (options.show_bytes) try writeBytes(writer, code[offset..instruction.end()]);
        try writeInstruction(writer, instruction, options);
        try writer.writeByte('\n');

        offset = instruction.end();
    }
}

/// Write a whole program: what the header says, then each import, then the code, then
/// the static data.
pub fn writeImage(writer: *Writer, image: container.Image, options: Options) !void {
    try writer.print(
        "; {d} bytes of code, {d} of static data, {d} zero-filled\n",
        .{ image.code.len, image.data.len, image.header.bss_len },
    );

    var iterator = image.importIterator();
    var index: usize = 0;
    while (try iterator.next()) |import| : (index += 1) {
        try writer.print("extern {s} {s} {s}", .{ import.symbol, import.library, import.symbol });
        for (import.argTypes()) |arg_type| try writer.print(" {s}", .{arg_type.name()});
        try writer.writeByte('\n');
    }

    var with_entry = options;
    if (with_entry.entry_point == null and image.kind.separatesData()) {
        with_entry.entry_point = image.header.entry_point;
    }
    try writeCode(writer, image.code, with_entry);

    if (image.data.len > 0) {
        try writer.print("; static data at {d}\n", .{image.code.len});
        try writeData(writer, image.data, image.code.len, options);
    }
}

/// Write the static-data region. A run of printable bytes that ends in a NUL is
/// written as the string it is, because that is what put it there. Anything else is
/// written as its bytes.
pub fn writeData(
    writer: *Writer,
    data: []const u8,
    base: usize,
    options: Options,
) Writer.Error!void {
    var offset: usize = 0;
    while (offset < data.len) {
        if (stringAt(data, offset)) |text| {
            try writeOffset(writer, base + offset);
            if (options.show_bytes) try writeBytes(writer, data[offset..][0 .. text.len + 1]);
            try writer.print("asciiz \"{s}\"\n", .{text});
            offset += text.len + 1;
            continue;
        }

        // A row of bytes, as many as the byte column holds. The row also stops where
        // the next string begins, so a string that follows raw bytes is still shown
        // as a string.
        const start = offset;
        while (offset < data.len and offset - start < byte_columns and stringAt(data, offset) == null) {
            offset += 1;
        }

        try writeOffset(writer, base + start);
        if (options.show_bytes) try writeBytes(writer, data[start..offset]);
        try writer.writeAll("i8 ");
        for (data[start..offset], 0..) |byte, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.print("{d}", .{byte});
        }
        try writer.writeByte('\n');
    }
}

/// The NUL-terminated printable string at `offset`, without its terminator, or null
/// if the bytes there are not one. A string of no characters is not reported: a lone
/// NUL byte is more likely padding than an empty string.
fn stringAt(data: []const u8, offset: usize) ?[]const u8 {
    const end = std.mem.indexOfScalarPos(u8, data, offset, 0) orelse return null;
    if (end == offset) return null;

    for (data[offset..end]) |byte| {
        if (byte < ' ' or byte > '~' or byte == '"') return null;
    }
    return data[offset..end];
}

fn writeOffset(writer: *Writer, offset: usize) Writer.Error!void {
    try writer.print("{x:0>4}  ", .{offset});
}

/// The width of the byte column, which is the length of the longest instruction.
const byte_columns = 5;

/// Write the bytes of one instruction, padded to that width. Therefore the
/// mnemonics of a listing line up.
fn writeBytes(writer: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |byte| try writer.print("{x:0>2} ", .{byte});
    if (bytes.len < byte_columns) try writer.splatByteAll(' ', (byte_columns - bytes.len) * 3);
    try writer.writeAll(" ");
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

fn expectListing(code: []const u8, options: Options, expected: []const u8) !void {
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    try writeCode(&output.writer, code, options);
    try testing.expectEqualStrings(expected, output.written());
}

/// The text of one instruction, with no offset and no bytes.
fn expectText(code: []const u8, expected: []const u8) !void {
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    try writeInstruction(&output.writer, try encode.decode(code, 0), .{});
    try testing.expectEqualStrings(expected, output.written());
}

test "each operand kind is written in the form the assembler reads" {
    var buffer: [8]u8 = undefined;

    _ = try encode.encode(&buffer, .halt, .none);
    try expectText(&buffer, "halt");

    _ = try encode.encode(&buffer, .push, .{ .signed = -42 });
    try expectText(&buffer, "push -42");

    _ = try encode.encode(&buffer, .load, .{ .data_address = 64 });
    try expectText(&buffer, "load 64");

    _ = try encode.encode(&buffer, .jmp, .{ .code_target = 17 });
    try expectText(&buffer, "jmp 17");

    _ = try encode.encode(&buffer, .load_local, .{ .local_index = 3 });
    try expectText(&buffer, "load_local 3");

    // `enter` is the one instruction with two operands, and they are written in the
    // order the assembler reads them.
    _ = try encode.encode(&buffer, .enter, .{ .frame_shape = .{ .arguments = 2, .locals = 1 } });
    try expectText(&buffer, "enter 2 1");
}

test "a foreign call names its import when the listing has the table" {
    var buffer: [8]u8 = undefined;
    _ = try encode.encode(&buffer, .foreign_call, .{ .import_index = 1 });

    var named: Writer.Allocating = .init(testing.allocator);
    defer named.deinit();
    try writeInstruction(&named.writer, try encode.decode(&buffer, 0), .{
        .import_names = &.{ "first", "MessageBoxA" },
    });
    try testing.expectEqualStrings("foreign_call MessageBoxA", named.written());

    // Without the table the number is all the instruction holds.
    try expectText(&buffer, "foreign_call 1");
}

test "a listing gives the offset and the bytes of each instruction" {
    const code = &(pushBytes(42) ++ [_]u8{ @intFromEnum(OpCode.print), @intFromEnum(OpCode.halt) });

    try expectListing(code, .{}, "0000  01 2a 00 00 00  push 42\n" ++
        "0005  04              print\n" ++
        "0006  00              halt\n");

    // Without the bytes the listing is the offset and the instruction.
    try expectListing(code, .{ .show_bytes = false }, "0000  push 42\n" ++
        "0005  print\n" ++
        "0006  halt\n");
}

test "the entry point is marked where it is" {
    const code = &([_]u8{@intFromEnum(OpCode.halt)} ++ pushBytes(1) ++
        [_]u8{@intFromEnum(OpCode.halt)});

    try expectListing(code, .{ .show_bytes = false, .entry_point = 1 }, "0000  halt\n" ++
        "        ; entry point\n" ++
        "0001  push 1\n" ++
        "0006  halt\n");
}

test "a byte that does not decode is written and the listing continues" {
    // 0xfe has no instruction. The byte after it does, and a listing that stopped
    // would hide it. The unknown byte is written as the data directive that puts
    // that byte back.
    const code = &[_]u8{ 0xfe, @intFromEnum(OpCode.halt) };
    try expectListing(code, .{ .show_bytes = false }, "0000  i8 254\n" ++
        "0001  halt\n");

    // The last instruction of the region is cut short. Its opcode byte is known but
    // its operand is not there, so the byte is all the listing can show. The listing
    // then starts again at the next byte, which here is an operand byte that happens
    // to decode. A listing shows the bytes of a region and does not claim to know
    // which of them a program can reach; the verifier is what knows that.
    const truncated = &[_]u8{ @intFromEnum(OpCode.push), 1, 0 };
    try expectListing(truncated, .{ .show_bytes = false }, "0000  i8 1\n" ++
        "0001  i8 1\n" ++
        "0002  halt\n");
}

test "the static data shows a string as a string" {
    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    // A string, then two bytes that are not one, then a second string. The base is
    // the length of the code, so the offsets are the addresses in memory.
    try writeData(&output.writer, "hi\x00\x01\x02ok\x00", 16, .{ .show_bytes = false });
    try testing.expectEqualStrings(
        \\0010  asciiz "hi"
        \\0013  i8 1, 2
        \\0015  asciiz "ok"
        \\
    , output.written());
}

test "a whole image reports its regions and its imports" {
    const code = [_]u8{ @intFromEnum(OpCode.foreign_call), 0, @intFromEnum(OpCode.halt) };
    var imports = [_]@import("foreign.zig").Import{
        .{ .library = "kernel32.dll", .symbol = "GetCurrentProcessId" },
    };

    const layout: container.Layout = .{
        .imports = &imports,
        .code = &code,
        .data = "hi\x00",
        .bss_len = 8,
        .entry_point = 0,
    };
    const bytes = try testing.allocator.alloc(u8, try container.encodedSize(layout));
    defer testing.allocator.free(bytes);
    std.debug.assert(try container.write(layout, bytes) == bytes.len);

    var output: Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try writeImage(&output.writer, try container.parse(bytes), .{
        .show_bytes = false,
        .import_names = &.{"GetCurrentProcessId"},
    });

    try testing.expectEqualStrings(
        \\; 3 bytes of code, 3 of static data, 8 zero-filled
        \\extern GetCurrentProcessId kernel32.dll GetCurrentProcessId
        \\        ; entry point
        \\0000  foreign_call GetCurrentProcessId
        \\0002  halt
        \\; static data at 3
        \\0003  asciiz "hi"
        \\
    , output.written());
}

/// `push value` as bytes, so a test can write a program without the encoder.
fn pushBytes(value: i32) [5]u8 {
    var bytes: [5]u8 = undefined;
    bytes[0] = @intFromEnum(OpCode.push);
    std.mem.writeInt(i32, bytes[1..5], value, .little);
    return bytes;
}
