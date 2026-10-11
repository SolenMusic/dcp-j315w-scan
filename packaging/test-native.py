#!/usr/bin/env python3
"""Actual package-manager lifecycle tests. Disposable root Docker only."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import time

assert os.geteuid() == 0 and Path('/.dockerenv').exists(), 'Disposable Docker container only'
root = Path(__file__).resolve().parent.parent
name = root.name
# CI mounts each repository as /source, so use its VERSION-independent identity.
scanning = (root / 'src/scanner.c').exists()
name = 'dcp-j315w-scan' if scanning else 'dcp-j315w-cups'
flavour = sys.argv[1]
first, second = map(lambda s: str(Path(s).resolve()), sys.argv[2:4])


def run(*args, check=True):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and p.returncode:
        print(p.stdout, flush=True)
        p.check_returncode()
    return p


def install(file):
    if flavour in ('debian', 'raspberrypi'): run('apt-get', 'install', '-y', file)
    elif flavour == 'fedora': run('dnf', 'install', '-y', file)
    elif flavour == 'opensuse': run('zypper', '--non-interactive', '--no-gpg-checks', 'install', file)
    elif flavour == 'arch': run('pacman', '-U', '--noconfirm', file)
    elif flavour == 'alpine': run('apk', 'add', '--allow-untrusted', file)
    else: raise AssertionError(flavour)


def owned(file):
    if flavour in ('debian', 'raspberrypi'): p = run('dpkg', '-S', str(file))
    elif flavour in ('fedora', 'opensuse'): p = run('rpm', '-qf', str(file))
    elif flavour == 'arch': p = run('pacman', '-Qo', str(file))
    else: p = run('apk', 'info', '--who-owns', str(file))
    assert name in p.stdout, p.stdout


def remove():
    if flavour in ('debian', 'raspberrypi'): run('apt-get', 'remove', '-y', name)
    elif flavour == 'fedora': run('dnf', 'remove', '-y', name)
    elif flavour == 'opensuse': run('zypper', '--non-interactive', 'remove', name)
    elif flavour == 'arch': run('pacman', '-R', '--noconfirm', name)
    else: run('apk', 'del', name)


install(first)
print('PASS: package manager resolves dependencies and installs', flush=True)
if scanning:
    helper = Path('/usr/bin/dcp-j315w-scan-configure')
    owned(helper)
    run(str(helper), '--address', '127.0.0.1')
    conf = Path('/etc/sane.d/dcpj315w.conf')
    before = conf.read_bytes()
    assert 'dcpj315w:127.0.0.1' in run('scanimage', '-L').stdout
    libraries = sorted({p.resolve() for p in list(Path('/usr/lib').glob('**/sane/libsane-dcpj315w.so.1.0.0')) + list(Path('/usr/lib64').glob('sane/libsane-dcpj315w.so.1.0.0'))})
    assert len(libraries) == 1, libraries
    owned(libraries[0])
    # Through the real distro DLL loader, fragmented colour scans and failures.
    run('python3', str(root / 'test_sane.py'))
    install(second)
    assert conf.read_bytes() == before
    assert 'dcpj315w:127.0.0.1' in run('scanimage', '-L').stdout
    print('PASS: native SANE loader scans; upgrade preserves scanner address', flush=True)
    remove()
    assert not libraries[0].exists() and not helper.exists()
    backups = [conf, Path(str(conf) + '.rpmsave'), Path(str(conf) + '.pacsave')]
    assert any(p.exists() and p.read_bytes() == before for p in backups), backups
    assert not Path('/etc/sane.d/dll.d/dcpj315w').exists(), 'Backend activation must be removed'
    if flavour in ('debian', 'raspberrypi'):
        # Debian retains even unmodified conffiles on remove. Purge owns cleanup.
        pass
    print('PASS: removal unregisters driver and preserves edited configuration', flush=True)
else:
    configure = Path('/usr/bin/dcp-j315w-print-configure')
    remover = '/usr/bin/dcp-j315w-print-remove-queue'
    owned(configure)
    binary = Path('/usr/lib/cups/filter/dcp-j315w-cups/rastertodcpj315w')
    owned(binary)
    if flavour == 'alpine':
        # Disposable test setup: Alpine's stock CUPS administration group.
        run('addgroup', 'root', 'lpadmin')
    daemon = subprocess.Popen(['cupsd', '-f'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(50):
            if run('lpstat', '-r', check=False).returncode == 0: break
            time.sleep(.1)
        else: raise AssertionError('CUPS did not start')
        queue, other = 'DCP_NativePackage', 'UnrelatedPackageTest'
        run(str(configure), '--queue', queue, '--address', '127.0.0.1', '--port', '9')
        model = Path('/usr/share/cups/model/dcp-j315w-cups.ppd')
        owned(model)
        foreign = Path('/tmp/foreign.ppd')
        foreign.write_text(model.read_text().replace(str(binary), 'rastertoforeign'))
        run('lpadmin', '-p', other, '-E', '-v', 'socket://127.0.0.1:9', '-P', str(foreign))
        run('lpadmin', '-p', queue, '-o', 'PageSize=A5', '-o', 'Resolution=600dpi', '-o', 'ColorModel=Color')
        settings = run('lpoptions', '-p', queue, '-l').stdout
        connection = run('lpstat', '-v', queue).stdout
        model_hash = hashlib.sha256(model.read_bytes()).hexdigest()
        run(str(configure), '--queue', queue)
        assert hashlib.sha256(model.read_bytes()).hexdigest() == model_hash
        assert run('lpoptions', '-p', queue, '-l').stdout == settings
        held = Path('/tmp/package-held.txt')
        held.write_text('Held test only; never sent to a printer.\n')
        run('lp', '-d', queue, '-H', 'hold', str(held))
        p = run(remover, '--queue', queue, check=False)
        assert p.returncode and 'unfinished jobs' in p.stdout
        assert binary.exists()
        run('cancel', queue)
        install(second)
        assert run('lpoptions', '-p', queue, '-l').stdout == settings
        assert run('lpstat', '-v', queue).stdout == connection
        # Feed a PDF through the package-owned PPD/filter, with no printer IO.
        fixture = root / 'fixtures/print-options.pdf'
        if flavour == 'arch':
            run('qpdf', '--stream-data=uncompress', str(fixture), '/tmp/native-fixture.pdf')
            fixture = Path('/tmp/native-fixture.pdf')
        p = subprocess.run(['cupsfilter', '-e', '-p', str(model), '-i', 'application/pdf', '-m', 'printer/foo', '-o', 'page-ranges=1', str(fixture)], capture_output=True, timeout=180)
        if p.returncode: print(p.stderr.decode(errors='replace'))
        assert p.returncode == 0
        sys.path.insert(0, str(root))
        from inspect_protocol import inspect
        pages = inspect(p.stdout)
        assert len(pages) == 1 and pages[0]['ink_pixels'] > 0
        print('PASS: packaged PDF filter prints; upgrade keeps queue settings and connection', flush=True)
        run(remover, '--queue', queue)
        assert binary.exists(), 'Queue helper must not remove package-owned files'
        assert run('lpstat', '-p', other).returncode == 0
        remove()
        assert not binary.exists() and not configure.exists() and not model.exists()
        assert run('lpstat', '-p', other).returncode == 0
        print('PASS: safe queue removal; package manager removes owned files; unrelated queue preserved', flush=True)
    finally:
        daemon.terminate()
        try: daemon.wait(timeout=5)
        except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
print('NATIVE PACKAGE VERIFICATION COMPLETE - no physical device contacted', flush=True)
