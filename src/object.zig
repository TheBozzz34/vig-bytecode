//! The VIG relocatable object format: what a compiler or an assembler makes for
//! one translation unit, and what the linker joins into a container.
//!
//! ```text
//! offset size field
//!      0    4 magic "VIGO"
//!      4    1 format version
//!      5    1 flags
//!      6    1 import count
//!      7    1 reserved, must be zero
//!      8    4 code length            (little-endian u32)
//!     12    4 static-data length
//!     16    4 zero-filled length
//!     20    4 import-table length in bytes
//!     24    4 symbol count
//!     28    4 relocation count
//!     32    4 string-table length in bytes
//!     36      import table, `import count` entries
//!             symbol records, 16 bytes each
//!             relocation records, 16 bytes each
//!             string table
//!             code
//!             static data
//! ```
//!
//! An object is not a program. It has no entry point, because which function
//! starts the program is a decision of the link and not of any one translation
//! unit: the linker finds the entry by name. Its code is not verifiable on its
//! own either, since a `call` to another object cannot be followed until the
//! address of that function is known. Therefore nothing here verifies the code.
//! The linker verifies once, after the last relocation is applied, and that
//! check covers every byte that will actually run.
//!
//! ## Addresses in an object are section-relative
//!
//! A container holds one image and one address space. An object holds three
//! sections that the linker will place, so every address in it is an offset
//! from the start of a section that it names. The three are the code, the
//! static data, and the zero-filled region. A symbol says which section it
//! belongs to and how far into it, and a relocation says which section holds
//! the bytes it patches.
//!
//! A relocation cannot patch the zero-filled region: that region has no bytes
//! in the file to patch. Only the code and the static data can hold one.
//!
//! ## The import table is the container's import table
//!
//! An object declares its foreign imports in exactly the encoding a container
//! uses, and this file writes and reads it through `container`. The linker
//! merges the tables of its inputs and writes the result straight into the
//! container it produces, so a second encoding would be a second thing to keep
//! in step for no gain.
//!
//! The one difference is what an index means. A `foreign_call` in an object
//! names an entry of *that object's* table. The linker deduplicates the tables
//! of all its inputs, so the index changes; a `foreign_import8` relocation
//! marks the operand byte so the linker can rewrite it.
//!
//! ## Names
//!
//! A symbol record holds an offset into the string table rather than the name
//! itself, so every record is the same size and the reader can find record `n`
//! without decoding the ones before it. A relocation names its symbol by that
//! index into the symbol table, in file order.
//!
//! A string is a little-endian `u16` length and then the bytes. There is no
//! terminator: a name is a slice of the file, and a reader that has the length
//! never needs one.

const std = @import("std");
const abi = @import("abi.zig");
const container = @import("container.zig");
const foreign = @import("foreign.zig");

pub const magic = "VIGO";

/// The format version that this package writes. An object is a build artefact
/// with a life of one command, so there is no older version to read: a file
/// from another version is refused rather than translated.
pub const vig32_version: u8 = abi.Profile.vig32.objectVersion();
pub const vig64_version: u8 = abi.Profile.vig64.objectVersion();
/// The version this package writes until the wider VIG64 object records are in
/// place.
pub const version: u8 = vig32_version;

pub fn profileForVersion(file_version: u8) ?abi.Profile {
    return abi.Profile.fromObjectVersion(file_version);
}

pub const header_size = 36;
pub const symbol_record_size = 16;
pub const relocation_record_size = 16;
/// VIG64 objects use a wide header and fixed 32-byte symbol and relocation
/// records. They are separate from the VIG32 records above.
pub const vig64_header_size = 64;
pub const vig64_symbol_record_size = 32;
pub const vig64_relocation_record_size = 32;

/// The largest alignment a symbol may ask for, as a power of two. A section of
/// a VIG program is placed inside one small guest memory, so an alignment past
/// a page would waste more of it than any access could win back.
pub const max_alignment_shift: u8 = 16;

const offset_version = 4;
const offset_flags = 5;
const offset_import_count = 6;
const offset_reserved = 7;
const offset_code_len = 8;
const offset_data_len = 12;
const offset_bss_len = 16;
const offset_import_table_len = 20;
const offset_symbol_count = 24;
const offset_relocation_count = 28;
const offset_string_table_len = 32;

const symbol_name_offset = 0;
const symbol_offset = 4;
const symbol_size = 8;
const symbol_alignment_shift = 12;
const symbol_binding = 13;
const symbol_kind = 14;
const symbol_section = 15;

const relocation_offset = 0;
const relocation_target = 4;
const relocation_addend = 8;
const relocation_kind = 12;
const relocation_section = 13;
const relocation_reserved = 14;

/// The errors of this format, and the errors of the import table it shares with
/// `container`. An object's import table is a container's import table, so a
/// fault in one is reported with the name the container reader gives it.
pub const Error = container.Error || error{
    InvalidObjectHeader,
    UnsupportedObjectVersion,
    UnsupportedObjectFlags,
    ObjectSizeMismatch,
    InvalidSymbol,
    InvalidRelocation,
    NameTooLong,
};

test "the numbered object versions select an explicit ABI profile" {
    try std.testing.expectEqual(abi.Profile.vig32, profileForVersion(vig32_version).?);
    try std.testing.expectEqual(abi.Profile.vig64, profileForVersion(vig64_version).?);
    try std.testing.expect(profileForVersion(3) == null);
}

/// The flags for the complete object. Every bit is reserved, and a reader
/// refuses an object that sets one. A tool must understand a flag before it can
/// use the file, so it must refuse a file whose flags it does not know.
pub const Flags = packed struct(u8) {
    reserved: u8 = 0,

    pub fn toByte(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) Error!Flags {
        const flags: Flags = @bitCast(byte);
        if (flags.reserved != 0) return error.UnsupportedObjectFlags;
        return flags;
    }
};

/// Which region of the object an address belongs to. `none` is for a symbol
/// that this object does not place: one it expects from elsewhere, and one it
/// asks the linker to make room for.
pub const Section = enum(u8) {
    none = 0,
    code = 1,
    data = 2,
    bss = 3,

    pub fn fromByte(byte: u8) Error!Section {
        return std.enums.fromInt(Section, byte) orelse error.InvalidSymbol;
    }
};

/// What a symbol names. The linker uses this to refuse a relocation that would
/// call a variable or read a function as data, so the two cannot be confused by
/// a mistake in one object that the other objects cannot see.
pub const SymbolKind = enum(u8) {
    function = 0,
    object = 1,

    pub fn fromByte(byte: u8) Error!SymbolKind {
        return std.enums.fromInt(SymbolKind, byte) orelse error.InvalidSymbol;
    }
};

