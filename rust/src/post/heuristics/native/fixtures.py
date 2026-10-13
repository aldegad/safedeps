#!/usr/bin/env python3
"""Build our own image fixtures on macOS; never execute or load an image."""
import pathlib
import struct
import subprocess
import sys


def build(root):
    root = pathlib.Path(root)
    root.mkdir(parents=True, exist_ok=True)
    source = root / 'fixture.c'
    source.write_text('int main(void) { return 42; }\nint safedeps_probe(void) { return 42; }\n')
    def run(*args):
        subprocess.run(list(map(str, args)), check=True, capture_output=True)
    for arch in ('arm64', 'x86_64'):
        run('clang', '-arch', arch, source, '-o', root / (arch + '.mach'))
        run('clang', '-dynamiclib', '-arch', arch, source, '-o', root / (arch + '.dylib'))
    run('lipo', '-create', root/'x86_64.mach', root/'arm64.mach', '-output', root/'fat-junk-first')
    run('lipo', '-create', root/'x86_64.dylib', root/'arm64.dylib', '-output', root/'hidden-arm64')
    run('lipo', '-create', '-fat64', root/'x86_64.dylib', root/'arm64.dylib', '-output', root/'fat64')
    for name in ('fat-junk-first', 'hidden-arm64'):
        data = bytearray((root/name).read_bytes())
        cpu, _, offset, _, _ = struct.unpack_from('>5I', data, 8)
        assert cpu == 0x01000007
        data[offset:offset+4] = bytes(4)
        if name == 'hidden-arm64':
            struct.pack_into('>I', data, 4, 1)
        (root/name).write_bytes(data)
    sysroot = pathlib.Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip())
    lld = next(sysroot.glob('lib/rustlib/*/bin/rust-lld'))
    run('clang', '--target=x86_64-unknown-linux-gnu', '-ffreestanding', '-fno-stack-protector', '-fPIC', '-c', source, '-o', root/'elf.o')
    run(lld, '-flavor', 'gnu', '-m', 'elf_x86_64', '-e', 'main', '-o', root/'elf-exec', root/'elf.o')
    run(lld, '-flavor', 'gnu', '-m', 'elf_x86_64', '-shared', '-o', root/'elf-dyn', root/'elf.o')
    for arch, machine, name in [('i686','x86','pe32'), ('x86_64','x64','pe64-dll')]:
        run('clang', '--target='+arch+'-pc-windows-msvc', '-ffreestanding', '-fno-stack-protector', '-c', source, '-o', root/(name+'.obj'))
        extra = ['/dll'] if name.endswith('dll') else []
        run(lld, '-flavor', 'link', '/entry:main', '/subsystem:console', '/nodefaultlib', '/machine:'+machine,
            '/out:'+str(root/name), *extra, root/(name+'.obj'))
    # A complete minimal JVMS class (no methods), with its source structure
    # kept here. Preview differs only in the minor version, 65535 (§4.1).
    # Constant pool: Utf8 Fixture, Class #1, Utf8 java/lang/Object, Class #3.
    data = bytes.fromhex('cafebabe000000410005')
    for name in (b'Fixture', b'java/lang/Object'):
        data += b'\x01' + struct.pack('>H', len(name)) + name
        data += b'\x07' + struct.pack('>H', 1 if name == b'Fixture' else 3)
    data += struct.pack('>7H', 0x21, 2, 4, 0, 0, 0, 0)
    (root/'ordinary.class').write_bytes(data)
    (root/'preview.class').write_bytes(data[:4]+b'\xff\xff'+data[6:])


if __name__ == '__main__':
    build(sys.argv[1])
