//! The VIG container format: the file that holds a program image.
//!
//! Format version 3 adds a zero-filled length. Version 2 recorded the shape of the
//! program in the header. Version 1 left that shape implicit in the length of the
//! file.
//!
//! ```text
//! offset size field
//!      0    4 magic "VIGF"
//!      4    1 format version
//!      5    1 flags
//!      6    1 import count
//!      7    1 reserved, must be zero
//!      8    4 code length      (little-endian u32)
//!     12    4 static-data length
//!     16    4 entry point, a code offset
//!     20    4 import-table length in bytes
//!     24    4 zero-filled length
//!     28      import table, `import count` entries
//!            code
//!            static data
//! ```
//!
//! The split of the code from the static data makes it possible to check the
//! instruction boundaries. A string is outside the executable region.
//! Therefore a verifier can read the code region and no text stops it, and each
//! jump must go to an instruction. The import-table length lets a reader find
//! the code without a decode of the imports. The version field and the flags
//! field let a reader refuse a container that it does not fully understand. The
//! reader does not try to read such a container.
//!
//! The zero-filled length is the number of bytes that the VM must add after the
//! static data. Those bytes are not in the file. A program declares an array of
//! one thousand integers, and the file grows by nothing. Without this field the
//! file would carry four thousand zeros.
//!
//! ## Why version 3 is not compatible with version 2
//!
//! In version 2 the operand of `load` and of `store` was an index into a separate
//! segment of i32 slots. In version 3 that operand is a byte address in the one
//! guest memory, the same address space that a label and a pointer use. Therefore
//! `store 4` names the fifth slot of a segment in an old program and the fifth byte
//! of memory in a new one.
//!
//! No reader can tell the two apart from the bytes, because the instruction did not
//! change. Therefore a version 2 container must be refused and not run. The version
//! field exists for exactly this. This package still reads the older forms, so a
//! tool can report what a file holds. `Kind.isExecutable` says which forms a VM
//! runs.
//!
//! A version 1 container has a six-byte prefix, then an import table, then one
//! region with both the code and the data in it. Bare code with no header is the
//! oldest form of all. Neither form splits the code from the data, so no verifier
//! can check them.

const std = @import("std");
const abi = @import("abi.zig");
const foreign = @import("foreign.zig");

pub const magic = "VIGF";

/// The numbered container versions for the two execution ABIs.
pub const vig32_version: u8 = abi.Profile.vig32.containerVersion();
pub const vig64_version: u8 = abi.Profile.vig64.containerVersion();
/// The format version that this package writes until every producer can emit
/// the wider VIG64 header.
pub const version: u8 = vig32_version;
/// The version before this one. Its `load` and `store` operands index a segment of
/// i32 slots, so a VM must refuse it rather than read those operands as addresses.
pub const slot_addressed_version: u8 = 2;
/// The earlier format: the magic, the version and the import count. Then come
/// the imports and one region that holds both the code and the data.
pub const legacy_version: u8 = 1;

/// Find the execution ABI that a numbered current container selects. Older
/// formats have different memory semantics and deliberately return null.
pub fn profileForVersion(file_version: u8) ?abi.Profile {
    return abi.Profile.fromContainerVersion(file_version);
}

pub const header_size = 28;
/// The VIG64 header keeps the same prefix, then uses five little-endian u64
/// fields: code length, data length, entry point, import-table length, and BSS
/// length.
pub const vig64_header_size = 48;
/// The size of a version 2 header. This package reads such a header so a tool can
/// report what an old file holds.
pub const slot_addressed_header_size = 24;
pub const legacy_header_size = 6;

const offset_version = 4;
const offset_flags = 5;
const offset_import_count = 6;
const offset_reserved = 7;
const offset_code_len = 8;
const offset_data_len = 12;
const offset_entry_point = 16;
const offset_import_table_len = 20;
const offset_bss_len = 24;

pub const Error = error{
    InvalidContainerHeader,
    UnsupportedContainerVersion,
    UnsupportedContainerFlags,
    ContainerSizeMismatch,
    EntryPointOutOfRange,
    TooManyForeignImports,
    TooManyForeignArguments,
    ForeignNameTooLong,
    InvalidForeignType,
    BufferTooSmall,
};

/// The flags for the complete container. Format version 2 reserves each bit. A
/// reader refuses a container if a bit is set. A VM must understand a new flag
/// before it can use the flag. Therefore an older VM must refuse the container.
/// It must not ignore the bit.
pub const Flags = packed struct(u8) {
    reserved: u8 = 0,

    pub fn toByte(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) Error!Flags {
        const flags: Flags = @bitCast(byte);
        if (flags.reserved != 0) return error.UnsupportedContainerFlags;
        return flags;
    }
};

pub const Header = struct {
    format_version: u8 = version,
    flags: Flags = .{},
    import_count: u8 = 0,
    code_len: u32 = 0,
    data_len: u32 = 0,
    entry_point: u32 = 0,
    import_table_len: u32 = 0,
    /// The number of zero bytes that the VM adds after the static data. These
    /// bytes are not in the file.
    bss_len: u32 = 0,
};

