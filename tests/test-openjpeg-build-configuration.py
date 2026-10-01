#!/usr/bin/env python3
"""Run the dependency's real configure step and check its C compiler behavior.

Also checks that everything names the same OpenJPEG: the tree's CMakeLists.txt,
what the configure step generates, and - when a Debug build
exists - the library that build installed. An install left from an older
release fails here instead of passing for the new one.
"""
import json
import re
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile
import argparse
import gzip
import hashlib
from dcmtk_build import BUILD, CONFIGURATION

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--downloads', type=Path, help='verified source archive cache; never downloads by default')
parser.add_argument('--allow-download', action='store_true', help='explicitly allow the production resolver to fetch the pin')
parser.add_argument('--build', action='store_true', help='also build/install Debug and Release and check recovery; coordinate the build slot')
args = parser.parse_args()
downloads = args.downloads or Path(os.environ.get('EXTERNAL_SOURCES_DOWNLOADS',
    str(BUILD.parent / 'ExternalSources.downloads')))
pin = json.loads((ROOT / 'Horos/Scripts/external-sources.json').read_text())['OpenJPEG']
if not args.allow_download and not (downloads / pin['archive']).is_file():
    print('skipped: needs --downloads with ' + pin['archive'] + ' (SHA-256 ' + pin['sha256'] + ') or --allow-download')
    raise SystemExit(2)
cmake = shutil.which('cmake')
if platform.system() != 'Darwin' or not cmake or not shutil.which('pkg-config'):
    print('skipped: needs macOS, CMake and pkg-config')
    raise SystemExit(2)

failures = []
version = pin['version']
print(f'source: OpenJPEG {version}')


def header_version(path):
    text = path.read_text()
    found = [re.search(r'#define OPJ_VERSION_%s (\d+)' % part, text) for part in ('MAJOR', 'MINOR', 'BUILD')]
    return '.'.join(match.group(1) for match in found) if all(found) else None


