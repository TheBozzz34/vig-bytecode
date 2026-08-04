//! Opcode identity and metadata.
//!
//! This is the single source of truth for the VIG instruction set. The VM used
//! to keep its own opcode enum and an int-to-enum switch, and the assembler kept
//! a third copy as a mnemonic table; adding an instruction meant editing all
//! three and hoping the byte values agreed. Everything is now derived from
//! `table`, whose shape is checked against `OpCode` at compile time.

const std = @import("std");

/// Every VIG instruction. The enum values are the on-disk opcode bytes and must
/// stay dense and in ascending order, which the `comptime` block below asserts.
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
    foreign_call = 24,
    print_string = 25,
    load_at = 26,
    store_at = 27,

    /// Decode an opcode byte. Unassigned bytes are rejected rather than skipped.
    pub fn fromByte(byte: u8) error{UnknownOpcode}!OpCode {
        return std.enums.fromInt(OpCode, byte) orelse error.UnknownOpcode;
    }

    /// Look up the instruction an assembler mnemonic names.
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

    /// Encoded length in bytes, including the opcode byte itself.
    pub fn size(self: OpCode) usize {
        return 1 + self.operandKind().size();
    }

    /// Whether execution can continue at the following instruction. `halt` stops
    /// the VM and `ret` and `jmp` transfer control elsewhere, so the bytes after
    /// them are only reachable through a jump or call.
    pub fn fallsThrough(self: OpCode) bool {
        return switch (self) {
            .halt, .ret, .jmp => false,
            else => true,
        };
    }
};

/// What follows the opcode byte in the instruction stream.
pub const OperandKind = enum {
    /// Nothing; the instruction is a single byte.
    none,
    /// Signed 32-bit immediate. Also how an address reaches the stack, since
    /// code and static-data labels are pushed as ordinary values.
    signed,
    /// Unsigned 32-bit index into the VM data segment.
    data_address,
    /// Unsigned 32-bit absolute offset into the container's code region.
    code_target,
    /// One-byte index into the container's import table.
    import_index,

    /// Operand length in bytes, excluding the opcode byte.
    pub fn size(self: OperandKind) usize {
        return switch (self) {
            .none => 0,
            .import_index => 1,
            .signed, .data_address, .code_target => 4,
        };
    }

    /// Whether an assembler may write a label address in this operand.
    pub fn acceptsLabel(self: OperandKind) bool {
        return switch (self) {
            .signed, .code_target => true,
            .none, .data_address, .import_index => false,
        };
    }
};

/// Human-readable description of one instruction, used by the assembler for
/// mnemonic lookup and by documentation and diagnostics for the rest.
pub const Info = struct {
    code: OpCode,
    mnemonic: []const u8,
    operand: OperandKind,
    /// Data-stack effect as `before → after`, where `a` is the lower value and
    /// `b` the top one. Empty when the instruction leaves the data stack alone.
    stack_effect: []const u8,
    summary: []const u8,
};

/// Metadata for every instruction, indexed by opcode byte.
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
    .{ .code = .load, .mnemonic = "load", .operand = .data_address, .stack_effect = "→ data[address]", .summary = "Push a value from the data segment." },
    .{ .code = .store, .mnemonic = "store", .operand = .data_address, .stack_effect = "value →", .summary = "Pop a value into the data segment." },
    .{ .code = .call, .mnemonic = "call", .operand = .code_target, .stack_effect = "", .summary = "Save the next instruction offset and jump to target." },
    .{ .code = .ret, .mnemonic = "ret", .operand = .none, .stack_effect = "", .summary = "Return to the offset saved by call." },
    .{ .code = .foreign_call, .mnemonic = "foreign_call", .operand = .import_index, .stack_effect = "arg1 ... argN → result", .summary = "Call an imported foreign function." },
    .{ .code = .print_string, .mnemonic = "print_string", .operand = .none, .stack_effect = "address → address", .summary = "Print the NUL-terminated string at a program address." },
    .{ .code = .load_at, .mnemonic = "load_at", .operand = .none, .stack_effect = "address → data[address]", .summary = "Push a data-segment value, using an address from the stack." },
    .{ .code = .store_at, .mnemonic = "store_at", .operand = .none, .stack_effect = "value address →", .summary = "Pop a value into the data segment, using an address from the stack." },
};

// `table` is indexed by opcode byte, so it has to describe every instruction
// exactly once and in order. Adding an `OpCode` without a table entry, or
// listing entries out of order, is a compile error rather than a silent
// mismatch between the assembler and the VM.
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
    // Mnemonic matching is exact, not a prefix match.
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
        // Only instructions that leave the data stack alone may omit an effect.
        if (entry.stack_effect.len == 0) {
            try std.testing.expect(switch (entry.code) {
                .halt, .jmp, .call, .ret => true,
                else => false,
            });
        }
    }
}
