#!/usr/bin/env python3
"""The external inputs are the declared ones, verified, and nothing else (#978).

PNG, TIFF, JPEG and the libraries libtiff links used to come from whatever the
building Mac's Homebrew had. Horos/Scripts/external-inputs.sh now stages the
bottles that Horos/Scripts/external-inputs.lock declares, by SHA-256. This
checks, without the network:

- the declaration is well formed and the build scripts use it, not /opt/homebrew;
- the resolver, on small bottles made here and served from a file:// mirror,
  stages and renames them, keeps a good result, and refuses a wrong digest, an
  undeclared dependency, a library for a newer macOS and a tool below its
  minimum, each time leaving the previous result in place;
- if a Debug build is present, the app links the staged libtiff and libpng,
  through the copies embedded in its bundle (#979), and nothing under
  /opt/homebrew.
"""
from pathlib import Path
import hashlib
import json
from http.server import BaseHTTPRequestHandler
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tools'))
from local_http import LocalHTTPServer  # noqa: E402
scripts = root / 'Horos/Scripts'
resolver = scripts / 'external-inputs.sh'
lock = scripts / 'external-inputs.lock'
failures = []


def report(ok, message):
    if not ok:
        failures.append(message)


class InterruptedDownload(BaseHTTPRequestHandler):
    attempts = 0

    def do_GET(self):
        type(self).attempts += 1
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        if self.attempts == 1:
            self.wfile.write(payload[:1])
            self.close_connection = True
        else:
            self.wfile.write(payload)

    def log_message(self, *arguments):
        pass


# --- the declaration -----------------------------------------------------------
# *.lock is ignored in this repository; this one has to reach a clone.
report(subprocess.run(['git', 'check-ignore', '-q', str(lock)], cwd=str(root)).returncode == 1,
       'git ignores external-inputs.lock, so a clone would not have it')
entries = [line.split('#')[0].split() for line in lock.read_text().splitlines()]
entries = [entry for entry in entries if entry]
bottles = [entry for entry in entries if entry[0] == 'bottle']
for entry in entries:
    report(entry[0] in ('bottle', 'tool', 'sdk'), 'unknown entry in the lock: %s' % entry)
for entry in bottles:
    report(len(entry) == 6, 'malformed bottle entry: %s' % entry)
    if len(entry) != 6:
        continue
    _, name, version, tag, digest, use = entry
    report(re.fullmatch(r'[0-9a-f]{64}', digest) is not None, '%s: not a SHA-256' % name)
    report(use in ('link', 'configure', 'runtime'), '%s: unknown use %s' % (name, use))
    # macOS 26 is the deployment target; a newer tag would not load there.
    report(tag == 'arm64_tahoe', '%s: bottle tag %s, not the macOS 26 one' % (name, tag))
names = {entry[1]: entry for entry in bottles if len(entry) == 6}
# libpng is linked since VTK 9: vtkOBJExporter writes its textures with vtkPNGWriter (#959).
for name, use in (('libtiff', 'link'), ('libpng', 'link'), ('jpeg-turbo', 'configure'),
                  ('webp', 'runtime'), ('zstd', 'runtime'), ('xz', 'runtime')):
    report(names.get(name, [None] * 6)[5] == use, '%s is not declared as %s' % (name, use))
tools = {entry[1] for entry in entries if entry[0] == 'tool'}
report({'cmake', 'pkg-config'} <= tools, 'build tools missing from the lock: %s' % tools)
report(any(entry[:2] == ['sdk', 'macosx'] for entry in entries), 'the lock declares no SDK')

# --- the scripts use it --------------------------------------------------------
homebrew = re.compile(r'/opt/homebrew/(include|lib)')
for relative in ('ITK/CMake.sh', 'VTK/CMake.sh', 'VTK/Make.sh', 'DCMTK/CMake.sh'):
    for number, line in enumerate((scripts / relative).read_text().splitlines(), 1):
        if homebrew.search(line) and 'CMAKE_IGNORE_PATH' not in line and not line.lstrip().startswith('#'):
            failures.append('%s:%d still takes %s' % (relative, number, line.strip()))
