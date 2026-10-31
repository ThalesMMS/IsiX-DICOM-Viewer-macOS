#!/usr/bin/env python3
"""The dependency builds fail loudly, and the frameworks are what they claim.

Two things a build system must not do: reuse a Makefile from a configure step
that failed, and ship a framework built for another architecture. This checks
the first in the scripts and the second in the project: no prebuilt framework
from Binaries/ is copied into the bundle any more.

A third: an object must be rebuilt when a dependency it includes changes. The
installed dependency headers are searched with -isystem, and Xcode's -MMD
leaves system headers out of the .d files, so every configuration with
SYSTEM_HEADER_SEARCH_PATHS asks clang for them; with a build present,
the .d files of a VTK and an OpenJPEG consumer must list those headers.

The Debug and Release builds that go with this are recorded in
the dependency build scripts.
"""
from pathlib import Path
import json
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
scripts = root / 'Horos/Scripts'

# --- every dependency script stops at the first failure ----------------------
for script in sorted(set(scripts.glob('*/CMake.sh')) | set(scripts.glob('*/Make.sh')) |
                     set(scripts.glob('*/Config.sh'))):
    text = script.read_text(errors='replace')
    if not re.search(r'^\s*set -e', text, re.M):
        failures.append('%s does not stop at the first failure' % script.relative_to(root))

# --- and a configure that failed leaves no stamp to skip it next time --------
for script in sorted(scripts.glob('*/CMake.sh')):
    text = script.read_text(errors='replace')
    # Two spellings of the same idea live in this tree.
    stamp_name = next((n for n in ('.cmakehash', '.buildhash') if n in text), None)
    if stamp_name is None:
        failures.append('%s has no stamp, so it reconfigures every build or never'
                        % script.relative_to(root))
        continue
    # The stamp must be written after cmake runs, or a failed configure would be
    # remembered as a good one.
    configure = text.rfind('\ncmake "${args[@]}"')
    if configure < 0:
        configure = text.rfind('cmake ')
    stamp = text.rfind(stamp_name)
    read = text.find(stamp_name)
    if configure < 0 or stamp < configure:
        failures.append('%s writes its stamp before cmake runs' % script.relative_to(root))
    if read > configure:
        failures.append('%s does not check its stamp before configuring' % script.relative_to(root))

# OpenSSL has no CMake step; it marks its install directory instead.
openssl = (scripts / 'OpenSSL/Make.sh').read_text(errors='replace')
if '.incomplete' not in openssl:
    failures.append('the OpenSSL build has no marker, so an interrupted one looks finished')
else:
    touched = openssl.find('touch "$install_dir/.incomplete"')
    removed = openssl.find('rm -f "$install_dir/.incomplete"')
    if touched < 0 or removed < 0 or removed < touched:
        failures.append('the OpenSSL marker is not created before the build and removed after it')

