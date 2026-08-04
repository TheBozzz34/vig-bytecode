# vig-bytecode

The definitions the [assembler](../vig-assembler) and the [VM](../vig-vm) both
need: the instruction set, the foreign-call ABI limits, the container format, and
the verifier. Each of those used to exist twice — an opcode enum plus an
int-to-enum switch in the VM, and a mnemonic table in the assembler — so adding
an instruction meant three edits that had to agree. Now there is one table, and a
`comptime` check that it covers every opcode in order.

```powershell
zig build test
```

## Modules

| Module | Contents |
| --- | --- |
| `opcode` | `OpCode`, operand kinds, mnemonics, stack effects, instruction sizes |
| `foreign` | foreign argument types and the ABI limits (16 imports, 4 arguments, 255-byte names) |
| `container` | the container header and import table, reader and writer |
| `encode` | instruction encoding and decoding |
| `verify` | instruction-boundary and control-flow verification |

## Container format

A VIG program file is a header, an import table, the code, and the static data.
All integers are little-endian.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | magic, `VIGF` |
| 4 | 1 | format version, currently 2 |
| 5 | 1 | flags |
| 6 | 1 | import count |
| 7 | 1 | reserved, must be zero |
| 8 | 4 | code length |
| 12 | 4 | static-data length |
| 16 | 4 | entry point, a code offset |
| 20 | 4 | import-table length in bytes |
| 24 | *import-table length* | import table |
| … | *code length* | code |
| … | *static-data length* | static data |

The file length must equal the header plus those three lengths exactly.

Each import-table entry is a library-name length, a symbol-name length, an
argument count, one byte per argument type, then the two names, unterminated.

Every flag bit is reserved in version 2 and a reader rejects any that are set,
because a flag that changes how a program runs must not be silently ignored by an
older VM. The same applies to the version field itself.

### Why code and data are separate

Recording the code length separately from the static data is what makes
verification possible. In a single blob, a walk over the program would decode
string bytes as instructions; with the split, the verifier can walk only the code
and prove that:

- every reachable instruction decodes and fits inside the code region;
- every jump and call lands on an instruction boundary rather than inside one;
- control never falls off the end of the code;
- every `foreign_call` names a declared import, and `load`/`store` addresses stay
  inside the data segment.

The walk follows branches from the entry point rather than sweeping linearly, so
unreachable bytes are ignored — they are never executed.

### Older files

Version 1 containers (a six-byte prefix, an import table, then code and strings
in one blob) and bare headerless code still load and run. They carry no code/data
split, so they cannot be verified and rely on the VM's runtime checks alone.
