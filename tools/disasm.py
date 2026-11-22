#!/usr/bin/env python3

import re
import struct
import sys
import zipfile

from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_ARM

APP = "Payload/TalkingJohn.app/"

class MachO:
    def __init__(self, data):
        self.data = data
        self.segments = []
        self.sections = []
        self.symbols = {}
        self._parse()

    def _parse(self):
        data = self.data
        magic = struct.unpack("<I", data[:4])[0]
        if magic != 0xFEEDFACE:
            raise SystemExit("ожидается thin armv7 Mach-O, magic=%x" % magic)
        ncmds = struct.unpack("<I", data[16:20])[0]
        offset = 28
        symoff = nsyms = stroff = 0
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack("<II", data[offset:offset + 8])
            if cmd == 0x01:
                segname = data[offset + 8:offset + 24].split(b"\0")[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack("<IIII", data[offset + 24:offset + 40])
                nsects = struct.unpack("<I", data[offset + 48:offset + 52])[0]
                self.segments.append((segname, vmaddr, vmsize, fileoff, filesize))
                sect_offset = offset + 56
                for _ in range(nsects):
                    sectname = data[sect_offset:sect_offset + 16].split(b"\0")[0].decode()
                    seg = data[sect_offset + 16:sect_offset + 32].split(b"\0")[0].decode()
                    addr, size = struct.unpack("<II", data[sect_offset + 32:sect_offset + 40])
                    soff = struct.unpack("<I", data[sect_offset + 40:sect_offset + 44])[0]
                    reserved1, reserved2 = struct.unpack("<II", data[sect_offset + 56:sect_offset + 64])
                    self.sections.append((seg, sectname, addr, size, soff, reserved1, reserved2))
                    sect_offset += 68
            elif cmd == 0x02:
                symoff, nsyms, stroff, strsize = struct.unpack("<IIII", data[offset + 8:offset + 24])
            offset += cmdsize

        for i in range(nsyms):
            base = symoff + i * 12
            strx, ntype, sect, desc, value = struct.unpack("<IBBHI", data[base:base + 12])
            end = data.index(b"\0", stroff + strx)
            name = data[stroff + strx:end].decode(errors="replace")
            if value:
                self.symbols.setdefault(value, name)

    def vm_to_off(self, addr):
        for _, vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= addr < vmaddr + vmsize and addr - vmaddr < filesize:
                return fileoff + (addr - vmaddr)
        return None

    def off_to_vm(self, off):
        for _, vmaddr, vmsize, fileoff, filesize in self.segments:
            if fileoff <= off < fileoff + filesize:
                return vmaddr + (off - fileoff)
        return None

    def import_stubs(self):
        symoff = nsyms = stroff = indirect = 0
        data = self.data
        ncmds = struct.unpack("<I", data[16:20])[0]
        offset = 28
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack("<II", data[offset:offset + 8])
            if cmd == 0x02:
                symoff, nsyms, stroff, _ = struct.unpack("<IIII", data[offset + 8:offset + 24])
            elif cmd == 0x0B:
                vals = struct.unpack("<18I", data[offset + 8:offset + 80])
                indirect = vals[12]
            offset += cmdsize

        def symname(idx):
            base = symoff + idx * 12
            strx = struct.unpack("<I", data[base:base + 4])[0]
            return data[stroff + strx:data.find(b"\0", stroff + strx)].decode(errors="replace")

        la_names = {}
        for seg, sect, addr, size, soff, r1, _ in self.sections:
            if sect != "__la_symbol_ptr":
                continue
            for i in range(0, size, 4):
                idx = struct.unpack("<I", data[indirect + (r1 + i // 4) * 4:
                                               indirect + (r1 + i // 4) * 4 + 4])[0]
                if idx < nsyms:
                    la_names[addr + i] = symname(idx)

        stubs = {}
        for seg, sect, addr, size, soff, r1, _ in self.sections:
            if not sect.startswith("__symbol_stub"):
                continue
            step = 12 if sect == "__symbol_stub4" else 16
            for i in range(0, size, step):
                literal = soff + i + step - 4
                if literal + 4 > len(data):
                    continue
                la_addr = struct.unpack("<I", data[literal:literal + 4])[0]
                if la_addr in la_names:
                    stubs[addr + i] = la_names[la_addr]
        return stubs

    def selector_refs(self):
        refs = {}
        for seg, sect, addr, size, soff, _r1, _r2 in self.sections:
            if sect != "__objc_selrefs":
                continue
            for i in range(0, size, 4):
                ptr = struct.unpack("<I", self.data[soff + i:soff + i + 4])[0]
                off = self.vm_to_off(ptr)
                if off is None:
                    continue
                end = self.data.find(b"\0", off)
                name = self.data[off:end].decode(errors="replace")
                refs[addr + i] = name
        return refs

    def cstring_at(self, addr):
        off = self.vm_to_off(addr)
        if off is None:
            return None
        end = self.data.find(b"\0", off)
        raw = self.data[off:end]
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return None
        if text and all(32 <= ord(c) < 127 or ord(c) > 127 for c in text):
            return text
        return None

def find_method(macho, name):
    needle = name.encode() + b"\0"
    pos = macho.data.find(needle)
    if pos < 0:
        return None
    name_vm = macho.off_to_vm(pos)
    if name_vm is None:
        return None
    target = struct.pack("<I", name_vm)
    for match in re.finditer(re.escape(target), macho.data):
        base = match.start()
        if base + 12 > len(macho.data):
            continue
        name_ptr, types_ptr, imp_ptr = struct.unpack("<III", macho.data[base:base + 12])
        if name_ptr != name_vm:
            continue
        if macho.vm_to_off(types_ptr) is None or macho.vm_to_off(imp_ptr) is None:
            continue
        return imp_ptr
    return None

def disassemble(macho, imp, limit=400, selrefs=None, stubs=None):
    off = macho.vm_to_off(imp & ~1)
    if off is None:
        print("  не удалось сопоставить адрес")
        return
    thumb = bool(imp & 1)
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB if thumb else CS_MODE_ARM)
    md.detail = True
    code = macho.data[off:off + limit * 4]
    print("  imp=0x%x (%s)" % (imp, "thumb" if thumb else "arm"))
    last_selector = None
    for insn in md.disasm(code, imp & ~1):
        line = "  0x%08x  %-8s %s" % (insn.address, insn.mnemonic, insn.op_str)
        if insn.mnemonic in ("ldr", "ldrb") and "pc" in insn.op_str:
            m = re.search(r"\[pc, #(0x[0-9a-f]+|\d+)\]", insn.op_str)
            if m:
                disp = int(m.group(1), 0)
                base = (insn.address + 4) & ~3
                literal_addr = base + disp
                lo = macho.vm_to_off(literal_addr)
                if lo is not None:
                    value = struct.unpack("<I", macho.data[lo:lo + 4])[0]
                    if selrefs and value in selrefs:
                        last_selector = selrefs[value]
                        line += "   ; @selector(%s)" % selrefs[value]
                    else:
                        text = macho.cstring_at(value)
                        if text:
                            line += '   ; "%s"' % text[:60]
                        else:
                            sym = macho.symbols.get(value)
                            if sym:
                                line += "   ; %s" % sym[:60]
        if insn.mnemonic in ("bl", "blx", "b") and insn.op_str.startswith("#"):
            target = int(insn.op_str[1:], 0)
            if stubs and target in stubs:
                fname = stubs[target]
                line += "   ; %s" % fname
                if fname in ("_objc_msgSend", "_objc_msgSendSuper2") and last_selector:
                    line += " -> %s" % last_selector
            else:
                sym = macho.symbols.get(target)
                if sym:
                    line += "   ; %s" % sym[:60]
        print(line)
        if insn.mnemonic in ("bx", "pop") and "pc" in insn.op_str:
            break
        if insn.mnemonic == "bx" and insn.op_str == "lr":
            break

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    archive = zipfile.ZipFile(sys.argv[1])
    fat = archive.read(APP + "TalkingJohn")
    count = struct.unpack(">I", fat[8:12])[0]
    cpu, sub, off, size, align = struct.unpack(">iiIII", fat[8:28])
    data = fat[off:off + size]
    macho = MachO(data)
    print("слайс: cputype=%d size=%d, сегментов %d, символов %d"
          % (cpu, size, len(macho.segments), len(macho.symbols)))
    selrefs = macho.selector_refs()
    stubs = macho.import_stubs()
    print("селекторов в __objc_selrefs: %d, импорт-стабов: %d" % (len(selrefs), len(stubs)))
    for name in sys.argv[2:]:
        print("\n=== %s ===" % name)
        imp = find_method(macho, name)
        if imp is None:
            print("  метод не найден")
            continue
        disassemble(macho, imp, selrefs=selrefs, stubs=stubs)
    return 0

if __name__ == "__main__":
    sys.exit(main())
