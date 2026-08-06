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

    // Call frames.
    //
    // `enter` gives a function its own storage. It takes the arguments off the
    // operand stack and puts them in that storage, so an argument and a local are
    // the same kind of thing afterwards: a numbered slot of the frame. Therefore one
    // pair of instructions reaches both, and `local_addr` gives the address of
    // either. A C parameter is an lvalue, and this is what makes it one.
    //
    // A frame needs a call to belong to. Therefore a function that has locals is
    // called, and the entry point of a program is a stub that calls it.
    enter = 48,
    ret_val = 49,
    load_local = 50,
    store_local = 51,
    local_addr = 52,

    // The unsigned instructions.
    //
    // A VIG value is 32 bits and nothing on the stack says what those bits mean.
    // Therefore `unsigned int` and `int` share every instruction whose result does
    // not depend on the answer — an add, a store, a test for equality — and differ
    // only in the ones here, where the sign bit decides the result.
    lt_u = 53,
    lte_u = 54,
    gt_u = 55,
    gte_u = 56,
    div_u = 57,
    mod_u = 58,

    // The arithmetic shift right. `shr_u` fills the vacated bits with zeros and this
    // one fills them with the sign bit, which is what a signed `>>` does.
    shr_s = 59,

    // The wrapping arithmetic.
    //
    // `add`, `sub` and `mul` trap on signed overflow, which is what a language wants
    // where overflow is a fault. Unsigned arithmetic in C is defined to wrap instead,
    // so a compiler needs a form that gives the low 32 bits and no trap. `add_wrap`
    // came first; these two complete the set.
    sub_wrap = 60,
    mul_wrap = 61,

    // A call whose target comes from the stack rather than from the instruction.
    // This is what a function pointer needs, and with it a dispatch table, a
    // comparison function and a method table become possible.
    call_indirect = 62,

    // A jump whose target comes from the stack. `call_indirect` reaches another
    // function; this one reaches a label of the function it is already in, which
    // is what a jump table needs: a `switch` becomes one load and one jump
    // instead of a comparison for every case.
    jmp_indirect = 63,

    // Single-precision floating point.
    //
    // A value is one slot holding the bits of an IEEE-754 binary32. The stack
    // says nothing about what a slot means, so the instruction decides, exactly
    // as it does for a signed and an unsigned integer.
    //
    // None of these traps except the two conversions to an integer. IEEE gives
    // every arithmetic operation an answer — a division by zero is an infinity
    // and not a fault — so trapping here would be this VM inventing a rule the
    // format does not have. That is the one place where the floating-point
    // instructions do not follow the habit of the integer ones.
    fadd = 64,
    fsub = 65,
    fmul = 66,
    fdiv = 67,
    fneg = 68,
    // `sqrt` is the one function of a mathematics library that IEEE-754
    // specifies exactly, so it gives the same bits on every host. `sin` and the
    // rest do not, and belong in a library written in C: an opcode for one would
    // cost the VM its reproducibility.
    fsqrt = 69,

    // The comparisons, each pushing 1 or 0 as its integer counterpart does. A
    // NaN compares false against everything including itself, so `fne` is the
    // only one of the six that is true for one.
    feq = 70,
    fne = 71,
    flt = 72,
    fle = 73,
    fgt = 74,
    fge = 75,

    // The conversions. `f2i` and `f2u` truncate toward zero, as a cast in C
    // does, and trap on a value the integer cannot hold — a NaN included, which
    // names no integer at all. Widening an integer never fails, though a large
    // one loses the low bits that 24 bits of significand cannot keep.
    f2i = 76,
    f2u = 77,
    i2f = 78,
    u2f = 79,

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
            .halt, .ret, .ret_val, .jmp => false,
            else => true,
        };
    }

    /// How the instruction changes the height of the operand stack, or null if the
    /// opcode alone does not say.
    ///
    /// The value is null for two kinds of instruction. One is a control transfer
    /// that has no next instruction to hand a height to: `halt`, `jmp`, `ret` and
    /// `ret_val`. The other is an instruction whose effect is written somewhere the
    /// opcode is not — the operand of `enter`, the import table for `foreign_call`,
    /// and the called function for `call` and `call_indirect`. A caller that tracks
    /// the height must read those places itself.
    pub fn stackEffect(self: OpCode) ?Effect {
        return switch (self) {
            // A control transfer, or an effect that the opcode does not hold.
            .halt, .jmp, .jmp_indirect, .ret, .ret_val => null,
            .call, .call_indirect, .foreign_call, .enter => null,

            // One value, from somewhere that is not the stack.
            .push, .load, .read_i32, .read_byte, .load_local, .local_addr => .{ .pops = 0, .pushes = 1 },

            // One value in, one value out. `print` and `print_hex` leave what they
            // printed, and a narrow load replaces an address with what it found.
            .print,
            .print_hex,
            .print_string,
            .not,
            .load_at,
            .load8_u,
            .load8_s,
            .load16_u,
            .load16_s,
            .load32,
            => .{ .pops = 1, .pushes = 1 },

            // One value consumed.
            .pop, .store, .store_local, .write_byte, .jmp_zero, .jmp_not_zero => .{ .pops = 1, .pushes = 0 },

            .dup => .{ .pops = 1, .pushes = 2 },
            .swap => .{ .pops = 2, .pushes = 2 },

            // A floating-point value is one slot, so these count the same as
            // their integer counterparts. A comparison takes two floats and
            // leaves an integer; a conversion takes one slot and leaves one.
            .fneg, .fsqrt, .f2i, .f2u, .i2f, .u2f => .{ .pops = 1, .pushes = 1 },
            .fadd,
            .fsub,
            .fmul,
            .fdiv,
            .feq,
            .fne,
            .flt,
            .fle,
            .fgt,
            .fge,
            => .{ .pops = 2, .pushes = 1 },

            // Two values in, one result out.
            .add,
            .sub,
            .mul,
            .div,
            .mod,
            .add_wrap,
            .sub_wrap,
            .mul_wrap,
            .div_u,
            .mod_u,
            .eq,
            .ne,
            .lt,
            .lte,
            .gt,
            .gte,
            .lt_u,
            .lte_u,
            .gt_u,
            .gte_u,
            .@"and",
            .@"or",
            .xor,
            .shl,
            .shr_u,
            .shr_s,
            .rotl,
            => .{ .pops = 2, .pushes = 1 },

            // A value and the address to put it at.
            .store_at, .store8, .store16, .store32 => .{ .pops = 2, .pushes = 0 },
        };
    }
};