# Exercise the actual Make guard without rebuilding OpenSSL. The fake make
# publishes only the requested installation products and records whether the
# incomplete marker protected both invocations. The Source stage stands for what
# Config.sh resolved: the record of the pinned archive and its read-only license,
# which Make.sh installs beside the libraries for the bundle and the release.
with tempfile.TemporaryDirectory() as directory:
    temporary = Path(directory)
    target = temporary / 'OpenSSL.build'
    install = target / 'Install'
    (target / 'Config').mkdir(parents=True)
    source_record = target / 'Source/share/source.json'
    source_license = target / 'Source/source/LICENSE.txt'
    source_record.parent.mkdir(parents=True)
    source_license.parent.mkdir(parents=True)
    source_record.write_text('{"name": "OpenSSL", "version": "selected"}\n')
    source_license.write_text('license of the selected archive\n')
    source_license.chmod(0o444)
    bin_dir = temporary / 'bin'
    bin_dir.mkdir()
    make = bin_dir / 'make'
    make.write_text('''#!/bin/sh
set -e
test -f "$TARGET_TEMP_DIR/Install/.incomplete"
echo "$*" >> "$TARGET_TEMP_DIR/calls"
[ "$1" = install_sw ] || exit 0
[ "$TEST_FAILED_INSTALL" != 1 ] || exit 0
mkdir -p "$TARGET_TEMP_DIR/Install/lib" "$TARGET_TEMP_DIR/Install/include/openssl"
for name in crypto ssl; do
    echo archive > "$TARGET_TEMP_DIR/Install/lib/lib$name.a"
done
for name in ssl crypto opensslv opensslconf configuration bio err x509; do
    echo header > "$TARGET_TEMP_DIR/Install/include/openssl/$name.h"
done
''')
    make.chmod(0o755)
    environment = dict(os.environ, TARGET_TEMP_DIR=str(target),
                       PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])

    def run_install():
        return subprocess.run(['/bin/bash', str(scripts / 'OpenSSL/Make.sh')],
                              env=environment, capture_output=True, text=True)

    def calls():
        log = target / 'calls'
        return log.read_text().splitlines() if log.exists() else []

    first = run_install()
    if first.returncode or len(calls()) != 2 or (install / '.incomplete').exists():
        failures.append('OpenSSL did not install and verify products with its marker: ' + first.stderr)
    installed_record = install / 'share/source.json'
    installed_license = install / 'share/licenses/OpenSSL/LICENSE.txt'
    if not (installed_record.is_file() and installed_record.read_bytes() == source_record.read_bytes()):
        failures.append('OpenSSL did not install the source record of its resolved Source stage')
    if not (installed_license.is_file() and installed_license.read_bytes() == source_license.read_bytes()):
        failures.append('OpenSSL did not install the license of its resolved Source stage')
    before = calls()
    cached = run_install()
    if cached.returncode or calls() != before:
        failures.append('OpenSSL did not reuse a complete installation')
    required = ['lib/libcrypto.a', 'lib/libssl.a'] + [
        'include/openssl/' + name + '.h'
        for name in ('ssl', 'crypto', 'opensslv', 'opensslconf', 'configuration', 'bio', 'err', 'x509')] + [
        'share/source.json', 'share/licenses/OpenSSL/LICENSE.txt']
    for product in required:
        for empty in (False, True):
            path = install / product
            if not path.exists():
                failures.append('OpenSSL did not install ' + product)
                break
            if empty:
                # The installed license keeps the read-only mode of the original.
                path.chmod(0o644)
                path.write_bytes(b'')
            else:
                path.unlink()
            before = len(calls())
            recovered = run_install()
            if recovered.returncode or len(calls()) != before + 2 or not path.is_file() or not path.stat().st_size:
                failures.append('OpenSSL reused a missing/empty product: ' + product)
    (install / '.incomplete').touch()
    before = len(calls())
    if run_install().returncode or len(calls()) != before + 2:
        failures.append('OpenSSL reused an installation with .incomplete')
    (install / 'lib/libssl.a').unlink()
    environment['TEST_FAILED_INSTALL'] = '1'
    failed = run_install()
    if failed.returncode == 0 or not (install / '.incomplete').exists():
        failures.append('OpenSSL marked a partial install successful')
    environment.pop('TEST_FAILED_INSTALL')
    if run_install().returncode or (install / '.incomplete').exists():
        failures.append('OpenSSL did not recover after a partial install')
    # Without the record of what Config.sh resolved, the libraries cannot be
    # attributed to a pinned source, so the installation must stay incomplete.
    installed_record.unlink(missing_ok=True)
    held_record = source_record.read_bytes()
    source_record.unlink()
    unrecorded = run_install()
    if unrecorded.returncode == 0 or not (install / '.incomplete').exists():
        failures.append('OpenSSL completed an installation without its resolved source record')
    source_record.write_bytes(held_record)
    if run_install().returncode or not installed_record.is_file() or installed_record.read_bytes() != held_record:
        failures.append('OpenSSL did not recover once its source record was resolved again')

# --- no private signing identity is baked into the project -------------------
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(errors='replace')

# Native sources come only from the archives external-sources.json pins: no
# build phase initializes, syncs or updates git submodules any more, and the
# repository tracks no submodule for them.
if re.search(r'git submodule|/\* Submodules \*/', project):
    failures.append('the project still acquires sources through git submodules')