for relative in ('ITK/CMake.sh', 'VTK/CMake.sh', 'DCMTK/CMake.sh'):
    text = (scripts / relative).read_text()
    report('-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;' in text,
           '%s lets CMake search /opt/homebrew' % relative)
    report('export PKG_CONFIG_LIBDIR=' in text, '%s lets pkg-config search its defaults' % relative)
for relative in ('ITK/CMake.sh', 'VTK/CMake.sh'):
    text = (scripts / relative).read_text()
    call = text.find('sh "$external_inputs"')
    stamp = text.find('.cmakehash')
    report(0 <= call < stamp, '%s does not resolve the inputs before its stamp check' % relative)
    if relative == 'VTK/CMake.sh':
        report('-DTIFF_LIBRARY="$external_prefix/lib/libtiff.dylib"' in text,
               '%s does not name the staged libtiff' % relative)
    else:
        report(not re.search(r'args\+=\(-D(?:ITK_USE_SYSTEM_(?:PNG|JPEG|TIFF)|(?:PNG|JPEG|TIFF)_).*', text),
               'ITK still configures unused codec inputs')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
report('/opt/homebrew' not in project, 'the project still searches /opt/homebrew')
report(project.count('"$CONFIGURATION_TEMP_DIR/ExternalInputs.build/Install/lib"') == 2,
       'the app does not link from the staged inputs in Debug and Release')

# --- the resolver, offline -----------------------------------------------------
# Pristine source archives have their own declaration/stage, with the same
# digest, local mirror, recovery and per-prefix locking policy as bottles.
source_declaration = scripts / 'external-sources.json'
source_pins = json.loads(source_declaration.read_text())
report(subprocess.run(['git', 'check-ignore', '-q', str(source_declaration)], cwd=root).returncode == 1,
       'git ignores the source declaration')
for name, pin in source_pins.items():
    report(pin['name'] == name and re.fullmatch(r'[0-9a-f]{40}', pin['revision']) is not None,
           'source pin has no immutable commit')
    if pin.get('archiveKind', 'commit') == 'release':
        report(pin['url'].startswith('https://') and pin['url'].endswith('/' + pin['archive']) and
               pin['version'] in pin['archive'] and pin.get('sourcePatches') == [] and pin.get('readOnly'),
               'release source does not name the original fixed asset')
    else:
        report(pin['revision'] in pin['url'].split('/'), 'source pin has a mutable URL')
    report(re.fullmatch(r'[0-9a-f]{64}', pin['sha256']) is not None, 'source pin has no SHA-256')