/// How a symbol takes part in the link.
pub const Binding = enum(u8) {
    /// Defined here and invisible to every other object. Two objects may each
    /// have a local of the same name and they stay separate. A local needs no
    /// name at all, which lets a producer place a label it only refers to by
    /// index.
    local = 0,
    /// Defined here and offered to every other object. Two definitions of one
    /// name are an error.
    global = 1,
    /// Used here and defined somewhere else. The link fails if nothing defines
    /// it.
    undefined = 2,
    /// A request for space rather than a definition. Several objects may ask
    /// for the same name, and the linker makes one region as large and as
    /// aligned as the largest request. This is what a C tentative definition
    /// -- `int counter;` at file scope, with no initialiser -- becomes.
    common = 3,

    pub fn fromByte(byte: u8) Error!Binding {
        return std.enums.fromInt(Binding, byte) orelse error.InvalidSymbol;
    }
};

/// What a relocation writes over the bytes it names.
pub const RelocationType = enum(u8) {
    /// Four bytes holding a code offset: the operand of a `call` or a `jmp`,
    /// and an entry of a jump table in the static data. The target must be a
    /// function, and the address must land inside the linked code.
    code_target32 = 0,
    /// Four bytes holding the guest address of a variable: the operand of a
    /// `load` or a `store`. The target must be an object.
    data_address32 = 1,
    /// Four bytes holding a guest address of no stated kind. This is what the
    /// address of something becomes when it is only ever a value -- a `void *`
    /// that may point at a function or at a variable -- and the checks the
    /// other two apply cannot be applied to it.
    guest_address32 = 2,
    /// One byte holding an index into this object's import table, which the
    /// linker rewrites to the index in the merged table.
    foreign_import8 = 3,

    pub fn fromByte(byte: u8) Error!RelocationType {
        return std.enums.fromInt(RelocationType, byte) orelse error.InvalidRelocation;
    }

    /// The number of bytes this relocation writes.
    pub fn width(self: RelocationType) u32 {
        return switch (self) {
            .foreign_import8 => 1,
            .code_target32, .data_address32, .guest_address32 => 4,
        };
    }
};

/// One symbol. `name` points into the file that supplied it.
pub const Symbol = struct {
    name: []const u8,
    binding: Binding,
    kind: SymbolKind,
    section: Section,
    /// How far into `section` the symbol sits. Zero for an undefined symbol and
    /// for a common one, neither of which this object places.
    offset: u32 = 0,
    /// How many bytes the symbol occupies. Zero means unstated, except for a
    /// common symbol, where it is the size of the request and must be at least
    /// one byte.
    size: u32 = 0,
    /// Always a power of two, because the encoding holds the exponent.
    alignment: u32 = 1,
};

/// One relocation: a place in this object's code or static data that cannot be
/// filled in until the linker has chosen addresses.
pub const Relocation = struct {
    relocation_type: RelocationType,
    /// Which region holds the bytes to patch. Only `code` and `data` have bytes
    /// in the file.
    section: Section,
    /// How far into `section` those bytes start.
    offset: u32,
    /// The symbol this refers to, as an index into the symbol table of this
    /// object -- or, for `foreign_import8`, into its import table.
    target: u32,
    /// Added to the address of the target. This is how `&array[3]` is written:
    /// the symbol is `array` and the addend is twelve. It must be zero for
    /// `foreign_import8`, where the value is an index and not an address.
    addend: i32 = 0,

    pub fn width(self: Relocation) u32 {
        return self.relocation_type.width();
    }
};

pub const Vig64RelocationType = enum(u8) {
    code_target64 = 0,
    data_address64 = 1,
    guest_address64 = 2,
    foreign_import8 = 3,

    pub fn fromByte(byte: u8) Error!Vig64RelocationType {
        return std.enums.fromInt(Vig64RelocationType, byte) orelse error.InvalidRelocation;
    }

    pub fn width(self: Vig64RelocationType) u64 {
        return switch (self) {
            .foreign_import8 => 1,
            .code_target64, .data_address64, .guest_address64 => 8,
        };
    }
};

pub const Vig64Symbol = struct {
    name: []const u8,
    binding: Binding,
    kind: SymbolKind,
    section: Section,
    offset: u64 = 0,
    size: u64 = 0,
    alignment: u32 = 1,
};

pub const Vig64Relocation = struct {
    relocation_type: Vig64RelocationType,
    section: Section,
    offset: u64,
    target: u64,
    addend: i64 = 0,

    pub fn width(self: Vig64Relocation) u64 {
        return self.relocation_type.width();
    }
};

/// One `extern` declaration of this object, with the index that its own
/// `foreign_call` instructions use.
pub const ForeignImport = struct {
    index: u8,
    import: foreign.Import,
};

/// An object after a parse: the counts and slices into the source bytes. The
/// image does not own these slices.
pub const Image = struct {
    format_version: u8,
    flags: Flags,
    import_count: u8,
    symbol_count: u32,
    relocation_count: u32,
    /// The encoded import table. Use `importIterator` to read the entries.
    imports: []const u8,
    /// The encoded symbol records. Use `symbolIterator`.
    symbol_records: []const u8,
    /// The encoded relocation records. Use `relocationIterator`.
    relocation_records: []const u8,
    /// The names that the symbol records point into.
    strings: []const u8,
    code: []const u8,
    data: []const u8,
    /// The number of zero bytes this object adds after its static data. These
    /// bytes are not in the file.
    bss_len: u32,

    /// The length of each section, indexed by the section tag. A reader checks
    /// every offset in the file against this, so no symbol and no relocation
    /// can name a byte outside the object that declared it.
    pub fn sectionLens(self: Image) [4]u32 {
        return .{ 0, @intCast(self.code.len), @intCast(self.data.len), self.bss_len };
    }

    pub fn symbolIterator(self: Image) SymbolIterator {
        return .{
            .records = self.symbol_records,
            .strings = self.strings,
            .section_lens = self.sectionLens(),
            .remaining = self.symbol_count,
        };
    }

    pub fn relocationIterator(self: Image) RelocationIterator {
        return .{
            .records = self.relocation_records,
            .section_lens = self.sectionLens(),
            .symbol_count = self.symbol_count,
            .import_count = self.import_count,
            .remaining = self.relocation_count,
        };
    }

    pub fn importIterator(self: Image) ImportIterator {
        return .{ .inner = .{ .bytes = self.imports, .remaining = self.import_count } };
    }
};

/// A parsed VIG64 object. The slices point into the source bytes, as they do
/// for `Image`, but all section offsets and counts are u64.
pub const Vig64Image = struct {
    flags: Flags,
    import_count: u8,
    symbol_count: u64,
    relocation_count: u64,
    imports: []const u8,
    symbol_records: []const u8,
    relocation_records: []const u8,
    strings: []const u8,
    code: []const u8,
    data: []const u8,
    bss_len: u64,

    pub fn sectionLens(self: Vig64Image) [4]u64 {
        return .{ 0, self.code.len, self.data.len, self.bss_len };
    }

    pub fn importIterator(self: Vig64Image) container.Vig64ImportIterator {
        return .{ .bytes = self.imports, .remaining = self.import_count };
    }

    pub fn symbolIterator(self: Vig64Image) Vig64SymbolIterator {
        return .{ .records = self.symbol_records, .strings = self.strings, .section_lens = self.sectionLens(), .remaining = self.symbol_count };
    }

    pub fn relocationIterator(self: Vig64Image) Vig64RelocationIterator {
        return .{ .records = self.relocation_records, .section_lens = self.sectionLens(), .symbol_count = self.symbol_count, .import_count = self.import_count, .remaining = self.relocation_count };
    }
};