gitlinks = [entry for entry in subprocess.run(['git', 'ls-files', '--stage', '-z'], cwd=root, check=True,
                                              capture_output=True).stdout.split(b'\0')
            if entry.startswith(b'160000 ')]
if gitlinks:
    failures.append('the repository still tracks submodules: %s' % gitlinks)
if (root / '.gitmodules').exists() and subprocess.run(['git', 'ls-files', '--error-unmatch', '.gitmodules'],
                                                       cwd=root, capture_output=True).returncode == 0:
    failures.append('the repository still declares submodules in .gitmodules')

# OpenSSL configures the original release archive that external-sources.json
# pins, resolved read-only into its own Source stage, never a repository
# checkout; generated files belong only to Config.
configure = (scripts / 'OpenSSL/Config.sh').read_text(errors='replace')
if 'source_dir="$(sh "$external_inputs" --source OpenSSL "$source_prefix"' not in configure:
    failures.append('the OpenSSL configure step does not resolve its pinned source archive')
if 'OpenSSL/upstream' in configure or '$PROJECT_DIR/$TARGET_NAME' in configure or 'git -C' in configure:
    failures.append('the OpenSSL configure step still reads the repository checkout')
if re.search(r'^\s*(ditto|cp|rsync)\b', configure, re.M):
    failures.append('the OpenSSL configure step still copies its source tree')
if configure.count('"$source_dir/Configure" "${configure_args[@]}"') != 2:
    failures.append('Debug and Release must configure the resolved source in the separate build directory')
if configure.rfind('echo "$hash"') < configure.rfind('if [ $configure_status -ne 0 ]'):
    failures.append('OpenSSL records its configure hash before checking Configure success')

# --- ITK builds the consumer roots, never the default test/I/O group ----------
itk_recipe = (scripts / 'ITK/CMake.sh').read_text()
for option in ('ITK_BUILD_DEFAULT_MODULES=OFF', 'ITKGroup_Core=OFF',
               'BUILD_TESTING=OFF', 'ITK_USE_64BITS_IDS=ON'):
    if 'args+=(-D%s)' % option not in itk_recipe:
        failures.append('ITK does not explicitly configure ' + option)

# Inspect generated configuration and installed payload when supplied by a build.
# A configure-only directory can also be checked without pretending it is an install.
itk_builds = [root / 'build/Intermediates.noindex/Horos.build' / configuration / 'ITK.build'
              for configuration in ('Debug', 'Release')]
explicit_itk_build = os.environ.get('HOROS_TEST_ITK_BUILD_DIR')
if explicit_itk_build:
    itk_builds.append(Path(explicit_itk_build))
    if not (Path(explicit_itk_build) / 'CMake/ITKConfig.cmake').is_file():
        failures.append('requested ITK build has no generated ITKConfig.cmake')
required_itk_modules = {'ITKCommon', 'ITKTransform', 'ITKRegionGrowing', 'ITKImageGrid',
                        'ITKNrrdIO', 'ITKVNL', 'ITKVNLInstantiation', 'ITKNetlib', 'ITKMetaIO'}
removed_itk_modules = {'ITKTestKernel', 'ITKIOGDCM', 'ITKGDCM', 'ITKGIFTI', 'ITKIOMeshGifti',
                       'ITKNIFTI', 'ITKIONIFTI', 'ITKIOPNG', 'ITKPNG', 'ITKIOJPEG', 'ITKJPEG',
                       'ITKIOTIFF', 'ITKTIFF', 'ITKOpenJPEG', 'ITKExpat'}
# The version comes from the declared original release, not from a tree here.
expected_itk_version = json.loads((scripts / 'external-sources.json').read_text())['ITK']['version'].split('.')
if (root / 'ITK').exists() or '--source ITK' not in itk_recipe or 'PROJECT_DIR/$TARGET_NAME' in itk_recipe:
    failures.append('ITK is not compiled from the acquired original release archive')