/// What an instruction takes off the operand stack and what it puts back.
pub const Effect = struct {
    pops: u8,
    pushes: u8,
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
    /// A two-byte index of a slot in the frame of the running function. Slot 0 is
    /// the first argument.
    local_index,
    /// Two two-byte counts: the arguments of a function and then its locals. Only
    /// `enter` uses this operand.
    frame_shape,

    /// The length of the operand in bytes. This length does not include the
    /// opcode byte.
    pub fn size(self: OperandKind) usize {
        return switch (self) {
            .none => 0,
            .import_index => 1,
            .local_index => 2,
            .signed, .data_address, .code_target, .frame_shape => 4,
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
            .none, .import_index, .local_index, .frame_shape => false,
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
    .{ .code = .enter, .mnemonic = "enter", .operand = .frame_shape, .stack_effect = "arg1 ... argN →", .summary = "Give the running function a frame, and move its arguments into it." },
    .{ .code = .ret_val, .mnemonic = "ret_val", .operand = .none, .stack_effect = "value → value", .summary = "Return one value to the caller and discard the rest of the frame." },
    .{ .code = .load_local, .mnemonic = "load_local", .operand = .local_index, .stack_effect = "→ frame[index]", .summary = "Push the value of an argument or a local of the running function." },
    .{ .code = .store_local, .mnemonic = "store_local", .operand = .local_index, .stack_effect = "value →", .summary = "Pop a value into an argument or a local of the running function." },
    .{ .code = .local_addr, .mnemonic = "local_addr", .operand = .local_index, .stack_effect = "→ address", .summary = "Push the memory address of an argument or a local of the running function." },
    .{ .code = .lt_u, .mnemonic = "lt_u", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a < b as unsigned values, otherwise 0." },
    .{ .code = .lte_u, .mnemonic = "lte_u", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a <= b as unsigned values, otherwise 0." },
    .{ .code = .gt_u, .mnemonic = "gt_u", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a > b as unsigned values, otherwise 0." },
    .{ .code = .gte_u, .mnemonic = "gte_u", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a >= b as unsigned values, otherwise 0." },
    .{ .code = .div_u, .mnemonic = "div_u", .operand = .none, .stack_effect = "a b → a / b", .summary = "Unsigned integer division. Traps on division by zero." },
    .{ .code = .mod_u, .mnemonic = "mod_u", .operand = .none, .stack_effect = "a b → a % b", .summary = "Unsigned remainder. Traps on division by zero." },
    .{ .code = .shr_s, .mnemonic = "shr_s", .operand = .none, .stack_effect = "a b → a >> (b mod 32)", .summary = "Shift right arithmetically by the low five bits of the shift count." },
    .{ .code = .sub_wrap, .mnemonic = "sub_wrap", .operand = .none, .stack_effect = "a b → a -% b", .summary = "Subtract the top value from the next value and wrap modulo 2^32." },
    .{ .code = .mul_wrap, .mnemonic = "mul_wrap", .operand = .none, .stack_effect = "a b → a *% b", .summary = "Multiply two values and wrap modulo 2^32." },
    .{ .code = .call_indirect, .mnemonic = "call_indirect", .operand = .none, .stack_effect = "target →", .summary = "Save the next instruction offset and jump to a code address from the stack." },
    .{ .code = .jmp_indirect, .mnemonic = "jmp_indirect", .operand = .none, .stack_effect = "target →", .summary = "Jump to a code address from the stack, saving no return offset." },
    .{ .code = .fadd, .mnemonic = "fadd", .operand = .none, .stack_effect = "a b → a + b", .summary = "Add two binary32 values." },
    .{ .code = .fsub, .mnemonic = "fsub", .operand = .none, .stack_effect = "a b → a - b", .summary = "Subtract the top binary32 value from the next." },
    .{ .code = .fmul, .mnemonic = "fmul", .operand = .none, .stack_effect = "a b → a * b", .summary = "Multiply two binary32 values." },
    .{ .code = .fdiv, .mnemonic = "fdiv", .operand = .none, .stack_effect = "a b → a / b", .summary = "Divide binary32 values. A zero divisor gives an infinity or a NaN, not a trap." },
    .{ .code = .fneg, .mnemonic = "fneg", .operand = .none, .stack_effect = "a → -a", .summary = "Negate a binary32 value, which flips its sign bit and nothing else." },
    .{ .code = .fsqrt, .mnemonic = "fsqrt", .operand = .none, .stack_effect = "a → sqrt(a)", .summary = "The square root, which IEEE-754 specifies exactly. A negative operand gives a NaN." },
    .{ .code = .feq, .mnemonic = "feq", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a == b as binary32 values, otherwise 0." },
    .{ .code = .fne, .mnemonic = "fne", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a != b as binary32 values, otherwise 0. A NaN is unequal to everything." },
    .{ .code = .flt, .mnemonic = "flt", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a < b as binary32 values, otherwise 0." },
    .{ .code = .fle, .mnemonic = "fle", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a <= b as binary32 values, otherwise 0." },
    .{ .code = .fgt, .mnemonic = "fgt", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a > b as binary32 values, otherwise 0." },
    .{ .code = .fge, .mnemonic = "fge", .operand = .none, .stack_effect = "a b → bool", .summary = "Push 1 when a >= b as binary32 values, otherwise 0." },
    .{ .code = .f2i, .mnemonic = "f2i", .operand = .none, .stack_effect = "a → int", .summary = "Truncate a binary32 value toward zero to a signed integer. Traps if it does not fit." },
    .{ .code = .f2u, .mnemonic = "f2u", .operand = .none, .stack_effect = "a → int", .summary = "Truncate a binary32 value toward zero to an unsigned integer. Traps if it does not fit." },
    .{ .code = .i2f, .mnemonic = "i2f", .operand = .none, .stack_effect = "a → float", .summary = "Convert a signed integer to binary32, rounding to nearest." },
    .{ .code = .u2f, .mnemonic = "u2f", .operand = .none, .stack_effect = "a → float", .summary = "Convert an unsigned integer to binary32, rounding to nearest." },
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

test "the stack effect agrees with the effect written for a reader" {
    // The two descriptions of an instruction are written by hand in different forms,
    // so this test compares them where the text is simple enough to count: a name on
    // each side of the arrow, and nothing else. That covers most of the set, and a
    // new instruction whose two descriptions disagree fails here.
    for (table) |entry| {
        const effect = entry.code.stackEffect() orelse continue;
        const arrow = std.mem.indexOf(u8, entry.stack_effect, "→") orelse continue;

        const before = countNames(entry.stack_effect[0..arrow]) orelse continue;
        const after = countNames(entry.stack_effect[arrow + "→".len ..]) orelse continue;

        try std.testing.expectEqual(before, effect.pops);
        try std.testing.expectEqual(after, effect.pushes);
    }
}

/// The names that a stack effect gives to one value. A side of an effect that holds
/// only these can be counted; anything else is prose written for a reader, and the
/// test above leaves it alone. `a b` is two values, and `a + b` and `i32 at address`
/// each describe one value in words that no count can follow.
const value_names = [_][]const u8{ "a", "b", "bool", "value", "address", "condition", "byte", "target" };

/// The number of values that one side of a stack effect names, or null if the text
/// says anything else.
fn countNames(text: []const u8) ?u8 {
    var count: u8 = 0;
    var words = std.mem.tokenizeAny(u8, text, " ");
    words: while (words.next()) |word| {
        for (value_names) |name| {
            if (std.mem.eql(u8, word, name)) {
                count += 1;
                continue :words;
            }
        }
        return null;
    }
    return count;
}

test "the instructions with no fixed effect are the ones that need more than an opcode" {
    // A control transfer has no next instruction of its own to give a height to, and
    // the other four hold their effect somewhere else. Every other instruction must
    // answer, so a new one cannot join the set without a decision about its effect.
    for (table) |entry| {
        const expected_null = switch (entry.code) {
            .halt, .jmp, .jmp_indirect, .ret, .ret_val => true,
            .call, .call_indirect, .foreign_call, .enter => true,
            else => false,
        };
        try std.testing.expectEqual(expected_null, entry.code.stackEffect() == null);
    }
}
