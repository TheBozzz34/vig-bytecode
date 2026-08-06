//! The bytecode verifier.
//!
//! The verifier reads the code region of a container. It starts at the entry
//! point and goes to each branch target. It then makes sure that:
//!
//! - each byte sequence that the program can reach decodes to a known
//!   instruction, and that instruction is inside the code region;
//! - each jump target and each call target is at the first byte of an
//!   instruction, and not inside an instruction. Therefore no path can execute
//!   an operand byte as an opcode;
//! - control does not continue past the end of the code region;
//! - each `foreign_call` names an import that the container declares. Also,
//!   `load` and `store` address guest memory inside its bounds if the caller gives
//!   the size of that memory, and no `store` names an address in the code region.
//!
//! These checks are possible only because format version 2 records the code
//! length apart from the static data. A read of a region that also holds strings
//! decodes text as instructions. Therefore no verifier can check a version 1
//! container. The VM runs such a container with the run-time checks only.
//!
//! The verifier looks only at the bytes that the program can reach. It does not
//! do a linear read of the region. Therefore the verifier ignores a byte that
//! the program cannot reach, and it does not report that byte. The VM never
//! executes such a byte.

const std = @import("std");
const encode = @import("encode.zig");
const opcode = @import("opcode.zig");

pub const Error = error{
    UnknownOpcode,
    TruncatedInstruction,
    EntryPointOutOfRange,
    /// A jump target or a call target is outside the code region.
    TargetOutOfRange,
    /// A jump target or a call target is inside a different instruction.
    MisalignedTarget,
    /// Two instructions that the program can reach use the same bytes.
    OverlappingInstruction,
    /// After an instruction, control continues past the end of the code region.
    ExecutionRunsOffEnd,
    UnknownForeignImport,
    /// The operand of a `load` or a `store` names an address that is not in guest
    /// memory, or an address whose four-byte access would run past the end of it.
    DataAddressOutOfRange,
    /// The operand of a `store` names an address in the code region. Such a store
    /// would change an instruction, and then the result of this verifier would say
    /// nothing about the bytes that run.
    StoreIntoCodeRegion,
    ScratchTooSmall,
};

/// What the verifier knows about one byte of the code region.
pub const Mark = enum(u8) {
    unknown,
    /// The program can reach this byte. The verifier must still decode it.
    pending,
    /// The first byte of an instruction that the program can reach.
    boundary,
    /// An operand byte of an instruction that the program can reach.
    interior,
};

pub const Options = struct {
    code: []const u8,
    entry_point: u32 = 0,
    /// The number of imports that the container declares. Each `foreign_call`
    /// index must be less than this number.
    import_count: u8 = 0,
    /// The number of bytes of guest memory. A `null` value stops the address checks
    /// on `load` and `store`. Use `null` if the caller does not set the size of that
    /// memory.
    ///
    /// The operand of `load` and of `store` is a byte address, and each of the two
    /// reads or writes four bytes. Therefore the whole of that access must fit, and
    /// an address four bytes from the end of memory is a fault.
    memory_size: ?u32 = null,
    /// The number of bytes of code. A `store` operand below this length would write
    /// an instruction, which would make the result of this verifier untrue for the
    /// rest of the run. A `null` value stops that check.
    ///
    /// This is normally the length of `code`. It is a separate field because the
    /// assembler verifies a program before it decides the final image.
    code_len: ?u32 = null,
};

/// The location of a failure, for a diagnostic message. `offset` is the
/// instruction that the verifier refused. The problem can be at a different
/// byte.
pub const Failure = struct {
    offset: usize,
    reason: Error,
};

/// The number of temporary marks that `verify` needs for a code region of
/// `code_len` bytes.
pub fn scratchSize(code_len: usize) usize {
    return code_len;
}

/// Verify `options.code`. `scratch` must hold `scratchSize(code.len)` marks or
/// more, and `verify` writes over all of it. If the caller gives a `failure`
/// value, `verify` puts the location of the first problem into it.
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
    return walk(options, marks, options.entry_point, failure);
}

/// Verify the code that `target` can reach, and keep the marks that an earlier call
/// left in `scratch`.
///
/// `call_indirect` takes its target from the stack, so no read of the code region
/// can find that target and the walk from the entry point does not reach a function
/// that only a pointer names. Such a function is therefore verified when a call
/// first goes to it. The code region cannot change while a program runs, so the
/// answer is the one that a check before the run would have given.
///
/// The caller must give the same `scratch` and the same `options.code` that `verify`
/// received. A target that is already `boundary` was verified before, and this
/// function then does nothing.
pub fn verifyFrom(options: Options, scratch: []Mark, target: u32, failure: ?*Failure) Error!void {
    const code = options.code;
    if (scratch.len < scratchSize(code.len)) return fail(failure, 0, error.ScratchTooSmall);

    const marks = scratch[0..code.len];
    if (target >= marks.len) return fail(failure, target, error.TargetOutOfRange);

    switch (marks[target]) {
        // The instruction at this address has been decoded, and so has everything it
        // can reach.
        .boundary => return,
        // The address is inside a different instruction, so a call to it would
        // execute an operand byte as an opcode.
        .interior => return fail(failure, target, error.MisalignedTarget),
        .unknown, .pending => marks[target] = .pending,
    }
    return walk(options, marks, target, failure);
}