with tempfile.TemporaryDirectory(prefix='external-source-') as directory:
    temporary = Path(directory)
    prefix, downloads, mirror = temporary / 'Source', temporary / 'downloads', temporary / 'mirror'
    mirror.mkdir()
    fixture = temporary / 'fixture'
    fixture.mkdir()
    production = source_pins['OpenJPEG']
    (fixture / 'CMakeLists.txt').write_text('set(OPENJPEG_VERSION_MAJOR 2)\nset(OPENJPEG_VERSION_MINOR 5)\nset(OPENJPEG_VERSION_BUILD 4)\n')
    (fixture / 'LICENSE').write_text('test license\n')
    (fixture / 'openjpeg.h').write_text('test header\n')

    def source_archive(variant='first', layout=None):
        archive = mirror / (variant + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(fixture, arcname=layout or production['root'])
        return dict(production, archive=archive.name,
                    sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                    licenseSha256=hashlib.sha256((fixture / 'LICENSE').read_bytes()).hexdigest())

    def source_resolve(pin, offline=False, use_mirror=True, destination=None):
        declaration = temporary / 'sources.json'
        declaration.write_text(json.dumps({'OpenJPEG': pin}))
        environment = dict(os.environ, EXTERNAL_INPUTS_OFFLINE='1' if offline else '0',
                           EXTERNAL_SOURCES_MIRROR=(mirror if use_mirror else temporary / 'missing').as_uri())
        environment.pop('EXTERNAL_INPUTS_LOCKED', None)
        return subprocess.run(['/bin/sh', str(resolver), '--source', 'OpenJPEG', str(destination or prefix),
                               str(downloads), str(declaration)], env=environment,
                              capture_output=True, text=True, timeout=30)

    pin = source_archive()
    outcome = source_resolve(pin)
    report(outcome.returncode == 0, 'source local mirror failed: ' + outcome.stderr)
    if outcome.returncode == 0:
        report(json.loads((prefix / 'share/source.json').read_text()) == pin, 'resolved source pin not recorded')
        original_stamp = (prefix / '.resolved').stat().st_mtime_ns
        outcome = source_resolve(pin, offline=True, use_mirror=False)
        report(outcome.returncode == 0 and (prefix / '.resolved').stat().st_mtime_ns == original_stamp,
               'unchanged source did not hit its offline cache')
        for path in ('source/openjpeg.h', 'source/LICENSE', 'share/source.json', '.products.json'):
            (prefix / path).write_text('tampered\n')
            outcome = source_resolve(pin, offline=True, use_mirror=False)
            report(outcome.returncode == 0, 'source recovery failed for ' + path + ': ' + outcome.stderr)
        (prefix / 'source/openjpeg.h').unlink()
        outcome = source_resolve(pin, offline=True, use_mirror=False)
        report(outcome.returncode == 0 and (prefix / 'source/openjpeg.h').is_file(), 'missing source was silently approved')
        shutil.rmtree(prefix)
        outcome = source_resolve(pin, offline=True, use_mirror=False)
        report(outcome.returncode == 0, 'offline clone with supplied archive failed: ' + outcome.stderr)
        # A same-version source change replaces the source identity and bytes.
        old_stamp = (prefix / '.resolved').read_text()
        (fixture / 'openjpeg.h').write_text('second header\n')
        second = source_archive('second')
        outcome = source_resolve(second)
        report(outcome.returncode == 0 and (prefix / '.resolved').read_text() != old_stamp and
               (prefix / 'source/openjpeg.h').read_text() == 'second header\n',
               'same-version source pin reused stale products')

        def source_refused(bad, expected, offline=False):
            before = (prefix / '.resolved').read_bytes()
            result = source_resolve(bad, offline=offline)
            report(result.returncode != 0 and expected in result.stderr,
                   'invalid source accepted or wrong diagnosis: ' + result.stderr)
            report((prefix / '.resolved').read_bytes() == before, 'source acquisition failure discarded previous stage')
            report(not prefix.with_name(prefix.name + '.partial').exists(), 'failed source left partial products')

        source_refused(dict(second, sha256='f' * 64), 'declared ' + 'f' * 64)
        source_refused(dict(second, url=production['upstream'] + '/archive/main.tar.gz'), 'immutable commit')
        source_refused(source_archive('bad-layout', 'unexpected-root'), 'unexpected layout')
        # Digest verification alone cannot approve an archive that writes
        # outside its root or introduces symbolic links into pristine source.
        for variant, member_name, member_type, expected in (
                ('traversal', production['root'] + '/../outside', tarfile.REGTYPE, 'unsafe archive layout'),
                ('link', production['root'] + '/escape', tarfile.SYMTYPE, 'unexpected layout')):
            bad_archive = mirror / (variant + '.tar.gz')
            with tarfile.open(bad_archive, 'w:gz') as tar:
                member = tarfile.TarInfo(member_name)
                member.type = member_type
                member.linkname = '/outside'
                tar.addfile(member)
            bad = dict(second, archive=bad_archive.name,
                       sha256=hashlib.sha256(bad_archive.read_bytes()).hexdigest())
            source_refused(bad, expected)
        source_refused(dict(second, version='2.5.5'), 'archive version')
        source_refused(dict(second, archive='absent.tar.gz'), second['sha256'], offline=True)
        # Corrupted archive cannot repair a modified stage offline; the full
        # diagnostic names the required file and digest, without equivalence.
        (prefix / 'source/openjpeg.h').write_text('corrupt stage\n')
        (downloads / second['archive']).write_text('corrupt archive\n')
        source_refused(second, 'missing or corrupt archive', offline=True)
        outcome = source_resolve(second)
        report(outcome.returncode == 0 and (prefix / 'source/openjpeg.h').read_text() == 'second header\n',
               'corrupt source archive was not reobtained through the verified mirror')

        # The official release URL need not pretend to contain a commit. Its
        # fixed asset/version and digest govern the same pristine transaction.
        release = source_archive('OpenJPEG-2.5.4')
        release.update(archiveKind='release', readOnly=True, sourcePatches=[],
                       url='https://example.org/releases/' + release['archive'])
        outcome = source_resolve(release)
        report(outcome.returncode == 0, 'release acquisition failed: ' + outcome.stderr)
        if outcome.returncode == 0:
            report((prefix / 'source/openjpeg.h').stat().st_mode & 0o222 == 0,
                   'original release files are writable')
            release_stamp = (prefix / '.resolved').stat().st_mtime_ns
            outcome = source_resolve(release, offline=True, use_mirror=False)
            report(outcome.returncode == 0 and (prefix / '.resolved').stat().st_mtime_ns == release_stamp,
                   'release archive did not support offline cache reuse')
            other_prefix = temporary / 'Release/Source'
            outcome = source_resolve(release, offline=True, use_mirror=False, destination=other_prefix)
            report(outcome.returncode == 0 and other_prefix.resolve() != prefix.resolve(),
                   'configuration source stages are not independent: ' + outcome.stderr)
            other_identity = (other_prefix / '.products.json').read_bytes()
            other_stamp = (other_prefix / '.resolved').stat().st_mtime_ns
            # Permission changes count as source corruption, even with the
            # original bytes; the verified archive restores original modes.
            (prefix / 'source/openjpeg.h').chmod(0o644)
            outcome = source_resolve(release, offline=True, use_mirror=False)
            report(outcome.returncode == 0 and (prefix / 'source/openjpeg.h').stat().st_mode & 0o222 == 0,
                   'pristine cache ignored modified permissions')
            report((other_prefix / '.products.json').read_bytes() == other_identity and
                   (other_prefix / '.resolved').stat().st_mtime_ns == other_stamp,
                   'repairing one configuration changed the other source stage')
            for bad in (dict(release, url='https://example.org/latest/' + release['archive']),
                        dict(release, url='https://example.org/releases/unversioned.tar.gz'),
                        dict(release, version='2.5.5')):
                source_refused(bad, 'fixed versioned asset')
            source_refused(dict(release, archiveKind='branch'), 'unsupported source archive kind')
            source_refused(dict(release, sha256='f'*64), 'declared ' + 'f'*64)
            (prefix / 'source/openjpeg.h').chmod(0o644)
            (prefix / 'source/openjpeg.h').write_text('changed original release\n')
            outcome = source_resolve(release, offline=True, use_mirror=False)
            report(outcome.returncode == 0 and (prefix / 'source/openjpeg.h').read_text() == 'second header\n',
                   'release cache did not restore pristine source bytes')
            shutil.rmtree(prefix)
            (downloads / release['archive']).unlink()
            (temporary / 'sources.json').write_text(json.dumps({'OpenJPEG': release}))
            payload = (mirror / release['archive']).read_bytes()
            InterruptedDownload.attempts = 0
            server = LocalHTTPServer(('127.0.0.1', 0), InterruptedDownload)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                environment = dict(os.environ, EXTERNAL_INPUTS_OFFLINE='0',
                    EXTERNAL_SOURCES_MIRROR='http://127.0.0.1:%d' % server.server_port)
                environment.pop('EXTERNAL_INPUTS_LOCKED', None)
                outcome = subprocess.run(['/bin/sh', str(resolver), '--source', 'OpenJPEG', str(prefix),
                    str(downloads), str(temporary / 'sources.json')], env=environment,
                    capture_output=True, text=True, timeout=30)
                report(outcome.returncode == 0 and InterruptedDownload.attempts == 2,
                       'interrupted release download did not retry: ' + outcome.stderr)
                report(not list(downloads.glob('*.part')) and not prefix.with_name(prefix.name+'.partial').exists(),
                       'interrupted source download left partial publication')
            finally:
                server.shutdown()
                server.server_close()
                worker.join()

PATH = os.pathsep.join([os.environ.get('PATH', ''), '/opt/homebrew/bin', '/usr/bin', '/bin',
                        '/usr/sbin', '/sbin'])


def dylib(directory, name, install_name, minimum='26.0', link=()):
    source = directory / (name + '.c')
    source.write_text('int %s_value(void) { return 1; }\n' % name.replace('.', '_').replace('-', '_'))
    output = directory / name
    command = ['xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-mmacosx-version-min=' + minimum,
               '-Wl,-headerpad_max_install_names', '-install_name', install_name,
               str(source), '-o', str(output)] + list(link)
    subprocess.run(command, check=True, capture_output=True)
    return output


def bottle(mirror, work, name, version, files, headers=True):
    keg = work / name / version
    (keg / 'lib').mkdir(parents=True)
    if headers:
        (keg / 'include').mkdir()
        (keg / 'include' / (name + '.h')).write_text('/* %s */\n' % name)
    (keg / 'LICENSE').write_text('license of %s\n' % name)
    for file, alias in files:
        shutil.copy(file, keg / 'lib' / file.name)
        if alias:
            os.symlink(file.name, keg / 'lib' / alias)
    archive = work / ('%s.tar.gz' % name)
    with tarfile.open(archive, 'w:gz') as tar:
        tar.add(work / name, arcname=name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    blobs = mirror / name / 'blobs'
    blobs.mkdir(parents=True, exist_ok=True)
    shutil.copy(archive, blobs / ('sha256:' + digest))
    return digest


def resolve(prefix, downloads, lock_text, mirror, deployment='26.0'):
    lock_file = prefix.parent / 'test.lock'
    lock_file.write_text(lock_text)
    environment = dict(os.environ, PATH=PATH, ARCHS='arm64', MACOSX_DEPLOYMENT_TARGET=deployment,
                       EXTERNAL_INPUTS_MIRROR='file://%s' % mirror)
    environment.pop('EXTERNAL_INPUTS_LOCKED', None)
    return subprocess.run(['/bin/sh', str(resolver), str(prefix), str(downloads), str(lock_file)],
                          env=environment, capture_output=True, text=True)


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun clang to make the test bottles', file=sys.stderr)
    sys.exit(2)

with tempfile.TemporaryDirectory() as directory:
    temporary = Path(directory).resolve()
    work, mirror, downloads = temporary / 'work', temporary / 'mirror', temporary / 'downloads'
    work.mkdir(); mirror.mkdir()
    prefix = temporary / 'ExternalInputs.build' / 'Install'
    prefix.parent.mkdir()

    placeholder = '@@HOMEBREW_PREFIX@@/opt/%s/lib/%s'
    foo = dylib(work, 'libfoo.1.dylib', placeholder % ('foo', 'libfoo.1.dylib'))
    bar = dylib(work, 'libbar.1.dylib', placeholder % ('bar', 'libbar.1.dylib'), link=[str(foo)])
    new = dylib(work, 'libnew.1.dylib', placeholder % ('new', 'libnew.1.dylib'), minimum='27.0')
    (work / 'k').mkdir()
    foo_digest = bottle(mirror, work / 'k', 'foo', '1.0', [(foo, 'libfoo.dylib')], headers=False)
    bar_digest = bottle(mirror, work / 'k', 'bar', '2.0_1', [(bar, 'libbar.dylib')])
    new_digest = bottle(mirror, work / 'k', 'new', '3.0', [(new, None)], headers=False)

    good = ('# test\nbottle bar 2.0_1 arm64_tahoe %s link\nbottle foo 1.0 arm64_tahoe %s runtime\n'
            'tool cmake 3.0\nsdk macosx 26.0\n' % (bar_digest, foo_digest))
    result = resolve(prefix, downloads, good, mirror)
    report(result.returncode == 0, 'the declared bottles did not resolve: %s' % result.stderr.strip())
    if result.returncode == 0:
        # A truncated transfer must be retried before the digest is checked.
        payload = (mirror / 'foo/blobs' / ('sha256:' + foo_digest)).read_bytes()
        InterruptedDownload.attempts = 0

        server = LocalHTTPServer(('127.0.0.1', 0), InterruptedDownload)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            retry_lock = temporary / 'retry.lock'
            retry_lock.write_text('bottle foo 1.0 arm64_tahoe %s runtime\n' % foo_digest)
            environment = dict(os.environ, PATH=PATH, ARCHS='arm64', MACOSX_DEPLOYMENT_TARGET='26.0',
                               EXTERNAL_INPUTS_MIRROR='http://127.0.0.1:%d' % server.server_port)
            environment.pop('EXTERNAL_INPUTS_LOCKED', None)
            retried = subprocess.run(['/bin/sh', str(resolver), str(temporary / 'retry/Install'),
                                      str(temporary / 'retry-downloads'), str(retry_lock)],
                                     env=environment, capture_output=True, text=True, timeout=30)
            report(retried.returncode == 0 and InterruptedDownload.attempts == 2,
                   'an interrupted download was not retried successfully: %s' % retried.stderr.strip())
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

        staged_bar = prefix / 'lib/libbar.1.dylib'
        listing = subprocess.run(['otool', '-L', str(staged_bar)], capture_output=True, text=True).stdout
        report('%s/lib/libbar.1.dylib' % prefix in listing, 'libbar was not renamed into the prefix')
        report('%s/lib/libfoo.1.dylib' % prefix in listing, 'libbar still points outside the prefix')
        report('@@HOMEBREW' not in listing, 'a Homebrew placeholder survived')
        report(subprocess.run(['codesign', '-v', str(staged_bar)], capture_output=True).returncode == 0,
               'the renamed library is not validly signed')
        report((prefix / 'lib/libbar.dylib').is_symlink(), 'the library link was not kept as a link')
        report((prefix / 'include/bar.h').is_file(), 'the headers of a linked input were not staged')
        report(not (prefix / 'include/foo.h').exists(), 'a runtime-only input brought headers')
        report((prefix / 'share/licenses/foo/LICENSE').is_file(), 'the licence was not kept')
        recorded = (prefix / 'share/external-inputs.txt').read_text()
        report(bar_digest in recorded and foo_digest in recorded, 'the staged inputs are not recorded')
        report((downloads / ('bar--2.0_1.arm64_tahoe.bottle.tar.gz')).is_file(), 'the bottle was not kept')

        # Nothing changed: nothing is redone, and no mirror is needed.
        stamp = (prefix / '.resolved').stat().st_mtime_ns
        shutil.rmtree(mirror / 'bar')
        again = resolve(prefix, downloads, good, temporary / 'nowhere')
        report(again.returncode == 0 and (prefix / '.resolved').stat().st_mtime_ns == stamp,
               'an unchanged declaration was resolved again')

        def products():
            return {str(path.relative_to(prefix)): ('link', os.readlink(path)) if path.is_symlink()
                    else ('file', path.read_bytes())
                    for path in prefix.rglob('*') if path.is_symlink() or path.is_file()}

        original = products()
        cases = [
            ('removed dylib', lambda: staged_bar.unlink()),
            ('removed header', lambda: (prefix / 'include/bar.h').unlink()),
            ('altered header', lambda: (prefix / 'include/bar.h').write_text('changed header\n')),
            ('corrupt dylib', lambda: staged_bar.write_bytes(b'corrupt')),
            ('altered record', lambda: (prefix / 'share/external-inputs.txt').write_text('wrong\n')),
            ('missing manifest', lambda: (prefix / '.products.json').unlink()),
            ('corrupt manifest', lambda: (prefix / '.products.json').write_text('{')),
        ]

        def broken_link():
            alias = prefix / 'lib/libbar.dylib'
            alias.unlink()
            alias.symlink_to('missing.dylib')

        def outside_link():
            alias = prefix / 'lib/libbar.dylib'
            alias.unlink()
            alias.symlink_to(bar)

        def unmanaged_link():
            alias = prefix / 'lib/libbar.dylib'
            alias.unlink()
            alias.symlink_to('../.resolved')

        def root_link():
            alias = prefix / 'lib/libbar.dylib'
            alias.unlink()
            alias.symlink_to('..')

        cases += [('broken symlink', broken_link), ('outside symlink', outside_link),
                  ('unmanaged symlink', unmanaged_link), ('prefix symlink', root_link)]
        for label, mutate in cases:
            mutate()
            repaired = resolve(prefix, downloads, good, temporary / 'nowhere')
            report(repaired.returncode == 0, '%s was not recovered offline: %s'
                   % (label, repaired.stderr.strip()))
            report(products() == original, '%s left different staged products' % label)
            report('recovering staged products' in repaired.stdout,
                   '%s did not invalidate the cache' % label)
            report(not Path(str(prefix) + '.partial').exists(), '%s left a partial stage' % label)

        # A damaged download is reobtained only after its replacement passes SHA-256.
        cached_foo = downloads / 'foo--1.0.arm64_tahoe.bottle.tar.gz'
        cached_foo.write_bytes(b'corrupt bottle')
        (prefix / 'include/bar.h').unlink()
        recovered = resolve(prefix, downloads, good, mirror)
        report(recovered.returncode == 0 and products() == original,
               'a corrupt cached bottle was not reobtained and repaired: %s' % recovered.stderr.strip())
        report(hashlib.sha256(cached_foo.read_bytes()).hexdigest() == foo_digest,
               'a reobtained bottle was not digest verified')

        # A failed update must preserve every byte/link of the valid prefix.
        before = products()
        cached_foo.write_bytes(b'corrupt bottle')
        foo_blob = mirror / 'foo/blobs' / ('sha256:' + foo_digest)
        foo_payload = foo_blob.read_bytes()
        for payload, expected in ((None, 'could not download'), (b'wrong bytes', 'downloaded SHA-256')):
            if payload is None:
                foo_blob.unlink()
            else:
                foo_blob.write_bytes(payload)
            failed = resolve(prefix, downloads, good + '# new input\n', mirror)
            report(failed.returncode != 0 and expected in failed.stderr,
                   'failed acquisition did not diagnose %s: %s' % (expected, failed.stderr.strip()))
            report(products() == before, 'failed acquisition changed the valid prefix')
            report(not Path(str(prefix) + '.partial').exists(), 'failed acquisition left a partial stage')
            report(not Path(str(cached_foo) + '.part').exists(), 'failed acquisition left a partial bottle')
        foo_blob.write_bytes(foo_payload)
        restored = resolve(prefix, downloads, good + '# new input\n', mirror)
        report(restored.returncode == 0 and (prefix / '.resolved').read_bytes() != before['.resolved'][1],
               'a changed lock did not invalidate the stage')
        flagged = resolve(prefix, downloads, good + '# new input\n', temporary / 'nowhere', '26.1')
        report(flagged.returncode == 0 and 'resolved into' in flagged.stdout,
               'a deployment target change did not invalidate the stage')

    def refused(lock_text, expected, message, deployment='26.0'):
        before = (prefix / '.resolved').read_text() if (prefix / '.resolved').exists() else None
        outcome = resolve(prefix, downloads, lock_text, mirror, deployment)
        report(outcome.returncode != 0, message + ' was accepted')
        report(expected in outcome.stderr, '%s: expected "%s", got: %s'
               % (message, expected, outcome.stderr.strip()))
        after = (prefix / '.resolved').read_text() if (prefix / '.resolved').exists() else None
        report(after == before, message + ' replaced the previous result')

    # A digest that the file does not have: served under that name by the mirror.
    wrong = 'f' * 64
    (mirror / 'foo' / 'blobs' / ('sha256:' + wrong)).write_bytes(
        (mirror / 'foo' / 'blobs' / ('sha256:' + foo_digest)).read_bytes() + b'tampered')
    refused('bottle foo 1.0 arm64_tahoe %s runtime\n' % wrong, 'declared ' + wrong, 'a wrong digest')
    report(not (downloads / 'foo--1.0.arm64_tahoe.bottle.tar.gz.part').exists(),
           'the refused download was left behind')

    (work / 'k3').mkdir()
    bar_only = bottle(mirror, work / 'k3', 'bar', '2.0_1', [(bar, 'libbar.dylib')])
    refused('bottle bar 2.0_1 arm64_tahoe %s link\n' % bar_only, 'does not declare',
            'an undeclared dependency')
    refused('bottle new 3.0 arm64_tahoe %s runtime\n' % new_digest, 'requires macOS 27.0',
            'a library for a newer macOS')
    refused('bottle foo 1.0 arm64_tahoe %s runtime\ntool cmake 999.0\n' % foo_digest,
            'older than the declared minimum', 'a tool below its minimum')
    refused('bottle foo 1.0 arm64_tahoe %s runtime\nsdk macosx 99.0\n' % foo_digest,
            'at least 99.0 is required', 'an SDK below its minimum')

# --- the Debug build, when there is one ----------------------------------------
build = None
for candidate in (root / 'build/Intermediates.noindex', root / 'build/Build/Intermediates.noindex'):
    if (candidate / 'Horos.build/Debug/ExternalInputs.build/Install/.resolved').exists():
        build = candidate / 'Horos.build/Debug/ExternalInputs.build/Install'
        break
app = root / 'build/Build/Products/Debug/Horos.app/Contents/MacOS/Horos'
if build is not None and app.exists():
    recorded = (build / 'share/external-inputs.txt').read_text().split('\n')
    declared = ['%s %s %s %s %s' % tuple(entry[1:]) for entry in bottles]
    report([line for line in recorded if line] == declared,
           'the Debug build staged something other than the lock declares')
    linked = subprocess.run(['otool', '-L', str(app)], capture_output=True, text=True).stdout
    report('/opt/homebrew' not in linked, 'the Debug app still links from /opt/homebrew')
    # Since #979 the bundle carries the staged libraries and loads its own
    # copies, never the build directory (spelled Build/ or build/ here).
    report('ExternalInputs.build'.lower() not in linked.lower(),
           'the Debug app loads staged libraries from the build directory')

    def text_section(path):
        return subprocess.run(['otool', '-t', str(path)], capture_output=True,
                              text=True).stdout.split('\n', 1)[-1]
    for library in ('libtiff.6.dylib', 'libpng16.16.dylib'):
        report('@loader_path/../Frameworks/' + library in linked,
               'the Debug app does not load the %s embedded in its bundle' % library)
        embedded = app.parent.parent / 'Frameworks' / library
        if embedded.is_file():
            report(text_section(embedded) == text_section(build / 'lib' / library),
                   'the %s in the bundle is not the staged one' % library)
        else:
            report(False, 'the Debug bundle has no Frameworks/%s' % library)
    checked_build = True
else:
    checked_build = False

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the lock is well formed and used; the resolver stages declared bottles and refuses a '
      'wrong digest, an undeclared dependency, a newer macOS and old tools'
      + ('; the Debug app loads the staged libtiff and libpng from its own bundle' if checked_build else
         ' (no Debug build with staged inputs to inspect)'))
