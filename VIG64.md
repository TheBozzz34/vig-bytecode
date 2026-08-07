# VIG64 ABI

VIG64 is the 64-bit VIG execution ABI. It is a new ABI. It does not change the
meaning of VIG32 programs.

## Compatibility

- A VIG32 container uses format version 3.
- A VIG64 container uses format version 4.
- A VIG32 VM must reject version 4.
- A VIG64 VM must continue to run version 3 with VIG32 rules.
- Raw bytecode has no version. It is VIG32 only.

## Container layout

The VIG64 container has a 48-byte header. It starts with the usual `VIGF`
magic, version byte 4, flags byte, import count byte, and one zero reserved
byte. It then has five little-endian `u64` fields in this order:

1. code length;
2. static-data length;
3. entry-point code offset;
4. import-table length; and
5. zero-filled BSS length.

This is not the VIG32 header with wider values in memory. It is a different
on-disk version. A VIG32 reader rejects it.

A VIG64 import record is `library length`, `symbol length`, `argument count`,
`result type`, argument-type bytes, library bytes, and symbol bytes. It allows
up to 16 arguments. The result type is explicit, including `void`; it is not
implicitly an unsigned 32-bit value as it is in VIG32.

## Object layout

A VIG64 object uses object format version 2. Its 64-byte header has the same
prefix as a container and then seven little-endian `u64` fields: code length,
data length, BSS length, import-table length, symbol count, relocation count,
and string-table length.

Each symbol record is 32 bytes: string-table offset, section offset, and size
as `u64`, then alignment shift, binding, kind, section, and four zero reserved
bytes. Each relocation record is 32 bytes: patch offset, symbol target, signed
addend, relocation kind, section, and six zero reserved bytes. VIG64 address
relocations write eight bytes. Foreign-import-index relocations still write one
byte because an import table has at most 16 entries.

The object format also has a new version for VIG64. A linker must not link a
VIG32 object with a VIG64 object.

## C data model

VIG64 uses one C data model on every host.

| C type | Size |
| --- | --- |
| `char` | 1 byte |
| `short` | 2 bytes |
| `int` | 4 bytes |
| `long` | 8 bytes |
| `long long` | 8 bytes |
| pointer | 8 bytes |
| `float` | 4 bytes |
| `double` | 8 bytes |
| `long double` | 8 bytes |

This is the LP64 model. `size_t` is `unsigned long` and `ptrdiff_t` is `long`.
The model is part of VIG. It does not depend on Windows, POSIX, or the build
host.

## Values and memory

A VIG64 stack item and a VIG64 frame slot are eight bytes. A guest address is
an unsigned 64-bit byte address. A VM may set a smaller memory limit, but it
must not truncate an address before it checks that limit.

The old integer instructions keep their 32-bit rules. They use the low 32 bits
of a stack item. VIG64 adds explicit 64-bit instructions for signed and
unsigned arithmetic, comparisons, shifts, loads, stores, constants, and
addresses. This keeps C `int` rules correct and makes the type of each emitted
operation clear.

`float` uses the existing binary32 instructions. VIG64 adds binary64
instructions for `double` and `long double`.

## Foreign calls

The VIG64 import record states every argument type and the result type. It can
name `i32`, `u32`, `i64`, `u64`, a guest pointer, or an opaque host pointer.
A guest pointer is checked guest memory. An opaque host pointer can only pass
back to a foreign call. Guest code cannot load through it.

The VIG64 foreign ABI supports up to 16 arguments. This is a limit of the
portable VIG ABI. It is not a limit of an operating system ABI.

In VIGasm, a VIG64 object declares an import as
`extern local_name library_name symbol_name result_type [argument_type ...]`.
For example, `CreateFileA` has seven arguments:
`extern CreateFileA kernel32.dll CreateFileA host_ptr guest_ptr u32 u32 host_ptr u32 u32 host_ptr`.