pub const Vig64SymbolIterator = struct {
    records: []const u8,
    strings: []const u8,
    section_lens: [4]u64,
    remaining: u64,
    offset: usize = 0,

    pub fn next(self: *Vig64SymbolIterator) Error!?Vig64Symbol {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        if (self.records.len - self.offset < vig64_symbol_record_size) return error.InvalidSymbol;
        const record = self.records[self.offset..][0..vig64_symbol_record_size];
        self.offset += vig64_symbol_record_size;
        const shift = record[24];
        if (shift > max_alignment_shift) return error.InvalidSymbol;
        for (record[28..32]) |byte| if (byte != 0) return error.InvalidSymbol;
        const symbol: Vig64Symbol = .{
            .name = try readVig64Name(self.strings, std.mem.readInt(u64, record[0..8], .little)),
            .offset = std.mem.readInt(u64, record[8..16], .little),
            .size = std.mem.readInt(u64, record[16..24], .little),
            .alignment = @as(u32, 1) << @intCast(shift),
            .binding = try Binding.fromByte(record[25]),
            .kind = try SymbolKind.fromByte(record[26]),
            .section = try Section.fromByte(record[27]),
        };
        try checkVig64Symbol(symbol, self.section_lens);
        return symbol;
    }
};

pub const Vig64RelocationIterator = struct {
    records: []const u8,
    section_lens: [4]u64,
    symbol_count: u64,
    import_count: u8,
    remaining: u64,
    offset: usize = 0,

    pub fn next(self: *Vig64RelocationIterator) Error!?Vig64Relocation {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        if (self.records.len - self.offset < vig64_relocation_record_size) return error.InvalidRelocation;
        const record = self.records[self.offset..][0..vig64_relocation_record_size];
        self.offset += vig64_relocation_record_size;
        for (record[26..32]) |byte| if (byte != 0) return error.InvalidRelocation;
        const relocation: Vig64Relocation = .{
            .offset = std.mem.readInt(u64, record[0..8], .little),
            .target = std.mem.readInt(u64, record[8..16], .little),
            .addend = std.mem.readInt(i64, record[16..24], .little),
            .relocation_type = try Vig64RelocationType.fromByte(record[24]),
            .section = Section.fromByte(record[25]) catch return error.InvalidRelocation,
        };
        try checkVig64Relocation(relocation, self.section_lens, self.symbol_count, self.import_count);
        return relocation;
    }
};

pub const SymbolIterator = struct {
    records: []const u8,
    strings: []const u8,
    section_lens: [4]u32,
    remaining: u32,
    offset: usize = 0,

    pub fn next(self: *SymbolIterator) Error!?Symbol {
        if (self.remaining == 0) return null;
        self.remaining -= 1;

        if (self.records.len - self.offset < symbol_record_size) return error.InvalidSymbol;
        const record = self.records[self.offset..][0..symbol_record_size];
        self.offset += symbol_record_size;

        const shift = record[symbol_alignment_shift];
        if (shift > max_alignment_shift) return error.InvalidSymbol;

        const symbol: Symbol = .{
            .name = try readName(self.strings, readU32(record, symbol_name_offset)),
            .binding = try Binding.fromByte(record[symbol_binding]),
            .kind = try SymbolKind.fromByte(record[symbol_kind]),
            .section = try Section.fromByte(record[symbol_section]),
            .offset = readU32(record, symbol_offset),
            .size = readU32(record, symbol_size),
            .alignment = @as(u32, 1) << @intCast(shift),
        };
        try checkSymbol(symbol, self.section_lens);
        return symbol;
    }
};

pub const RelocationIterator = struct {
    records: []const u8,
    section_lens: [4]u32,
    symbol_count: u32,
    import_count: u8,
    remaining: u32,
    offset: usize = 0,

    pub fn next(self: *RelocationIterator) Error!?Relocation {
        if (self.remaining == 0) return null;
        self.remaining -= 1;

        if (self.records.len - self.offset < relocation_record_size) return error.InvalidRelocation;
        const record = self.records[self.offset..][0..relocation_record_size];
        self.offset += relocation_record_size;

        if (record[relocation_reserved] != 0 or record[relocation_reserved + 1] != 0) {
            return error.InvalidRelocation;
        }

        const relocation: Relocation = .{
            .relocation_type = try RelocationType.fromByte(record[relocation_kind]),
            .section = Section.fromByte(record[relocation_section]) catch
                return error.InvalidRelocation,
            .offset = readU32(record, relocation_offset),
            .target = readU32(record, relocation_target),
            .addend = @bitCast(readU32(record, relocation_addend)),
        };
        try checkRelocation(relocation, self.section_lens, self.symbol_count, self.import_count);
        return relocation;
    }
};

/// The import table of an object, with each entry's own index alongside it.
pub const ImportIterator = struct {
    inner: container.ImportIterator,
    index: u8 = 0,

    pub fn next(self: *ImportIterator) Error!?ForeignImport {
        const import = (try self.inner.next()) orelse return null;
        const index = self.index;
        self.index += 1;
        return .{ .index = index, .import = import };
    }
};

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn readName(strings: []const u8, offset: u32) Error![]const u8 {
    if (offset > strings.len or strings.len - offset < 2) return error.InvalidSymbol;
    const len = std.mem.readInt(u16, strings[offset..][0..2], .little);
    const start = @as(usize, offset) + 2;
    if (strings.len - start < len) return error.InvalidSymbol;
    return strings[start..][0..len];
}

fn readVig64Name(strings: []const u8, offset: u64) Error![]const u8 {
    if (offset > strings.len or strings.len - @as(usize, @intCast(offset)) < 2) return error.InvalidSymbol;
    const start = @as(usize, @intCast(offset));
    const len = std.mem.readInt(u16, strings[start..][0..2], .little);
    if (strings.len - start - 2 < len) return error.InvalidSymbol;
    return strings[start + 2 ..][0..len];
}