with tempfile.TemporaryDirectory(prefix='horos-openjpeg-config-') as temporary:
    work = Path(temporary)
    recipes = work / 'recipes'
    shutil.copytree(ROOT / 'Horos/Scripts/OpenJPEG', recipes / 'OpenJPEG')
    for name in ('external-inputs.sh', 'dependency-hash.sh', 'external-sources.json'):
        shutil.copyfile(ROOT / 'Horos/Scripts' / name, recipes / name)
    configure_script = recipes / 'OpenJPEG/CMake.sh'
    environment = {**os.environ, 'PROJECT_DIR': str(ROOT), 'TARGET_NAME': 'OpenJPEG',
        'TARGET_TEMP_DIR': str(work), 'ARCHS': platform.machine(),
        'PROJECT_TEMP_DIR': str(work), 'EXTERNAL_SOURCES_DOWNLOADS': str(downloads),
        'EXTERNAL_INPUTS_OFFLINE': '0' if args.allow_download else '1',
        'MACOSX_DEPLOYMENT_TARGET': '26.0', 'SDK_NAME': 'macosx',
        'OTHER_CFLAGS': '-fvisibility=default', 'OTHER_CPLUSPLUSFLAGS': '',
        'CLANG_CXX_LANGUAGE_STANDARD': '', 'CLANG_CXX_LIBRARY': ''}
    for configuration in ('Debug', 'Release'):
        # Reuse the directory: changing the configuration must invalidate the cache.
        subprocess.run(['/bin/bash', str(configure_script)],
            cwd=ROOT, env={**environment, 'CONFIGURATION': configuration},
            check=True, capture_output=True, text=True, timeout=60)
        build = work/'CMake'
        subprocess.run([cmake, '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '.'], cwd=build,
            check=True, capture_output=True, text=True, timeout=60)
        entries = json.loads((build/'compile_commands.json').read_text())
        entry = next(row for row in entries if row['file'].endswith('/openjpeg.c'))
        command = shlex.split(entry['command'])
        output_index = command.index('-o')
        del command[output_index:output_index+2]
        command.remove('-c')
        macros = subprocess.check_output([*command, '-dM', '-E'],
            cwd=entry['directory'], text=True, timeout=30)
        optimized = '#define __OPTIMIZE__ 1' in macros
        if optimized != (configuration == 'Release'):
            raise SystemExit(f'{configuration}: unexpected C optimization: {entry["command"]}')
        print(f'PASS: {configuration} C compilation optimization={optimized}')
        generated = header_version(build/'src/lib/openjp2/opj_config.h')
        if generated != version:
            failures.append(f'{configuration}: configure generated OpenJPEG {generated}, the tree is {version}')
        if args.build:
            make_script = recipes / 'OpenJPEG/Make.sh'
            subprocess.run(['/bin/bash', str(make_script)], cwd=ROOT,
                env={**environment, 'CONFIGURATION': configuration},
                check=True, capture_output=True, text=True, timeout=180)
            installed = work / 'Install'
            if header_version(installed / 'include/OpenJPEG/opj_config.h') != version:
                failures.append('isolated install version differs from the declared source')
            if not (installed / 'include/OpenJPEG').is_symlink() or (installed / 'bin').exists():
                failures.append('install lost its compatibility alias or installed codec tools')
            if (installed / 'include/OpenJPEG/format_defs.h').exists():
                failures.append('install retained an unused internal header')
            before_install = (installed / '.products.json').stat().st_mtime_ns
            subprocess.run(['/bin/bash', str(make_script)], cwd=ROOT,
                env={**environment, 'CONFIGURATION': configuration},
                check=True, capture_output=True, text=True, timeout=180)
            if (installed / '.products.json').stat().st_mtime_ns != before_install:
                failures.append('unchanged verified install was rebuilt')
            for damaged in ('include/openjpeg-2.5/openjpeg.h', 'lib/libopenjp2.a'):
                (installed / damaged).write_text('corrupt install\n')
                subprocess.run(['/bin/bash', str(make_script)], cwd=ROOT,
                    env={**environment, 'CONFIGURATION': configuration},
                    check=True, capture_output=True, text=True, timeout=180)
                if (installed / damaged).read_bytes() == b'corrupt install\n' or (installed / '.incomplete').exists():
                    failures.append('Make silently approved a modified install product: ' + damaged)
            print(f'PASS: {configuration} static library/public headers installed; altered install recovered')
        resolved = work / 'Source'
        record = json.loads((resolved / 'share/source.json').read_text())
        if record != pin:
            failures.append('configure did not consume the declared source pin')
        cmakelists = (resolved / 'source/CMakeLists.txt').read_text()
        parts = [re.search(pattern, cmakelists) for pattern in pin['versionPatterns']]
        if not all(parts) or '.'.join(part.group(1) for part in parts if part) != version:
            failures.append('resolved source has the wrong version')
        # A source repair preserves the configure hit when the original bytes
        # are restored; app signing never reaches the dependency identity.
        before = (build / '.cmakehash').stat().st_mtime_ns
        (resolved / 'source/src/lib/openjp2/openjpeg.h').write_text('corrupt source\n')
        subprocess.run(['/bin/bash', str(configure_script)], cwd=ROOT,
            env={**environment, 'CONFIGURATION': configuration, 'DEVELOPMENT_TEAM': 'different'},
            check=True, capture_output=True, text=True, timeout=60)
        if (build / '.cmakehash').stat().st_mtime_ns != before:
            failures.append('source repair or signing change needlessly reconfigured OpenJPEG')
        if (resolved / 'source/src/lib/openjp2/openjpeg.h').read_text() == 'corrupt source\n':
            failures.append('configure silently reused modified upstream source')
    # Repackage exactly the same tar payload with another gzip identity. This
    # keeps source/version/flags unchanged while moving the declared digest.
    alternate_downloads = work / 'alternate-downloads'
    alternate_downloads.mkdir()
    alternate = alternate_downloads / pin['archive']
    alternate.write_bytes(gzip.compress(gzip.decompress((downloads / pin['archive']).read_bytes()), mtime=0))
    alternate_pin = {**pin, 'sha256': hashlib.sha256(alternate.read_bytes()).hexdigest()}
    if alternate_pin['sha256'] == pin['sha256']:
        failures.append('same-version digest test did not change archive identity')
    (recipes / 'external-sources.json').write_text(json.dumps({'OpenJPEG': alternate_pin}))
    before = (build / '.cmakehash').read_text()
    subprocess.run(['/bin/bash', str(configure_script)], cwd=ROOT,
        env={**environment, 'CONFIGURATION': 'Release', 'EXTERNAL_SOURCES_DOWNLOADS': str(alternate_downloads)},
        check=True, capture_output=True, text=True, timeout=60)
    if (build / '.cmakehash').read_text() == before:
        failures.append('same-version source digest did not invalidate configure')
    if (work / 'Install').exists():
        failures.append('same-version source digest did not invalidate install')
    print('PASS: same-version archive digest invalidates configure; source repair/signing preserve hits')

# The last Debug build, if there is one: the installed header, the version the
# library itself reports (opj_version() returns this string).
build = BUILD
install = build/'OpenJPEG.build/Install'
if not (install/'lib/libopenjp2.a').is_file():
    print(f'note: no {CONFIGURATION} OpenJPEG install; only the requested isolated checks were performed')
else:
    installed = header_version(install/'include/OpenJPEG/opj_config.h')
    if installed != version:
        failures.append(f'the {CONFIGURATION} install is OpenJPEG {installed}, the pin is {version}')
    strings = subprocess.run(['strings', '-a', str(install/'lib/libopenjp2.a')],
        capture_output=True, text=True).stdout.split()
    if version not in strings:
        failures.append(f'libopenjp2.a does not carry the version string {version}')
    if not failures:
        print(f'PASS: {CONFIGURATION} install and libopenjp2.a name OpenJPEG {version}')

for failure in failures:
    print('FAIL:', failure)
raise SystemExit(1 if failures else 0)
