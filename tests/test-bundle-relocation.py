#!/usr/bin/env python3
"""The bundle carries the current external libraries it loads, and the audit says so.

Horos/Scripts/Horos/embed-external-inputs.py copies into Contents/Frameworks
the staged external libraries the bundle's binaries load, with their own
dependencies, and points the binaries at the copies; tools/audit-release-bundle.py
resolves every load command of a bundle and, with --strict, refuses one that
loads from outside itself and the macOS. This checks, without the network and
without Xcode's build:

- the phase, run with an Xcode-like environment on a small bundle whose
  executable links a staged library by absolute path (which loads another by
  @rpath, with an LC_RPATH of Homebrew), embeds exactly the two, renames them,
  drops the rpath, rewrites the executable, records the bottles and copies
  their licenses, leaves an unused staged library out, and does nothing more
  on a second run;
- changed input content, even with an equal or older timestamp, and rollbacks
  replace the signed copy; renamed ABIs and removed pins clean only managed
  libraries and notices; failed preparation leaves the previous bundle intact;
- the audit passes that bundle once signed, and refuses a library by absolute
  path outside the bundle, a missing library, an outside LC_RPATH and a binary
  without arm64;
- the phase is wired into the application target, after the other copies and
  before CodeSigning, and script/build_release.sh audits before replacing its
  output;
- DCMTK is configured with its oficonv tables built in and OpenSSL with the
  system's configuration directory, so neither reads data from the build
  directory at run time;
- the Debug and Release products, when present, load nothing from outside
  themselves, carry that OPENSSLDIR, and the signed build/Release/Isis DICOM Viewer.app
  passes the strict audit.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import json
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
embed_script = root / 'Horos/Scripts/Horos/embed-external-inputs.py'
auditor = root / 'tools/audit-release-bundle.py'
failures = []


def report(ok, message):
    if not ok:
        failures.append(message)


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun clang to make the test binaries', file=sys.stderr)
    sys.exit(2)


sources = Path(tempfile.mkdtemp(prefix='sources-'))


def compile_dylib(output, install_name, link=(), extra=(), arch='arm64', value=1):
    source = sources / (output.name + '.c')
    source.write_text('int %s_value(void) { return %s; }\n' % (re.sub(r'\W', '_', output.stem), value))
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-arch', arch, '-mmacosx-version-min=26.0',
                    '-Wl,-headerpad_max_install_names', '-install_name', install_name,
                    str(source), '-o', str(output)] + list(link) + list(extra),
                   check=True, capture_output=True)
    return output


def compile_executable(output, link=(), extra=(), arch='arm64'):
    source = sources / (output.name + '.exe.c')
    source.write_text('int main(void) { return 0; }\n')
    subprocess.run(['xcrun', 'clang', '-arch', arch, '-mmacosx-version-min=26.0',
                    '-Wl,-headerpad_max_install_names', str(source), '-o', str(output)]
                   + list(link) + list(extra), check=True, capture_output=True)
    return output


def make_bundle(folder, name='Test'):
    app = folder / (name + '.app')
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/Frameworks').mkdir()
    (app / 'Contents/Resources').mkdir()
    (app / 'Contents/Info.plist').write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        '<key>CFBundleExecutable</key><string>%s</string>'
        '<key>CFBundleIdentifier</key><string>test.%s</string>'
        '<key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n' % (name, name.lower()))
    return app


def audit(app, strict=True):
    result = subprocess.run([sys.executable, str(auditor), str(app)] + (['--strict'] if strict else []),
                            capture_output=True, text=True)
    try:
        data = json.loads(result.stdout)
    except ValueError:
        data = {}
    return result.returncode, data, result.stderr


def load_commands(path):
    return subprocess.run(['otool', '-l', str(path)], capture_output=True, text=True).stdout


with tempfile.TemporaryDirectory() as directory:
    temporary = Path(directory).resolve()
    work = temporary / 'work'
    work.mkdir()

    # --- a staged prefix as external-inputs.sh leaves it -------------------------
    temp_dir = temporary / 'Intermediates/Horos.build/Debug'
    prefix = temp_dir / 'ExternalInputs.build/Install'
    lib = prefix / 'lib'
    lib.mkdir(parents=True)
    downloads = temporary / 'Intermediates/Horos.build/ExternalInputs.downloads'
    downloads.mkdir(parents=True)
    zed = compile_dylib(lib / 'libzed.2.dylib', str(lib / 'libzed.2.dylib'))
    # A companion referred to by @rpath, as libwebp refers to libsharpyuv.
    compile_dylib(lib / 'libqux.1.dylib', '@rpath/libqux.1.dylib')
    compile_dylib(lib / 'libtop.1.dylib', str(lib / 'libtop.1.dylib'),
                  link=[str(zed), str(lib / 'libqux.1.dylib')],
                  extra=['-Wl,-rpath,@@HOMEBREW_CELLAR@@/top/1.0/lib'])
    compile_dylib(lib / 'libunused.1.dylib', str(lib / 'libunused.1.dylib'))
    os.symlink('libtop.1.dylib', lib / 'libtop.dylib')
    (prefix / '.resolved').write_text('stamp\n')
    (prefix / 'share/licenses').mkdir(parents=True)
    records = []
    for name, files in (('top', ['libtop.1.dylib', 'libtop.dylib']), ('zed', ['libzed.2.dylib']),
                        ('qux', ['libqux.1.dylib']), ('unused', ['libunused.1.dylib'])):
        keg = work / 'kegs' / name / '1.0'
        (keg / 'lib').mkdir(parents=True)
        for file in files:
            (keg / 'lib' / file).write_bytes(b'x')
        archive = downloads / ('%s--1.0.arm64_tahoe.bottle.tar.gz' % name)
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(work / 'kegs' / name, arcname=name)
        (prefix / 'share/licenses' / name).mkdir()
        (prefix / 'share/licenses' / name / 'LICENSE').write_text('license of %s\n' % name)
        records.append('%s 1.0 arm64_tahoe %s %s' % (name, '0' * 64, 'link' if name == 'top' else 'runtime'))
    (prefix / 'share/external-inputs.txt').write_text('\n'.join(records) + '\n')
    source_pin = (root / 'Horos/Scripts/external-sources.json').read_text()
    import json
    compiled_install = temp_dir / 'OpenJPEG.build/Install/share'
    (compiled_install / 'licenses/OpenJPEG').mkdir(parents=True)
    (compiled_install / 'source.json').write_text(json.dumps(json.loads(source_pin)['OpenJPEG']))
    shutil.copyfile(root / 'Binaries/Splash/ThirdParty/Native/OpenJPEG/LICENSE',
                    compiled_install / 'licenses/OpenJPEG/LICENSE')
    vtk_install = temp_dir / 'VTK.build/Install'
    (vtk_install/'share').mkdir(parents=True)
    (vtk_install/'lib').mkdir()
    vtk_module = vtk_install/'lib/libvtkfreetype-9.7.a'
    vtk_module.write_bytes(b'synthetic module identity for bundle transaction\n')
    (vtk_install/'wlib').mkdir()
    vtk_aggregate = vtk_install/'wlib/libVTK.a'
    vtk_aggregate.write_bytes(b'synthetic aggregate identity for bundle transaction\n')
    vtk_pin = json.loads(source_pin)['VTK']
    (vtk_install/'share/source.json').write_text(json.dumps(vtk_pin))
    (vtk_install/'share/licenses/VTK').mkdir(parents=True)
    shutil.copyfile(root/'Binaries/Splash/ThirdParty/Native/VTK/Copyright.txt',
                    vtk_install/'share/licenses/VTK/Copyright.txt')
    vtk_record = vtk_install/'share/freetype-host-adaptation.json'
    vtk_record.write_text(json.dumps({'archive':vtk_module.name,
        'source':{'sourceVersion':vtk_pin['version'],'archiveSha256':vtk_pin['sha256']},
        'publicSymbol':'_vtkfreetype_FT_MulFix',
        'installedArchiveSha256':hashlib.sha256(vtk_module.read_bytes()).hexdigest(),
        'aggregateSha256':hashlib.sha256(vtk_aggregate.read_bytes()).hexdigest()}))

    # --- a bundle whose executable links the staged library by absolute path -----
    products = temporary / 'Products/Debug'
    products.mkdir(parents=True)
    app = make_bundle(products)
    executable = compile_executable(app / 'Contents/MacOS/Test', link=[str(lib / 'libtop.1.dylib')],
                                    extra=['-Wl,-rpath,@executable_path/../Frameworks'])
    helper = compile_executable(app / 'Contents/Resources/helper')
    environment = dict(os.environ, TARGET_BUILD_DIR=str(products), CONTENTS_FOLDER_PATH='Test.app/Contents',
                       FRAMEWORKS_FOLDER_PATH='Test.app/Contents/Frameworks',
                       UNLOCALIZED_RESOURCES_FOLDER_PATH='Test.app/Contents/Resources',
                       CONFIGURATION_TEMP_DIR=str(temp_dir),
                       PROJECT_TEMP_DIR=str(temp_dir.parent), CODE_SIGNING_ALLOWED='NO')
    result = subprocess.run([sys.executable, str(embed_script)], env=environment, capture_output=True, text=True)
    report(result.returncode == 0, 'the embed phase failed: %s' % result.stderr.strip())
    compiled_bundle = app / 'Contents/Resources/CompiledSources/OpenJPEG'
    vtk_bundle = app / 'Contents/Resources/CompiledSources/VTK/freetype-host-adaptation.json'
    report(vtk_bundle.is_file() and vtk_bundle.read_bytes() == vtk_record.read_bytes(),
           'VTK host adaptation record did not reach the bundle')
    report((compiled_bundle / 'source.json').is_file() and
           (compiled_bundle / 'source.json').read_bytes() == (compiled_install / 'source.json').read_bytes(),
           'compiled source record did not reach the bundle')
    report((compiled_bundle / 'LICENSE').is_file() and
           (compiled_bundle / 'LICENSE').read_bytes() == (compiled_install / 'licenses/OpenJPEG/LICENSE').read_bytes(),
           'compiled source license did not reach the bundle')
    vtk_resources = app / 'Contents/Resources/CompiledSources/VTK'
    report((vtk_resources/'source.json').read_bytes() == (vtk_install/'share/source.json').read_bytes() and
           (vtk_resources/'Copyright.txt').read_bytes() == (vtk_install/'share/licenses/VTK/Copyright.txt').read_bytes(),
           'VTK original source/license did not reach the bundle transaction')
    frameworks = app / 'Contents/Frameworks'
    embedded = sorted(p.name for p in frameworks.glob('*.dylib'))
    report(embedded == ['libqux.1.dylib', 'libtop.1.dylib', 'libzed.2.dylib'],
           'embedded %s, not the three libraries the executable loads' % embedded)
    linked = load_commands(executable)
    report('@loader_path/../Frameworks/libtop.1.dylib' in linked and str(lib) not in linked,
           'the executable still loads from the staged prefix')
    top = load_commands(frameworks / 'libtop.1.dylib')
    report('@rpath/libtop.1.dylib' in top, 'the embedded library was not renamed @rpath/')
    report('@loader_path/libzed.2.dylib' in top and '@loader_path/libqux.1.dylib' in top,
           'the embedded library does not load its companions beside it')
    report('LC_RPATH' not in top, 'the embedded library kept an LC_RPATH')
    record = (app / 'Contents/Resources/ExternalLibraries/embedded-libraries.txt').read_text() \
        if (app / 'Contents/Resources/ExternalLibraries/embedded-libraries.txt').exists() else ''
    report('top 1.0 arm64_tahoe' in record and 'libtop.1.dylib' in record and 'unused' not in record,
           'the record of embedded bottles is wrong: %r' % record)
    report((app / 'Contents/Resources/ExternalLibraries/qux/LICENSE').is_file()
           and not (app / 'Contents/Resources/ExternalLibraries/unused').exists(),
           'the licenses copied are not those of the embedded bottles')
    for library in embedded:
        report(subprocess.run(['codesign', '-v', str(frameworks / library)], capture_output=True).returncode == 0,
               '%s is not validly signed' % library)
    signature = subprocess.run(['codesign', '-v', str(executable)], capture_output=True, text=True)
    report(signature.returncode == 0,
           'the rewritten executable is not validly signed: %s' % signature.stderr.strip())
    report(subprocess.run([str(executable)], capture_output=True).returncode == 0,
           'the rewritten executable does not run with its embedded libraries')

    stamp = (frameworks / 'libtop.1.dylib').stat().st_mtime_ns, executable.stat().st_mtime_ns
    again = subprocess.run([sys.executable, str(embed_script)], env=environment, capture_output=True, text=True)
    report(again.returncode == 0, 'a second run failed: %s' % again.stderr.strip())
    report(((frameworks / 'libtop.1.dylib').stat().st_mtime_ns, executable.stat().st_mtime_ns) == stamp,
           'a second run changed a bundle that was already done')

    def embed_again():
        return subprocess.run([sys.executable, str(embed_script)], env=environment,
                              capture_output=True, text=True)

    def fingerprint(folder):
        return {str(path.relative_to(folder)): (hashlib.sha256(path.read_bytes()).hexdigest(),
                                                path.stat().st_mtime_ns)
                for path in folder.rglob('*') if path.is_file()}

    preserved_bundle = fingerprint(app)
    original_record = vtk_record.read_bytes()
    mismatched = json.loads(original_record)
    mismatched['aggregateSha256'] = 'f' * 64
    vtk_record.write_text(json.dumps(mismatched))
    rejected = embed_again()
    report(rejected.returncode != 0 and 'VTK aggregate differs' in rejected.stderr and
           fingerprint(app) == preserved_bundle,
           'a divergent VTK aggregate record changed the bundle/resources/signature')
    vtk_record.write_bytes(original_record)
    original_aggregate = vtk_aggregate.read_bytes()
    vtk_aggregate.write_bytes(original_aggregate+b'altered\n')
    rejected = embed_again()
    report(rejected.returncode != 0 and 'VTK aggregate differs' in rejected.stderr and
           fingerprint(app) == preserved_bundle,
           'a modified VTK aggregate changed the bundle/resources/signature')
    vtk_aggregate.write_bytes(original_aggregate)

    source_record = vtk_install/'share/source.json'
    original_source_record = source_record.read_bytes()
    wrong_source = json.loads(original_source_record)
    wrong_source['sha256'] = 'f'*64
    source_record.write_text(json.dumps(wrong_source))
    rejected = embed_again()
    report(rejected.returncode != 0 and 'original source/license differs' in rejected.stderr and
           fingerprint(app) == preserved_bundle, 'a divergent VTK source changed the bundle transaction')
    source_record.write_bytes(original_source_record)
    copyright_file = vtk_install/'share/licenses/VTK/Copyright.txt'
    original_copyright = copyright_file.read_bytes()
    copyright_file.write_bytes(original_copyright+b'changed\n')
    rejected = embed_again()
    report(rejected.returncode != 0 and 'original source/license differs' in rejected.stderr and
           fingerprint(app) == preserved_bundle, 'a changed VTK copyright altered bundle resources/signatures')
    copyright_file.write_bytes(original_copyright)

    notices = app / 'Contents/Resources/ExternalLibraries'
    manifest_path = notices / 'embedded-identities.json'

    def check_input(library, expected_value):
        embedded_path = frameworks / library.name
        function = re.sub(r'\W', '_', library.stem) + '_value'
        probe = subprocess.run([sys.executable, '-c',
                                'import ctypes, sys; print(getattr(ctypes.CDLL(sys.argv[1]), '
                                'sys.argv[2])())', str(embedded_path), function],
                               capture_output=True, text=True)
        report(probe.returncode == 0 and probe.stdout.strip() == str(expected_value),
               'the embedded %s does not execute the current input (%s): %s' %
               (library.name, expected_value, probe.stderr.strip()))
        entry = json.loads(manifest_path.read_text())['libraries'][library.name]
        report(entry['sourceSha256'] == hashlib.sha256(library.read_bytes()).hexdigest()
               and entry['embeddedSha256'] == hashlib.sha256(embedded_path.read_bytes()).hexdigest(),
               'the identity record does not match the input and signed output')
        report(subprocess.run(['codesign', '-v', str(embedded_path)], capture_output=True).returncode == 0,
               'the updated library is not validly signed')

    original_zed = zed.read_bytes()
    original_time = zed.stat().st_mtime_ns
    for value, timestamp in ((2, original_time), (3, original_time - 10_000_000_000)):
        compile_dylib(zed, str(zed), value=value)
        os.utime(zed, ns=(timestamp, timestamp))
        replacement = embed_again()
        report(replacement.returncode == 0, 'replacement failed: %s' % replacement.stderr.strip())
        check_input(zed, value)
        stable = fingerprint(app)
        unchanged = embed_again()
        report(unchanged.returncode == 0 and fingerprint(app) == stable,
               'an unchanged input rewrote bundle bytes or timestamps')
    zed.write_bytes(original_zed)
    os.utime(zed, ns=(original_time - 20_000_000_000, original_time - 20_000_000_000))
    rolled_back = embed_again()
    report(rolled_back.returncode == 0, 'input rollback failed: %s' % rolled_back.stderr.strip())
    check_input(zed, 1)

    # A damaged output is not reusable just because the source has not changed.
    damaged = frameworks / zed.name
    damaged.write_bytes(b'damaged embedded copy')
    repaired = embed_again()
    report(repaired.returncode == 0, 'damaged output was not repaired: %s' % repaired.stderr.strip())
    check_input(zed, 1)

    # A legacy record establishes ownership but has no content identity yet.
    manifest_path.unlink()
    legacy = embed_again()
    report(legacy.returncode == 0 and manifest_path.is_file(),
           'the legacy bottle record did not migrate to content identities')
    check_input(zed, 1)

    # Late preparation failures must not publish changed code or partial notices.
    compile_dylib(zed, str(zed), value=4)
    before_failure = fingerprint(app)
    license_path = prefix / 'share/licenses/zed/LICENSE'
    license_text = license_path.read_text()
    license_path.unlink()
    failed = embed_again()
    report(failed.returncode != 0 and 'no license text' in failed.stderr
           and fingerprint(app) == before_failure,
           'missing license did not preserve the previous artifact')
    license_path.write_text(license_text)
    archive_path = downloads / 'zed--1.0.arm64_tahoe.bottle.tar.gz'
    archive_path.rename(archive_path.with_suffix('.hidden'))
    failed = embed_again()
    report(failed.returncode != 0 and 'verified bottle' in failed.stderr
           and fingerprint(app) == before_failure,
           'missing bottle did not preserve the previous artifact')
    archive_path.with_suffix('.hidden').rename(archive_path)
    zed.write_bytes(b'not a valid Mach-O library')
    failed = embed_again()
    report(failed.returncode != 0 and 'not Mach-O' in failed.stderr
           and fingerprint(app) == before_failure,
           'invalid input did not preserve the previous artifact')
    zed.write_bytes(original_zed)

    # Exercise failure after publication: a main-executable signing failure must
    # restore its bytes, companion libraries, notices and resource seals.
    compile_executable(executable, link=[str(lib / 'libtop.1.dylib')],
                       extra=['-Wl,-rpath,@executable_path/../Frameworks'])
    before_failure = fingerprint(app)
    updated_source = json.loads((compiled_install / 'source.json').read_text())
    updated_source['revision'] = '1' * 40
    (compiled_install / 'source.json').write_text(json.dumps(updated_source))
    updated_vtk = json.loads(vtk_record.read_text())
    updated_vtk['configuration'] = 'updated synthetic provenance'
    vtk_record.write_text(json.dumps(updated_vtk))
    injected = (
        'import os, runpy, subprocess, sys; original = subprocess.run\n'
        'def run(command, *args, **kwargs):\n'
        '    if command[0] == "/usr/bin/codesign" and command[-1] == os.environ["FAIL_SIGN_PATH"]:\n'
        '        signed = original(command, *args, **kwargs)\n'
        '        if signed.returncode: return signed\n'
        '        return subprocess.CompletedProcess(command, 1, "", "injected signing failure")\n'
        '    return original(command, *args, **kwargs)\n'
        'subprocess.run = run; runpy.run_path(sys.argv[1], run_name="__main__")\n')
    failed = subprocess.run([sys.executable, '-c', injected, str(embed_script)],
                            env=dict(environment, FAIL_SIGN_PATH=str(executable)),
                            capture_output=True, text=True)
    report(failed.returncode != 0 and 'injected signing failure' in failed.stderr
           and fingerprint(app) == before_failure,
           'failed signing did not roll back published bundle files and seals')
    recovered = embed_again()
    report(recovered.returncode == 0, 'embedding did not recover after failure: %s' % recovered.stderr.strip())
    report((compiled_bundle / 'source.json').read_bytes() == (compiled_install / 'source.json').read_bytes(),
           'recovery did not publish the current static source record')
    report(vtk_bundle.read_bytes() == vtk_record.read_bytes(), 'recovery did not publish VTK adaptation metadata')

    # ABI rename + pin removal: managed files disappear even from the staged
    # prefix. A separate dylib and notice in the same directories remain intact.
    unmanaged = compile_dylib(frameworks / 'libforeign.1.dylib', '@rpath/libforeign.1.dylib')
    subprocess.run(['codesign', '--force', '--sign', '-', str(unmanaged)], check=True, capture_output=True)
    (notices / 'Unrelated').mkdir()
    (notices / 'Unrelated/LICENSE').write_text('unmanaged notice\n')
    foreign_before = fingerprint(notices / 'Unrelated'), unmanaged.read_bytes(), unmanaged.stat().st_mtime_ns
    saved_executable = executable.read_bytes()
    collision = compile_dylib(lib / unmanaged.name, str(lib / unmanaged.name))
    compile_executable(executable, link=[str(collision)])
    before_collision = fingerprint(app)
    refused_collision = embed_again()
    report(refused_collision.returncode != 0 and 'unmanaged library' in refused_collision.stderr
           and fingerprint(app) == before_collision,
           'an input basename collision overwrote unmanaged bundle code')
    collision.unlink()
    executable.write_bytes(saved_executable)
    new_qux = compile_dylib(lib / 'libqux.2.dylib', '@rpath/libqux.2.dylib', value=5)
    compile_dylib(lib / 'libtop.1.dylib', str(lib / 'libtop.1.dylib'), link=[str(new_qux)])
    (lib / 'libqux.1.dylib').unlink()
    zed.unlink()
    keg = work / 'kegs/qux/2.0/lib'
    keg.mkdir(parents=True)
    (keg / new_qux.name).write_bytes(b'x')
    with tarfile.open(downloads / 'qux--2.0.arm64_tahoe.bottle.tar.gz', 'w:gz') as tar:
        tar.add(keg.parent.parent, arcname='qux')
    new_records = [line for line in records if not line.startswith(('zed ', 'qux '))]
    new_records.append('qux 2.0 arm64_tahoe %s runtime' % ('1' * 64))
    (prefix / 'share/external-inputs.txt').write_text('\n'.join(new_records) + '\n')
    (prefix / 'share/licenses/qux/LICENSE').write_text('license of qux 2.0\n')
    renamed = embed_again()
    report(renamed.returncode == 0, 'ABI rename failed: %s' % renamed.stderr.strip())
    report(not (frameworks / 'libqux.1.dylib').exists() and not (frameworks / 'libzed.2.dylib').exists(),
           'removed staged pins/ABI names left orphaned managed libraries')
    new_record = (notices / 'embedded-libraries.txt').read_text()
    report('qux 2.0' in new_record and 'libqux.2.dylib' in new_record
           and 'libqux.1.dylib' not in new_record and 'zed' not in new_record
           and not (notices / 'zed').exists()
           and (notices / 'qux/LICENSE').read_text() == 'license of qux 2.0\n',
           'updated closure retained incorrect bottle records or notices')
    report((fingerprint(notices / 'Unrelated'), unmanaged.read_bytes(), unmanaged.stat().st_mtime_ns) == foreign_before,
           'cleanup touched an unmanaged library or notice')
    check_input(new_qux, 5)
    stable = fingerprint(app)
    unchanged = embed_again()
    report(unchanged.returncode == 0 and fingerprint(app) == stable,
           'renamed closure is not idempotent')
    new_qux.rename(new_qux.with_suffix('.hidden'))
    missing_input = embed_again()
    report(missing_input.returncode != 0 and 'no longer staged' in missing_input.stderr
           and fingerprint(app) == stable,
           'a still-loaded removed input was silently kept or removed from the bundle')
    new_qux.with_suffix('.hidden').rename(new_qux)

    # No pins remain needed: retain unrelated resources and an empty ownership
    # record, without keeping managed dylibs or their licenses.
    compile_executable(executable)
    removed = embed_again()
    report(removed.returncode == 0, 'removing all pins failed: %s' % removed.stderr.strip())
    report(sorted(path.name for path in frameworks.glob('*.dylib')) == [unmanaged.name]
           and not (notices / 'qux').exists() and not (notices / 'top').exists()
           and json.loads(manifest_path.read_text())['libraries'] == {},
           'empty closure left managed code or notices behind')
    report((fingerprint(notices / 'Unrelated'), unmanaged.read_bytes(), unmanaged.stat().st_mtime_ns) == foreign_before,
           'empty closure removed unmanaged files')

    # Restore a two-library closure to exercise the relocated final bundle.
    compile_executable(executable, link=[str(lib / 'libtop.1.dylib')],
                       extra=['-Wl,-rpath,@executable_path/../Frameworks'])
    restored = embed_again()
    report(restored.returncode == 0, 'restoring closure failed: %s' % restored.stderr.strip())
    unmanaged.unlink()

    # The staged prefix goes away: the bundle still runs, and it passes the audit.
    moved = temporary / 'elsewhere'
    moved.mkdir()
    shutil.move(str(app), str(moved / 'Test.app'))
    shutil.move(str(prefix), str(temporary / 'hidden-prefix'))
    app = moved / 'Test.app'
    report(subprocess.run([str(app / 'Contents/MacOS/Test')], capture_output=True).returncode == 0,
           'the moved bundle does not run without the staged prefix')
    signed = subprocess.run(['codesign', '--force', '--sign', '-', str(app)], capture_output=True, text=True)
    report(signed.returncode == 0, 'the embedded bundle could not be signed: %s' % signed.stderr.strip())
    status, data, stderr = audit(app)
    report(status == 0, 'the audit refused a self-contained bundle: %s' % stderr.strip())
    report(data.get('embeddedLibraries') == ['Contents/Frameworks/libqux.2.dylib',
                                             'Contents/Frameworks/libtop.1.dylib'],
           'the audit lists %s as embedded' % data.get('embeddedLibraries'))

    # --- what the audit must refuse -------------------------------------------------
    outside = compile_dylib(work / 'libout.1.dylib', str(work / 'libout.1.dylib'))

    def refused(name, build, expected):
        bundle = make_bundle(temporary / name, 'Bad')
        build(bundle)
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(bundle)], capture_output=True)
        code, _, err = audit(bundle)
        report(code != 0 and expected in err, '%s was not refused (%s): %s' % (name, expected, err.strip()))

    (temporary / 'external').mkdir()
    refused('external', lambda b: compile_executable(b / 'Contents/MacOS/Bad', link=[str(outside)]),
            'from outside the bundle')
    (temporary / 'missing').mkdir()

    def missing(bundle):
        compile_dylib(work / 'libgone.1.dylib', '@loader_path/../Frameworks/libgone.1.dylib')
        compile_executable(bundle / 'Contents/MacOS/Bad', link=[str(work / 'libgone.1.dylib')])
    refused('missing', missing, 'nowhere in the bundle')
    (temporary / 'rpath').mkdir()
    refused('rpath', lambda b: compile_executable(b / 'Contents/MacOS/Bad', extra=['-Wl,-rpath,/opt/homebrew/lib']),
            'outside the bundle')
    (temporary / 'intel').mkdir()

    def intel(bundle):
        compile_executable(bundle / 'Contents/MacOS/Bad')
        compile_dylib(bundle / 'Contents/Frameworks/libintel.dylib', '@rpath/libintel.dylib', arch='x86_64')
    refused('intel', intel, 'has no arm64')

# --- the wiring ------------------------------------------------------------------------
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
target = re.search(r'/\* Horos \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?buildPhases = \((.*?)\);', project, re.S)
phases = re.findall(r'/\* (.+?) \*/', target.group(1)) if target else []
report('Embed External Libraries' in phases, 'the application target has no Embed External Libraries phase')
if 'Embed External Libraries' in phases:
    position = phases.index('Embed External Libraries')
    for earlier in ('Frameworks', 'Copy Frameworks', 'Copy Executables', 'Copy Embedded Plugins'):
        report(earlier in phases and phases.index(earlier) < position,
               'the embed phase runs before %s' % earlier)
    report(phases.index('CodeSigning') > position, 'the embed phase runs after CodeSigning')
phase = re.search(r'/\* Embed External Libraries \*/ = \{(.*?)\n\t\t\};', project, re.S)
report(phase is not None and 'embed-external-inputs.py' in phase.group(1)
       and 'alwaysOutOfDate = 1' in phase.group(1),
       'the embed phase does not run the script on every build')
release = (root / 'script/build_release.sh').read_text()
strict_audit = re.search(r'audit-release-bundle\.py[^\n]*--strict[^\n]*--notices', release)
report(strict_audit is not None and strict_audit.start() < release.find('ITEMS=("$APP_NAME.app"'),
       'script/build_release.sh does not audit the package before replacing its output')
report('--deep --sign' not in release and 'FinderPreview.entitlements' in release,
       'script/build_release.sh does not sign inside out with the extensions\' entitlements')

# Data the static libraries read at run time must not come from the build directory
# either: DCMTK's character set tables and OpenSSL's configuration directory.
report('-DDCMTK_ENABLE_BUILTIN_OFICONV_DATA=ON' in (root / 'Horos/Scripts/DCMTK/CMake.sh').read_text(),
       'DCMTK reads its oficonv tables from the build directory at run time')
report('--openssldir=/private/etc/ssl' in (root / 'Horos/Scripts/OpenSSL/Config.sh').read_text(),
       'OpenSSL looks for its configuration in the build directory at run time')

# --- the products, when there are any -----------------------------------------------------
checked = []
for app in (root / 'build/Build/Products/Debug/Isis DICOM Viewer.app', root / 'build/Build/Products/Release/Isis DICOM Viewer.app',
            root / 'build/Release/Isis DICOM Viewer.app'):
    if not (app / 'Contents/MacOS/Isis DICOM Viewer').is_file():
        continue
    signed_release = app == root / 'build/Release/Isis DICOM Viewer.app'
    code, data, err = audit(app, strict=signed_release)
    label = str(app.relative_to(root))
    report(not data.get('external') and not data.get('missing'),
           '%s loads from outside itself: %s %s' % (label, data.get('external'), data.get('missing')))
    report('Contents/Frameworks/libtiff.6.dylib' in data.get('embeddedLibraries', []),
           '%s does not carry libtiff' % label)
    report(not any(name in item for item in data.get('foreignOnly', [])
                   for name in ('3DconnexionClient', 'homephone')) and
           not (app / 'Contents/Resources/HorosCloud.horosplugin.zip').exists(),
           '%s still carries a framework or plugin without arm64' % label)
    executable = (app / 'Contents/MacOS/Isis DICOM Viewer').read_bytes()
    report(b'OPENSSLDIR: "/private/etc/ssl"' in executable,
           '%s was built with another OPENSSLDIR' % label)
    if signed_release:
        report(code == 0, '%s does not pass the strict audit: %s' % (label, err.strip()))
    checked.append(label)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the embed phase copies what the bundle loads and nothing else, renamed and signed; the audit '
      'passes a self-contained bundle and refuses external, missing, outside-rpath and Intel-only code; '
      'the phase and the release audit are wired'
      + ('; checked %s' % ', '.join(checked) if checked else ' (no built bundle to inspect)'))
