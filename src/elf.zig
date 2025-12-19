const libelf = @cImport({
    @cInclude("libelf.h");
    @cInclude("elf.h");
});

pub fn isPie(fd: c_int) !bool {
    const libelf_version = libelf.elf_version(libelf.EV_CURRENT);
    if (libelf_version == libelf.EV_NONE) return error.LibElf;
    const elf = libelf.elf_begin(fd, libelf.ELF_C_READ, null) orelse return error.LibElf;
    defer _ = libelf.elf_end(elf);
    const header = libelf.elf64_getehdr(elf);
    return header.*.e_type != libelf.ET_EXEC;
}
