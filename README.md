# Printfdebugger (literaly)
Have you been "printfdebugging"? This debugger (not some blasphemous gdb front-end) takes this experience to a new level.

It inserts a breakpoint at every line containing `printf` (even in comments!)

> [!CAUTION]
> My flawless debugger only supports non-PIE executable

# Building
Make sure you have the following installed:

- Zig 0.15.2
- `libdw` from elfutils

Then run
```
zig build -Dcpu=native -Doptimize=ReleaseSafe
```
to compile the project.

# Usage
There is only one command - `c` for `c`ontinue! Don't be fooled by a gdb like propmt, it's not interactive (it's time to grow up).

# Issues
If there are any, idk, I coded this in several evenings for fun. (˵ •̀ ᴗ - ˵ ) 

# References
- `man elf`
- `man libelf`
- [Introduction to the DWARF debugging format](https://dwarfstd.org/doc/Debugging%20using%20DWARF-2012.pdf)
- [DWARF Debugging Information Format Version 5](https://dwarfstd.org/doc/DWARF5.pdf)
- Claude for generating a `libdw` example
