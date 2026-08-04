# vig-bytecode

Definitions for the VIG [assembler](../vig-assembler) and [VM](../vig-vm). Ibncludes
the instruction set, foreign-call ABI limits, container format, and
the verifier.

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