/// How a file gives the shape of its contents.
pub const Kind = enum {
    /// No magic bytes. The complete file is code, as in the first VIG programs.
    raw,
    /// Format version 1: an import table, then the code and the data in one
    /// region.
    legacy,
    /// Format version 2. It splits the code from the data, but its `load` and
    /// `store` operands index a segment of i32 slots and not guest memory.
    slot_addressed,
    /// Format version 3. The top of this file gives the layout.
    current,

    /// This function is true if the container keeps the code apart from the
    /// static data. A verifier needs this split to find where the instructions
    /// stop.
    pub fn separatesData(self: Kind) bool {
        return self == .current or self == .slot_addressed;
    }

    /// This function is true if a VM can run the container.
    ///
    /// Version 1 and version 2 are refused. Each one is a numbered format, and in
    /// each one the operand of `load` and of `store` is an index into a segment of
    /// i32 slots. That operand is now a byte address. No reader can tell the two
    /// apart from the bytes, because the instruction did not change. Therefore a VM
    /// that ran such a file would compute a wrong answer and report nothing.
    ///
    /// Bare code is still executable. It carries no version and no promise, it is
    /// the oldest and least formal input, and the VM has never verified it. It is
    /// also the only input that reaches the run-time checks of the VM, because a
    /// verified container has already been refused for the faults that those checks
    /// find. A test of those checks therefore needs this form.
    pub fn isExecutable(self: Kind) bool {
        return switch (self) {
            .current, .raw => true,
            .slot_addressed, .legacy => false,
        };
    }
};

/// A container after a parse: the header and slices into the source bytes. The
/// image does not own these slices.
pub const Image = struct {
    kind: Kind,
    header: Header,
    /// The encoded import table. Use `importIterator` to read the entries.
    imports: []const u8,
    /// The executable instructions. The VM executes no byte outside this range.
    code: []const u8,
    /// The static data. The VM puts it in memory directly after the code.
    /// Therefore an address from a program is an index into `code ++ data`. This
    /// field is always empty for a `raw` image and a `legacy` image.
    data: []const u8,

    /// The number of bytes of the program that come from the file: the code and the
    /// static data. The VM copies exactly this many bytes into memory.
    pub fn fileImageLen(self: Image) usize {
        return self.code.len + self.data.len;
    }

    /// The number of bytes that the program uses in VM memory. This total includes
    /// the zero-filled region, which the file does not hold.
    pub fn imageLen(self: Image) usize {
        return self.fileImageLen() + self.header.bss_len;
    }

    pub fn importIterator(self: Image) ImportIterator {
        return .{ .bytes = self.imports, .remaining = self.header.import_count };
    }
};

pub fn isContainer(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], magic);
}

/// The largest correct file for a VM that has a program image of `image_size`
/// bytes or less. The total is the header, the largest possible import table and
/// the image.
pub fn maxFileSize(image_size: usize) usize {
    return header_size + foreign.max_table_size + image_size;
}

pub fn writeHeader(header: Header, dest: *[header_size]u8) void {
    @memcpy(dest[0..magic.len], magic);
    dest[offset_version] = header.format_version;
    dest[offset_flags] = header.flags.toByte();
    dest[offset_import_count] = header.import_count;
    dest[offset_reserved] = 0;
    std.mem.writeInt(u32, dest[offset_code_len..][0..4], header.code_len, .little);
    std.mem.writeInt(u32, dest[offset_data_len..][0..4], header.data_len, .little);
    std.mem.writeInt(u32, dest[offset_entry_point..][0..4], header.entry_point, .little);
    std.mem.writeInt(u32, dest[offset_import_table_len..][0..4], header.import_table_len, .little);
    std.mem.writeInt(u32, dest[offset_bss_len..][0..4], header.bss_len, .little);
}

/// Read a header in format version 3, or in version 2.
///
/// A version 2 header has no zero-filled length and is four bytes shorter.
/// `bss_len` is therefore zero for such a header. `parse` records the version in
/// `Kind`, and a VM refuses to run anything that is not the current version.
pub fn readHeader(bytes: []const u8) Error!Header {
    if (!isContainer(bytes) or bytes.len < slot_addressed_header_size) {
        return error.InvalidContainerHeader;
    }

    const file_version = bytes[offset_version];
    if (file_version != version and file_version != slot_addressed_version) {
        return error.UnsupportedContainerVersion;
    }
    if (file_version == version and bytes.len < header_size) {
        return error.InvalidContainerHeader;
    }
    if (bytes[offset_reserved] != 0) return error.InvalidContainerHeader;

    const import_count = bytes[offset_import_count];
    if (import_count > foreign.max_imports) return error.TooManyForeignImports;

    return .{
        .format_version = file_version,
        .flags = try Flags.fromByte(bytes[offset_flags]),
        .import_count = import_count,
        .code_len = std.mem.readInt(u32, bytes[offset_code_len..][0..4], .little),
        .data_len = std.mem.readInt(u32, bytes[offset_data_len..][0..4], .little),
        .entry_point = std.mem.readInt(u32, bytes[offset_entry_point..][0..4], .little),
        .import_table_len = std.mem.readInt(u32, bytes[offset_import_table_len..][0..4], .little),
        .bss_len = if (file_version == version)
            std.mem.readInt(u32, bytes[offset_bss_len..][0..4], .little)
        else
            0,
    };
}