/// The checks that a symbol must pass, applied both when one is written and
/// when one is read. Writing an object that this reader would refuse is a fault
/// in the producer, and it is cheaper to find at the point that made it.
fn checkSymbol(symbol: Symbol, section_lens: [4]u32) Error!void {
    switch (symbol.binding) {
        .local, .global => {
            if (symbol.section == .none) return error.InvalidSymbol;
            // A definition with no name cannot be offered to another object.
            if (symbol.binding == .global and symbol.name.len == 0) return error.InvalidSymbol;

            const limit = section_lens[@intFromEnum(symbol.section)];
            // A label may sit at the very end of its section, which is one past
            // the last byte, so the comparison allows equality.
            if (symbol.offset > limit) return error.InvalidSymbol;
            if (symbol.size > limit - symbol.offset) return error.InvalidSymbol;
            // The linker aligns the base of a section to the strongest alignment
            // any symbol in it asks for. Therefore a symbol whose offset is not a
            // multiple of its own alignment can never come out aligned, whatever
            // the linker does with the section.
            if (symbol.offset % symbol.alignment != 0) return error.InvalidSymbol;
        },
        .undefined, .common => {
            // Neither is placed by this object, so neither may name a section or
            // an offset in one.
            if (symbol.section != .none or symbol.offset != 0) return error.InvalidSymbol;
            if (symbol.name.len == 0) return error.InvalidSymbol;
            // A common symbol is a request for space, and a request for no space
            // is not a request. Without this it would read as an undefined symbol
            // that nothing defines.
            if (symbol.binding == .common and symbol.size == 0) return error.InvalidSymbol;
            if (symbol.binding == .undefined and symbol.size != 0) return error.InvalidSymbol;
        },
    }
}

fn checkVig64Symbol(symbol: Vig64Symbol, section_lens: [4]u64) Error!void {
    switch (symbol.binding) {
        .local, .global => {
            if (symbol.section == .none) return error.InvalidSymbol;
            if (symbol.binding == .global and symbol.name.len == 0) return error.InvalidSymbol;
            const limit = section_lens[@intFromEnum(symbol.section)];
            if (symbol.offset > limit or symbol.size > limit - symbol.offset) return error.InvalidSymbol;
            if (symbol.offset % symbol.alignment != 0) return error.InvalidSymbol;
        },
        .undefined, .common => {
            if (symbol.section != .none or symbol.offset != 0 or symbol.name.len == 0) return error.InvalidSymbol;
            if (symbol.binding == .common and symbol.size == 0) return error.InvalidSymbol;
            if (symbol.binding == .undefined and symbol.size != 0) return error.InvalidSymbol;
        },
    }
}

fn checkRelocation(
    relocation: Relocation,
    section_lens: [4]u32,
    symbol_count: u32,
    import_count: u8,
) Error!void {
    const limit = switch (relocation.section) {
        .code, .data => section_lens[@intFromEnum(relocation.section)],
        // The zero-filled region has no bytes in the file to patch, and `none`
        // is not a place at all.
        .bss, .none => return error.InvalidRelocation,
    };
    const width = relocation.width();
    if (relocation.offset > limit or limit - relocation.offset < width) {
        return error.InvalidRelocation;
    }

    switch (relocation.relocation_type) {
        .foreign_import8 => {
            // The value is an index into a table, so there is nothing to add to
            // it. A non-zero addend here would mean the producer confused this
            // relocation with an address.
            if (relocation.addend != 0) return error.InvalidRelocation;
            if (relocation.target >= import_count) return error.InvalidRelocation;
        },
        .code_target32, .data_address32, .guest_address32 => {
            if (relocation.target >= symbol_count) return error.InvalidRelocation;
        },
    }
}

fn checkVig64Relocation(relocation: Vig64Relocation, section_lens: [4]u64, symbol_count: u64, import_count: u8) Error!void {
    const limit = switch (relocation.section) {
        .code, .data => section_lens[@intFromEnum(relocation.section)],
        .bss, .none => return error.InvalidRelocation,
    };
    const width = relocation.width();
    if (relocation.offset > limit or limit - relocation.offset < width) return error.InvalidRelocation;
    switch (relocation.relocation_type) {
        .foreign_import8 => {
            if (relocation.addend != 0 or relocation.target >= import_count) return error.InvalidRelocation;
        },
        .code_target64, .data_address64, .guest_address64 => {
            if (relocation.target >= symbol_count) return error.InvalidRelocation;
        },
    }
}

fn alignmentShift(alignment: u32) Error!u8 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidSymbol;
    const shift = std.math.log2_int(u32, alignment);
    if (shift > max_alignment_shift) return error.InvalidSymbol;
    return @intCast(shift);
}

/// Parse an object. Every slice in the result points into `bytes`.
pub fn parse(bytes: []const u8) Error!Image {
    if (bytes.len < header_size) return error.InvalidObjectHeader;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidObjectHeader;
    if (bytes[offset_version] != version) return error.UnsupportedObjectVersion;
    if (bytes[offset_reserved] != 0) return error.InvalidObjectHeader;

    const flags = try Flags.fromByte(bytes[offset_flags]);
    const import_count = bytes[offset_import_count];
    if (import_count > foreign.max_imports) return error.TooManyForeignImports;

    const code_len = readU32(bytes, offset_code_len);
    const data_len = readU32(bytes, offset_data_len);
    const bss_len = readU32(bytes, offset_bss_len);
    const import_table_len = readU32(bytes, offset_import_table_len);
    const symbol_count = readU32(bytes, offset_symbol_count);
    const relocation_count = readU32(bytes, offset_relocation_count);
    const string_table_len = readU32(bytes, offset_string_table_len);

    // Every length is a u32 and the total is computed as a u64, so the sum
    // cannot wrap and hide a region that runs past the end of the file.
    const symbol_bytes = @as(u64, symbol_count) * symbol_record_size;
    const relocation_bytes = @as(u64, relocation_count) * relocation_record_size;
    const declared = @as(u64, header_size) + import_table_len + symbol_bytes +
        relocation_bytes + string_table_len + code_len + data_len;
    if (declared != bytes.len) return error.ObjectSizeMismatch;

    // The declared lengths add up to the size of the file. Therefore each of
    // these offsets is inside it.
    var cursor: usize = header_size;
    const imports = bytes[cursor..][0..import_table_len];
    cursor += import_table_len;
    const symbol_records = bytes[cursor..][0..@intCast(symbol_bytes)];
    cursor += @intCast(symbol_bytes);
    const relocation_records = bytes[cursor..][0..@intCast(relocation_bytes)];
    cursor += @intCast(relocation_bytes);
    const strings = bytes[cursor..][0..string_table_len];
    cursor += string_table_len;
    const code = bytes[cursor..][0..code_len];
    cursor += code_len;
    const data = bytes[cursor..][0..data_len];

    // The table must decode to exactly `import_count` entries, and those
    // entries must fill `import_table_len` bytes. If they do not, the header
    // and the table disagree about what the file holds.
    if (try container.importTableSize(imports, import_count) != imports.len) {
        return error.ObjectSizeMismatch;
    }

    return .{
        .format_version = version,
        .flags = flags,
        .import_count = import_count,
        .symbol_count = symbol_count,
        .relocation_count = relocation_count,
        .imports = imports,
        .symbol_records = symbol_records,
        .relocation_records = relocation_records,
        .strings = strings,
        .code = code,
        .data = data,
        .bss_len = bss_len,
    };
}