itk_configs_checked = itk_installs_checked = 0
for itk_build in dict.fromkeys(itk_builds):
    install = itk_build / 'Install'
    configs = [itk_build / 'CMake/ITKConfig.cmake', *install.glob('lib/cmake/ITK-*/ITKConfig.cmake')]
    for config in configs:
        if not config.is_file():
            continue
        itk_configs_checked += 1
        match = re.search(r'set\(ITK_MODULES_ENABLED "([^"]*)"\)', config.read_text())
        modules = set(match.group(1).split(';')) if match else set()
        if required_itk_modules - modules:
            failures.append('%s misses required ITK modules: %s' %
                            (config, sorted(required_itk_modules - modules)))
        if removed_itk_modules & modules or any(module.endswith('Test') for module in modules):
            failures.append('%s enables unused test/I/O modules: %s' %
                            (config, sorted(removed_itk_modules & modules)))
    cache = itk_build / 'CMake/CMakeCache.txt'
    if cache.is_file():
        cache_text = cache.read_text()
        for key, value in (('ITKGroup_Core', 'OFF'), ('ITK_USE_64BITS_IDS', 'ON')):
            if not re.search(r'^%s:[^=]+=%s$' % (key, value), cache_text, re.M):
                failures.append('%s does not configure %s=%s' % (cache, key, value))
    for header in (itk_build / 'CMake/Modules/Core/Common/itkConfigure.h',
                   install / 'include/itkConfigure.h'):
        if not header.is_file():
            continue
        header_text = header.read_text()
        version = [re.search(r'^#define ITK_VERSION_%s (\d+)$' % part, header_text, re.M)
                   for part in ('MAJOR', 'MINOR', 'PATCH')]
        if not all(version) or [match.group(1) for match in version] != expected_itk_version:
            failures.append('%s does not match the source ITK version' % header)
        if not re.search(r'^#define ITK_USE_64BITS_IDS\b', header_text, re.M):
            failures.append('%s does not use 64-bit IDs' % header)
    if not (install / 'lib').is_dir():
        continue
    itk_installs_checked += 1
    # Inspect the installed headers/archives too: an old payload cannot pass
    # merely because the newly generated CMake module list is correct.
    forbidden_payload = re.compile(r'gdcm|gifti|charls|openjpeg|nifti|testkernel', re.I)
    for path in [*install.rglob('*.a'), *install.rglob('*.h'), *install.rglob('*.hxx')]:
        if forbidden_payload.search(path.name):
            failures.append('unused ITK payload remains installed: %s' % path)
    for library in ('ITKCommon', 'ITKNrrdIO', 'ITKMetaIO', 'itkvnl', 'itkNetlibSlatec'):
        if not list((install / 'lib').glob('lib%s-*.a' % library)):
            failures.append('%s lacks the required %s archive' % (install, library))
    configured = install / 'include/itkConfigure.h'
    if not configured.is_file() or not re.search(r'^#define ITK_USE_64BITS_IDS\b',
                                                configured.read_text(), re.M):
        failures.append('%s lacks the installed 64-bit-ID contract' % install)
print('ITK inventory: %d generated/installed module lists, %d installs checked' %
      (itk_configs_checked, itk_installs_checked))

# --- no private signing identity is baked into the project -------------------
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(errors='replace')
itk_target = re.search(r'/\* ITK \*/ = \{\n\t+isa = PBXAggregateTarget;(.*?)\n\t\t\};',
                       project, re.S)
if not itk_target:
    failures.append('the ITK aggregate target is missing')
else:
    dependencies = re.search(r'dependencies = \((.*?)\);', itk_target.group(1), re.S)
    ids = re.findall(r'(\w+) /\* PBXTargetDependency \*/', dependencies.group(1)) if dependencies else []
    for identifier in ids:
        target_dependency = re.search(identifier + r' /\* PBXTargetDependency \*/ = \{(.*?)\n\t\t\};',
                                      project, re.S)
        if target_dependency and re.search(r'target = .* /\* (GDCM|OpenJPEG) \*/;',
                                           target_dependency.group(1)):
            failures.append('ITK still requires a host codec target it does not consume')
teams = set(re.findall(r'DEVELOPMENT_TEAM = ([^;]+);', project))
for team in teams:
    if '$(' not in team and team.strip('" ') not in ('', '-'):
        failures.append('a development team is baked into the project: %s' % team)