/// The size of the header that a file of this version has.
fn headerSizeFor(file_version: u8) usize {
    return if (file_version == version) header_size else slot_addressed_header_size;
}

/// Parse a container that this package can read, current or legacy.
pub fn parse(bytes: []const u8) Error!Image {
    if (!isContainer(bytes)) {
        return .{
            .kind = .raw,
            .header = .{ .format_version = 0, .code_len = try castLen(bytes.len) },
            .imports = &.{},
            .code = bytes,
            .data = &.{},
        };
    }

    if (bytes.len > magic.len and bytes[offset_version] == legacy_version) return parseLegacy(bytes);

    const header = try readHeader(bytes);
    const prefix = headerSizeFor(header.format_version);
    const declared = @as(u64, prefix) + header.import_table_len + header.code_len + header.data_len;
    if (declared != bytes.len) return error.ContainerSizeMismatch;

    // The declared lengths add up to the size of the file. Therefore these
    // offsets are safe.
    const code_start = prefix + @as(usize, header.import_table_len);
    const code_end = code_start + @as(usize, header.code_len);

    const imports = bytes[prefix..code_start];
    // The table must decode to exactly `import_count` entries, and these
    // entries must fill `import_table_len` bytes. If they do not, the header and
    // the table disagree.
    if (try importTableSize(imports, header.import_count) != imports.len) {
        return error.ContainerSizeMismatch;
    }

    try checkEntryPoint(header.entry_point, header.code_len);

    return .{
        .kind = if (header.format_version == version) .current else .slot_addressed,
        .header = header,
        .imports = imports,
        .code = bytes[code_start..code_end],
        .data = bytes[code_end..],
    };
}

/// Parse only a VIG64 container. `parse` intentionally continues to reject
/// this version until the VM selects its VIG64 execution path.
pub fn parseVig64(bytes: []const u8) Error!Vig64Image {
    const header = try readVig64Header(bytes);
    const declared = @as(u128, vig64_header_size) + header.import_table_len + header.code_len + header.data_len;
    if (declared != bytes.len) return error.ContainerSizeMismatch;
    if (header.code_len > std.math.maxInt(usize) or header.data_len > std.math.maxInt(usize)) {
        return error.ContainerSizeMismatch;
    }

    const import_end_u64 = @as(u64, vig64_header_size) + header.import_table_len;
    if (import_end_u64 > std.math.maxInt(usize)) return error.ContainerSizeMismatch;
    const code_start: usize = @intCast(import_end_u64);
    const code_end_u64 = import_end_u64 + header.code_len;
    if (code_end_u64 > std.math.maxInt(usize)) return error.ContainerSizeMismatch;
    const code_end: usize = @intCast(code_end_u64);
    const imports = bytes[vig64_header_size..code_start];
    if (try vig64ImportTableSize(imports, header.import_count) != imports.len) {
        return error.ContainerSizeMismatch;
    }
    try checkVig64EntryPoint(header.entry_point, header.code_len);
    return .{ .header = header, .imports = imports, .code = bytes[code_start..code_end], .data = bytes[code_end..] };
}

fn parseLegacy(bytes: []const u8) Error!Image {
    if (bytes.len < legacy_header_size) return error.InvalidContainerHeader;

    const import_count = bytes[5];
    if (import_count > foreign.max_imports) return error.TooManyForeignImports;

    const rest = bytes[legacy_header_size..];
    const table_len = try importTableSize(rest, import_count);

    return .{
        .kind = .legacy,
        .header = .{
            .format_version = legacy_version,
            .import_count = import_count,
            .code_len = try castLen(rest.len - table_len),
            .import_table_len = @intCast(table_len),
        },
        .imports = rest[0..table_len],
        // Version 1 put a string in the same region as the code. Therefore all
        // the bytes after the import table must stay executable, and a program
        // must be able to address them.
        .code = rest[table_len..],
        .data = &.{},
    };
}

fn castLen(len: usize) Error!u32 {
    return std.math.cast(u32, len) orelse error.ContainerSizeMismatch;
}

fn checkEntryPoint(entry_point: u32, code_len: usize) Error!void {
    if (code_len == 0) {
        if (entry_point != 0) return error.EntryPointOutOfRange;
        return;
    }
    if (entry_point >= code_len) return error.EntryPointOutOfRange;
}

/// The number of bytes that the first `count` import entries use.
pub fn importTableSize(bytes: []const u8, count: u8) Error!usize {
    var iterator: ImportIterator = .{ .bytes = bytes, .remaining = count };
    while (try iterator.next()) |_| {}
    return iterator.offset;
}

fn checkVig64EntryPoint(entry_point: u64, code_len: u64) Error!void {
    if (code_len == 0) {
        if (entry_point != 0) return error.EntryPointOutOfRange;
        return;
    }
    if (entry_point >= code_len) return error.EntryPointOutOfRange;
}