/// Parse a version 2 VIG64 object. VIG32 parsing remains separate so a linker
/// cannot accidentally mix its 32-bit relocations with these wide records.
pub fn parseVig64(bytes: []const u8) Error!Vig64Image {
    if (bytes.len < vig64_header_size) return error.InvalidObjectHeader;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidObjectHeader;
    if (bytes[offset_version] != vig64_version) return error.UnsupportedObjectVersion;
    if (bytes[offset_reserved] != 0) return error.InvalidObjectHeader;

    const flags = try Flags.fromByte(bytes[offset_flags]);
    const import_count = bytes[offset_import_count];
    if (import_count > foreign.max_imports) return error.TooManyForeignImports;
    const code_len = std.mem.readInt(u64, bytes[8..16], .little);
    const data_len = std.mem.readInt(u64, bytes[16..24], .little);
    const bss_len = std.mem.readInt(u64, bytes[24..32], .little);
    const import_table_len = std.mem.readInt(u64, bytes[32..40], .little);
    const symbol_count = std.mem.readInt(u64, bytes[40..48], .little);
    const relocation_count = std.mem.readInt(u64, bytes[48..56], .little);
    const string_table_len = std.mem.readInt(u64, bytes[56..64], .little);
    const symbol_bytes = @as(u128, symbol_count) * vig64_symbol_record_size;
    const relocation_bytes = @as(u128, relocation_count) * vig64_relocation_record_size;
    const declared = @as(u128, vig64_header_size) + import_table_len + symbol_bytes + relocation_bytes + string_table_len + code_len + data_len;
    if (declared != bytes.len) return error.ObjectSizeMismatch;
    if (import_table_len > std.math.maxInt(usize) or symbol_bytes > std.math.maxInt(usize) or relocation_bytes > std.math.maxInt(usize) or string_table_len > std.math.maxInt(usize) or code_len > std.math.maxInt(usize) or data_len > std.math.maxInt(usize)) return error.ObjectSizeMismatch;

    var cursor: usize = vig64_header_size;
    const imports = bytes[cursor..][0..@intCast(import_table_len)];
    cursor += imports.len;
    const symbol_records = bytes[cursor..][0..@intCast(symbol_bytes)];
    cursor += symbol_records.len;
    const relocation_records = bytes[cursor..][0..@intCast(relocation_bytes)];
    cursor += relocation_records.len;
    const strings = bytes[cursor..][0..@intCast(string_table_len)];
    cursor += strings.len;
    const code = bytes[cursor..][0..@intCast(code_len)];
    cursor += code.len;
    const data = bytes[cursor..][0..@intCast(data_len)];
    if (try container.vig64ImportTableSize(imports, import_count) != imports.len) return error.ObjectSizeMismatch;

    return .{ .flags = flags, .import_count = import_count, .symbol_count = symbol_count, .relocation_count = relocation_count, .imports = imports, .symbol_records = symbol_records, .relocation_records = relocation_records, .strings = strings, .code = code, .data = data, .bss_len = bss_len };
}

/// The data for `write`. A symbol's name is written into the string table in
/// the order the symbols appear, so a relocation's `target` is an index into
/// this same `symbols` slice.
pub const Layout = struct {
    imports: []const foreign.Import = &.{},
    symbols: []const Symbol = &.{},
    relocations: []const Relocation = &.{},
    code: []const u8,
    data: []const u8 = &.{},
    bss_len: u32 = 0,
    flags: Flags = .{},
};

pub const Vig64Layout = struct {
    imports: []const foreign.Vig64Import = &.{},
    symbols: []const Vig64Symbol = &.{},
    relocations: []const Vig64Relocation = &.{},
    code: []const u8,
    data: []const u8 = &.{},
    bss_len: u64 = 0,
    flags: Flags = .{},
};

const Sizes = struct {
    import_table: u32,
    symbols: u32,
    relocations: u32,
    strings: u32,
    total: usize,
};

/// Measure a layout and apply every limit the format has. `encodedSize` and
/// `write` both go through here, so a layout that measures is a layout that
/// writes, and what it writes is a file that `parse` accepts.
fn measure(layout: Layout) Error!Sizes {
    const import_table = try container.importTableLen(layout.imports);
    const symbol_count = std.math.cast(u32, layout.symbols.len) orelse
        return error.ObjectSizeMismatch;
    const relocation_count = std.math.cast(u32, layout.relocations.len) orelse
        return error.ObjectSizeMismatch;
    const code_len = std.math.cast(u32, layout.code.len) orelse return error.ObjectSizeMismatch;
    const data_len = std.math.cast(u32, layout.data.len) orelse return error.ObjectSizeMismatch;

    const section_lens: [4]u32 = .{ 0, code_len, data_len, layout.bss_len };

    var strings: u64 = 0;
    for (layout.symbols) |symbol| {
        if (symbol.name.len > std.math.maxInt(u16)) return error.NameTooLong;
        _ = try alignmentShift(symbol.alignment);
        try checkSymbol(symbol, section_lens);
        strings += 2 + symbol.name.len;
    }
    for (layout.relocations) |relocation| {
        try checkRelocation(
            relocation,
            section_lens,
            symbol_count,
            @intCast(layout.imports.len),
        );
    }

    const string_table = std.math.cast(u32, strings) orelse return error.ObjectSizeMismatch;
    const symbol_bytes = @as(u64, symbol_count) * symbol_record_size;
    const relocation_bytes = @as(u64, relocation_count) * relocation_record_size;
    const total = @as(u64, header_size) + import_table + symbol_bytes + relocation_bytes +
        string_table + code_len + data_len;

    return .{
        .import_table = import_table,
        .symbols = @intCast(symbol_bytes),
        .relocations = @intCast(relocation_bytes),
        .strings = string_table,
        .total = std.math.cast(usize, total) orelse return error.ObjectSizeMismatch,
    };
}

/// The exact size of the file that `write` makes for `layout`.
pub fn encodedSize(layout: Layout) Error!usize {
    return (try measure(layout)).total;
}

pub fn encodedVig64Size(layout: Vig64Layout) Error!usize {
    return (try measureVig64(layout)).total;
}

const Vig64Sizes = struct { imports: u64, strings: u64, total: usize };

fn measureVig64(layout: Vig64Layout) Error!Vig64Sizes {
    const imports = try container.vig64ImportTableLen(layout.imports);
    const section_lens: [4]u64 = .{ 0, layout.code.len, layout.data.len, layout.bss_len };
    var strings: u64 = 0;
    for (layout.symbols) |symbol| {
        if (symbol.name.len > std.math.maxInt(u16)) return error.NameTooLong;
        _ = try alignmentShift(symbol.alignment);
        try checkVig64Symbol(symbol, section_lens);
        strings += 2 + symbol.name.len;
    }
    for (layout.relocations) |relocation| {
        try checkVig64Relocation(relocation, section_lens, layout.symbols.len, @intCast(layout.imports.len));
    }
    const total = @as(u128, vig64_header_size) + imports +
        @as(u128, layout.symbols.len) * vig64_symbol_record_size +
        @as(u128, layout.relocations.len) * vig64_relocation_record_size + strings + layout.code.len + layout.data.len;
    const total_usize = std.math.cast(usize, total) orelse return error.ObjectSizeMismatch;
    return .{ .imports = imports, .strings = strings, .total = total_usize };
}

