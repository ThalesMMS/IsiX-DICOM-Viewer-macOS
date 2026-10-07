#!/usr/bin/env python3
"""Keep original FreeType code behind VTK's public C symbol in installed archives."""
from pathlib import Path
import collections
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

recipe = Path(__file__).resolve().parent
raw = '_FT_MulFix'
public = '_vtkfreetype_FT_MulFix'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def recipe_identity():
    return {name: digest(recipe / name) for name in
            ('adapt-freetype.py', 'freetype-source.json', 'CMake.sh', 'Make.sh', 'HostBuild.cmake')}


def run(*arguments, binary=False):
    result = subprocess.run(arguments, capture_output=True, text=not binary)
    if result.returncode:
        error = result.stderr.decode(errors='replace') if binary else result.stderr
        raise ValueError('%s failed: %s' % (Path(arguments[0]).name, error.strip()))
    if result.stderr:
        sys.stderr.write(result.stderr.decode(errors='replace') if binary else result.stderr)
    return result.stdout


def source_identity(source):
    pin = json.loads((recipe / 'freetype-source.json').read_text())
    tree = hashlib.sha256()
    count = 0
    for path in sorted(source.rglob('*')):
        if path.is_symlink():
            raise ValueError('unexpected link in the original FreeType source')
        if path.is_file():
            relative = path.relative_to(source).as_posix()
            tree.update(relative.encode() + b'\0' + digest(path).encode() + b'\n')
            count += 1
    if count != pin['files'] or tree.hexdigest() != pin['treeSha256']:
        raise ValueError('FreeType source differs from its pinned original archive')
    return pin


def symbols(path):
    # Addresses change during the partial link; names, binding, and visibility
    # are the ABI. Count definitions too, so a duplicated member cannot pass.
    found = collections.Counter()
    for line in run('xcrun', 'nm', '-g', '--defined-only', '-m', str(path)).splitlines():
        if ' external ' in line:
            found[(line.split()[-1], 'private' if 'private external' in line else 'public',
                   'weak' if 'weak' in line else 'strong')] += 1
    return found


def build_architecture():
    """The single slice of this build's package (arm64 or x86_64)."""
    slices = os.environ.get('ARCHS', 'arm64').split()
    if len(slices) != 1 or slices[0] not in ('arm64', 'x86_64'):
        raise ValueError('the FreeType host adaptation builds one slice, arm64 or x86_64, not %s' % ' '.join(slices))
    return slices[0]


def adapt(install, source):
    pin = source_identity(source)
    architecture = build_architecture()
    if not (install / '.incomplete').is_file():
        raise ValueError('refusing to alter a completed installation')
    libraries = list((install / 'lib').glob('libvtkfreetype-*.a'))
    if len(libraries) != 1:
        raise ValueError('expected one installed VTK FreeType archive')
    archive = libraries[0]
    if run('xcrun', 'lipo', '-archs', str(archive)).strip() != architecture:
        raise ValueError('the FreeType host adaptation requires an %s archive' % architecture)
    before = symbols(archive)
    if before[(raw, 'public', 'strong')] != 1 or any(name == public for name, _, _ in before):
        raise ValueError('expected one original FT_MulFix and no prefixed definition')
    members = run('xcrun', 'ar', '-t', str(archive)).splitlines()
    selected = [name for name in members if name == 'ftbase.c.o']
    if len(selected) != 1:
        raise ValueError('expected exactly one original ftbase.c.o archive member')
    original_digest = digest(archive)
    # Work beside Install, and publish only after the object and complete module
    # preserve every other global/private-extern definition. Source and CMake's
    # object files remain original, allowing a subsequent install to start clean.
    with tempfile.TemporaryDirectory(prefix='.freetype-', dir=install.parent) as directory:
        work = Path(directory)
        original = work / 'original.o'
        original.write_bytes(run('xcrun', 'ar', '-p', str(archive), selected[0], binary=True))
        linked = work / 'aliased.o'
        run('xcrun', 'ld', '-r', '-arch', architecture, '-keep_private_externs',
            '-alias', raw, public, '-o', str(linked), str(original))
        names = work / 'local-symbols'
        names.write_text(raw + '\n')
        isolated = work / selected[0]
        run('xcrun', 'nmedit', '-R', str(names), '-o', str(isolated), str(linked))
        expected_object = symbols(original)
        if expected_object[(raw, 'public', 'strong')] != 1:
            raise ValueError('FT_MulFix is not defined by the original ftbase member')
        del expected_object[(raw, 'public', 'strong')]
        expected_object[(public, 'public', 'strong')] += 1
        if symbols(isolated) != expected_object:
            raise ValueError('partial link changed another FreeType symbol or its visibility')
        staged = work / archive.name
        shutil.copyfile(archive, staged)
        run('xcrun', 'ar', '-r', str(staged), str(isolated))
        expected = before.copy()
        del expected[(raw, 'public', 'strong')]
        expected[(public, 'public', 'strong')] += 1
        if symbols(staged) != expected or run('xcrun', 'ar', '-t', str(staged)).splitlines() != members:
            raise ValueError('adapted FreeType module changed unrelated archive members/symbols')
        record = {
            'format': 1, 'source': pin, 'sourcePatches': [],
            'method': 'Mach-O partial-link alias with private externs preserved; original symbol localized',
            'publicSymbol': public, 'localSymbol': raw,
            'archive': archive.name, 'originalArchiveSha256': original_digest,
            'installedArchiveSha256': digest(staged),
            'configuration': os.environ.get('CONFIGURATION', ''), 'architecture': architecture,
            'compiler': run('xcrun', 'clang', '--version').splitlines()[0],
            'recipeSha256': recipe_identity(),
        }
        prepared = work / 'freetype-host-adaptation.json'
        prepared.write_text(json.dumps(record, sort_keys=True, indent=2) + '\n')
        (install / 'share').mkdir(exist_ok=True)
        os.replace(staged, archive)
        os.replace(prepared, install / 'share/freetype-host-adaptation.json')