/// Decode every instruction that the pending marks can reach, and mark what it
/// finds. `hint` is where the search for pending work starts.
fn walk(options: Options, marks: []Mark, start: usize, failure: ?*Failure) Error!void {
    const code = options.code;
    var hint: usize = start;

    while (findPending(marks, hint)) |offset| {
        hint = offset;

        const instruction = encode.decode(code, offset) catch |err| return fail(failure, offset, switch (err) {
            error.UnknownOpcode => error.UnknownOpcode,
            else => error.TruncatedInstruction,
        });

        marks[offset] = .boundary;
        for (marks[offset + 1 .. instruction.end()]) |*mark| {
            // A different path that the program can reach starts an
            // instruction inside this instruction. Therefore one of the
            // two decodes an operand byte as an opcode.
            if (mark.* != .unknown and mark.* != .interior) {
                return fail(failure, offset, error.OverlappingInstruction);
            }
            mark.* = .interior;
        }

        switch (instruction.operand) {
            .import_index => |index| if (index >= options.import_count) {
                return fail(failure, offset, error.UnknownForeignImport);
            },
            .data_address => |address| {
                // The access is four bytes wide, so the address alone is not enough.
                // Written as a subtraction so it cannot overflow.
                if (options.memory_size) |size| {
                    if (size < 4 or address > size - 4) {
                        return fail(failure, offset, error.DataAddressOutOfRange);
                    }
                }
                // A `store` must not write the code. `load` may read it.
                if (instruction.code == .store) {
                    if (options.code_len) |code_len| {
                        if (address < code_len) {
                            return fail(failure, offset, error.StoreIntoCodeRegion);
                        }
                    }
                }
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

/// The next byte that the verifier must decode. The search starts at `from`. It
/// then continues one time from the start of the region.
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

/// This structure makes a code region. It gives the offset of each instruction.
/// Therefore a test can name a branch target and does not have to count bytes.
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
    // The address is past the end of the code, because a `store` must not write an
    // instruction. This program is 32 bytes of code.
    const global = 64;
    const loop = program.add(.load, .{ .data_address = global });
    _ = program.add(.push, .{ .signed = 1 });
    _ = program.add(.sub, .none);
    _ = program.add(.dup, .none);
    _ = program.add(.store, .{ .data_address = global });
    _ = program.add(.jmp_not_zero, .{ .code_target = @intCast(loop) });
    const subroutine_call = program.len + OpCode.call.size() + OpCode.halt.size();
    _ = program.add(.call, .{ .code_target = @intCast(subroutine_call) });
    _ = program.add(.halt, .none);
    _ = program.add(.push, .{ .signed = 7 });
    _ = program.add(.ret, .none);

    try expectVerified(.{
        .code = program.code(),
        .memory_size = 256,
        .code_len = @intCast(program.code().len),
    });
}

test "an entry point past the first instruction is honoured" {
    var program: Builder = .{};
    // The static data is usually in its own region. But an entry point that goes
    // past a prologue must also work.
    _ = program.addByte(0xfe);
    const entry = program.add(.halt, .none);

    try expectVerified(.{ .code = program.code(), .entry_point = @intCast(entry) });
    // The same bytes do not decode from offset 0.
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
    // This jump goes one byte into the `push`. At that byte, the VM executes an
    // operand byte as an opcode.
    _ = program.add(.push, .{ .signed = 0 });
    const jump = program.add(.jmp, .{ .code_target = 1 });

    try expectFailure(.{ .code = program.code() }, error.MisalignedTarget, jump);
}

test "an overlap is caught when the instruction is decoded after its target" {
    // The verifier decodes the `jmp_not_zero` at 10 first and makes a boundary
    // at that offset. The `push` at its target then uses byte 10 as an operand.
    // One of the two must be wrong. This is true for each possible sequence of
    // the decodes.
    var program: Builder = .{};
    _ = program.add(.jmp, .{ .code_target = 10 });
    _ = program.addByte(0); // a byte that the program cannot reach
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

    // A program can end with `halt`, `ret` or `jmp`. Control does not continue
    // after these instructions.
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
    // The program cannot reach these bytes after `halt` from the entry point.
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

test "a load or store address is checked when the size of memory is known" {
    var program: Builder = .{};
    _ = program.add(.store, .{ .data_address = 256 });
    _ = program.add(.halt, .none);

    // The access is four bytes wide. Therefore 256 needs memory of 260 bytes, and
    // memory of 256 bytes or of 259 bytes is not enough.
    try expectFailure(.{ .code = program.code(), .memory_size = 256 }, error.DataAddressOutOfRange, 0);
    try expectFailure(.{ .code = program.code(), .memory_size = 259 }, error.DataAddressOutOfRange, 0);
    try expectVerified(.{ .code = program.code(), .memory_size = 260 });

    // If the caller does not set the size of memory, the VM does this check.
    try expectVerified(.{ .code = program.code() });
}

test "a store into the code region is refused before the program runs" {
    var program: Builder = .{};
    _ = program.add(.store, .{ .data_address = 0 });
    _ = program.add(.halt, .none);
    const code_len: u32 = @intCast(program.code().len);

    // Address 0 is the first byte of the code. A program that wrote there would
    // change an instruction that this verifier has already read.
    try expectFailure(
        .{ .code = program.code(), .code_len = code_len },
        error.StoreIntoCodeRegion,
        0,
    );
    // The last byte of the code is still the code.
    try expectFailure(
        .{ .code = program.code(), .code_len = code_len },
        error.StoreIntoCodeRegion,
        0,
    );

    // The first byte after the code is not.
    var past: Builder = .{};
    _ = past.add(.store, .{ .data_address = code_len });
    _ = past.add(.halt, .none);
    try expectVerified(.{ .code = past.code(), .code_len = code_len });

    // A `load` may read the code, so the same address is accepted for it.
    var reader: Builder = .{};
    _ = reader.add(.load, .{ .data_address = 0 });
    _ = reader.add(.halt, .none);
    try expectVerified(.{ .code = reader.code(), .code_len = @intCast(reader.code().len) });
}

test "verification needs one scratch mark per code byte" {
    var program: Builder = .{};
    _ = program.add(.halt, .none);

    var scratch: [0]Mark = undefined;
    try testing.expectEqual(@as(usize, 1), scratchSize(program.code().len));
    try testing.expectError(error.ScratchTooSmall, verify(.{ .code = program.code() }, &scratch, null));
}

test "verifying from an address reaches code that the first walk did not" {
    // A function that only a `call_indirect` names is not reachable from the entry
    // point, so the walk at load time leaves it unknown. `verifyFrom` is how the VM
    // checks it when a call first goes there.
    var program: Builder = .{};
    _ = program.add(.halt, .none);
    const function = program.add(.push, .{ .signed = 7 });
    _ = program.add(.ret, .none);

    const options: Options = .{ .code = program.code() };
    var scratch: [128]Mark = undefined;
    try verify(options, &scratch, null);

    // The first walk stopped at `halt`, so the function is bytes it never read.
    try testing.expectEqual(Mark.unknown, scratch[function]);

    try verifyFrom(options, &scratch, @intCast(function), null);
    try testing.expectEqual(Mark.boundary, scratch[function]);
    // The `ret` after it was reached through the fall-through of the `push`.
    try testing.expectEqual(Mark.boundary, scratch[function + OpCode.push.size()]);

    // A second call is answered by the marks that the first one left.
    try verifyFrom(options, &scratch, @intCast(function), null);
}

test "verifying from an address applies the checks that the first walk applies" {
    var program: Builder = .{};
    _ = program.add(.halt, .none);
    // A function whose body runs off the end of the code region.
    const runs_off = program.add(.push, .{ .signed = 1 });

    const options: Options = .{ .code = program.code() };
    var scratch: [128]Mark = undefined;
    try verify(options, &scratch, null);

    var failure: Failure = undefined;
    try testing.expectError(
        error.ExecutionRunsOffEnd,
        verifyFrom(options, &scratch, @intCast(runs_off), &failure),
    );
    try testing.expectEqual(runs_off, failure.offset);

    // An address with no instruction is refused before anything runs.
    var unknown_byte: Builder = .{};
    _ = unknown_byte.add(.halt, .none);
    const bad = unknown_byte.addByte(0xfe);

    const second: Options = .{ .code = unknown_byte.code() };
    try verify(second, &scratch, null);
    try testing.expectError(
        error.UnknownOpcode,
        verifyFrom(second, &scratch, @intCast(bad), &failure),
    );
}

test "verifying from an address inside an instruction is refused" {
    // The first walk marked the operand bytes of the `push`, so an address inside it
    // is known to be no place to start. Without that mark the verifier would decode
    // an operand byte as an opcode and could not tell.
    var program: Builder = .{};
    _ = program.add(.push, .{ .signed = 1 });
    _ = program.add(.halt, .none);

    const options: Options = .{ .code = program.code() };
    var scratch: [128]Mark = undefined;
    try verify(options, &scratch, null);
    try testing.expectEqual(Mark.interior, scratch[1]);

    var failure: Failure = undefined;
    try testing.expectError(error.MisalignedTarget, verifyFrom(options, &scratch, 1, &failure));
    try testing.expectEqual(@as(usize, 1), failure.offset);

    // An address past the code region is not in the program at all.
    try testing.expectError(
        error.TargetOutOfRange,
        verifyFrom(options, &scratch, @intCast(program.code().len), &failure),
    );
}
