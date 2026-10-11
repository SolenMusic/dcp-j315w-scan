#!/usr/bin/env python3
"""Check Linux installer/removal boundaries using a private staging filesystem."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent
binary = Path(os.environ.get('OUTPUT_DIR', root/'build/linux-sane'))/'libsane-dcpj315w.so.1.0.0'
with tempfile.TemporaryDirectory(prefix='dcp-sane-install-') as tmp:
    base = Path(tmp)
    package = base/'package'
    package.mkdir()
    for script in ('install.sh', 'uninstall.sh', 'linux_arch.sh'): shutil.copy2(root/'linux'/script, package/script)
    shutil.copy2(binary, package/binary.name)
    musl = bool(list(Path('/lib').glob('ld-musl-*.so.1')))
    (package/'BUNDLE_LIBC').write_text('musl\n' if musl else 'glibc\n')
    if not musl: (package/'MIN_GLIBC').write_text('2.17\n')
    stage = base/'system'
    conf = stage/'etc/sane.d'
    lib = stage/'usr/lib64/sane'
    conf.mkdir(parents=True)
    lib.mkdir(parents=True)
    (conf/'dll.conf').write_bytes(b'# Existing scanner configuration\nepson2\n')
    (conf/'other.conf').write_bytes(b'keep this\n')
    (lib/'libsane-other.so').write_bytes(b'other backend')
    old = {p:p.read_bytes() for p in (conf/'dll.conf', conf/'other.conf', lib/'libsane-other.so')}
    def run(address='127.0.0.1', okay=True):
        result = subprocess.run([package/'install.sh','--address',address,'--libdir','/usr/lib64','--destdir',stage],capture_output=True,text=True)
        assert (result.returncode == 0) == okay, result
        return result
    for address in ('', 'hostname.local', '1.2.3.999', '01.2.3.4', '1.2.3.4;false'):
        run(address, False)
    assert not (conf/'dcpj315w.conf').exists()
    run()
    assert all(p.read_bytes() == data for p,data in old.items())
    installed = lib/binary.name
    assert installed.read_bytes() == binary.read_bytes()
    assert installed.stat().st_mode & 0o777 == 0o755
    assert (conf/'dcpj315w.conf').stat().st_mode & 0o777 == 0o644
    assert (lib/'libsane-dcpj315w.so.1').resolve() == installed
    assert (conf/'dll.d/dcpj315w').read_text() == 'dcpj315w\n'
    run('127.0.0.2')
    assert (conf/'dcpj315w.conf').read_text().endswith('127.0.0.2\n')
    print('PASS: install/update preserve other backends, validate addresses, and set library/config permissions')
    # A symlink target is rejected before any installed file changes.
    installed.unlink()
    victim = base/'unrelated'
    victim.write_bytes(b'preserve')
    installed.symlink_to(victim)
    run(okay=False)
    assert victim.read_bytes() == b'preserve'
    installed.unlink()
    run()
    print('PASS: installer refuses a symlink payload and preserves its target')
    result = subprocess.run([package/'uninstall.sh','--libdir','/usr/lib64','--destdir',stage],capture_output=True,text=True)
    assert result.returncode == 0, result
    assert not list(lib.glob('libsane-dcpj315w*')) and not (conf/'dll.d/dcpj315w').exists()
    assert (conf/'dcpj315w.conf').exists() and all(p.read_bytes() == data for p,data in old.items())
    wrong = bytearray((package/binary.name).read_bytes())
    current = int.from_bytes(wrong[18:20],'little')
    wrong[18:20] = (183 if current == 62 else 62).to_bytes(2,'little')
    (package/binary.name).write_bytes(wrong)
    run(okay=False)
    assert not list(lib.glob('libsane-dcpj315w*'))
    print('PASS: removal preserves documents/configuration/other drivers; wrong CPU rejected before installation')
    shutil.copy2(binary, package/binary.name)
    (package/'BUNDLE_LIBC').write_text('glibc\n' if musl else 'musl\n')
    run(okay=False)
    assert not list(lib.glob('libsane-dcpj315w*'))
    if not musl:
        (package/'BUNDLE_LIBC').write_text('glibc\n')
        (package/'MIN_GLIBC').write_text('999.0\n')
        run(okay=False)
        assert not list(lib.glob('libsane-dcpj315w*'))
    print('PASS: incompatible C runtime and glibc version are rejected before installation')
    shutil.copy2(binary, package/binary.name)
    (package/'BUNDLE_LIBC').write_text('musl\n' if musl else 'glibc\n')
    (package/'MIN_GLIBC').unlink(missing_ok=True)
    wrong_class=bytearray((package/binary.name).read_bytes())
    wrong_class[4]=1 if wrong_class[4]==2 else 2
    (package/binary.name).write_bytes(wrong_class)
    run(okay=False)
    assert not list(lib.glob('libsane-dcpj315w*'))
    shutil.copy2(binary, package/binary.name)
    if current==40:
        wrong_float=bytearray((package/binary.name).read_bytes())
        flags=int.from_bytes(wrong_float[36:40],'little')
        flags=(flags & ~0x600) | (0x200 if flags & 0x400 else 0x400)
        wrong_float[36:40]=flags.to_bytes(4,'little')
        (package/binary.name).write_bytes(wrong_float)
        run(okay=False)
        assert not list(lib.glob('libsane-dcpj315w*'))
    print('PASS: incompatible ELF class and ARM float ABI are rejected before installation')

print('All Linux installer checks passed.')
