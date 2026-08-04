//! Bytecode verifier.
//!
//! The verifier walks a container's code region from its entry point, following
//! every branch, and proves that:
//!
//! - every reachable byte sequence decodes to a known instruction that fits
//!   inside the code region;
//! - every jump and call target lands on an instruction boundary rather than in
//!   the middle of one, so no path can execute an operand as an opcode;
//! - control never falls off the end of the code region;
//! - every `foreign_call` names an import the container actually declares, and
//!   `load`/`store` stay inside the data segment when its size is known.
//!
//! This is only practical because format version 2 records the code length
//! separately from static data: a walk over a region with strings mixed in would
//! decode text as instructions. Version 1 containers therefore cannot be
//! verified, and are still executed with runtime checks alone.
//!
//! The walk is reachability-based, not a linear sweep, so unreachable bytes are
//! ignored rather than reported. They are never executed.

const std = @import("std");
const encode = @import("encode.zig");
const opcode = @import("opcode.zig");

pub const Error = error{
    UnknownOpcode,
    TruncatedInstruction,
    EntryPointOutOfRange,
    /// A jump or call target lies outside the code region.
    TargetOutOfRange,
    /// A jump or call target lies inside another instruction.
    MisalignedTarget,
    /// Two reachable instructions claim the same bytes.
    OverlappingInstruction,
    /// A reachable instruction falls through past the end of the code region.
    ExecutionRunsOffEnd,
    UnknownForeignImport,
    DataAddressOutOfRange,
    ScratchTooSmall,
};

/// What the walk has established about one byte of the code region.
pub const Mark = enum(u8) {
    unknown,
    /// Reachable and waiting to be decoded.
    pending,
    /// The first byte of a reachable instruction.
    boundary,
    /// An operand byte of a reachable instruction.
    interior,
};

pub const Options = struct {
    code: []const u8,
    entry_point: u32 = 0,
    /// Imports the container declares; `foreign_call` indices must be below it.
    import_count: u8 = 0,
    /// Slots in the VM data segment. `null` skips `load`/`store` address checks,
    /// for callers that do not fix the segment size.
    data_slots: ?u32 = null,
};

/// Where verification failed, for diagnostics. `offset` is the instruction that
/// was rejected, not necessarily the byte the problem is at.
pub const Failure = struct {
    offset: usize,
    reason: Error,
};

/// Scratch bytes `verify` needs for a code region of `code_len` bytes.
pub fn scratchSize(code_len: usize) usize {
    return code_len;
}

/// Verify `options.code`. `scratch` must hold at least `scratchSize(code.len)`
/// marks; it is fully overwritten. `failure`, when supplied, receives the
/// location of the first problem found.
pub fn verify(options: Options, scratch: []Mark, failure: ?*Failure) Error!void {
    const code = options.code;
    if (scratch.len < scratchSize(code.len)) return fail(failure, 0, error.ScratchTooSmall);

    const marks = scratch[0..code.len];
    @memset(marks, .unknown);

    if (code.len == 0) {
        if (options.entry_point != 0) return fail(failure, options.entry_point, error.EntryPointOutOfRange);
        return;
    }
    if (options.entry_point >= code.len) {
        return fail(failure, options.entry_point, error.EntryPointOutOfRange);
    }

    marks[options.entry_point] = .pending;
    var hint: usize = options.entry_point;

    while (findPending(marks, hint)) |offset| {
        hint = offset;

        const instruction = encode.decode(code, offset) catch |err| return fail(failure, offset, switch (err) {
            error.UnknownOpcode => error.UnknownOpcode,
            else => error.TruncatedInstruction,
        });

        marks[offset] = .boundary;
        for (marks[offset + 1 .. instruction.end()]) |*mark| {
            // Another reachable path starts an instruction inside this one, so
            // one of the two decodes an operand byte as an opcode.
            if (mark.* != .unknown and mark.* != .interior) {
                return fail(failure, offset, error.OverlappingInstruction);
            }
            mark.* = .interior;
        }

        switch (instruction.operand) {
            .import_index => |index| if (index >= options.import_count) {
                return fail(failure, offset, error.UnknownForeignImport);
            },
            .data_address => |address| if (options.data_slots) |slots| {
                if (address >= slots) return fail(failure, offset, error.DataAddressOutOfRange);
            },
            else => {},
        }

        if (instruction.codeTarget()) |target| {
            try schedule(marks, target, offset, failure, &hint);
        }
        if (instruction.code.fallsThrough()) {
            const next = instruction.end();
            if (next >= code.len) return fail(failure, offset, error.ExecutionRunsOffEnd);
            try schedule(marks, @intCast(next), offset, failure, &hint);
        }
    }
}