pub fn writeVig64Header(header: Vig64Header, dest: *[vig64_header_size]u8) void {
    @memcpy(dest[0..magic.len], magic);
    dest[offset_version] = vig64_version;
    dest[offset_flags] = header.flags.toByte();
    dest[offset_import_count] = header.import_count;
    dest[offset_reserved] = 0;
    std.mem.writeInt(u64, dest[8..16], header.code_len, .little);
    std.mem.writeInt(u64, dest[16..24], header.data_len, .little);
    std.mem.writeInt(u64, dest[24..32], header.entry_point, .little);
    std.mem.writeInt(u64, dest[32..40], header.import_table_len, .little);
    std.mem.writeInt(u64, dest[40..48], header.bss_len, .little);
}

pub fn readVig64Header(bytes: []const u8) Error!Vig64Header {
    if (!isContainer(bytes) or bytes.len < vig64_header_size) return error.InvalidContainerHeader;
    if (bytes[offset_version] != vig64_version) return error.UnsupportedContainerVersion;
    if (bytes[offset_reserved] != 0) return error.InvalidContainerHeader;
    const import_count = bytes[offset_import_count];
    if (import_count > foreign.max_imports) return error.TooManyForeignImports;

    return .{
        .format_version = vig64_version,
        .flags = try Flags.fromByte(bytes[offset_flags]),
        .import_count = import_count,
        .code_len = std.mem.readInt(u64, bytes[8..16], .little),
        .data_len = std.mem.readInt(u64, bytes[16..24], .little),
        .entry_point = std.mem.readInt(u64, bytes[24..32], .little),
        .import_table_len = std.mem.readInt(u64, bytes[32..40], .little),
        .bss_len = std.mem.readInt(u64, bytes[40..48], .little),
    };
}

/// The number of bytes that the first `count` VIG64 import entries use.
pub fn vig64ImportTableSize(bytes: []const u8, count: u8) Error!usize {
    var iterator: Vig64ImportIterator = .{ .bytes = bytes, .remaining = count };
    while (try iterator.next()) |_| {}
    return iterator.offset;
}

pub const ImportIterator = struct {
    bytes: []const u8,
    offset: usize = 0,
    remaining: u8,

    pub fn next(self: *ImportIterator) Error!?foreign.Import {
        if (self.remaining == 0) return null;
        self.remaining -= 1;

        if (self.bytes.len - self.offset < 3) return error.InvalidContainerHeader;
        const library_len: usize = self.bytes[self.offset];
        const symbol_len: usize = self.bytes[self.offset + 1];
        const arg_count: usize = self.bytes[self.offset + 2];
        self.offset += 3;

        if (arg_count > foreign.max_args) return error.TooManyForeignArguments;
        if (self.bytes.len - self.offset < arg_count) return error.InvalidContainerHeader;

        var import: foreign.Import = .{ .library = "", .symbol = "" };
        for (self.bytes[self.offset..][0..arg_count]) |byte| {
            try import.addArg(try foreign.ArgType.fromByte(byte));
        }
        self.offset += arg_count;

        const names_len = library_len + symbol_len;
        if (self.bytes.len - self.offset < names_len) return error.InvalidContainerHeader;
        import.library = self.bytes[self.offset..][0..library_len];
        import.symbol = self.bytes[self.offset + library_len ..][0..symbol_len];
        self.offset += names_len;

        return import;
    }
};

pub const Vig64Header = struct {
    format_version: u8 = vig64_version,
    flags: Flags = .{},
    import_count: u8 = 0,
    code_len: u64 = 0,
    data_len: u64 = 0,
    entry_point: u64 = 0,
    import_table_len: u64 = 0,
    bss_len: u64 = 0,
};

/// A parsed VIG64 image. It uses VIG64 imports and lengths, so it is separate
/// from `Image`, which describes VIG32 and historic container forms.
pub const Vig64Image = struct {
    header: Vig64Header,
    imports: []const u8,
    code: []const u8,
    data: []const u8,

    pub fn fileImageLen(self: Vig64Image) u64 {
        return self.header.code_len + self.header.data_len;
    }

    pub fn imageLen(self: Vig64Image) u64 {
        return self.fileImageLen() + self.header.bss_len;
    }

    pub fn importIterator(self: Vig64Image) Vig64ImportIterator {
        return .{ .bytes = self.imports, .remaining = self.header.import_count };
    }
};

/// VIG64 stores a result-type byte between the argument count and its argument
/// type bytes. Its record is intentionally not compatible with a VIG32 record.
pub const Vig64ImportIterator = struct {
    bytes: []const u8,
    offset: usize = 0,
    remaining: u8,

    pub fn next(self: *Vig64ImportIterator) Error!?foreign.Vig64Import {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        if (self.bytes.len - self.offset < 4) return error.InvalidContainerHeader;

        const library_len: usize = self.bytes[self.offset];
        const symbol_len: usize = self.bytes[self.offset + 1];
        const arg_count: usize = self.bytes[self.offset + 2];
        const result = try foreign.Vig64ResultType.fromByte(self.bytes[self.offset + 3]);
        self.offset += 4;
        if (arg_count > foreign.vig64_max_args) return error.TooManyForeignArguments;
        if (self.bytes.len - self.offset < arg_count) return error.InvalidContainerHeader;

        var import: foreign.Vig64Import = .{ .library = "", .symbol = "", .result = result };
        for (self.bytes[self.offset..][0..arg_count]) |byte| {
            try import.addArg(try foreign.Vig64Type.fromByte(byte));
        }
        self.offset += arg_count;

        const names_len = library_len + symbol_len;
        if (self.bytes.len - self.offset < names_len) return error.InvalidContainerHeader;
        import.library = self.bytes[self.offset..][0..library_len];
        import.symbol = self.bytes[self.offset + library_len ..][0..symbol_len];
        self.offset += names_len;
        return import;
    }
};

