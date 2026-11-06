#!/usr/bin/env python3
"""tools/export-isix-plugin-kit.py --zip writes the SDK zip a release publishes.

    python3 tests/test-sdk-release-zip.py [TEMPLATE_DIR]

The SDK is built with --swiftc for arm64 and x86_64, which needs no Xcode
build of the application, and zipped. The test checks that the zip:

- has one top folder named after the zip and no AppleDouble `._` entry,
  `__MACOSX/` or `.DS_Store`, even when the folder it is made from has them;
- holds IsiXPluginKit.framework with its binary, its module interfaces and its
  symbolic links stored as links, and SDK.json describing that binary;
- holds the application's LICENSE, COPYING, COPYING.LESSER and NOTICE, and
  README.md, the kit's documentation, as they are in this checkout;
- holds LegacyPorting/ with the porting kit (LICENSE, IsiXLegacyBridge/ with
  its symbolic links, IsiXPluginKit/README.md and the three tools/ scripts),
  whose files and links match PORTING.json and this checkout;
- extracts with unzip and with ditto to the same tree, links included, with
  no `._` file, and PORTING.json still matches;
- comes out byte for byte the same when written again from the same folder.

TEMPLATE_DIR is a checkout of the plugin template. With it, its
`script/sdk.py check --sdk <folder> --require-porting` must accept each
extracted copy: the release's LegacyPorting/ has the form the template
exports. Without it, everything else is checked and the test exits 2.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools' / 'export-isix-plugin-kit.py'
NAME = 'IsiXPluginKit'
ARCHS = ('arm64', 'x86_64')
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def junk(name):
    base = name.rstrip('/').rsplit('/', 1)[-1]
    return base.startswith('._') or base == '.DS_Store' or '__MACOSX' in name.split('/')


def zip_tree(archive):
    """{path below the top folder: ('dir',) | ('link', target) | ('file', sha256, mode)} and the top folder."""
    tree, tops = {}, set()
    with zipfile.ZipFile(archive) as bundle:
        for info in bundle.infolist():
            name = info.filename
            tops.add(name.split('/', 1)[0])
            relative = name.split('/', 1)[1].rstrip('/') if '/' in name else ''
            if not relative:
                continue
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                tree[relative] = ('link', bundle.read(info).decode())
            elif info.is_dir():
                tree[relative] = ('dir',)
            else:
                tree[relative] = ('file', sha256(bundle.read(info)), stat.S_IMODE(mode))
    return tree, tops


def disk_tree(folder):
    tree = {}
    for path in sorted(Path(folder).rglob('*')):
        relative = path.relative_to(folder).as_posix()
        if path.is_symlink():
            tree[relative] = ('link', os.readlink(path))
        elif path.is_dir():
            tree[relative] = ('dir',)
        else:
            tree[relative] = ('file', sha256(path.read_bytes()), stat.S_IMODE(path.stat().st_mode))
    return tree


def expected_source(relative):
    """What LegacyPorting/<relative> must be, read from this checkout."""
    path = ROOT / relative
    return f'symlink:{os.readlink(path)}' if path.is_symlink() else sha256(path.read_bytes())


if shutil.which('xcrun') is None or not Path('/usr/bin/unzip').exists() or not Path('/usr/bin/ditto').exists():
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools), /usr/bin/unzip and /usr/bin/ditto\n')
    sys.exit(2)
template = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None

spec = importlib.util.spec_from_file_location('exporter', TOOL)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

with tempfile.TemporaryDirectory(prefix='sdk-release-zip-') as temporary:
    work = Path(temporary)
    output, archive = work / 'sdk', work / 'IsiXPluginKit-SDK-0.0.0-test.zip'
    top = archive.name[:-len('.zip')]
    result = subprocess.run([sys.executable, str(TOOL), '--swiftc', '--archs', ','.join(ARCHS),
                             '--output', str(output), '--zip', str(archive)],
                            capture_output=True, text=True, timeout=600)
    if result.returncode != 0 or not archive.is_file():
        print(f'the export with --zip failed ({result.returncode}): {result.stderr[-2000:]}')
        sys.exit(1)
    printed = json.loads(result.stdout)
    check(printed.get('zipSHA256') == sha256(archive.read_bytes()), 'the printed zipSHA256 is not the zip\'s')

    tree, tops = zip_tree(archive)
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        check(bundle.testzip() is None, 'the zip has a corrupt entry')
    check(tops == {top}, f'the zip\'s top level is {sorted(tops)}, not {top}/ alone')
    bad = [n for n in names if junk(n)]
    check(not bad, f'the zip has AppleDouble, __MACOSX or .DS_Store entries: {bad[:10]}')
    check(len(names) == len(set(names)), 'the zip lists an entry twice')

    # The framework and SDK.json, as the export without --zip leaves them in <output>.
    framework = f'{NAME}.framework'
    binary = tree.get(f'{framework}/Versions/A/{NAME}')
    check(binary is not None and binary[0] == 'file', 'the zip has no framework binary')
    for link, target in ((f'{framework}/Versions/Current', 'A'), (f'{framework}/{NAME}', f'Versions/Current/{NAME}'),
                         (f'{framework}/Modules', 'Versions/Current/Modules'),
                         (f'{framework}/Resources', 'Versions/Current/Resources')):
        check(tree.get(link) == ('link', target), f'{link} is {tree.get(link)}, not a link to {target}')
    module = f'{framework}/Versions/A/Modules/{NAME}.swiftmodule'
    for arch in ARCHS:
        check(tree.get(f'{module}/{arch}-apple-macos.swiftinterface', ('',))[0] == 'file',
              f'the zip has no {arch} module interface')
    check(not [p for p in tree if p.endswith(('.private.swiftinterface', '.swiftmodule')) and p != module],
          'the zip carries the host\'s private interface or a binary module')
    sdk_json = tree.get('SDK.json')
    check(sdk_json is not None and sdk_json[1] == sha256((output / 'SDK.json').read_bytes()),
          'SDK.json in the zip is not the exported one')
    description = json.loads((output / 'SDK.json').read_text())
    check(description.get('name') == NAME and sorted(description.get('architectures', [])) == sorted(ARCHS),
          f'SDK.json describes {description.get("name")} {description.get("architectures")}')
    check(binary is not None and description.get('binarySHA256') == binary[1],
          'SDK.json\'s binarySHA256 is not the zipped binary\'s')
    for interface, digest in description.get('interfaceSHA256', {}).items():
        check(tree.get(f'{module}/{interface}', ('', ''))[1] == digest, f'{interface} differs from SDK.json')

    # The license files and the README the published SDK carries.
    for name, source in [(n, n) for n in ('LICENSE', 'COPYING', 'COPYING.LESSER', 'NOTICE')] + [
            ('README.md', 'IsiXPluginKit/README.md')]:
        check(tree.get(name, ('', ''))[1] == sha256((ROOT / source).read_bytes()),
              f'{name} in the zip is missing or is not this checkout\'s {source}')
    expected_top = sorted([framework, 'SDK.json', 'LegacyPorting', 'LICENSE', 'COPYING', 'COPYING.LESSER', 'NOTICE',
                           'README.md'])
    check(sorted(p for p in tree if '/' not in p) == expected_top,
          f'the zip\'s top folder holds {sorted(p for p in tree if "/" not in p)}, not {expected_top}')

    # LegacyPorting/: the porting kit, described by PORTING.json, as in this checkout.
    porting = {p[len('LegacyPorting/'):]: v for p, v in tree.items() if p.startswith('LegacyPorting/')}
    manifest_entry = porting.pop('PORTING.json', None)
    check(manifest_entry is not None, 'LegacyPorting/ has no PORTING.json')
    manifest = json.loads((output / 'LegacyPorting' / 'PORTING.json').read_text())
    check(manifest_entry is not None and manifest_entry[1] == sha256((output / 'LegacyPorting/PORTING.json').read_bytes()),
          'PORTING.json in the zip is not the exported one')
    files = manifest.get('files', {})
    check(manifest.get('revision', '').split('+')[0] == description.get('revision', '').split('+')[0]
          and len(manifest.get('revision', '')) >= 40, f'PORTING.json\'s revision is {manifest.get("revision")!r}')
    zipped = {p: (f'symlink:{v[1]}' if v[0] == 'link' else v[1]) for p, v in porting.items() if v[0] != 'dir'}
    differing = sorted({p for p in zipped if zipped[p] != files.get(p)} | {p for p in files if p not in zipped})
    check(not differing, f'LegacyPorting/ in the zip differs from PORTING.json: {differing[:10]}')
    for source in exporter.PORTING_SOURCES:
        check(source in files or any(p.startswith(source + '/') for p in files), f'PORTING.json lists no {source}')
    links = sorted(p for p, v in files.items() if v.startswith('symlink:'))
    check(any(p.startswith('IsiXLegacyBridge/Include/') for p in links),
          f'PORTING.json lists no symbolic link of IsiXLegacyBridge/Include: {links}')
    stale = sorted(p for p, v in files.items() if expected_source(p) != v)
    check(not stale, f'LegacyPorting/ differs from this checkout: {stale[:10]}')
    tracked = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '--', 'IsiXLegacyBridge'], capture_output=True,
                             text=True).stdout.splitlines()
    check(tracked and not [p for p in tracked if p not in files],
          'LegacyPorting/IsiXLegacyBridge lacks tracked files of IsiXLegacyBridge')
    for script in ('tools/port-legacy-plugin.py', 'tools/build-isix-legacy-plugin.py', 'tools/inventory-plugin-api.py'):
        entry = porting.get(script)
        executable = bool((ROOT / script).stat().st_mode & 0o111)
        check(entry is not None and entry[0] == 'file' and entry[2] == (0o755 if executable else 0o644),
              f'LegacyPorting/{script} is missing or lost its permissions: {entry}')

    # What unzip and ditto make of it.
    extracted = []
    for label, command in (('unzip', ['/usr/bin/unzip', '-q', str(archive), '-d']),
                           ('ditto', ['/usr/bin/ditto', '-x', '-k', str(archive)])):
        destination = work / label
        destination.mkdir()
        done = subprocess.run(command + [str(destination)], capture_output=True, text=True, timeout=120)
        check(done.returncode == 0, f'{label} could not extract the zip: {done.stderr[-500:]}')
        folder = destination / top
        on_disk = disk_tree(folder) if folder.is_dir() else {}
        check(on_disk == tree, f'{label} extracted another tree: '
              + repr(sorted(set(on_disk.items()) ^ set(tree.items()), key=str)[:6]))
        check(not [p for p in destination.rglob('*') if junk(p.name)], f'{label} extracted AppleDouble files')
        problems = exporter.check_porting(folder / 'LegacyPorting')
        check(not problems, f'{label}: LegacyPorting/ differs from PORTING.json: {problems[:10]}')
        extracted.append((label, folder))

    # Written again from the same folder, the zip is the same; junk beside the files stays out.
    again = work / 'again' / archive.name
    exporter.write_zip(output, expected_top, again)
    check(again.read_bytes() == archive.read_bytes(), 'the zip written again from the same folder differs')
    (output / '._SDK.json').write_bytes(b'\0\5\26\7')
    (output / f'{framework}/Versions/A/._{NAME}').write_bytes(b'\0\5\26\7')
    (output / '__MACOSX').mkdir()
    (output / '__MACOSX/._LICENSE').write_bytes(b'\0\5\26\7')
    (output / 'LegacyPorting/.DS_Store').write_bytes(b'\0')
    junked = work / 'junked' / archive.name
    exporter.write_zip(output, expected_top + ['__MACOSX', '._SDK.json'], junked)
    with zipfile.ZipFile(junked) as bundle:
        bad = [n for n in bundle.namelist() if junk(n)]
    check(not bad, f'files beside the SDK went into the zip: {bad}')
    check(zip_tree(junked)[0] == tree, 'the zip made beside junk files differs from the first one')

    # The porting kit copied from a source with junk files: they stay out of LegacyPorting/ and PORTING.json.
    source = work / 'source'
    for name in exporter.PORTING_SOURCES + exporter.NOTICES:
        origin, target = ROOT / name, source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if origin.is_dir():
            shutil.copytree(origin, target, symlinks=True)
        else:
            shutil.copy2(origin, target)
    (source / 'IsiXLegacyBridge/._README.md').write_bytes(b'\0\5\26\7')
    (source / 'IsiXLegacyBridge/Headers/.DS_Store').write_bytes(b'\0')
    planted = work / 'planted'
    planted.mkdir()
    copied = exporter.export_porting(planted, source)
    check(copied['files'] == files, 'the porting kit copied from a source with junk files lists them')
    check(not [p for p in (planted / 'LegacyPorting').rglob('*') if junk(p.name)],
          'the porting kit copied from a source with junk files carries them')

    template_checked = False
    if template is not None and (template / 'script' / 'sdk.py').is_file():
        for label, folder in extracted:
            done = subprocess.run([sys.executable, str(template / 'script' / 'sdk.py'), 'check', '--sdk', str(folder),
                                   '--require-porting', '--archs', ' '.join(ARCHS)],
                                  capture_output=True, text=True, timeout=120)
            check(done.returncode == 0 and 'entries matching PORTING.json' in done.stdout,
                  f'the template refuses the {label} copy: {(done.stdout + done.stderr).strip()[-800:]}')
        template_checked = True

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'the SDK zip holds the framework, SDK.json, the license files, README.md and LegacyPorting/ matching '
      f'PORTING.json ({len(files)} entries, {len(links)} links), without AppleDouble or __MACOSX entries')
if not template_checked:
    sys.stderr.write('SKIP: the template check needs a checkout of the plugin template as argument (TEMPLATE_DIR)\n')
    sys.exit(2)
print(f'the template\'s script/sdk.py check --require-porting accepts the copies extracted by unzip and ditto')