/// Write a complete object into `dest`. The function gives the number of bytes
/// that it wrote.
pub fn write(layout: Layout, dest: []u8) Error!usize {
    const sizes = try measure(layout);
    if (dest.len < sizes.total) return error.BufferTooSmall;

    @memset(dest[0..header_size], 0);
    @memcpy(dest[0..magic.len], magic);
    dest[offset_version] = version;
    dest[offset_flags] = layout.flags.toByte();
    dest[offset_import_count] = @intCast(layout.imports.len);
    writeU32(dest, offset_code_len, @intCast(layout.code.len));
    writeU32(dest, offset_data_len, @intCast(layout.data.len));
    writeU32(dest, offset_bss_len, layout.bss_len);
    writeU32(dest, offset_import_table_len, sizes.import_table);
    writeU32(dest, offset_symbol_count, @intCast(layout.symbols.len));
    writeU32(dest, offset_relocation_count, @intCast(layout.relocations.len));
    writeU32(dest, offset_string_table_len, sizes.strings);

    var offset: usize = header_size;
    offset += container.writeImportTable(layout.imports, dest[offset..]);

    // A name goes into the string table at the position the ones before it
    // leave, so this runs alongside the records rather than after them.
    var name_offset: u32 = 0;
    for (layout.symbols) |symbol| {
        const record = dest[offset..][0..symbol_record_size];
        writeU32(record, symbol_name_offset, name_offset);
        writeU32(record, symbol_offset, symbol.offset);
        writeU32(record, symbol_size, symbol.size);
        record[symbol_alignment_shift] = try alignmentShift(symbol.alignment);
        record[symbol_binding] = @intFromEnum(symbol.binding);
        record[symbol_kind] = @intFromEnum(symbol.kind);
        record[symbol_section] = @intFromEnum(symbol.section);
        offset += symbol_record_size;
        name_offset += @intCast(2 + symbol.name.len);
    }

    for (layout.relocations) |relocation| {
        const record = dest[offset..][0..relocation_record_size];
        writeU32(record, relocation_offset, relocation.offset);
        writeU32(record, relocation_target, relocation.target);
        writeU32(record, relocation_addend, @bitCast(relocation.addend));
        record[relocation_kind] = @intFromEnum(relocation.relocation_type);
        record[relocation_section] = @intFromEnum(relocation.section);
        record[relocation_reserved] = 0;
        record[relocation_reserved + 1] = 0;
        offset += relocation_record_size;
    }

    for (layout.symbols) |symbol| {
        std.mem.writeInt(u16, dest[offset..][0..2], @intCast(symbol.name.len), .little);
        offset += 2;
        @memcpy(dest[offset..][0..symbol.name.len], symbol.name);
        offset += symbol.name.len;
    }

    @memcpy(dest[offset..][0..layout.code.len], layout.code);
    offset += layout.code.len;
    @memcpy(dest[offset..][0..layout.data.len], layout.data);
    return offset + layout.data.len;
}

