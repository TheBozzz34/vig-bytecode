//! Shared VIG bytecode definitions.
//!
//! The assembler creates VIG programs. The VM runs these programs.
//! Both tools use the same opcode definitions, operand widths,
//! foreign-call limits, and container format.
//!
//! Previously, each tool had a separate copy of these definitions.
//! This package now contains the shared definitions for both tools.
//!
//! - `opcode` defines the instruction set, mnemonics, operand types,
//!   and stack effects.
//! - `foreign` defines the foreign-call argument types and interface limits.
//! - `container` defines the program header and import table.
//! - `encode` encodes and decodes instructions.
//! - `verify` checks instruction boundaries and control flow.
//! - `disasm` writes the bytes of a program as text a person can read.

pub const container = @import("container.zig");
pub const disasm = @import("disasm.zig");
pub const encode = @import("encode.zig");
pub const foreign = @import("foreign.zig");
pub const opcode = @import("opcode.zig");
pub const verify = @import("verify.zig");

// These are the names that a caller uses most often. This package exports them
// again to make the code of a caller easier to read.
pub const Info = opcode.Info;
pub const OpCode = opcode.OpCode;
pub const OperandKind = opcode.OperandKind;

test {
    @import("std").testing.refAllDecls(@This());
}