/// The data for `write`. `code` and `data` are regions that the assembler made
/// before. An address in the program refers to the two regions as one continuous
/// image.
pub const Layout = struct {
    imports: []const foreign.Import = &.{},
    code: []const u8,
    data: []const u8 = &.{},
    /// The number of zero bytes that come after the static data in memory. The file
    /// does not hold these bytes.
    bss_len: u32 = 0,
    entry_point: u32 = 0,
    flags: Flags = .{},
};

pub const Vig64Layout = struct {
    imports: []const foreign.Vig64Import = &.{},
    code: []const u8,
    data: []const u8 = &.{},
    bss_len: u64 = 0,
    entry_point: u64 = 0,
    flags: Flags = .{},
};

/// The exact size of the file that `write` makes for `layout`.
pub fn encodedSize(layout: Layout) Error!usize {
    return header_size + try importTableLen(layout.imports) + layout.code.len + layout.data.len;
}

pub fn encodedVig64Size(layout: Vig64Layout) Error!usize {
    const table_len = try vig64ImportTableLen(layout.imports);
    const total = @as(u128, vig64_header_size) + table_len + layout.code.len + layout.data.len;
    return std.math.cast(usize, total) orelse error.ContainerSizeMismatch;
}

/// Write a complete container into `dest`. The function gives the number of
/// bytes that it wrote.
pub fn write(layout: Layout, dest: []u8) Error!usize {
    const table_len = try importTableLen(layout.imports);
    try checkEntryPoint(layout.entry_point, layout.code.len);

    const total = header_size + table_len + layout.code.len + layout.data.len;
    if (dest.len < total) return error.BufferTooSmall;

    writeHeader(.{
        .flags = layout.flags,
        .import_count = @intCast(layout.imports.len),
        .code_len = try castLen(layout.code.len),
        .data_len = try castLen(layout.data.len),
        .entry_point = layout.entry_point,
        .import_table_len = @intCast(table_len),
        .bss_len = layout.bss_len,
    }, dest[0..header_size]);

    var offset: usize = header_size + writeImportTable(layout.imports, dest[header_size..]);

    @memcpy(dest[offset..][0..layout.code.len], layout.code);
    offset += layout.code.len;
    @memcpy(dest[offset..][0..layout.data.len], layout.data);
    return offset + layout.data.len;
}

/// Write a complete VIG64 container into `dest`.
pub fn writeVig64(layout: Vig64Layout, dest: []u8) Error!usize {
    const table_len = try vig64ImportTableLen(layout.imports);
    const code_len: u64 = @intCast(layout.code.len);
    const data_len: u64 = @intCast(layout.data.len);
    try checkVig64EntryPoint(layout.entry_point, code_len);
    const total = try encodedVig64Size(layout);
    if (dest.len < total) return error.BufferTooSmall;

    writeVig64Header(.{
        .flags = layout.flags,
        .import_count = @intCast(layout.imports.len),
        .code_len = code_len,
        .data_len = data_len,
        .entry_point = layout.entry_point,
        .import_table_len = table_len,
        .bss_len = layout.bss_len,
    }, dest[0..vig64_header_size]);

    var offset = vig64_header_size + writeVig64ImportTable(layout.imports, dest[vig64_header_size..]);
    @memcpy(dest[offset..][0..layout.code.len], layout.code);
    offset += layout.code.len;
    @memcpy(dest[offset..][0..layout.data.len], layout.data);
    return offset + layout.data.len;
}

/// Write the import table alone, without a header around it, and give the number
/// of bytes written. `dest` must hold `importTableLen(imports)` bytes or more.
///
/// The relocatable object format holds the same table in the same encoding, so
/// both formats write it from here and neither can drift from the other.
pub fn writeImportTable(imports: []const foreign.Import, dest: []u8) usize {
    var offset: usize = 0;
    for (imports) |import| {
        dest[offset] = @intCast(import.library.len);
        dest[offset + 1] = @intCast(import.symbol.len);
        dest[offset + 2] = import.arg_count;
        offset += 3;
        for (import.argTypes()) |arg_type| {
            dest[offset] = @intFromEnum(arg_type);
            offset += 1;
        }
        @memcpy(dest[offset..][0..import.library.len], import.library);
        offset += import.library.len;
        @memcpy(dest[offset..][0..import.symbol.len], import.symbol);
        offset += import.symbol.len;
    }
    return offset;
}

