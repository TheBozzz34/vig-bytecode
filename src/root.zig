//! Shared VIG bytecode definitions.
//!
//! The assembler writes VIG programs and the VM runs them, so both need the same
//! answers about opcodes, operand widths, foreign-call limits, and the container
//! format. They used to keep private copies of those tables; this package is the
//! one definition both depend on.
//!
//! - `opcode` — the instruction set, its mnemonics, operand kinds, and stack
//!   effects.
//! - `foreign` — foreign-import argument types and ABI limits.
//! - `container` — the on-disk container header and import table.
//! - `encode` — instruction encoding and decoding.
//! - `verify` — instruction-boundary and control-flow verification.

pub const container = @import("container.zig");
pub const encode = @import("encode.zig");
pub const foreign = @import("foreign.zig");
pub const opcode = @import("opcode.zig");
pub const verify = @import("verify.zig");

// The names reached for most often, re-exported for callers' readability.
pub const Info = opcode.Info;
pub const OpCode = opcode.OpCode;
pub const OperandKind = opcode.OperandKind;

test {
    @import("std").testing.refAllDecls(@This());
}
