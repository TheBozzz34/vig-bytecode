//! The identity and the metadata of an opcode.
//!

const std = @import("std");

/// Each VIG instruction.
pub const OpCode = enum(u8) {
    halt = 0,
    push = 1,
    add = 2,
    sub = 3,
    print = 4,
    dup = 5,
    pop = 6,
    swap = 7,
    mul = 8,
    div = 9,
    mod = 10,
    eq = 11,
    ne = 12,
    lt = 13,
    lte = 14,
    gt = 15,
    gte = 16,
    jmp = 17,
    jmp_zero = 18,
    jmp_not_zero = 19,
    load = 20,
    store = 21,
    call = 22,
    ret = 23,
    foreign_call = 24, // ffi
    print_string = 25,
    load_at = 26,
    store_at = 27,
    @"and" = 28,
    @"or" = 29,
    xor = 30,
    not = 31,
    shl = 32,
    shr_u = 33,
    rotl = 34,
    add_wrap = 35,
    read_i32 = 36,
    read_byte = 37,
    print_hex = 38,
    write_byte = 39,

    // Byte-addressed access to guest memory
    load8_u = 40,
    load8_s = 41,
    load16_u = 42,
    load16_s = 43,
    load32 = 44,
    store8 = 45,
    store16 = 46,
    store32 = 47,

    /// Decode an opcode byte. The function gives an error for a byte that has
    /// no instruction. It does not ignore that byte.
    pub fn fromByte(byte: u8) error{UnknownOpcode}!OpCode {
        return std.enums.fromInt(OpCode, byte) orelse error.UnknownOpcode;
    }

    /// Find the instruction that has this assembler mnemonic.
    pub fn fromMnemonic(text: []const u8) ?OpCode {
        for (table) |entry| {
            if (std.mem.eql(u8, text, entry.mnemonic)) return entry.code;
        }
        return null;
    }

    pub fn info(self: OpCode) Info {
        return table[@intFromEnum(self)];
    }

    pub fn mnemonic(self: OpCode) []const u8 {
        return self.info().mnemonic;
    }

    pub fn operandKind(self: OpCode) OperandKind {
        return self.info().operand;
    }

    /// The length of the instruction in bytes. This length includes the opcode
    /// byte.
    pub fn size(self: OpCode) usize {
        return 1 + self.operandKind().size();
    }

    /// This function is true if execution can continue at the next
    /// instruction. `halt` stops the VM. `ret` and `jmp` move control to a
    /// different offset. Therefore only a jump or a call can reach the bytes
    /// after these three instructions.
    pub fn fallsThrough(self: OpCode) bool {
        return switch (self) {
            .halt, .ret, .jmp => false,
            else => true,
        };
    }
};

/// The data that comes after the opcode byte in the instruction stream.
pub const OperandKind = enum {
    /// No operand. The instruction is one byte.
    none,
    /// A signed 32-bit value in the instruction. This operand also puts an
    /// address on the stack, because the assembler writes a code label or a
    /// static-data label as a usual value.
    signed,
    /// An unsigned 32-bit byte address in guest memory.
    data_address,
    /// An unsigned 32-bit absolute offset into the code region of the
    /// container.
    code_target,
    /// A one-byte index into the import table of the container.
    import_index,

    /// The length of the operand in bytes. This length does not include the
    /// opcode byte.
    pub fn size(self: OperandKind) usize {
        return switch (self) {
            .none => 0,
            .import_index => 1,
            .signed, .data_address, .code_target => 4,
        };
    }

    /// This function is true if an assembler can write a label address in this
    /// operand.
    ///
    /// A data address accepts one, because a global is now a byte address in the
    /// program image and a label is how a program names it. Before guest memory was
    /// one address space, this operand was an index into a separate segment of slots
    /// and no label could name it.
    pub fn acceptsLabel(self: OperandKind) bool {
        return switch (self) {
            .signed, .code_target, .data_address => true,
            .none, .import_index => false,
        };
    }
};

/// A description of one instruction for a person to read. The assembler uses
/// the mnemonic to find the instruction. The documentation and the diagnostic
/// messages use the other fields.
pub const Info = struct {
    code: OpCode,
    mnemonic: []const u8,
    operand: OperandKind,
    /// The effect on the data stack, as `before → after`. `a` is the lower
    /// value and `b` is the top value. This field is empty if the instruction
    /// does not change the data stack.
    stack_effect: []const u8,
    summary: []const u8,
};

