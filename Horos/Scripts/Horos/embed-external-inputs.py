#!/usr/bin/env python3
"""Embed in the application bundle the pinned external libraries it loads.

Horos/Scripts/external-inputs.sh stages the bottles of external-inputs.lock in
the build directory, and the app links libtiff from there by absolute path. An
app linked that way runs only on the Mac, and from the build directory, it was
compiled in. This phase, the application target's last before signing, makes
the bundle carry what it loads:

- every Mach-O in the bundle is read, and each library it loads from the staged
  prefix is copied into Contents/Frameworks, then the libraries those load, and
  so on; nothing the bundle does not load is copied, so libpng, libtiffxx or
  libturbojpeg stay out;
- each copy is renamed @rpath/<name>, loads its companions by @loader_path and
  keeps no LC_RPATH, so none of them can reach back to the build directory or
  to Homebrew; each binary that loaded one loads the copy by a path relative to
  itself (@loader_path/../Frameworks/libtiff.6.dylib for the executable);
- the licenses of the bottles that provided a copy go to
  Resources/ExternalLibraries, with a record of bottle, version, digest and
  files;
- source and signed-output hashes govern reuse, independent of timestamps;
  the prior record limits cleanup to managed libraries and notices, and a
  failed copy, rewrite or signing restores the previous artifact;
- the copies are signed, and so is every binary whose load commands changed,
  ad hoc unless Xcode is signing with an identity; the outer signature is left
  to Xcode or to script/build_release.sh;
- finally, any Mach-O in the bundle that still loads something by an absolute
  path outside /usr/lib and /System stops the build.

Libraries of the macOS itself are left alone. The phase runs on every build and
does nothing to a bundle that is already done.

    embed-external-inputs.py            (from Xcode, with its environment)
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

MACHO = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
SYSTEM = ('/usr/lib/', '/System/')


def fail(message):
    print('error: embed external inputs: %s' % message, file=sys.stderr)
    sys.exit(1)


def environment(name):
    value = os.environ.get(name, '')
    if not value:
        fail('%s is not set; run this phase from Xcode' % name)
    return value


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        fail('%s failed: %s' % (' '.join(command), result.stderr.strip()))
    return result.stdout


def is_macho(path):
    try:
        with open(path, 'rb') as handle:
            return handle.read(4) in MACHO
    except OSError:
        return False


def load_commands(path):
    """(install name or None, [loaded libraries], [rpaths]) of a Mach-O."""
    listing = run('/usr/bin/otool', '-l', str(path))
    identifier, loaded, rpaths = None, [], []
    command = None
    for line in listing.splitlines():
        line = line.strip()
        if line.startswith('cmd '):
            command = line.split()[1]
        elif line.startswith('name ') and command in ('LC_ID_DYLIB',):
            identifier = line.split()[1]
        elif line.startswith('name ') and command in ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB',
                                                        'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB'):
            loaded.append(line.split()[1])
        elif line.startswith('path ') and command == 'LC_RPATH':
            rpaths.append(line.split()[1])
    return identifier, sorted(set(loaded)), rpaths


target_build_dir = Path(environment('TARGET_BUILD_DIR'))
contents = target_build_dir / environment('CONTENTS_FOLDER_PATH')
frameworks = target_build_dir / environment('FRAMEWORKS_FOLDER_PATH')
resources = target_build_dir / environment('UNLOCALIZED_RESOURCES_FOLDER_PATH')
prefix = Path(environment('CONFIGURATION_TEMP_DIR')) / 'ExternalInputs.build/Install'
downloads = Path(environment('PROJECT_TEMP_DIR')) / 'ExternalInputs.downloads'
for folder in (contents, frameworks, resources):
    if target_build_dir not in folder.parents:
        fail('refusing to work outside the build directory: %s' % folder)
if not contents.is_dir():
    fail('no bundle at %s' % contents)
staged = prefix / 'lib'
if not (prefix / '.resolved').is_file():
    fail('the external inputs are not staged at %s; the ITK and VTK targets stage them' % prefix)

signing = os.environ.get('CODE_SIGNING_ALLOWED', 'YES') != 'NO'
identity = (os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-') if signing else '-'


def staged_name(reference):
    """The staged library a load command names, or None.

    The staged libraries are named by absolute path in the build directory
    (possibly spelled with another case), and among themselves some use @rpath.
    A reference already rewritten to the embedded copy counts too, so that a
    second run still knows what the bundle needs.
    """
    name = reference.rsplit('/', 1)[-1]
    if not (staged / name).exists():
        if name in previous_libraries and reference.startswith(('@rpath/', '@loader_path/', '@executable_path/')):
            fail('the bundle still loads %s, but it is no longer staged; relink its consumer' % name)
        return None
    if reference.startswith('/'):
        return name if os.path.exists(reference) and os.path.samefile(reference, staged / name) else None
    if reference.startswith(('@rpath/', '@loader_path/', '@executable_path/')):
        return name
    return None


def relative_to_frameworks(binary):
    return os.path.relpath(frameworks, binary.parent)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def safe_name(name):
    if not name or name in ('.', '..') or Path(name).name != name:
        fail('invalid name in the embedded library record: %r' % name)
    return name


licenses = resources / 'ExternalLibraries'
previous_libraries = set()
previous_bottles = set()
previous_record = licenses / 'embedded-libraries.txt'
if previous_record.is_file():
    for line in previous_record.read_text().splitlines():
        fields = line.split()
        if not fields or line.startswith('#'):
            continue
        if len(fields) < 5:
            fail('invalid embedded library record')
        previous_bottles.add(safe_name(fields[0]))
        for name in fields[4:]:
            if not safe_name(name).endswith('.dylib'):
                fail('invalid managed library name: %s' % name)
            previous_libraries.add(name)

manifest_name = 'embedded-identities.json'
previous_identities = {}
if (licenses / manifest_name).is_file():
    try:
        manifest = json.loads((licenses / manifest_name).read_text())
        if manifest.get('format') == 1:
            previous_identities = manifest['libraries']
    except (ValueError, KeyError, TypeError):
        fail('invalid embedded library identities')

# Resolve provenance before preparing any bundle changes. This remains independent
# of the staged cache's timestamp or its resolver's private manifest format.
providers = {}
declared = (prefix / 'share/external-inputs.txt').read_text().splitlines()
for line in declared:
    fields = line.split()
    if len(fields) < 5:
        continue
    name, version, tag, digest, _ = fields[:5]
    safe_name(name)
    archive = downloads / ('%s--%s.%s.bottle.tar.gz' % (name, version, tag))
    if not archive.is_file():
        fail('the verified bottle of %s is not at %s' % (name, archive))
    with tarfile.open(archive) as bottle:
        members = {Path(member).name for member in bottle.getnames()
                   if re.fullmatch(r'[^/]+/[^/]+/lib/[^/]+\.dylib', member)}
    for member in members:
        provider = ' '.join(fields[:4])
        if member in providers and providers[member] != provider:
            fail('multiple declared bottles provide %s' % member)
        providers[member] = provider


def tree_identity(folder):
    """Compare prepared notices without touching an already complete bundle."""
    if not folder.is_dir():
        return None
    entries = []
    for path in sorted(folder.rglob('*')):
        relative = str(path.relative_to(folder))
        if path.is_symlink():
            entries.append((relative, 'link', os.readlink(path)))
        elif path.is_file():
            entries.append((relative, path.stat().st_mode & 0o777, sha256(path)))
        else:
            entries.append((relative, 'directory'))
    return entries


def commit_prepared(replacements, removals, transaction, own_signatures):
    """Publish only validated files; restore the previous artifact on I/O errors."""
    backups = transaction / 'backups'
    backups.mkdir()
    journal = []
    signature_backups = []
    # Signing a bundle's main executable also writes its resource seal. Keep
    # that bundle context, and restore seals as well as binaries on failure.
    signature_paths = ({path for path in contents.rglob('_CodeSignature') if path.is_dir()}
                       if own_signatures else set())
    for binary in own_signatures:
        signature_paths.update((binary.parent / '_CodeSignature', binary.parent.parent / '_CodeSignature'))
    for path in sorted(signature_paths):
        backup = backups / ('signature-%s' % len(signature_backups))
        existed = path.exists()
        if existed:
            shutil.copytree(path, backup, symlinks=True)
        signature_backups.append((path, backup if existed else None))
    try:
        for destination in sorted(set(replacements) | set(removals)):
            destination.parent.mkdir(parents=True, exist_ok=True)
            backup = backups / str(len(journal))
            existed = destination.exists() or destination.is_symlink()
            if existed:
                os.replace(destination, backup)
            journal.append((destination, backup if existed else None))
            if destination in replacements:
                os.replace(replacements[destination], destination)
        for binary in sorted(own_signatures, key=lambda path: (-len(path.parts), str(path))):
            # Xcode later signs these again with the outer bundle's identity.
            run('/usr/bin/codesign', '--force', '--sign', '-',
                '--preserve-metadata=entitlements', str(binary))
    except BaseException:
        for destination, backup in reversed(journal):
            if destination.is_dir() and not destination.is_symlink():
                shutil.rmtree(destination)
            elif destination.exists() or destination.is_symlink():
                destination.unlink()
            if backup is not None:
                os.replace(backup, destination)
        for path, backup in signature_backups:
            if path.exists():
                shutil.rmtree(path)
            if backup is not None:
                os.replace(backup, path)
        raise


def prepare_and_embed(transaction):
    embedded = {}      # name -> prepared or unchanged library
    identities = {}
    replacements = {}  # bundle destination -> prepared file
    own_signatures = set()

    def candidate(destination, source):
        folder = transaction / ('binary-%s' % len(replacements))
        folder.mkdir()
        prepared = folder / destination.name
        shutil.copy2(source, prepared)
        replacements[destination] = prepared
        return prepared

    def embed(name):
        if name in embedded:
            return
        source = (staged / name).resolve()
        destination = frameworks / name
        if (destination.exists() or destination.is_symlink()) and name not in previous_libraries:
            fail('refusing to replace unmanaged library %s' % destination)
        provider = providers.get(name)
        if provider is None:
            fail('no declared bottle provides %s' % name)
        if not is_macho(source):
            fail('the staged library is not Mach-O: %s' % source)
        source_digest = sha256(source)
        old = previous_identities.get(name, {})
        fresh = (not destination.is_file() or destination.is_symlink()
                 or old.get('sourceSha256') != source_digest
                 or old.get('bottle') != provider
                 or old.get('signingIdentity') != identity
                 or old.get('embeddedSha256') != sha256(destination))
        path = candidate(destination, source) if fresh else destination
        if fresh and sha256(path) != source_digest:
            fail('the staged library changed while copying: %s' % source)
        embedded[name] = path
        identifier, loaded, rpaths = load_commands(path)
        arguments = []
        if identifier != '@rpath/' + name:
            arguments += ['-id', '@rpath/' + name]
        for reference in loaded:
            wanted = staged_name(reference)
            if wanted is not None and reference != '@loader_path/' + wanted:
                arguments += ['-change', reference, '@loader_path/' + wanted]
        for rpath in rpaths:
            arguments += ['-delete_rpath', rpath]
        if arguments:
            if not fresh:
                path = candidate(destination, destination)
                embedded[name] = path
            run('/usr/bin/install_name_tool', *arguments, str(path))
        if destination in replacements:
            path.chmod(0o755)
            run('/usr/bin/codesign', '--force', '--sign', identity, str(path))
        identities[name] = dict(sourceSha256=source_digest, embeddedSha256=sha256(path),
                                bottle=provider, signingIdentity=identity)
        for reference in loaded:
            wanted = staged_name(reference)
            if wanted is not None:
                embed(wanted)

    binaries = []
    for binary in sorted(contents.rglob('*')):
        if binary.is_symlink() or not binary.is_file():
            continue
        if binary.parent == frameworks and binary.name in previous_libraries:
            continue
        if is_macho(binary):
            binaries.append(binary)
    for binary in binaries:
        _, loaded, _ = load_commands(binary)
        arguments = []
        for reference in loaded:
            name = staged_name(reference)
            if name is None:
                continue
            embed(name)
            wanted = '@loader_path/%s/%s' % (relative_to_frameworks(binary), name)
            if reference != wanted:
                arguments += ['-change', reference, wanted]
        if arguments:
            path = candidate(binary, binary)
            run('/usr/bin/install_name_tool', *arguments, str(path))
            own_signatures.add(binary)

    record = []
    bottles = set()
    for provider in sorted({providers[name] for name in embedded}):
        files = sorted(name for name in embedded if providers[name] == provider)
        record.append(provider + ' ' + ' '.join(files))
        bottles.add(provider.split()[0])
    prepared_licenses = transaction / 'licenses'
    if licenses.exists():
        shutil.copytree(licenses, prepared_licenses, symlinks=True)
    else:
        prepared_licenses.mkdir()
    # The prior record is the ownership boundary, including when a pin disappears.
    # Preserve other resources, frameworks, plugins and unclaimed notice entries.
    for name in previous_bottles:
        path = prepared_licenses / name
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
    for name in bottles:
        source = prefix / 'share/licenses' / name
        texts = sorted(source.glob('*')) if source.is_dir() else []
        if not texts:
            fail('the bottle of %s carries no license text' % name)
        if (prepared_licenses / name).exists() or (prepared_licenses / name).is_symlink():
            fail('refusing to replace unmanaged notices of %s' % name)
        shutil.copytree(source, prepared_licenses / name)
    (prepared_licenses / 'embedded-libraries.txt').write_text(
        '# Libraries in Contents/Frameworks, from the bottles pinned in external-inputs.lock:\n'
        '# bottle version tag sha256-of-bottle files\n' + '\n'.join(record) + '\n')
    (prepared_licenses / manifest_name).write_text(
        json.dumps(dict(format=1, libraries=identities), sort_keys=True, indent=2) + '\n')
    if tree_identity(licenses) != tree_identity(prepared_licenses):
        replacements[licenses] = prepared_licenses

    # Publish static source records and licenses in the same transaction as
    # the libraries, so a signing failure restores every managed resource.
    openjpeg_install = Path(environment('CONFIGURATION_TEMP_DIR')) / 'OpenJPEG.build/Install'
    source_record = openjpeg_install / 'share/source.json'
    source_license = openjpeg_install / 'share/licenses/OpenJPEG/LICENSE'
    if not source_record.is_file() or not source_license.is_file():
        fail('OpenJPEG has no installed source record or license')
    pin = json.loads(source_record.read_text())
    if pin['name'] != 'OpenJPEG' or sha256(source_license) != pin['licenseSha256']:
        fail('OpenJPEG installed provenance or license differs from its source record')
    compiled_sources = resources / 'CompiledSources/OpenJPEG'
    prepared_sources = transaction / 'openjpeg-source'
    prepared_sources.mkdir()
    shutil.copyfile(source_record, prepared_sources / 'source.json')
    shutil.copyfile(source_license, prepared_sources / 'LICENSE')
    if tree_identity(compiled_sources) != tree_identity(prepared_sources):
        replacements[compiled_sources] = prepared_sources

    # Carry the VTK host adaptation separately from upstream source identity;
    # installed module and aggregate share this implementation of the C ABI.
    vtk_install = Path(environment('CONFIGURATION_TEMP_DIR')) / 'VTK.build/Install'
    adaptation = vtk_install / 'share/freetype-host-adaptation.json'
    if adaptation.is_file():
        if (vtk_install / '.incomplete').exists():
            fail('VTK installation is incomplete')
        record = json.loads(adaptation.read_text())
        module = vtk_install / 'lib' / safe_name(record['archive'])
        if record['publicSymbol'] != '_vtkfreetype_FT_MulFix' or sha256(module) != record['installedArchiveSha256']:
            fail('VTK FreeType archive differs from its host adaptation record')
        if sha256(vtk_install / 'wlib/libVTK.a') != record['aggregateSha256']:
            fail('VTK aggregate differs from its host adaptation record')
        source_record = vtk_install / 'share/source.json'
        source_license = vtk_install / 'share/licenses/VTK/Copyright.txt'
        if not source_record.is_file() or not source_license.is_file():
            fail('VTK has no installed original source record or license')
        pin = json.loads(source_record.read_text())
        selected = json.loads((Path(__file__).resolve().parent.parent / 'external-sources.json').read_text())['VTK']
        if (pin != selected or pin['name'] != 'VTK' or pin.get('sourcePatches') != [] or
                record['source']['sourceVersion'] != pin['version'] or
                record['source']['archiveSha256'] != pin['sha256'] or
                sha256(source_license) != pin['licenseSha256']):
            fail('VTK original source/license differs from its installed identity')
        prepared_vtk = transaction / 'vtk-host-adaptation'
        prepared_vtk.mkdir()
        shutil.copyfile(adaptation, prepared_vtk / adaptation.name)
        shutil.copyfile(source_record, prepared_vtk / 'source.json')
        shutil.copyfile(source_license, prepared_vtk / 'Copyright.txt')
        vtk_resources = resources / 'CompiledSources/VTK'
        if tree_identity(vtk_resources) != tree_identity(prepared_vtk):
            replacements[vtk_resources] = prepared_vtk
    elif (vtk_install / 'wlib/libVTK.a').is_file():
        fail('VTK has no installed FreeType host adaptation record')

    # ITK is compiled from its original release archive: carry the record of
    # that source with its license and notice.
    itk_install = Path(environment('CONFIGURATION_TEMP_DIR')) / 'ITK.build/Install'
    if (itk_install / 'wlib/libITK.a').is_file():
        if (itk_install / '.incomplete').exists():
            fail('ITK installation is incomplete')
        source_record = itk_install / 'share/source.json'
        source_license = itk_install / 'share/licenses/ITK/LICENSE'
        source_notice = itk_install / 'share/licenses/ITK/NOTICE'
        if not source_record.is_file() or not source_license.is_file() or not source_notice.is_file():
            fail('ITK has no installed original source record, license or notice')
        pin = json.loads(source_record.read_text())
        selected = json.loads((Path(__file__).resolve().parent.parent / 'external-sources.json').read_text())['ITK']
        if (pin != selected or pin['name'] != 'ITK' or pin.get('sourcePatches') != [] or
                sha256(source_license) != pin['licenseSha256'] or sha256(source_notice) != pin['noticeSha256']):
            fail('ITK original source, license or notice differs from its installed identity')
        prepared_itk = transaction / 'itk-source'
        prepared_itk.mkdir()
        shutil.copyfile(source_record, prepared_itk / 'source.json')
        shutil.copyfile(source_license, prepared_itk / 'LICENSE')
        shutil.copyfile(source_notice, prepared_itk / 'NOTICE')
        itk_resources = resources / 'CompiledSources/ITK'
        if tree_identity(itk_resources) != tree_identity(prepared_itk):
            replacements[itk_resources] = prepared_itk

    problems = []
    for binary in binaries + [frameworks / name for name in embedded]:
        for reference in load_commands(replacements.get(binary, binary))[1]:
            if reference.startswith('/') and not reference.startswith(SYSTEM):
                problems.append('%s loads %s' % (binary.relative_to(contents.parent), reference))
    if problems:
        fail('the bundle loads code from outside itself and the macOS:\n  ' + '\n  '.join(problems))
    removals = {frameworks / name for name in previous_libraries - set(embedded)}
    commit_prepared(replacements, removals, transaction, own_signatures)
    for path in sorted(removals):
        print('embed external inputs: removed %s, which nothing loads any more' % path.name)
    print('embed external inputs: %s' % (', '.join(sorted(embedded)) if embedded else 'nothing to embed'))


# Prepare on the same filesystem as the bundle, outside Contents: no partial
# rewrite, notice deletion or invalid signature is published on a failed phase.
with tempfile.TemporaryDirectory(prefix='.embed-external-', dir=target_build_dir) as folder:
    prepare_and_embed(Path(folder))