identities = set(re.findall(r'CODE_SIGN_IDENTITY[^=]*= ([^;]+);', project))
for identity in identities:
    value = identity.strip('" ')
    if value not in ('', '-', 'Apple Development', 'Mac Developer') and '$(' not in identity:
        failures.append('a signing identity is baked into the project: %s' % identity)

# --- no prebuilt framework ships with the application -----------------------
# 3DconnexionClient (x86_64, i386) and homephone (x86_64) used to be unpacked
# from Binaries/ and copied into the arm64 bundle, where they could never load.
# Every framework in the bundle is now built by a target of this project.
prebuilt = sorted(set(re.findall(r'path = "?(Binaries/[^;"]*\.framework)"?;', project)))
if prebuilt:
    failures.append('the project refers to prebuilt frameworks in Binaries/: %s' % ', '.join(prebuilt))
unzip = (scripts / 'Horos/Unzip.sh').read_text(errors='replace')
unpacked = re.findall(r'^\s*unzip\b.*\.framework\.zip', unzip, re.M)
if unpacked:
    failures.append('Horos/Scripts/Horos/Unzip.sh unpacks prebuilt frameworks: %s' % unpacked)

# --- objects depend on the dependency headers they include -----------
xcconfig = (root / 'Horos/Horos.xcconfig').read_text(errors='replace')
if not re.search(r'^HOROS_SYSTEM_HEADER_DEPENDENCIES = -Xclang -sys-header-deps$', xcconfig, re.M):
    failures.append('Horos.xcconfig does not ask clang for system headers in the .d files')
configurations = re.findall(r'/\* (\w+) configuration for PBXNativeTarget "([^"]+)" \*/ = \{(.*?)\n\t\t\};',
                            project, re.S)
tracked = 0
for name, target, body in configurations:
    if 'SYSTEM_HEADER_SEARCH_PATHS' not in body:
        continue
    tracked += 1
    flags = re.search(r'\n\t\t\t\tOTHER_CFLAGS = ([^;]+);', body)
    cxx = re.search(r'\n\t\t\t\tOTHER_CPLUSPLUSFLAGS = ([^;]+);', body)
    if not flags or '$(HOROS_SYSTEM_HEADER_DEPENDENCIES)' not in flags.group(1):
        failures.append('%s %s searches -isystem paths without putting them in the .d files'
                        % (target, name))
    if cxx and '$(OTHER_CFLAGS)' not in cxx.group(1) and \
            '$(HOROS_SYSTEM_HEADER_DEPENDENCIES)' not in cxx.group(1):
        failures.append('%s %s compiles C++ without the system header dependencies' % (target, name))
if tracked < 4:
    failures.append('expected the Horos and Decompress configurations with SYSTEM_HEADER_SEARCH_PATHS, '
                    'found %d' % tracked)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD  # noqa: E402
consumers = {
    BUILD / 'Horos.build/Objects-normal/arm64/SceneFactory.d': 'VTK.build/Install/include/vtkAutoInit.h',
    BUILD / 'Horos.build/Objects-normal/arm64/HorosJPEG2000Codec.d': 'OpenJPEG.build/Install/include/OpenJPEG/openjpeg.h',
    BUILD / 'Decompress.build/Objects-normal/arm64/HorosJPEG2000Codec.d':
        'OpenJPEG.build/Install/include/OpenJPEG/openjpeg.h',
}
checked = 0
for depfile, header in consumers.items():
    if not depfile.is_file():
        continue
    checked += 1
    listed = depfile.read_text(errors='replace')
    paths = (header, header.replace('/include/', '/include/vtk-9.7/')) if 'VTK.build/' in header else (header,)
    if not any(path in listed for path in paths):
        failures.append('%s does not list %s; rebuild after the flag change'
                        % (depfile.relative_to(BUILD), header))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: every dependency script stops at the first failure and cannot remember a configure '
      'that did not finish, no signing identity is baked in, no prebuilt framework is '
      'copied into the bundle, and the %d configurations with -isystem dependency headers put them '
      'in the .d files (%d of %d consumer .d files of a build checked)' % (tracked, checked, len(consumers)))