/// Write the first VIG64 object form. It contains the V2 header and typed
/// imports. Wide symbol and relocation records are added before this writer is
/// exposed through the assembler.
pub fn writeVig64(layout: Vig64Layout, dest: []u8) Error!usize {
    const sizes = try measureVig64(layout);
    const total = sizes.total;
    if (dest.len < total) return error.BufferTooSmall;

    @memset(dest[0..vig64_header_size], 0);
    @memcpy(dest[0..magic.len], magic);
    dest[offset_version] = vig64_version;
    dest[offset_flags] = layout.flags.toByte();
    dest[offset_import_count] = @intCast(layout.imports.len);
    std.mem.writeInt(u64, dest[8..16], @intCast(layout.code.len), .little);
    std.mem.writeInt(u64, dest[16..24], @intCast(layout.data.len), .little);
    std.mem.writeInt(u64, dest[24..32], layout.bss_len, .little);
    std.mem.writeInt(u64, dest[32..40], sizes.imports, .little);
    std.mem.writeInt(u64, dest[40..48], layout.symbols.len, .little);
    std.mem.writeInt(u64, dest[48..56], layout.relocations.len, .little);
    std.mem.writeInt(u64, dest[56..64], sizes.strings, .little);

    var offset = vig64_header_size + container.writeVig64ImportTable(layout.imports, dest[vig64_header_size..]);
    var name_offset: u64 = 0;
    for (layout.symbols) |symbol| {
        const record = dest[offset..][0..vig64_symbol_record_size];
        @memset(record, 0);
        std.mem.writeInt(u64, record[0..8], name_offset, .little);
        std.mem.writeInt(u64, record[8..16], symbol.offset, .little);
        std.mem.writeInt(u64, record[16..24], symbol.size, .little);
        record[24] = try alignmentShift(symbol.alignment);
        record[25] = @intFromEnum(symbol.binding);
        record[26] = @intFromEnum(symbol.kind);
        record[27] = @intFromEnum(symbol.section);
        offset += vig64_symbol_record_size;
        name_offset += 2 + symbol.name.len;
    }
    for (layout.relocations) |relocation| {
        const record = dest[offset..][0..vig64_relocation_record_size];
        @memset(record, 0);
        std.mem.writeInt(u64, record[0..8], relocation.offset, .little);
        std.mem.writeInt(u64, record[8..16], relocation.target, .little);
        std.mem.writeInt(i64, record[16..24], relocation.addend, .little);
        record[24] = @intFromEnum(relocation.relocation_type);
        record[25] = @intFromEnum(relocation.section);
        offset += vig64_relocation_record_size;
    }
    for (layout.symbols) |symbol| {
        std.mem.writeInt(u16, dest[offset..][0..2], @intCast(symbol.name.len), .little);
        offset += 2;
        @memcpy(dest[offset..][0..symbol.name.len], symbol.name);
        offset += symbol.name.len;
    }
    @memcpy(dest[offset..][0..layout.code.len], layout.code);
    offset += layout.code.len;
    @memcpy(dest[offset..][0..layout.data.len], layout.data);
    return offset + layout.data.len;
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

fn writeAlloc(layout: Layout) ![]u8 {
    const buffer = try testing.allocator.alloc(u8, try encodedSize(layout));
    errdefer testing.allocator.free(buffer);
    try testing.expectEqual(buffer.len, try write(layout, buffer));
    return buffer;
}

const sample_code = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
const sample_data = "hi\x00\x00";

fn sampleLayout() Layout {
    return .{ .code = &sample_code, .data = sample_data, .bss_len = 8 };
}

test "a VIG64 object round-trips the wide header and imports" {
    var import: foreign.Vig64Import = .{ .library = "kernel32.dll", .symbol = "CreateFileA", .result = .host_ptr };
    for ([_]foreign.Vig64Type{ .guest_ptr, .u32, .u32, .host_ptr, .u32, .u32, .host_ptr }) |arg_type| {
        try import.addArg(arg_type);
    }
    const code = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const symbols = [_]Vig64Symbol{
        .{ .name = "entry", .binding = .global, .kind = .function, .section = .code },
        .{ .name = "large", .binding = .common, .kind = .object, .section = .none, .size = @as(u64, 1) << 32, .alignment = 8 },
    };
    const relocations = [_]Vig64Relocation{.{ .relocation_type = .guest_address64, .section = .code, .offset = 1, .target = 1 }};
    const layout: Vig64Layout = .{ .imports = &.{import}, .symbols = &symbols, .relocations = &relocations, .code = &code, .data = "x\x00", .bss_len = @as(u64, 1) << 32 };
    var bytes: [256]u8 = undefined;
    const written = try writeVig64(layout, &bytes);
    const image = try parseVig64(bytes[0..written]);
    try testing.expectEqual(@as(u64, 1) << 32, image.bss_len);
    try testing.expectEqual(@as(u64, 2), image.symbol_count);
    try testing.expectEqual(@as(u64, 1), image.relocation_count);
    try testing.expectEqualSlices(u8, &code, image.code);
    var iterator = image.importIterator();
    const decoded = (try iterator.next()).?;
    try testing.expectEqual(foreign.Vig64ResultType.host_ptr, decoded.result);
    try testing.expectEqual(@as(usize, 7), decoded.argTypes().len);
    var symbols_it = image.symbolIterator();
    try testing.expectEqualStrings("entry", (try symbols_it.next()).?.name);
    try testing.expectEqual(@as(u64, 1) << 32, (try symbols_it.next()).?.size);
    var relocations_it = image.relocationIterator();
    try testing.expectEqual(Vig64RelocationType.guest_address64, (try relocations_it.next()).?.relocation_type);
}

test "an object round-trips every kind of symbol, relocation and import" {
    var import: foreign.Import = .{ .library = "user32.dll", .symbol = "MessageBoxA" };
    for ([_]foreign.ArgType{ .ptr, .cstr, .u32 }) |arg_type| try import.addArg(arg_type);

    const symbols = [_]Symbol{
        .{ .name = "main", .binding = .global, .kind = .function, .section = .code },
        .{ .name = "", .binding = .local, .kind = .function, .section = .code, .offset = 4 },
        .{
            .name = "greeting",
            .binding = .local,
            .kind = .object,
            .section = .data,
            .size = 3,
        },
        .{ .name = "helper", .binding = .undefined, .kind = .function, .section = .none },
        .{
            .name = "counter",
            .binding = .common,
            .kind = .object,
            .section = .none,
            .size = 8,
            .alignment = 8,
        },
        .{
            .name = "buffer",
            .binding = .global,
            .kind = .object,
            .section = .bss,
            .size = 8,
            .alignment = 4,
        },
    };
    const relocations = [_]Relocation{
        .{ .relocation_type = .code_target32, .section = .code, .offset = 1, .target = 3 },
        .{
            .relocation_type = .data_address32,
            .section = .code,
            .offset = 4,
            .target = 2,
            .addend = 1,
        },
        .{ .relocation_type = .guest_address32, .section = .data, .offset = 0, .target = 0 },
        .{ .relocation_type = .foreign_import8, .section = .code, .offset = 3, .target = 0 },
    };

    const bytes = try writeAlloc(.{
        .imports = &.{import},
        .symbols = &symbols,
        .relocations = &relocations,
        .code = &sample_code,
        .data = sample_data,
        .bss_len = 8,
    });
    defer testing.allocator.free(bytes);

    const image = try parse(bytes);
    try testing.expectEqual(version, image.format_version);
    try testing.expectEqual(@as(u8, 1), image.import_count);
    try testing.expectEqual(@as(u32, symbols.len), image.symbol_count);
    try testing.expectEqual(@as(u32, relocations.len), image.relocation_count);
    try testing.expectEqual(@as(u32, 8), image.bss_len);
    try testing.expectEqualSlices(u8, &sample_code, image.code);
    try testing.expectEqualStrings(sample_data, image.data);

    var symbol_iterator = image.symbolIterator();
    for (symbols) |expected| {
        const decoded = (try symbol_iterator.next()).?;
        try testing.expectEqualStrings(expected.name, decoded.name);
        try testing.expectEqual(expected.binding, decoded.binding);
        try testing.expectEqual(expected.kind, decoded.kind);
        try testing.expectEqual(expected.section, decoded.section);
        try testing.expectEqual(expected.offset, decoded.offset);
        try testing.expectEqual(expected.size, decoded.size);
        try testing.expectEqual(expected.alignment, decoded.alignment);
    }
    try testing.expectEqual(@as(?Symbol, null), try symbol_iterator.next());

    var relocation_iterator = image.relocationIterator();
    for (relocations) |expected| {
        const decoded = (try relocation_iterator.next()).?;
        try testing.expectEqual(expected.relocation_type, decoded.relocation_type);
        try testing.expectEqual(expected.section, decoded.section);
        try testing.expectEqual(expected.offset, decoded.offset);
        try testing.expectEqual(expected.target, decoded.target);
        try testing.expectEqual(expected.addend, decoded.addend);
    }
    try testing.expectEqual(@as(?Relocation, null), try relocation_iterator.next());

    var import_iterator = image.importIterator();
    const declaration = (try import_iterator.next()).?;
    try testing.expectEqual(@as(u8, 0), declaration.index);
    try testing.expectEqualStrings("user32.dll", declaration.import.library);
    try testing.expectEqualStrings("MessageBoxA", declaration.import.symbol);
    try testing.expectEqualSlices(
        foreign.ArgType,
        &.{ .ptr, .cstr, .u32 },
        declaration.import.argTypes(),
    );
    try testing.expectEqual(@as(?ForeignImport, null), try import_iterator.next());
}

test "an empty object is a complete object" {
    const bytes = try writeAlloc(.{ .code = &.{} });
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, header_size), bytes.len);

    const image = try parse(bytes);
    try testing.expectEqual(@as(u32, 0), image.symbol_count);
    try testing.expectEqual(@as(usize, 0), image.code.len);

    var symbols = image.symbolIterator();
    try testing.expectEqual(@as(?Symbol, null), try symbols.next());
}

test "a label at the end of its section is inside it, one past it is not" {
    const at_end: Symbol = .{
        .name = "tail",
        .binding = .global,
        .kind = .function,
        .section = .code,
        .offset = sample_code.len,
    };
    var layout = sampleLayout();
    layout.symbols = &.{at_end};
    const bytes = try writeAlloc(layout);
    defer testing.allocator.free(bytes);

    var past = at_end;
    past.offset = sample_code.len + 1;
    layout.symbols = &.{past};
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));
}

test "a symbol is refused when its own alignment cannot hold" {
    var layout = sampleLayout();

    // Four-byte alignment at an offset of two can never come out aligned.
    layout.symbols = &.{.{
        .name = "misplaced",
        .binding = .global,
        .kind = .object,
        .section = .data,
        .offset = 2,
        .alignment = 4,
    }};
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));

    // An alignment must be a power of two, because the encoding holds only the
    // exponent and the linker's rounding assumes it.
    layout.symbols = &.{.{
        .name = "odd",
        .binding = .global,
        .kind = .object,
        .section = .data,
        .alignment = 3,
    }};
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));

    layout.symbols = &.{.{
        .name = "enormous",
        .binding = .common,
        .kind = .object,
        .section = .none,
        .size = 4,
        .alignment = @as(u32, 1) << (max_alignment_shift + 1),
    }};
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));
}