/// Write a VIG64 import table. The result type makes this table a different
/// format from the VIG32 table above.
pub fn writeVig64ImportTable(imports: []const foreign.Vig64Import, dest: []u8) usize {
    var offset: usize = 0;
    for (imports) |import| {
        dest[offset] = @intCast(import.library.len);
        dest[offset + 1] = @intCast(import.symbol.len);
        dest[offset + 2] = import.arg_count;
        dest[offset + 3] = @intFromEnum(import.result);
        offset += 4;
        for (import.argTypes()) |arg_type| {
            dest[offset] = @intFromEnum(arg_type);
            offset += 1;
        }
        @memcpy(dest[offset..][0..import.library.len], import.library);
        offset += import.library.len;
        @memcpy(dest[offset..][0..import.symbol.len], import.symbol);
        offset += import.symbol.len;
    }
    return offset;
}

/// The number of bytes that `writeImportTable` needs for these imports. It is
/// also where every limit on an import is applied: the count, the two name
/// lengths and the number of arguments.
pub fn importTableLen(imports: []const foreign.Import) Error!u32 {
    if (imports.len > foreign.max_imports) return error.TooManyForeignImports;

    var total: usize = 0;
    for (imports) |import| {
        if (import.library.len > foreign.max_name_len or import.symbol.len > foreign.max_name_len) {
            return error.ForeignNameTooLong;
        }
        if (import.arg_count > foreign.max_args) return error.TooManyForeignArguments;
        total += import.encodedSize();
    }
    return @intCast(total);
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

fn writeAlloc(layout: Layout) ![]u8 {
    const buffer = try testing.allocator.alloc(u8, try encodedSize(layout));
    errdefer testing.allocator.free(buffer);
    try testing.expectEqual(buffer.len, try write(layout, buffer));
    return buffer;
}

test "a container round-trips code, static data, imports and the entry point" {
    var import: foreign.Import = .{ .library = "user32.dll", .symbol = "MessageBoxA" };
    for ([_]foreign.ArgType{ .ptr, .cstr, .u32 }) |arg_type| try import.addArg(arg_type);

    const code = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    const data = "hi\x00";
    const bytes = try writeAlloc(.{
        .imports = &.{import},
        .code = &code,
        .data = data,
        .entry_point = 5,
    });
    defer testing.allocator.free(bytes);

    const image = try parse(bytes);
    try testing.expectEqual(Kind.current, image.kind);
    try testing.expect(image.kind.separatesData());
    try testing.expectEqual(version, image.header.format_version);
    try testing.expectEqual(@as(u32, 5), image.header.entry_point);
    try testing.expectEqual(@as(u8, 1), image.header.import_count);
    try testing.expectEqualSlices(u8, &code, image.code);
    try testing.expectEqualStrings(data, image.data);
    try testing.expectEqual(code.len + data.len, image.imageLen());

    var iterator = image.importIterator();
    const decoded = (try iterator.next()).?;
    try testing.expectEqualStrings("user32.dll", decoded.library);
    try testing.expectEqualStrings("MessageBoxA", decoded.symbol);
    try testing.expectEqualSlices(foreign.ArgType, &.{ .ptr, .cstr, .u32 }, decoded.argTypes());
    try testing.expectEqual(@as(?foreign.Import, null), try iterator.next());
}

pub fn vig64ImportTableLen(imports: []const foreign.Vig64Import) Error!u64 {
    if (imports.len > foreign.max_imports) return error.TooManyForeignImports;
    var total: u64 = 0;
    for (imports) |import| {
        if (import.library.len > foreign.max_name_len or import.symbol.len > foreign.max_name_len) {
            return error.ForeignNameTooLong;
        }
        if (import.arg_count > foreign.vig64_max_args) return error.TooManyForeignArguments;
        total += import.encodedSize();
    }
    return total;
}

test "the numbered current containers select an explicit ABI profile" {
    try testing.expectEqual(abi.Profile.vig32, profileForVersion(vig32_version).?);
    try testing.expectEqual(abi.Profile.vig64, profileForVersion(vig64_version).?);
    try testing.expect(profileForVersion(slot_addressed_version) == null);
}

test "a VIG64 import table carries a result type and seven arguments" {
    var import: foreign.Vig64Import = .{
        .library = "kernel32.dll",
        .symbol = "CreateFileA",
        .result = .host_ptr,
    };
    for ([_]foreign.Vig64Type{ .guest_ptr, .u32, .u32, .host_ptr, .u32, .u32, .host_ptr }) |arg_type| {
        try import.addArg(arg_type);
    }

    const size = try vig64ImportTableLen(&.{import});
    var bytes: [64]u8 = undefined;
    try testing.expectEqual(size, writeVig64ImportTable(&.{import}, &bytes));
    try testing.expectEqual(@as(usize, size), try vig64ImportTableSize(bytes[0..size], 1));

    var iterator: Vig64ImportIterator = .{ .bytes = bytes[0..size], .remaining = 1 };
    const decoded = (try iterator.next()).?;
    try testing.expectEqual(foreign.Vig64ResultType.host_ptr, decoded.result);
    try testing.expectEqualStrings("kernel32.dll", decoded.library);
    try testing.expectEqualStrings("CreateFileA", decoded.symbol);
    try testing.expectEqualSlices(foreign.Vig64Type, import.argTypes(), decoded.argTypes());
    try testing.expectEqual(@as(?foreign.Vig64Import, null), try iterator.next());
}

test "a VIG64 container round-trips its wide header and typed imports" {
    var import: foreign.Vig64Import = .{ .library = "kernel32.dll", .symbol = "CreateFileA", .result = .host_ptr };
    for ([_]foreign.Vig64Type{ .guest_ptr, .u32, .u32, .host_ptr, .u32, .u32, .host_ptr }) |arg_type| {
        try import.addArg(arg_type);
    }
    const code = [_]u8{ @intFromEnum(@import("opcode.zig").OpCode.halt) };
    const data = "x\x00";
    const layout: Vig64Layout = .{ .imports = &.{import}, .code = &code, .data = data, .entry_point = 0, .bss_len = 1 << 32 };
    var bytes: [128]u8 = undefined;
    const written = try writeVig64(layout, &bytes);
    try testing.expectEqual(try encodedVig64Size(layout), written);
    try testing.expectEqual(vig64_header_size + 4 + 7 + 12 + 11 + code.len + data.len, written);

    const image = try parseVig64(bytes[0..written]);
    try testing.expectEqual(vig64_version, image.header.format_version);
    try testing.expectEqual(@as(u64, 1) << 32, image.header.bss_len);
    try testing.expectEqual(@as(u64, 0), image.header.entry_point);
    try testing.expectEqualSlices(u8, &code, image.code);
    try testing.expectEqualStrings(data, image.data);
    try testing.expectEqual(@as(u64, code.len + data.len) + (@as(u64, 1) << 32), image.imageLen());
    try testing.expectError(error.UnsupportedContainerVersion, parse(bytes[0..written]));
}

test "the header occupies its documented layout" {
    const bytes = try writeAlloc(.{ .code = &[_]u8{ 0, 0, 0 }, .data = "xy", .entry_point = 2 });
    defer testing.allocator.free(bytes);

    try testing.expectEqualStrings("VIGF", bytes[0..4]);
    try testing.expectEqual(version, bytes[offset_version]);
    try testing.expectEqual(@as(u8, 0), bytes[offset_flags]);
    try testing.expectEqual(@as(u8, 0), bytes[offset_import_count]);
    try testing.expectEqual(@as(u8, 0), bytes[offset_reserved]);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[offset_code_len..][0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[offset_data_len..][0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[offset_entry_point..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[offset_import_table_len..][0..4], .little));
    try testing.expectEqual(@as(usize, header_size + 5), bytes.len);
}

test "headerless bytes parse as a raw code image" {
    const image = try parse(&[_]u8{ 0, 1, 2 });
    try testing.expectEqual(Kind.raw, image.kind);
    try testing.expect(!image.kind.separatesData());
    try testing.expectEqual(@as(usize, 3), image.code.len);
    try testing.expectEqual(@as(usize, 0), image.data.len);
    try testing.expectEqual(@as(u8, 0), image.header.import_count);
}

test "version 1 containers still parse, with code and data in one region" {
    // The magic, version 1, one import, then `lstrlenA` and two code bytes.
    const bytes = "VIGF" ++ [_]u8{ 1, 1, 12, 8, 1, @intFromEnum(foreign.ArgType.cstr) } ++
        "kernel32.dlllstrlenA" ++ [_]u8{ 24, 0 };

    const image = try parse(bytes);
    try testing.expectEqual(Kind.legacy, image.kind);
    try testing.expect(!image.kind.separatesData());
    try testing.expectEqual(@as(u32, 2), image.header.code_len);
    try testing.expectEqualSlices(u8, &[_]u8{ 24, 0 }, image.code);
    try testing.expectEqual(@as(usize, 0), image.data.len);

    var iterator = image.importIterator();
    const decoded = (try iterator.next()).?;
    try testing.expectEqualStrings("kernel32.dll", decoded.library);
    try testing.expectEqualStrings("lstrlenA", decoded.symbol);
    try testing.expectEqualSlices(foreign.ArgType, &.{.cstr}, decoded.argTypes());
}

test "a truncated version 1 import table is rejected" {
    const bytes = "VIGF" ++ [_]u8{ 1, 1, 12, 8, 0 } ++ "kernel32.dll";
    try testing.expectError(error.InvalidContainerHeader, parse(bytes));
}

test "unreadable containers are rejected rather than guessed at" {
    var buffer: [header_size]u8 = undefined;
    // This header describes an empty program. The header is correct, so each
    // change below is the only reason for a refusal of its container.
    writeHeader(.{}, &buffer);
    const good = buffer;

    try testing.expectError(error.InvalidContainerHeader, parse(buffer[0 .. header_size - 1]));

    // An unknown format version. Version 2 is not unknown: this package reads it
    // so a tool can report what an old file holds.
    buffer = good;
    buffer[offset_version] = version + 1;
    try testing.expectError(error.UnsupportedContainerVersion, parse(&buffer));

    // A flag bit that this version does not define.
    buffer = good;
    buffer[offset_flags] = 1;
    try testing.expectError(error.UnsupportedContainerFlags, parse(&buffer));

    // A reserved byte must be zero. Then it stays available for later use.
    buffer = good;
    buffer[offset_reserved] = 1;
    try testing.expectError(error.InvalidContainerHeader, parse(&buffer));

    // More imports than the ABI permits.
    buffer = good;
    buffer[offset_import_count] = foreign.max_imports + 1;
    try testing.expectError(error.TooManyForeignImports, parse(&buffer));

    // Lengths that do not add up to the size of the file.
    buffer = good;
    std.mem.writeInt(u32, buffer[offset_code_len..][0..4], 99, .little);
    try testing.expectError(error.ContainerSizeMismatch, parse(&buffer));

    // An entry point outside the code region.
    var with_code: [header_size + 1]u8 = undefined;
    writeHeader(.{ .code_len = 1, .entry_point = 7 }, with_code[0..header_size]);
    with_code[header_size] = @intFromEnum(@import("opcode.zig").OpCode.halt);
    try testing.expectError(error.EntryPointOutOfRange, parse(&with_code));
}

test "an import table shorter than its declared length is rejected" {
    // Declare one import, but keep the table empty.
    var buffer: [header_size]u8 = undefined;
    writeHeader(.{ .import_count = 1 }, &buffer);
    try testing.expectError(error.InvalidContainerHeader, parse(&buffer));
}

test "writing rejects layouts the format cannot express" {
    var buffer: [header_size + 8]u8 = undefined;
    // An entry point must name an instruction in the code region.
    try testing.expectError(error.EntryPointOutOfRange, write(.{ .code = "", .entry_point = 1 }, &buffer));
    try testing.expectError(
        error.EntryPointOutOfRange,
        write(.{ .code = &[_]u8{0}, .entry_point = 1 }, &buffer),
    );

    const long_name: [foreign.max_name_len + 1]u8 = @splat('x');
    try testing.expectError(error.ForeignNameTooLong, encodedSize(.{
        .imports = &.{.{ .library = &long_name, .symbol = "s" }},
        .code = &[_]u8{0},
    }));

    const many: [foreign.max_imports + 1]foreign.Import = @splat(.{ .library = "k.dll", .symbol = "s" });
    try testing.expectError(error.TooManyForeignImports, encodedSize(.{ .imports = &many, .code = &[_]u8{0} }));

    try testing.expectError(error.BufferTooSmall, write(.{ .code = &[_]u8{0} }, buffer[0..header_size]));
}

test "a zero-filled length is in the header and not in the file" {
    // This is the reason for version 3. A program declares one thousand integers and
    // the file grows by nothing.
    const bytes = try writeAlloc(.{ .code = &[_]u8{0}, .data = "xy", .bss_len = 4000 });
    defer testing.allocator.free(bytes);

    try testing.expectEqual(@as(usize, header_size + 3), bytes.len);

    const image = try parse(bytes);
    try testing.expectEqual(@as(u32, 4000), image.header.bss_len);
    // The file holds three bytes of the program. The program uses 4003 bytes of
    // memory.
    try testing.expectEqual(@as(usize, 3), image.fileImageLen());
    try testing.expectEqual(@as(usize, 4003), image.imageLen());
}

test "a version 2 container reads, but it is not executable" {
    // A version 2 header is four bytes shorter and has no zero-filled length. This
    // package still reads one. But its `load` and `store` operands index a segment
    // of slots, so a VM must refuse it rather than read them as addresses.
    var buffer: [slot_addressed_header_size + 1]u8 = undefined;
    var full: [header_size]u8 = undefined;
    writeHeader(.{ .code_len = 1, .format_version = slot_addressed_version }, &full);
    @memcpy(buffer[0..slot_addressed_header_size], full[0..slot_addressed_header_size]);
    buffer[slot_addressed_header_size] = @intFromEnum(@import("opcode.zig").OpCode.halt);

    const image = try parse(&buffer);
    try testing.expectEqual(Kind.slot_addressed, image.kind);
    try testing.expectEqual(slot_addressed_version, image.header.format_version);
    // It splits the code from the data, so a verifier could read it.
    try testing.expect(image.kind.separatesData());
    // But no VM may run it.
    try testing.expect(!image.kind.isExecutable());
    try testing.expectEqual(@as(u32, 0), image.header.bss_len);
}

test "a numbered format that addressed slots is not executable" {
    try testing.expect(Kind.current.isExecutable());
    // Bare code carries no version and no promise, and it is the only input that
    // reaches the run-time checks of the VM.
    try testing.expect(Kind.raw.isExecutable());
    // These two are numbered formats whose `load` and `store` operands meant a slot.
    try testing.expect(!Kind.slot_addressed.isExecutable());
    try testing.expect(!Kind.legacy.isExecutable());
}

test "the file-size bound covers the largest legal container" {
    const image_size = 4096;

    const library: [foreign.max_name_len]u8 = @splat('l');
    const symbol: [foreign.max_name_len]u8 = @splat('s');
    const code: [image_size]u8 = @splat(0);
    const many: [foreign.max_imports]foreign.Import = @splat(.{
        .library = &library,
        .symbol = &symbol,
        .arg_types = @splat(.u32),
        .arg_count = foreign.max_args,
    });

    try testing.expectEqual(maxFileSize(image_size), try encodedSize(.{
        .imports = &many,
        .code = &code,
    }));
}