def verify_install(install, completing=False):
    if not completing and (install / '.incomplete').exists():
        raise ValueError('installation is incomplete')
    record = json.loads((install / 'share/freetype-host-adaptation.json').read_text())
    expected_source = json.loads((recipe / 'freetype-source.json').read_text())
    if record['source'] != expected_source or record['recipeSha256'] != recipe_identity():
        raise ValueError('installed FreeType source/recipe identity changed')
    selected = json.loads((recipe.parent / 'external-sources.json').read_text())['VTK']
    installed = json.loads((install / 'share/source.json').read_text())
    if (installed != selected or selected['version'] != expected_source['sourceVersion'] or
            selected['sha256'] != expected_source['archiveSha256'] or selected.get('sourcePatches') != [] or
            digest(install / 'share/licenses/VTK/Copyright.txt') != selected['licenseSha256']):
        raise ValueError('installed VTK original source/license identity changed')
    if os.environ.get('CONFIGURATION') and record['configuration'] != os.environ['CONFIGURATION']:
        raise ValueError('installed FreeType configuration changed')
    if record['archive'] != 'libvtkfreetype-' + expected_source['sourceVersion'].rsplit('.', 1)[0] + '.a':
        raise ValueError('unexpected installed FreeType module')
    if (digest(install / 'lib' / record['archive']) != record['installedArchiveSha256'] or
            digest(install / 'wlib/libVTK.a') != record['aggregateSha256']):
        raise ValueError('installed FreeType module/aggregate differs from its identity')


def complete(install):
    if not (install / '.incomplete').is_file():
        raise ValueError('refusing to complete an unmarked installation')
    path = install / 'share/freetype-host-adaptation.json'
    record = json.loads(path.read_text())
    record['aggregateSha256'] = digest(install / 'wlib/libVTK.a')
    with tempfile.TemporaryDirectory(prefix='.freetype-record-', dir=install / 'share') as directory:
        prepared = Path(directory) / path.name
        prepared.write_text(json.dumps(record, sort_keys=True, indent=2) + '\n')
        os.replace(prepared, path)
    verify_install(install, completing=True)


try:
    if len(sys.argv) == 3 and sys.argv[1] == '--verify-source':
        source_identity(Path(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == '--verify-install':
        verify_install(Path(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == '--complete':
        complete(Path(sys.argv[2]))
    elif len(sys.argv) == 3:
        adapt(Path(sys.argv[1]), Path(sys.argv[2]))
    else:
        raise ValueError('usage: adapt-freetype.py INSTALL SOURCE | --verify-source SOURCE | --verify-install INSTALL | --complete INSTALL')
except (OSError, ValueError, KeyError) as error:
    prefix = 'VTK FreeType cache requires rebuilding: ' if '--verify-install' in sys.argv else 'error: VTK FreeType host adaptation: '
    sys.exit(prefix + str(error))
