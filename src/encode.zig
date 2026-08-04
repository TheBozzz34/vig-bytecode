//! How to encode an instruction and how to decode it.
//!
//! This one module holds the rules that change an instruction into bytes. It
//! also holds the rules that change those bytes into an instruction again.
//! Therefore the output stage of the assembler and the verifier of the VM cannot
//! disagree about the width or the sign of an operand.

const std = @import("std");
const opcode = @import("opcode.zig");

const OpCode = opcode.OpCode;
const OperandKind = opcode.OperandKind;

pub const Error = error{
    UnknownOpcode,
    /// The operand of the instruction continues past the end of the code
    /// region.
    TruncatedInstruction,
    /// The given operand is not the operand kind of the opcode.
    OperandKindMismatch,
    BufferTooSmall,
};

/// A decoded operand. The tags are the same as the values of `OperandKind`.
/// Therefore `encode` can find an operand that the opcode cannot hold.
pub const Operand = union(enum) {
    none,
    signed: i32,
    data_address: u32,
    code_target: u32,
    import_index: u8,

    pub fn kind(self: Operand) OperandKind {
        return switch (self) {
            .none => .none,
            .signed => .signed,
            .data_address => .data_address,
            .code_target => .code_target,
            .import_index => .import_index,
        };
    }
};

pub const Instruction = struct {
    code: OpCode,
    operand: Operand,
    /// The offset of the opcode byte in the code region that supplied it.
    offset: usize,
    /// The length of the instruction in bytes. This length includes the opcode
    /// byte.
    size: usize,

    /// The offset of the first byte after this instruction. Execution continues
    /// at this offset if the instruction does not move control.
    pub fn end(self: Instruction) usize {
        return self.offset + self.size;
    }

    /// The absolute code offset that this instruction moves control to. The
    /// result is null if the instruction does not move control.
    pub fn codeTarget(self: Instruction) ?u32 {
        return switch (self.operand) {
            .code_target => |target| target,
            else => null,
        };
    }
};

/// Decode the instruction at `offset` in `code`.
pub fn decode(code: []const u8, offset: usize) Error!Instruction {
    if (offset >= code.len) return error.TruncatedInstruction;

    const instruction = try OpCode.fromByte(code[offset]);
    const size = instruction.size();
    if (code.len - offset < size) return error.TruncatedInstruction;

    const bytes = code[offset + 1 ..];
    return .{
        .code = instruction,
        .offset = offset,
        .size = size,
        .operand = switch (instruction.operandKind()) {
            .none => .none,
            .signed => .{ .signed = std.mem.readInt(i32, bytes[0..4], .little) },
            .data_address => .{ .data_address = std.mem.readInt(u32, bytes[0..4], .little) },
            .code_target => .{ .code_target = std.mem.readInt(u32, bytes[0..4], .little) },
            .import_index => .{ .import_index = bytes[0] },
        },
    };
}

/// Encode one instruction at the start of `dest`. The function gives the number
/// of bytes that it wrote.
pub fn encode(dest: []u8, code: OpCode, operand: Operand) Error!usize {
    if (operand.kind() != code.operandKind()) return error.OperandKindMismatch;

    const size = code.size();
    if (dest.len < size) return error.BufferTooSmall;

    dest[0] = @intFromEnum(code);
    switch (operand) {
        .none => {},
        .signed => |value| std.mem.writeInt(i32, dest[1..5], value, .little),
        .data_address, .code_target => |value| std.mem.writeInt(u32, dest[1..5], value, .little),
        .import_index => |index| dest[1] = index,
    }
    return size;
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

fn expectRoundTrip(code: OpCode, operand: Operand) !void {
    var buffer: [8]u8 = undefined;
    const size = try encode(&buffer, code, operand);
    try testing.expectEqual(code.size(), size);

    const decoded = try decode(buffer[0..size], 0);
    try testing.expectEqual(code, decoded.code);
    try testing.expectEqual(operand, decoded.operand);
    try testing.expectEqual(size, decoded.size);
    try testing.expectEqual(@as(usize, 0), decoded.offset);
    try testing.expectEqual(size, decoded.end());
}

test "every operand kind round-trips" {
    try expectRoundTrip(.halt, .none);
    try expectRoundTrip(.push, .{ .signed = -42 });
    try expectRoundTrip(.push, .{ .signed = std.math.minInt(i32) });
    try expectRoundTrip(.load, .{ .data_address = 255 });
    try expectRoundTrip(.jmp, .{ .code_target = std.math.maxInt(u32) });
    try expectRoundTrip(.foreign_call, .{ .import_index = 3 });
}

test "operands are little-endian and follow the opcode byte" {
    var buffer: [5]u8 = undefined;
    _ = try encode(&buffer, .push, .{ .signed = -42 });
    try testing.expectEqualSlices(u8, &.{ 1, 0xd6, 0xff, 0xff, 0xff }, &buffer);
}

test "decoding reports the target of a control transfer" {
    var buffer: [5]u8 = undefined;
    _ = try encode(&buffer, .call, .{ .code_target = 17 });
    try testing.expectEqual(@as(?u32, 17), (try decode(&buffer, 0)).codeTarget());

    _ = try encode(&buffer, .push, .{ .signed = 17 });
    try testing.expectEqual(@as(?u32, null), (try decode(&buffer, 0)).codeTarget());
}

test "decoding starts at an arbitrary offset" {
    const code = [_]u8{ 0, 0, @intFromEnum(OpCode.foreign_call), 7 };
    const decoded = try decode(&code, 2);
    try testing.expectEqual(OpCode.foreign_call, decoded.code);
    try testing.expectEqual(Operand{ .import_index = 7 }, decoded.operand);
    try testing.expectEqual(@as(usize, 4), decoded.end());
}

test "decoding rejects unknown opcodes and truncated operands" {
    try testing.expectError(error.UnknownOpcode, decode(&[_]u8{0xfe}, 0));
    try testing.expectError(error.TruncatedInstruction, decode(&[_]u8{}, 0));
    try testing.expectError(error.TruncatedInstruction, decode(&[_]u8{ 0, 0 }, 2));
    // `push` needs four operand bytes. Only three bytes come after it.
    try testing.expectError(error.TruncatedInstruction, decode(&[_]u8{ 1, 0, 0, 0 }, 0));
    try testing.expectError(
        error.TruncatedInstruction,
        decode(&[_]u8{@intFromEnum(OpCode.foreign_call)}, 0),
    );
}

test "encoding rejects an operand the opcode cannot carry" {
    var buffer: [8]u8 = undefined;
    try testing.expectError(error.OperandKindMismatch, encode(&buffer, .halt, .{ .signed = 1 }));
    try testing.expectError(error.OperandKindMismatch, encode(&buffer, .push, .none));
    // `jmp` takes a code offset. A data address is a different kind of operand.
    try testing.expectError(error.OperandKindMismatch, encode(&buffer, .jmp, .{ .data_address = 4 }));
    try testing.expectError(error.BufferTooSmall, encode(buffer[0..3], .push, .{ .signed = 1 }));
}