test "a symbol that names no section must not be placed, and one that does must be" {
    var layout = sampleLayout();

    layout.symbols = &.{
        .{ .name = "elsewhere", .binding = .undefined, .kind = .function, .section = .code },
    };
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));

    layout.symbols = &.{
        .{ .name = "nowhere", .binding = .global, .kind = .function, .section = .none },
    };
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));

    // A request for no space would read back as a name that nothing defines.
    layout.symbols = &.{
        .{ .name = "empty", .binding = .common, .kind = .object, .section = .none, .size = 0 },
    };
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));

    // A definition with no name cannot be offered to another object.
    layout.symbols = &.{
        .{ .name = "", .binding = .global, .kind = .function, .section = .code },
    };
    try testing.expectError(error.InvalidSymbol, encodedSize(layout));
}

test "a relocation must fit in a section that has bytes" {
    var layout = sampleLayout();
    layout.symbols = &.{
        .{ .name = "target", .binding = .global, .kind = .function, .section = .code },
    };

    // Four bytes starting five from the end of an eight-byte section run past it.
    layout.relocations = &.{
        .{ .relocation_type = .code_target32, .section = .code, .offset = 5, .target = 0 },
    };
    try testing.expectError(error.InvalidRelocation, encodedSize(layout));

    // The last four bytes of that section are exactly enough.
    layout.relocations = &.{
        .{ .relocation_type = .code_target32, .section = .code, .offset = 4, .target = 0 },
    };
    const bytes = try writeAlloc(layout);
    testing.allocator.free(bytes);

    // The zero-filled region has no bytes in the file to patch.
    layout.relocations = &.{
        .{ .relocation_type = .code_target32, .section = .bss, .offset = 0, .target = 0 },
    };
    try testing.expectError(error.InvalidRelocation, encodedSize(layout));
}

test "a relocation must name a symbol or an import that exists" {
    var layout = sampleLayout();
    layout.symbols = &.{
        .{ .name = "target", .binding = .global, .kind = .function, .section = .code },
    };

    layout.relocations = &.{
        .{ .relocation_type = .code_target32, .section = .code, .offset = 0, .target = 1 },
    };
    try testing.expectError(error.InvalidRelocation, encodedSize(layout));

    // There is no import table at all, so no index into it is in range.
    layout.relocations = &.{
        .{ .relocation_type = .foreign_import8, .section = .code, .offset = 0, .target = 0 },
    };
    try testing.expectError(error.InvalidRelocation, encodedSize(layout));

    // An import index is not an address, so there is nothing to add to it.
    layout.imports = &.{.{ .library = "kernel32.dll", .symbol = "GetTickCount" }};
    layout.relocations = &.{.{
        .relocation_type = .foreign_import8,
        .section = .code,
        .offset = 0,
        .target = 0,
        .addend = 1,
    }};
    try testing.expectError(error.InvalidRelocation, encodedSize(layout));
}

test "a reader refuses a file that is not this format" {
    const bytes = try writeAlloc(sampleLayout());
    defer testing.allocator.free(bytes);

    try testing.expectError(error.InvalidObjectHeader, parse(bytes[0 .. header_size - 1]));
    try testing.expectError(error.ObjectSizeMismatch, parse(bytes[0 .. bytes.len - 1]));

    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);

    copy[0] = 'X';
    try testing.expectError(error.InvalidObjectHeader, parse(copy));
    copy[0] = 'V';

    copy[offset_version] = version + 1;
    try testing.expectError(error.UnsupportedObjectVersion, parse(copy));
    copy[offset_version] = version;

    copy[offset_flags] = 1;
    try testing.expectError(error.UnsupportedObjectFlags, parse(copy));
    copy[offset_flags] = 0;

    copy[offset_reserved] = 1;
    try testing.expectError(error.InvalidObjectHeader, parse(copy));
    copy[offset_reserved] = 0;

    try testing.expectEqual(@as(u32, 8), (try parse(copy)).bss_len);
}

test "a reader refuses a record that the file's own lengths contradict" {
    var layout = sampleLayout();
    layout.symbols = &.{
        .{ .name = "value", .binding = .global, .kind = .object, .section = .data },
    };
    const bytes = try writeAlloc(layout);
    defer testing.allocator.free(bytes);

    const record = header_size;
    const strings = header_size + symbol_record_size;

    // A name that starts past the end of the string table.
    var copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    writeU32(copy, record + symbol_name_offset, 64);
    var symbols = (try parse(copy)).symbolIterator();
    try testing.expectError(error.InvalidSymbol, symbols.next());

    // A name whose length runs past the end of the string table.
    @memcpy(copy, bytes);
    std.mem.writeInt(u16, copy[strings..][0..2], 64, .little);
    symbols = (try parse(copy)).symbolIterator();
    try testing.expectError(error.InvalidSymbol, symbols.next());

    // A binding, a kind and a section that this version does not define.
    @memcpy(copy, bytes);
    copy[record + symbol_binding] = 9;
    symbols = (try parse(copy)).symbolIterator();
    try testing.expectError(error.InvalidSymbol, symbols.next());

    @memcpy(copy, bytes);
    copy[record + symbol_section] = 9;
    symbols = (try parse(copy)).symbolIterator();
    try testing.expectError(error.InvalidSymbol, symbols.next());

    // An alignment exponent past the largest this format allows.
    @memcpy(copy, bytes);
    copy[record + symbol_alignment_shift] = max_alignment_shift + 1;
    symbols = (try parse(copy)).symbolIterator();
    try testing.expectError(error.InvalidSymbol, symbols.next());
}

test "a reader refuses a relocation whose reserved bytes are not zero" {
    var layout = sampleLayout();
    layout.symbols = &.{
        .{ .name = "target", .binding = .global, .kind = .function, .section = .code },
    };
    layout.relocations = &.{
        .{ .relocation_type = .code_target32, .section = .code, .offset = 0, .target = 0 },
    };
    const bytes = try writeAlloc(layout);
    defer testing.allocator.free(bytes);

    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    copy[header_size + symbol_record_size + relocation_reserved] = 1;

    var relocations = (try parse(copy)).relocationIterator();
    try testing.expectError(error.InvalidRelocation, relocations.next());
}

test "a negative addend survives the round trip" {
    var layout = sampleLayout();
    layout.symbols = &.{
        .{ .name = "array", .binding = .global, .kind = .object, .section = .data },
    };
    layout.relocations = &.{.{
        .relocation_type = .data_address32,
        .section = .data,
        .offset = 0,
        .target = 0,
        .addend = -12,
    }};
    const bytes = try writeAlloc(layout);
    defer testing.allocator.free(bytes);

    var relocations = (try parse(bytes)).relocationIterator();
    try testing.expectEqual(@as(i32, -12), (try relocations.next()).?.addend);
}