/// The metadata for each instruction. The opcode byte is the index.
pub const table = [_]Info{
    .{ .code = .halt, .mnemonic = "halt", .operand = .none, .stack_effect = "", .summary = "Stop execution." },
    .{ .code = .push, .mnemonic = "push", .operand = .signed, .stack_effect = "→ value", .summary = "Push a signed 32-bit integer." },
    .{ .code = .add, .mnemonic = "add", .operand = .none, .stack_effect = "a b → a + b", .summary = "Add two values." },
    .{ .code = .sub, .mnemonic = "sub", .operand = .none, .stack_effect = "a b → a - b", .summary = "Subtract the top value from the next value." },
    .{ .code = .print, .mnemonic = "print", .operand = .none, .stack_effect = "a → a", .summary = "Print the top value without removing it." },
    .{ .code = .dup, .mnemonic = "dup", .operand = .none, .stack_effect = "a → a a", .summary = "Duplicate the top value." },
    .{ .code = .pop, .mnemonic = "pop", .operand = .none, .stack_effect = "a →", .summary = "Discard the top value." },
    .{ .code = .swap, .mnemonic = "swap", .operand = .none, .stack_effect = "a b → b a", .summary = "Exchange the top two values." },
    .{ .code = .mul, .mnemonic = "mul", .operand = .none, .stack_effect = "a b → a * b", .summary = "Multiply two values." },
    .{ .code = .div, .mnemonic = "div", .operand = .none, .stack_effect = "a b → a / b", .summary = "Signed integer division, truncated toward zero." },
    .{ .code = .mod, .mnemonic = "mod", .operand = .none, .stack_effect = "a b → a % b", .summary = "Signed remainder." },
    .{ .code = .eq, .mnemonic = "eq", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a == b, otherwise 0." },
    .{ .code = .ne, .mnemonic = "ne", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a != b, otherwise 0." },
    .{ .code = .lt, .mnemonic = "lt", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a < b, otherwise 0." },
    .{ .code = .lte, .mnemonic = "lte", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a <= b, otherwise 0." },
    .{ .code = .gt, .mnemonic = "gt", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a > b, otherwise 0." },
    .{ .code = .gte, .mnemonic = "gte", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a >= b, otherwise 0." },
    .{ .code = .jmp, .mnemonic = "jmp", .operand = .code_target, .stack_effect = "", .summary = "Jump unconditionally to an absolute code offset." },
    .{ .code = .jmp_zero, .mnemonic = "jmp_zero", .operand = .code_target, .stack_effect = "condition →", .summary = "Jump when condition is 0." },
    .{ .code = .jmp_not_zero, .mnemonic = "jmp_not_zero", .operand = .code_target, .stack_effect = "condition →", .summary = "Jump when condition is not 0." },
    .{ .code = .load, .mnemonic = "load", .operand = .data_address, .stack_effect = "→ i32 at address", .summary = "Push the 32-bit value at a byte address that the instruction holds." },
    .{ .code = .store, .mnemonic = "store", .operand = .data_address, .stack_effect = "value →", .summary = "Pop a value and write 32 bits to a byte address that the instruction holds." },
    .{ .code = .call, .mnemonic = "call", .operand = .code_target, .stack_effect = "", .summary = "Save the next instruction offset and jump to target." },
    .{ .code = .ret, .mnemonic = "ret", .operand = .none, .stack_effect = "", .summary = "Return to the offset saved by call." },
    .{ .code = .foreign_call, .mnemonic = "foreign_call", .operand = .import_index, .stack_effect = "arg1 ... argN → result", .summary = "Call an imported foreign function." },
    .{ .code = .print_string, .mnemonic = "print_string", .operand = .none, .stack_effect = "address → address", .summary = "Print the NUL-terminated string at a program address." },
    .{ .code = .load_at, .mnemonic = "load_at", .operand = .none, .stack_effect = "address → i32 at address", .summary = "The same instruction as load32. The older name is kept." },
    .{ .code = .store_at, .mnemonic = "store_at", .operand = .none, .stack_effect = "value address →", .summary = "The same instruction as store32. The older name is kept." },
    .{ .code = .@"and", .mnemonic = "and", .operand = .none, .stack_effect = "a b → a & b", .summary = "Compute the bitwise AND of two values." },
    .{ .code = .@"or", .mnemonic = "or", .operand = .none, .stack_effect = "a b → a | b", .summary = "Compute the bitwise OR of two values." },
    .{ .code = .xor, .mnemonic = "xor", .operand = .none, .stack_effect = "a b → a ^ b", .summary = "Compute the bitwise XOR of two values." },
    .{ .code = .not, .mnemonic = "not", .operand = .none, .stack_effect = "a → ~a", .summary = "Invert every bit of a value." },
    .{ .code = .shl, .mnemonic = "shl", .operand = .none, .stack_effect = "a b → a << (b mod 32)", .summary = "Shift left by the low five bits of the shift count." },
    .{ .code = .shr_u, .mnemonic = "shr_u", .operand = .none, .stack_effect = "a b → unsigned(a) >> (b mod 32)", .summary = "Shift right logically by the low five bits of the shift count." },
    .{ .code = .rotl, .mnemonic = "rotl", .operand = .none, .stack_effect = "a b → rotate_left(a, b mod 32)", .summary = "Rotate left by the low five bits of the rotation count." },
    .{ .code = .add_wrap, .mnemonic = "add_wrap", .operand = .none, .stack_effect = "a b → a +% b", .summary = "Add two values and wrap modulo 2^32." },
    .{ .code = .read_i32, .mnemonic = "read_i32", .operand = .none, .stack_effect = "→ value", .summary = "Read a signed decimal integer from the input stream." },
    .{ .code = .read_byte, .mnemonic = "read_byte", .operand = .none, .stack_effect = "→ byte", .summary = "Read one input byte, or push -1 at end of input." },
    .{ .code = .print_hex, .mnemonic = "print_hex", .operand = .none, .stack_effect = "a → a", .summary = "Print the top value as eight hexadecimal digits without removing it." },
    .{ .code = .write_byte, .mnemonic = "write_byte", .operand = .none, .stack_effect = "byte →", .summary = "Pop one value and write its low byte to the output stream." },
    .{ .code = .load8_u, .mnemonic = "load8_u", .operand = .none, .stack_effect = "address → u8 at address", .summary = "Push the byte at a memory address, without its sign." },
    .{ .code = .load8_s, .mnemonic = "load8_s", .operand = .none, .stack_effect = "address → i8 at address", .summary = "Push the byte at a memory address, with its sign extended." },
    .{ .code = .load16_u, .mnemonic = "load16_u", .operand = .none, .stack_effect = "address → u16 at address", .summary = "Push the 16-bit value at a memory address, without its sign." },
    .{ .code = .load16_s, .mnemonic = "load16_s", .operand = .none, .stack_effect = "address → i16 at address", .summary = "Push the 16-bit value at a memory address, with its sign extended." },
    .{ .code = .load32, .mnemonic = "load32", .operand = .none, .stack_effect = "address → i32 at address", .summary = "Push the 32-bit value at a memory address." },
    .{ .code = .store8, .mnemonic = "store8", .operand = .none, .stack_effect = "value address →", .summary = "Pop a value and write its low 8 bits to a memory address." },
    .{ .code = .store16, .mnemonic = "store16", .operand = .none, .stack_effect = "value address →", .summary = "Pop a value and write its low 16 bits to a memory address." },
    .{ .code = .store32, .mnemonic = "store32", .operand = .none, .stack_effect = "value address →", .summary = "Pop a value and write all 32 bits to a memory address." },
};

// The opcode byte is the index into `table`. Therefore the table must describe
// each instruction one time only, and in the correct sequence. A new `OpCode`
// with no table entry gives a compile error. An entry in the wrong position
// also gives a compile error. Without these checks, the assembler and the VM
// can disagree with no message.
comptime {
    const definition = @typeInfo(OpCode).@"enum";
    if (definition.field_names.len != table.len) {
        @compileError("opcode metadata table does not cover every OpCode");
    }
    for (definition.field_names, definition.field_values, 0..) |name, value, index| {
        if (value != index) @compileError("OpCode values must be dense and ascending: " ++ name);
        if (table[index].code != @field(OpCode, name)) {
            @compileError("opcode metadata table is out of order at: " ++ name);
        }
    }
}

test "opcode bytes round-trip through the metadata table" {
    for (table, 0..) |entry, index| {
        const byte: u8 = @intCast(index);
        try std.testing.expectEqual(entry.code, try OpCode.fromByte(byte));
        try std.testing.expectEqual(entry.code, OpCode.fromMnemonic(entry.mnemonic).?);
        try std.testing.expectEqual(byte, @intFromEnum(entry.code));
    }
}

test "unassigned opcode bytes and unknown mnemonics are rejected" {
    try std.testing.expectError(error.UnknownOpcode, OpCode.fromByte(@intCast(table.len)));
    try std.testing.expectError(error.UnknownOpcode, OpCode.fromByte(0xfe));
    try std.testing.expectEqual(@as(?OpCode, null), OpCode.fromMnemonic("nope"));
    // The mnemonic must be an exact match. A prefix is not sufficient.
    try std.testing.expectEqual(@as(?OpCode, null), OpCode.fromMnemonic("jmp_"));
}

test "instruction sizes follow the operand kind" {
    try std.testing.expectEqual(@as(usize, 1), OpCode.halt.size());
    try std.testing.expectEqual(@as(usize, 5), OpCode.push.size());
    try std.testing.expectEqual(@as(usize, 5), OpCode.jmp.size());
    try std.testing.expectEqual(@as(usize, 2), OpCode.foreign_call.size());
}

test "control flow metadata marks the instructions that end a run" {
    try std.testing.expect(!OpCode.halt.fallsThrough());
    try std.testing.expect(!OpCode.ret.fallsThrough());
    try std.testing.expect(!OpCode.jmp.fallsThrough());
    try std.testing.expect(OpCode.jmp_zero.fallsThrough());
    try std.testing.expect(OpCode.call.fallsThrough());
    try std.testing.expect(OpCode.add.fallsThrough());
}

test "every instruction carries documentation" {
    for (table) |entry| {
        try std.testing.expect(entry.mnemonic.len > 0);
        try std.testing.expect(entry.summary.len > 0);
        // Only an instruction that does not change the data stack can have no
        // effect text.
        if (entry.stack_effect.len == 0) {
            try std.testing.expect(switch (entry.code) {
                .halt, .jmp, .call, .ret => true,
                else => false,
            });
        }
    }
}
