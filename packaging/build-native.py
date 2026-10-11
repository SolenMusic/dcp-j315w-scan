#!/usr/bin/env python3
"""Build real Linux packages from a verified release bundle; development only.

FPM 1.17.0 writes deb/rpm/pacman metadata (using rpmbuild and bsdtar).
Alpine uses its native apk mkpkg, not FPM's older APK writer.
No Python or Ruby is needed on the end user's machine.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(x) for x in args], check=True)


def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(mode)


def copy(source, target, mode=0o644):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('flavour', choices=['debian', 'raspberrypi', 'fedora', 'opensuse', 'arch', 'alpine'])
    parser.add_argument('arch', choices=['x86_64', 'arm64', 'x86', 'armv6', 'armv6-softfloat', 'armv7'])
    parser.add_argument('bundle', type=Path, help='Extracted, checksum-verified Linux binary bundle')
    parser.add_argument('--output', type=Path, default=Path('build/native'))
    parser.add_argument('--revision', default='1')
    args = parser.parse_args()
    assert re.fullmatch(r'[1-9][0-9]*', args.revision), 'Invalid package revision'
    source = Path(__file__).resolve().parent.parent
    scanning = (source / 'src/scanner.c').exists()
    name = 'dcp-j315w-scan' if scanning else 'dcp-j315w-cups'
    bundle = args.bundle.resolve()
    version = (bundle / 'VERSION').read_text().strip()
    assert re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid version'
    assert (source / 'VERSION').read_text().strip() == version, 'Bundle/source version mismatch'
    flavour, arch = args.flavour, args.arch
    assert (bundle / 'BUNDLE_FLAVOUR').read_text().strip() == flavour, 'Wrong bundle flavour'
    if flavour in ('fedora', 'opensuse', 'arch'):
        assert arch in ('x86_64', 'arm64'), 'No supported 32-bit runtime for this flavour'
    if flavour == 'raspberrypi':
        assert arch == 'armv6', 'Raspberry Pi OS bundle must use ARMv6 hard-float'
    if flavour == 'debian':
        assert arch != 'armv6', 'Use raspberrypi for ARMv6 hard-float'
    if flavour == 'alpine':
        assert arch != 'armv6-softfloat', 'Alpine uses hard-float ARM'
    binary = bundle / ('libsane-dcpj315w.so.1.0.0' if scanning else 'rastertodcpj315w')
    helper = source / ('linux/linux_arch.sh' if scanning else 'linux_arch.sh')
    actual = subprocess.check_output(['sh', '-c', '. "$1"; dcp_elf_arch "$2"', 'sh', str(helper), str(binary)], text=True).strip()
    assert actual == arch, f'ELF architecture {actual} does not match {arch}'
    info = subprocess.check_output(['readelf', '-d', str(binary)], text=True)
    assert ('musl' in info) == (flavour == 'alpine'), 'Wrong libc'
    versions = subprocess.check_output(['readelf', '--version-info', str(binary)], text=True)
    glibc = max(re.findall(r'GLIBC_(\d+\.\d+(?:\.\d+)?)', versions), key=lambda s: tuple(map(int, s.split('.'))), default=None)
    debarch = {'x86_64': 'amd64', 'arm64': 'arm64', 'x86': 'i386', 'armv6': 'armhf', 'armv7': 'armhf', 'armv6-softfloat': 'armel'}[arch]
    nativearch = {'x86_64': 'x86_64', 'arm64': 'aarch64', 'x86': 'x86', 'armv6': 'armhf', 'armv7': 'armv7', 'armv6-softfloat': 'armel'}[arch]
    triplet = {'x86_64': 'x86_64-linux-gnu', 'arm64': 'aarch64-linux-gnu', 'x86': 'i386-linux-gnu', 'armv6': 'arm-linux-gnueabihf', 'armv7': 'arm-linux-gnueabihf', 'armv6-softfloat': 'arm-linux-gnueabi'}[arch]
    libdir = '/usr/lib/' + triplet if flavour in ('debian', 'raspberrypi') else ('/usr/lib64' if flavour in ('fedora', 'opensuse') else '/usr/lib')
    serverbin = '/usr/lib/cups'  # All supported distro packages use this CUPS location.
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='dcp-native-') as tmp:
        stage = Path(tmp) / 'root'
        stage.mkdir()
        doc = stage / 'usr/share/doc' / name
        for item in ('LICENSE', 'VERSION', 'CHANGELOG.md'):
            copy(bundle / item, doc / item)
        copy(source / 'packaging/README.md', doc / 'PACKAGES.md')
        copy(bundle / 'README.md', doc / 'README.md')
        write(stage / 'usr/share/licenses' / name / 'LICENSE', (bundle / 'LICENSE').read_text())
        configs = []
        if scanning:
            lib = stage / libdir.lstrip('/') / 'sane'
            copy(binary, lib / binary.name, 0o755)
            (lib / 'libsane-dcpj315w.so.1').symlink_to(binary.name)
            (lib / 'libsane-dcpj315w.so').symlink_to('libsane-dcpj315w.so.1')
            write(stage / 'etc/sane.d/dcpj315w.conf', '# DCP-J315W Open Scanner; one numeric IPv4 address per line.\n# Configure with: sudo dcp-j315w-scan-configure --address PRINTER_IPV4\n')
            write(stage / 'etc/sane.d/dll.d/dcpj315w', 'dcpj315w\n')
            configs = ['/etc/sane.d/dcpj315w.conf']
            copy(source / 'packaging/configure.sh', stage / 'usr/bin/dcp-j315w-scan-configure', 0o755)
        else:
            install = serverbin + '/filter/' + name
            lib = stage / install.lstrip('/')
            copy(binary, lib / binary.name, 0o755)
            for prologue in sorted(bundle.glob('prologue_*.bin')):
                assert prologue.stat().st_size == 820
                copy(prologue, lib / prologue.name)
            for item in ('DCP-J315W-CUPS.ppd.in', 'prepare_ppd.awk', 'linux_arch.sh', 'discover.sh', 'status.sh', 'status_parse.awk'):
                copy(source / item, lib / item, 0o755 if item.endswith('.sh') else 0o644)
            copy(source / 'install.sh', lib / 'configure.sh', 0o755)
            copy(source / 'uninstall.sh', lib / 'remove-queue.sh', 0o755)
            # Replace the old tar installer receipt's remover on migration, so
            # it cannot silently delete files now tracked by a package manager.
            write(lib / 'uninstall.sh', '#!/bin/sh\necho "This driver is package-managed. Use dcp-j315w-print-remove-queue, then remove dcp-j315w-cups using your package manager." >&2\nexit 1\n', 0o755)
            ppd = (source / 'DCP-J315W-CUPS.ppd.in').read_text().replace('@FILTER@', install + '/' + binary.name)
            write(lib / 'DCP-J315W-CUPS.ppd', ppd)
            write(stage / 'usr/share/cups/model/dcp-j315w-cups.ppd', ppd)
            for command, script, flag in [('configure', 'configure.sh', '--configure-only'), ('remove-queue', 'remove-queue.sh', '--queue-only')]:
                write(stage / ('usr/bin/dcp-j315w-print-' + command), f'#!/bin/sh\nexec /bin/bash {install}/{script} {flag} "$@"\n', 0o755)
        # Validate ARMv7 before unpacking onto an ARMv6 board: both Debian builds
        # use the armhf package label, which alone cannot distinguish the CPU.
        pre = Path(tmp) / 'preinstall'
        write(pre, '#!/bin/sh\nset -eu\n' + ("case $(uname -m) in armv6*) echo 'This ARMv7 package requires a Pi 2 or later CPU; use the Raspberry Pi OS ARMv6 build on Pi 1/Zero.' >&2; exit 1;; esac\n" if arch == 'armv7' else ':\n'), 0o755)
        deps = ['bash', 'binutils', 'file', 'gawk'] if not scanning else ['bash']
        if flavour in ('debian', 'raspberrypi'):
            kind, pkgarch, extension = 'deb', debarch, 'deb'
            deps += ['libsane1'] if scanning else ['cups', 'cups-client', 'cups-filters', 'ghostscript', 'libcups2']
            if glibc: deps += [f'libc6 >= {glibc}']
        elif flavour in ('fedora', 'opensuse'):
            kind, pkgarch, extension = 'rpm', nativearch, 'rpm'
            deps += ['sane-backends-libs' if flavour == 'fedora' else 'libsane1'] if scanning else ['cups', 'cups-client', 'cups-filters', 'ghostscript', 'cups-libs' if flavour == 'fedora' else 'libcups2']
            if glibc: deps += [f'glibc >= {glibc}']
        elif flavour == 'arch':
            kind, pkgarch, extension = 'pacman', nativearch, 'pkg.tar.zst'
            deps += ['sane'] if scanning else ['cups', 'cups-filters', 'ghostscript', 'libcups']
            if glibc: deps += [f'glibc>={glibc}']
        else:
            kind, pkgarch, extension = 'apk', nativearch, 'apk'
            deps += ['sane'] if scanning else ['cups', 'cups-client', 'cups-filters', 'ghostscript', 'cups-libs']
            deps += ['musl']
        dest = output / f'{name}-{version}-{args.revision}-{flavour}-{arch}.{extension}'
        assert not dest.exists(), f'Refusing to replace {dest}'
        description = 'Independent wireless ' + ('SANE scanner backend' if scanning else 'CUPS printer driver') + ' for Brother DCP-J315W'
        url = 'https://github.com/SolenMusic/' + name
        if kind == 'apk':
            # Native APKv3 packages: Alpine 3.24+ (apk-tools 3). /etc is protected
            # by APK's normal configuration handling, including upgrade backups.
            command = ['apk', 'mkpkg', '--files', str(stage), '--output', str(dest)]
            for key, value in [('name', name), ('version', version + '-r' + args.revision), ('arch', pkgarch), ('description', description), ('license', 'MIT'), ('url', url), ('depends', ' '.join(deps))]:
                command += ['--info', key + ':' + value]
            command += ['--script', 'pre-install:' + str(pre), '--script', 'pre-upgrade:' + str(pre)]
            run(*command)
        else:
            command = ['fpm', '-s', 'dir', '-t', kind, '-n', name, '-v', version, '--iteration', args.revision, '--architecture', pkgarch, '--license', 'MIT', '--url', url, '--maintainer', 'DCP-J315W driver contributors <noreply@users.noreply.github.com>', '--description', description, '--before-install', str(pre), '--before-upgrade', str(pre), '-C', str(stage), '-p', str(dest)]
            for dep in deps: command += ['-d', dep]
            # Pacman backup entries must be relative; FPM 1.17's template
            # calls gsub without retaining its result for absolute paths.
            for conf in configs: command += ['--config-files', conf.lstrip('/') if kind == 'pacman' else conf]
            if kind == 'rpm': command += ['--rpm-auto-add-directories', '--rpm-rpmbuild-define', '_build_id_links none', '--no-rpm-autoreq', '--no-rpm-autoprov']
            if kind == 'deb': command += ['--deb-no-default-config-files']
            if kind == 'pacman': command += ['--pacman-compression', 'zstd']
            run(*command, '.')
        print(dest)


if __name__ == '__main__':
    main()