fn schedule(marks: []Mark, target: u32, offset: usize, failure: ?*Failure, hint: *usize) Error!void {
    if (target >= marks.len) return fail(failure, offset, error.TargetOutOfRange);
    switch (marks[target]) {
        .interior => return fail(failure, offset, error.MisalignedTarget),
        .unknown => {
            marks[target] = .pending;
            hint.* = @min(hint.*, target);
        },
        .pending, .boundary => {},
    }
}

/// Next byte waiting to be decoded, searching from `from` and wrapping once.
fn findPending(marks: []const Mark, from: usize) ?usize {
    for (marks[from..], from..) |mark, offset| {
        if (mark == .pending) return offset;
    }
    for (marks[0..from], 0..) |mark, offset| {
        if (mark == .pending) return offset;
    }
    return null;
}

fn fail(failure: ?*Failure, offset: usize, reason: Error) Error {
    if (failure) |slot| slot.* = .{ .offset = offset, .reason = reason };
    return reason;
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;
const OpCode = opcode.OpCode;

/// Builds a code region and hands back each instruction's offset, so tests can
/// name branch targets instead of counting bytes.
const Builder = struct {
    buffer: [128]u8 = undefined,
    len: usize = 0,

    fn add(self: *Builder, instruction: OpCode, operand: encode.Operand) usize {
        const offset = self.len;
        self.len += encode.encode(self.buffer[self.len..], instruction, operand) catch unreachable;
        return offset;
    }

    fn addByte(self: *Builder, byte: u8) usize {
        const offset = self.len;
        self.buffer[self.len] = byte;
        self.len += 1;
        return offset;
    }

    fn code(self: *const Builder) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn expectVerified(options: Options) !void {
    var scratch: [128]Mark = undefined;
    try verify(options, &scratch, null);
}

fn expectFailure(options: Options, reason: Error, offset: usize) !void {
    var scratch: [128]Mark = undefined;
    var failure: Failure = undefined;
    try testing.expectError(reason, verify(options, &scratch, &failure));
    try testing.expectEqual(reason, failure.reason);
    try testing.expectEqual(offset, failure.offset);
}

test "a program with branches, a call and a loop verifies" {
    var program: Builder = .{};
    const loop = program.add(.load, .{ .data_address = 0 });
    _ = program.add(.push, .{ .signed = 1 });
    _ = program.add(.sub, .none);
    _ = program.add(.dup, .none);
    _ = program.add(.store, .{ .data_address = 0 });
    _ = program.add(.jmp_not_zero, .{ .code_target = @intCast(loop) });
    const subroutine_call = program.len + OpCode.call.size() + OpCode.halt.size();
    _ = program.add(.call, .{ .code_target = @intCast(subroutine_call) });
    _ = program.add(.halt, .none);
    _ = program.add(.push, .{ .signed = 7 });
    _ = program.add(.ret, .none);

    try expectVerified(.{ .code = program.code(), .data_slots = 256 });
}

test "an entry point past the first instruction is honoured" {
    var program: Builder = .{};
    // Static data would normally live in its own region, but an entry point that
    // skips a prologue has to work too.
    _ = program.addByte(0xfe);
    const entry = program.add(.halt, .none);

    try expectVerified(.{ .code = program.code(), .entry_point = @intCast(entry) });
    // From offset 0 the same bytes do not decode.
    try expectFailure(.{ .code = program.code() }, error.UnknownOpcode, 0);
}

test "an empty code region verifies only with a zero entry point" {
    try expectVerified(.{ .code = "" });
    try expectFailure(.{ .code = "", .entry_point = 1 }, error.EntryPointOutOfRange, 1);
}

test "an entry point outside the code region is rejected" {
    var program: Builder = .{};
    _ = program.add(.halt, .none);
    try expectFailure(.{ .code = program.code(), .entry_point = 1 }, error.EntryPointOutOfRange, 1);
}

test "a target inside another instruction is rejected" {
    var program: Builder = .{};
    // Jump one byte into the `push`, where an operand byte would be executed as
    // an opcode.
    _ = program.add(.push, .{ .signed = 0 });
    const jump = program.add(.jmp, .{ .code_target = 1 });

    try expectFailure(.{ .code = program.code() }, error.MisalignedTarget, jump);
}

test "an overlap is caught when the instruction is decoded after its target" {
    // The `jmp_not_zero` at 10 is decoded first and establishes a boundary
    // there; the `push` it branches to then claims byte 10 as an operand. One of
    // the two has to be wrong, whichever order the walk finds them in.
    var program: Builder = .{};
    _ = program.add(.jmp, .{ .code_target = 10 });
    _ = program.addByte(0); // unreachable filler
    const overlapping = program.addByte(@intFromEnum(OpCode.push));
    inline for (0..3) |_| _ = program.addByte(0);
    _ = program.addByte(@intFromEnum(OpCode.jmp_not_zero));
    _ = program.addByte(@intCast(overlapping));
    inline for (0..3) |_| _ = program.addByte(0);
    _ = program.addByte(@intFromEnum(OpCode.halt));

    try expectFailure(.{ .code = program.code() }, error.OverlappingInstruction, overlapping);
}

test "a target outside the code region is rejected" {
    var program: Builder = .{};
    _ = program.add(.call, .{ .code_target = 99 });
    _ = program.add(.halt, .none);
    try expectFailure(.{ .code = program.code() }, error.TargetOutOfRange, 0);
}

test "control must not fall off the end of the code region" {
    var program: Builder = .{};
    const push_offset = program.add(.push, .{ .signed = 1 });
    try expectFailure(.{ .code = program.code() }, error.ExecutionRunsOffEnd, push_offset);

    // Ending on `halt`, `ret` or `jmp` is fine: none of them fall through.
    for ([_]OpCode{ .halt, .ret }) |terminator| {
        var terminated: Builder = .{};
        _ = terminated.add(.push, .{ .signed = 1 });
        _ = terminated.add(terminator, .none);
        try expectVerified(.{ .code = terminated.code() });
    }
}

test "a reachable unknown opcode or truncated operand is rejected" {
    var unknown: Builder = .{};
    _ = unknown.addByte(0xfe);
    try expectFailure(.{ .code = unknown.code() }, error.UnknownOpcode, 0);

    var truncated: Builder = .{};
    _ = truncated.addByte(@intFromEnum(OpCode.push));
    _ = truncated.addByte(0);
    try expectFailure(.{ .code = truncated.code() }, error.TruncatedInstruction, 0);
}

test "unreachable bytes are ignored because they are never executed" {
    var program: Builder = .{};
    _ = program.add(.halt, .none);
    // Garbage after `halt` is not reachable from the entry point.
    _ = program.addByte(0xfe);
    _ = program.addByte(@intFromEnum(OpCode.push));

    try expectVerified(.{ .code = program.code() });
}

test "foreign calls must name a declared import" {
    var program: Builder = .{};
    _ = program.add(.foreign_call, .{ .import_index = 1 });
    _ = program.add(.halt, .none);

    try expectFailure(.{ .code = program.code(), .import_count = 1 }, error.UnknownForeignImport, 0);
    try expectVerified(.{ .code = program.code(), .import_count = 2 });
}

test "data addresses are checked when the segment size is known" {
    var program: Builder = .{};
    _ = program.add(.store, .{ .data_address = 256 });
    _ = program.add(.halt, .none);

    try expectFailure(.{ .code = program.code(), .data_slots = 256 }, error.DataAddressOutOfRange, 0);
    try expectVerified(.{ .code = program.code(), .data_slots = 257 });
    // A caller that does not fix the segment size leaves the check to the VM.
    try expectVerified(.{ .code = program.code() });
}

test "verification needs one scratch mark per code byte" {
    var program: Builder = .{};
    _ = program.add(.halt, .none);

    var scratch: [0]Mark = undefined;
    try testing.expectEqual(@as(usize, 1), scratchSize(program.code().len));
    try testing.expectError(error.ScratchTooSmall, verify(.{ .code = program.code() }, &scratch, null));
}
