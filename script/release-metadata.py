#!/usr/bin/env python3
"""Write BUILD-INFO.txt and SHA256SUMS.txt for a bundle script/build_release.sh made.

    release-metadata.py ROOT CONFIGURATION_TEMP_DIR STAGING_DIR AUDIT_JSON SOURCE_PACKAGES

ROOT is the checkout, CONFIGURATION_TEMP_DIR the intermediates of the Release
build (where the dependencies were installed), STAGING_DIR the folder holding
the signed and audited Horos.app, and AUDIT_JSON the report
tools/audit-release-bundle.py wrote for it. Both files are written into
STAGING_DIR, beside the application, so that the script moves the three
together.

BUILD-INFO.txt identifies the artifact: source commit and tree, configuration,
toolchain and SDK, the versions of the dependencies as installed by this build,
the libraries embedded in the bundle with the bottles they came from, how it is
signed, what the audit found and the SHA-256 of the executable and of each
embedded library. SHA256SUMS.txt lists every file of the bundle and BUILD-INFO
itself, so that `shasum -a 256 -c SHA256SUMS.txt`, run in the folder that
holds them, checks the whole artifact.

Public package URLs and verified public revisions identify remote dependencies.
Local Horos builds do not expose private checkout commits or paths. An optional
public source ref must match the source used by this build before it is recorded.
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

def run(*command, cwd=None):
    try:
        result = subprocess.run(command, capture_output=True, text=True, cwd=cwd)
    except OSError:
        return ''
    return result.stdout.strip() if result.returncode == 0 else ''


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def first_match(folder, names, pattern):
    """The first group of `pattern` in the first file called one of `names` under `folder`."""
    if not folder.is_dir():
        return ''
    for name in names:
        for path in sorted(folder.rglob(name)):
            found = re.search(pattern, path.read_text(errors='replace'), re.M)
            if found:
                return '.'.join(group for group in found.groups() if group)
    return ''


PUBLIC_PACKAGE_URL = 'https://github.com/ThalesMMS/DICOM-Swift.git'
LOCKFILE = 'Horos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


PACKAGE_NOTICE_PATHS = {
    'LICENSE': 'Splash/DICOM-Swift-LICENSE.txt',
    'ThirdPartyNotices.txt': 'Splash/ThirdParty/DICOMSwift/ThirdPartyNotices.txt',
    'DistributionProvenance.json': 'Splash/ThirdParty/DICOMSwift/DistributionProvenance.json',
    'ThirdPartyLicenses/pydicom/LICENSE': 'Splash/ThirdParty/DICOMSwift/pydicom/LICENSE',
    'ThirdPartyLicenses/DCMTK/COPYRIGHT': 'Splash/ThirdParty/DICOMSwift/DCMTK/COPYRIGHT',
    'ThirdPartyLicenses/GDCM/Copyright.txt': 'Splash/ThirdParty/DICOMSwift/GDCM/Copyright.txt',
    'ThirdPartyLicenses/GDCM/Source/DataDictionary/COPYRIGHT.dicom3tools': 'Splash/ThirdParty/DICOMSwift/GDCM/COPYRIGHT.dicom3tools',
}


def package_notices(checkout):
    notices = {}
    for source, bundled in PACKAGE_NOTICE_PATHS.items():
        path = checkout / source
        if not path.is_file() or not path.read_bytes().strip():
            raise ValueError('the resolved public package lacks a required license/provenance material')
        notices[bundled] = {'source': path, 'sha256': sha256(path)}
    return notices


def check_package_notices(records, app, stage=False):
    for record in records:
        for relative, notice in record.get('notices', {}).items():
            path = app / 'Contents/Resources' / relative
            if stage:
                if path.is_symlink():
                    raise ValueError('package notice destination must be a regular bundled file')
                path.parent.mkdir(parents=True, exist_ok=True)
                if path.exists(): path.chmod(0o644)
                path.write_bytes(notice['source'].read_bytes())
            if not path.is_file() or sha256(path) != notice['sha256']:
                raise ValueError('bundled package notice does not match the effective public package')


def project_objects(root):
    project = root / 'Horos.xcodeproj/project.pbxproj'
    if not project.is_file():
        raise ValueError('the versioned Xcode project is missing')
    result = subprocess.run(['plutil', '-convert', 'xml1', '-o', '-', str(project)],
                            capture_output=True)
    if result.returncode:
        raise ValueError('the Xcode project could not be read')
    return plistlib.loads(result.stdout)['objects']


def public_ref_revision(url, ref):
    # Ignore user/system URL rewrites and credential helpers for this public check.
    # Do not include git stderr: a configured remote can contain credentials.
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith('GIT_CONFIG') or key in ('GIT_DIR', 'GIT_WORK_TREE'):
            environment.pop(key)
    environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                       GIT_TERMINAL_PROMPT='0')
    with tempfile.TemporaryDirectory(prefix='horos-public-tag-') as neutral:
        result = subprocess.run(['git', '-c', 'credential.helper=', 'ls-remote', '--exit-code',
                                 url, ref, ref + '^{}'],
                                capture_output=True, text=True, env=environment, cwd=neutral, timeout=30)
    if result.returncode:
        raise ValueError('the approved public ref could not be verified over HTTPS')
    refs = dict(line.split()[::-1] for line in result.stdout.splitlines())
    revision = refs.get(ref + '^{}', refs.get(ref))
    if not revision or not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('the approved public ref has no valid revision')
    return revision


def verified_swift_packages(root, packages):
    """Compare approval with SwiftPM state and the actual clean Git checkouts.

    The lockfile alone is not evidence: local substitutions retain a remote pin.
    Every resolved dependency must have an unchanged remote source checkout.
    """
    # Release uses the canonical project workspace. Development overrides belong
    # in an ignored sibling workspace and cannot enter this build through it.
    workspace = root / 'Horos.xcodeproj/project.xcworkspace/contents.xcworkspacedata'
    if workspace.is_file():
        try:
            references = list(ET.fromstring(workspace.read_bytes()).iter('FileRef'))
        except ET.ParseError:
            raise ValueError('the canonical Xcode workspace is invalid')
        if any(ref.get('location') != 'self:' for ref in references):
            raise ValueError('release does not accept additional workspace references or local overrides')
    objects = project_objects(root)
    local = [obj for obj in objects.values() if obj.get('isa') == 'XCLocalSwiftPackageReference']
    if local:
        raise ValueError('release does not accept local Swift package references')
    requirements = {obj['repositoryURL']: obj['requirement'] for obj in objects.values()
                    if obj.get('isa') == 'XCRemoteSwiftPackageReference'}
    if not requirements:
        return []
    if PUBLIC_PACKAGE_URL not in requirements:
        raise ValueError('the DICOMweb client must resolve from its approved public URL')
    for requirement in requirements.values():
        if requirement.get('kind') != 'exactVersion':
            raise ValueError('release requires an Exact Version for each direct Swift package')
    lock = root / LOCKFILE
    try:
        pins = json.loads(lock.read_text())['pins']
        dependencies = json.loads((packages / 'workspace-state.json').read_text())['object']['dependencies']
    except (OSError, KeyError, ValueError):
        raise ValueError('the approved lockfile or effective SwiftPM workspace state is missing or invalid')
    if len({pin['identity'] for pin in pins}) != len(pins):
        raise ValueError('duplicate package identities in the approved lockfile')
    state_by_identity = {entry['packageRef']['identity']: entry for entry in dependencies}
    if len(state_by_identity) != len(dependencies) or set(state_by_identity) != {p['identity'] for p in pins}:
        raise ValueError('effective SwiftPM dependencies do not match the approved lockfile')
    if not set(requirements).issubset({pin['location'] for pin in pins}):
        raise ValueError('a direct Swift package is absent from the approved lockfile')
    products = {}
    for obj in objects.values():
        if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'Horos':
            for identifier in obj.get('packageProductDependencies', []):
                product = objects[identifier]
                url = objects[product['package']]['repositoryURL']
                products.setdefault(url, []).append(product['productName'])
    records = []
    for pin in pins:
        identity, url, approved = pin['identity'], pin['location'], pin['state']
        if not re.fullmatch('[a-zA-Z0-9._-]+', identity):
            raise ValueError('invalid package identity')
        version, revision = approved.get('version'), approved.get('revision')
        if (pin.get('kind') != 'remoteSourceControl' or not version
                or not re.fullmatch('[0-9a-f]{40}', revision or '')
                or not re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?', url)):
            raise ValueError('release requires versioned packages from public GitHub HTTPS URLs')
        if url in requirements and requirements[url].get('version') != version:
            raise ValueError('project Exact Version differs from the approved lockfile')
        entry = state_by_identity[identity]
        package_ref, state = entry['packageRef'], entry['state']
        if (package_ref.get('kind') != 'remoteSourceControl' or package_ref.get('location') != url
                or state.get('name') != 'sourceControlCheckout' or state.get('checkoutState') != approved):
            raise ValueError('effective SwiftPM resolution differs from approval or uses a local override')
        subpath = entry.get('subpath', '')
        checkout = packages / 'checkouts' / subpath
        if not subpath or Path(subpath).name != subpath or checkout.is_symlink() or not (checkout / '.git').exists():
            raise ValueError('effective package checkout is missing or outside SourcePackages')
        if run('git', '-C', str(checkout), 'rev-parse', 'HEAD') != revision:
            raise ValueError('effective package checkout revision differs from approval')
        origin = run('git', '-C', str(checkout), 'remote', 'get-url', 'origin')
        if origin.removesuffix('.git') != url.removesuffix('.git'):
            # Xcode clones its working copy from a local bare SourcePackages
            # repository. Follow exactly that cache hop, then check its effective
            # public remote; arbitrary filesystem origins remain overrides.
            cache = Path(origin)
            repositories = packages / 'repositories'
            if (not cache.is_absolute() or not cache.is_dir() or repositories.is_symlink()
                    or not cache.resolve().is_relative_to(repositories.resolve())
                    or run('git', '-C', str(cache), 'rev-parse', '--is-bare-repository') != 'true'
                    or run('git', '-C', str(cache), 'remote', 'get-url', 'origin').removesuffix('.git')
                    != url.removesuffix('.git')):
                raise ValueError('effective package origin was rewritten or is not the approved public URL')
        status = subprocess.run(['git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=all'],
                                capture_output=True, text=True)
        if status.returncode or status.stdout.strip():
            raise ValueError('effective package source checkout contains local changes')
        if public_ref_revision(url, 'refs/tags/' + version) != revision:
            raise ValueError('effective package revision does not match its public tag')
        if url in requirements and not products.get(url):
            raise ValueError('the Horos target does not link the approved package product')
        records.append({'identity': identity, 'url': url, 'version': version, 'revision': revision,
                        'products': sorted(products.get(url, [])), 'lockfileSHA256': sha256(lock),
                        'notices': package_notices(checkout) if url == PUBLIC_PACKAGE_URL else {}})
    return records


PUBLIC_HOROS_URL = 'https://github.com/ThalesMMS/horos.git'


def public_horos_source(root, ref):
    if not re.fullmatch(r'refs/(?:heads|tags)/[A-Za-z0-9._/-]+', ref):
        raise ValueError('public Horos source must name a full branch or tag ref')
    revision = public_ref_revision(PUBLIC_HOROS_URL, ref)
    # Internal records do not enter the app. Everything else, including native
    # source gitlinks and build recipes, must match the selected public revision.
    result = subprocess.run(['git', '-C', str(root), 'diff', '--quiet', revision, '--', '.',
                             ':!docs', ':!local-validation', ':!.codegraph', ':!AGENTS.md', ':!.github'],
                            capture_output=True)
    if result.returncode:
        raise ValueError('the build sources do not match the selected public Horos revision')
    return revision


def write_metadata(root, temp_dir, staging, audit_path, packages, public_source_ref=None):
    app = staging / 'Horos.app'
    package_records = verified_swift_packages(root, packages)
    check_package_notices(package_records, app)

    def git(*arguments, cwd=root):
        return run('git', '-C', str(cwd), *arguments)

    lines = []
    add = lines.append
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    add('Horos local release build')
    add('Built: %s' % now.isoformat().replace('+00:00', 'Z'))
    add('')
    add('Source')
    commit = git('rev-parse', 'HEAD')
    add('  public repository: %s' % PUBLIC_HOROS_URL)
    if public_source_ref:
        add('  public ref: %s' % public_source_ref)
        add('  verified public revision: %s' % public_horos_source(root, public_source_ref))
    else:
        add('  local development source; no public revision is asserted')
    add('')
    add('Artifact')
    add('  bundle: Horos.app, %s %s (build %s)' % (info.get('CFBundleIdentifier', '?'),
                                                   info.get('CFBundleShortVersionString', '?'),
                                                   info.get('CFBundleVersion', '?')))
    add('  configuration: Release')
    architectures = run('lipo', '-archs', str(app / 'Contents/MacOS' / info.get('CFBundleExecutable', 'Horos')))
    add('  architectures: %s' % (architectures or '?'))
    add('  minimum macOS: %s' % info.get('LSMinimumSystemVersion', '?'))
    add('')
    add('Toolchain')
    xcode = run('xcodebuild', '-version').replace('\n', ', ')
    add('  Xcode: %s' % (xcode or '?'))
    add('  SDK: macosx %s (%s)' % (run('xcrun', '--sdk', 'macosx', '--show-sdk-version') or '?',
                                   run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version') or '?'))
    add('  clang: %s' % (run('xcrun', 'clang', '--version').split('\n')[0] or '?'))
    add('  swift: %s' % (run('xcrun', 'swift', '-version').split('\n')[0] or '?'))
    add('  cmake: %s' % (re.sub(r'^cmake version ', '', run('cmake', '--version').split('\n')[0]) or '?'))
    add('  on: macOS %s (%s), %s' % (run('sw_vers', '-productVersion') or '?', run('sw_vers', '-buildVersion') or '?',
                                     run('uname', '-m') or '?'))
    add('')

    add('Dependencies, as installed by this build (static unless embedded below)')
    dependencies = [
        ('OpenSSL', 'OpenSSL', ['opensslv.h'], r'OPENSSL_FULL_VERSION_STR "([^"]+)"', 'OpenSSL/upstream'),
        ('DCMTK', 'DCMTK', ['osconfig.h'], r'PACKAGE_VERSION "([^"]+)"', 'DCMTK'),
        ('OpenJPEG', 'OpenJPEG', ['libopenjp2.pc'], r'^Version: (\S+)', 'OpenJPEG'),
        ('ITK', 'ITK', ['itkConfigure.h'],
         r'ITK_VERSION_MAJOR (\d+)\s*\n#define ITK_VERSION_MINOR (\d+)\s*\n#define ITK_VERSION_PATCH (\d+)', 'ITK'),
        ('VTK', 'VTK', ['vtkVersionMacros.h'], r'VTK_VERSION "([^"]+)"', 'VTK'),
    ]
    for label, target, names, pattern, source in dependencies:
        version = first_match(temp_dir / ('%s.build/Install' % target), names, pattern)
        if label == 'DCMTK' and version:
            version += first_match(temp_dir / 'DCMTK.build/Install', names, r'PACKAGE_VERSION_SUFFIX "([^"]*)"')
        origin = ''
        source_record = temp_dir / ('%s.build/Install/share/source.json' % target)
        if source_record.is_file():
            pin = json.loads(source_record.read_text())
            if pin['name'] != label or pin['version'] != version:
                sys.exit('error: installed %s does not match its compiled source record' % label)
            bundled = app / ('Contents/Resources/CompiledSources/%s/source.json' % label)
            if not bundled.is_file() or bundled.read_bytes() != source_record.read_bytes():
                sys.exit('error: bundle does not carry the compiled source record of ' + label)
            origin = 'upstream %s, commit %s, archive %s, sha256 %s' % (
                pin['upstream'], pin['revision'], pin['archive'], pin['sha256'])
            origin += '; source patches: %s' % (pin.get('sourcePatches') or 'none')
        elif label in ('OpenJPEG', 'VTK', 'ITK') and version:
            sys.exit('error: installed %s has no compiled source record' % label)
        elif (root / source / '.git').exists():
            origin = 'submodule %s' % (git('rev-parse', 'HEAD', cwd=root / source) or '?')
        elif commit:
            tree = git('rev-parse', 'HEAD:%s' % source)
            dirty = git('status', '--porcelain', '--untracked-files=no', '--', source)
            origin = 'tree %s%s' % (tree or '?', ', with local changes' if dirty else '')
        add('  %-16s %-10s %s' % (label, version or '(not found)', origin))
        if label == 'VTK' and version:
            adaptation = temp_dir / 'VTK.build/Install/share/freetype-host-adaptation.json'
            bundled = app / 'Contents/Resources/CompiledSources/VTK/freetype-host-adaptation.json'
            if not adaptation.is_file() or not bundled.is_file() or adaptation.read_bytes() != bundled.read_bytes():
                sys.exit('error: VTK has no matching bundled FreeType host adaptation record')
            details = json.loads(adaptation.read_text())
            add('    FreeType original %s; source archive sha256 %s; subtree sha256 %s' % (
                details['source']['version'], details['source']['archiveSha256'], details['source']['treeSha256']))
            add('    %s; public %s, local %s; source patches: none in FreeType' % (
                details['method'], details['publicSymbol'], details['localSymbol']))
            add('    installed module sha256 %s; recipe sha256 %s' % (
                details['installedArchiveSha256'], json.dumps(details['recipeSha256'], sort_keys=True)))
    dcmtk_record = root / 'Horos/Scripts/DCMTK/PREPARATION.json'
    if dcmtk_record.is_file():
        prepared = json.loads(dcmtk_record.read_text())
        if prepared['patches']:
            add('  DCMTK declared preparation base %s; prepared source differs from base' % prepared['base']['revision'])
        else:
            add('  DCMTK compiled from the unmodified checkout %s; source patches: none' % prepared['base']['revision'])
        for patch in prepared['patches']:
            add('    %s sha256 %s: %s' % (Path(patch['path']).name, patch['sha256'], ', '.join(patch['files'])))
        add('    JPEG-LS: partial link/symbol localization; no source transformation')
    provenance = app / 'Contents/Resources/Splash/ThirdParty/Provenance.json'
    if provenance.is_file():
        add('  incorporated source/resource provenance: Splash/ThirdParty/Provenance.json, sha256 %s' % sha256(provenance))
        for component in json.loads(provenance.read_text())['components']:
            if component['id'] == 'libarchive-headers':
                add('  libarchive headers source 3.7.4, Apple %s; runtime supplied by macOS' % component['revision'])

    feedback_record = app / 'Contents/Frameworks/FeedbackReporter.framework/Resources/BuildSource.json'
    if feedback_record.is_file():
        feedback = json.loads(feedback_record.read_text())
        add('  FeedbackReporter upstream %s, tree %s; host source selection:' %
            (feedback['revision'], feedback['tree']))
        for name, digest in sorted(feedback['hostSources'].items()):
            add('    %s sha256 %s' % (name, digest))
    else:
        add('  FeedbackReporter build source record unavailable')
    add('')

    add('Resolved Swift packages (products identify those linked by Horos)')
    if package_records:
        for record in package_records:
            add('  %s: %s' % (record['identity'], record['url']))
            add('    products: %s; tag: %s; public revision: %s' % (
                ', '.join(record['products']) or '(resolved only; not a Horos product)', record['version'], record['revision']))
            add('    approved lockfile: %s; sha256: %s' % (LOCKFILE, record['lockfileSHA256']))
            for path, notice in sorted(record['notices'].items()):
                add('    notice sha256: %s  %s' % (notice['sha256'], path))
    else:
        add('  no Swift packages linked by the project')
    add('')

    add('Bundled DICOM validator (acquisition pin; signing changes the helper bytes)')
    validator_record = app / 'Contents/Resources/dciodvfy.lock.json'
    if validator_record.is_file():
        validator = json.loads(validator_record.read_text())
        add('  snapshot: %s; architecture: %s' % (validator['snapshot'], validator['architecture']))
        add('  source: %s; sha256 %s' % (validator['source']['url'], validator['source']['sha256']))
        add('  build revision: %s' % validator['build']['revision'])
        add('  artifact: %s; sha256 %s' % (validator['artifact']['url'], validator['artifact']['sha256']))
        add('  acquired helper sha256: %s' % validator['helperSHA256'])
        add('  signed bundle helper sha256: %s' % sha256(app / 'Contents/Resources/dciodvfy'))
    else:
        add('  no acquisition record found')
    add('')

    add('Embedded dynamic libraries (Contents/Frameworks; licenses in Resources/ExternalLibraries)')
    record = app / 'Contents/Resources/ExternalLibraries/embedded-libraries.txt'
    if record.is_file():
        for line in record.read_text().splitlines():
            if line and not line.startswith('#'):
                name, version, tag, digest, *files = line.split()
                add('  %s %s (%s), bottle sha256 %s: %s' % (name, version, tag, digest, ' '.join(files)))
    else:
        add('  none recorded')
    add('  macOS libraries (/usr/lib, /System) are the system\'s and are not embedded.')
    add('')

    audit = json.loads(audit_path.read_text()) if audit_path.is_file() else {}
    executable_signature = next((item for item in audit.get('binaries', [])
                                 if item['path'] == 'Contents/MacOS/Horos'), {})
    add('Signing')
    add('  ad hoc (no certificate, no Team ID), hardened runtime; inside out: embedded libraries,')
    add('  frameworks, Quick Look extensions (app sandbox), helpers in Resources, then the app')
    add('  app entitlements: %s' % (', '.join(executable_signature.get('entitlements', [])) or '?'))
    add('  disable-library-validation is part of this local ad hoc signature only, not of Horos.entitlements')
    add('  NOT signed with Developer ID, NOT notarized, NOT stapled: Gatekeeper on another Mac does')
    add('  not approve this artifact. Nothing was published or sent to Apple.')
    add('')
    add('Audit (tools/audit-release-bundle.py --strict --notices)')
    add('  Mach-O files: %s, architectures: %s' % (audit.get('binaryCount', '?'),
                                                ' '.join(audit.get('architectures', [])) or '?'))
    add('  loaded from outside the bundle and the macOS: %d; missing: %d; unsigned: %d' % (
        len(audit.get('external', [])), len(audit.get('missing', [])), len(audit.get('unsigned', []))))
    add('  codesign --verify --deep --strict: %s' % ('passed' if audit.get('signatureValid') else 'failed'))
    add('  notices and licenses: %s' % ('present' if not audit.get('missingNotices') else
                                        'missing ' + ', '.join(audit['missingNotices'])))
    add('')
    add('SHA-256')
    executable = app / 'Contents/MacOS' / info.get('CFBundleExecutable', 'Horos')
    add('  %s  Horos.app/Contents/MacOS/%s' % (sha256(executable), executable.name))
    for library in sorted((app / 'Contents/Frameworks').glob('*.dylib')):
        if library.is_file() and not library.is_symlink():
            add('  %s  Horos.app/Contents/Frameworks/%s' % (sha256(library), library.name))
    add('  every file of the bundle: SHA256SUMS.txt (shasum -a 256 -c SHA256SUMS.txt)')

    text = '\n'.join(lines) + '\n'
    for forbidden in (str(Path.home()), '/Users/', 'horos-workbench'):
        if forbidden in text:
            sys.exit('error: BUILD-INFO.txt would name %s' % forbidden)
    (staging / 'BUILD-INFO.txt').write_text(text)

    sums = []
    for path in sorted(app.rglob('*')):
        if path.is_file() and not path.is_symlink():
            sums.append('%s  %s' % (sha256(path), path.relative_to(staging).as_posix()))
    sums.append('%s  BUILD-INFO.txt' % sha256(staging / 'BUILD-INFO.txt'))
    (staging / 'SHA256SUMS.txt').write_text('\n'.join(sums) + '\n')
    print('BUILD-INFO.txt and SHA256SUMS.txt: %d files' % (len(sums)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-packages', action='store_true',
                        help='check the approved lockfile against effective public SwiftPM checkouts')
    parser.add_argument('--stage-package-notices', action='store_true',
                        help='copy license/provenance materials from effective public checkouts before signing')
    parser.add_argument('--public-source-ref', help='full public Horos branch/tag ref matching the build source')
    parser.add_argument('root', type=Path)
    parser.add_argument('paths', nargs='+', type=Path)
    args = parser.parse_args()
    try:
        if args.stage_package_notices:
            if len(args.paths) != 2:
                parser.error('--stage-package-notices requires ROOT SOURCE_PACKAGES APP')
            records = verified_swift_packages(args.root, args.paths[0])
            check_package_notices(records, args.paths[1], stage=True)
        elif args.verify_packages:
            if len(args.paths) != 1:
                parser.error('--verify-packages requires ROOT SOURCE_PACKAGES')
            records = verified_swift_packages(args.root, args.paths[0])
            print('Verified effective public Swift packages: %d' % len(records))
        else:
            if len(args.paths) != 4:
                parser.error('requires ROOT TEMP_DIR STAGING_DIR AUDIT_JSON SOURCE_PACKAGES')
            write_metadata(args.root, *args.paths, public_source_ref=args.public_source_ref)
    except (ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
        # Errors describe the contract, never dump workspace/remote data.
        if isinstance(error, ValueError):
            sys.exit('error: ' + str(error))
        if isinstance(error, OSError):
            sys.exit('error: could not verify effective release inputs: ' + (error.strerror or 'filesystem failure'))
        if isinstance(error, KeyError):
            sys.exit('error: could not verify effective release input schema')
        sys.exit('error: could not verify effective release inputs')


if __name__ == '__main__':
    main()
