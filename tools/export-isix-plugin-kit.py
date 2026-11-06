#!/usr/bin/env python3
"""Export the IsiXPluginKit SDK: the framework a plugin compiles and links against.

The SDK is the IsiXPluginKit.framework the application embeds, without what is
for the application only: the private module interface (the host's SPI), the
compiled .swiftmodule files, which only the exact compiler that wrote them can
read, the ABI and source-info dumps and the code signature, which the removals
would break. A plugin compiles against the textual .swiftinterface and links the
binary; at run time it uses the copy inside the application, never this one.

    tools/export-isix-plugin-kit.py --xcode Release --output <folder> [--archs arm64,x86_64]
        builds the IsiXPluginKit target of Horos.xcodeproj alone and exports it;
    tools/export-isix-plugin-kit.py --framework <built IsiXPluginKit.framework> --output <folder>
        exports a framework already built, such as the one in build/Build/Products/Debug;
    tools/export-isix-plugin-kit.py --swiftc --output <folder> [--archs ...] [--keep-host-interface]
        compiles the sources with swiftc, for tests that run without Xcode's build.

The SDK is published from --xcode Release with both architectures, the build
a release ships. --framework takes the framework Xcode built, in
build/Build/Products/<configuration>, never the copy embedded in an
application: Xcode leaves the Modules folder out when it embeds a framework,
so that copy has no .swiftinterface to export, and is refused as such.

<folder> receives IsiXPluginKit.framework and SDK.json (API version, kit
version, source revision, architectures, compiler, and the SHA-256 of the
binary and of each module interface, to check a published copy against).

    tools/export-isix-plugin-kit.py --xcode Release --output <folder> --zip <path>/IsiXPluginKit-SDK-<version>.zip
        also makes the SDK a release publishes, as script/build_release.sh does.

With --zip, <folder> also receives what a release's SDK carries besides the
framework: LegacyPorting/, the porting kit for Horos and OsiriX plugins, laid
out and described as the plugin template's script/sdk.py export lays it out
(LICENSE, IsiXLegacyBridge/ with its symbolic links, IsiXPluginKit/README.md
and the three tools/ scripts that inventory, convert and build such a plugin,
with PORTING.json: the source revision and, for each entry, its SHA-256 or
`symlink:<target>`); the application's LICENSE, COPYING, COPYING.LESSER and
NOTICE; and README.md, the kit's documentation. The zip holds those entries
under one folder named after the zip, symbolic links stored as links, without
AppleDouble `._` files, `__MACOSX/` or `.DS_Store`, with normalized
permissions and the date of the source revision.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'IsiXPluginKit'
NAME = 'IsiXPluginKit'
INSTALL_NAME = f'@rpath/{NAME}.framework/Versions/A/{NAME}'
MINIMUM_SYSTEM = '15.0'
HOST_ONLY = ('.private.swiftinterface', '.package.swiftinterface', '.swiftmodule', '.abi.json', '.swiftsourceinfo')

# The porting kit for Horos and OsiriX plugins, and the scripts that use it, as
# the plugin template's script/sdk.py exports them into <SDK>/LegacyPorting:
# the same sources, the same layout (the converter finds the kit at
# ../IsiXLegacyBridge from its own folder, and the kit's README links
# ../IsiXPluginKit/README.md) and the same manifest, so that the template's
# `check --require-porting` accepts the folder a release publishes. LICENSE
# goes with them: part of the kit derives from Horos and OsiriX, and that file
# carries their notice.
PORTING = 'LegacyPorting'
PORTING_MANIFEST = 'PORTING.json'
PORTING_SOURCES = ('LICENSE', 'IsiXLegacyBridge', 'IsiXPluginKit/README.md', 'tools/port-legacy-plugin.py',
                   'tools/build-isix-legacy-plugin.py', 'tools/inventory-plugin-api.py')
# What else a release's SDK carries: the application's license and notices, and
# the kit's documentation as README.md.
NOTICES = ('LICENSE', 'COPYING', 'COPYING.LESSER', 'NOTICE')
README = 'IsiXPluginKit/README.md'
# Finder, and copies through other file systems, leave these beside the files.
# They are neither copied, listed in PORTING.json nor zipped.
IGNORED = ('.DS_Store', '__pycache__', '__MACOSX')


def ignored(name):
    return name in IGNORED or name.startswith('._')


def sources():
    return sorted((KIT / 'Sources').glob('*.swift'))


def api_version():
    text = (KIT / 'Sources' / 'IsiXPlugin.swift').read_text()
    return int(re.search(r'public let IsiXPluginAPIVersion: Int = (\d+)', text).group(1))


def kit_version():
    info = plistlib.loads((KIT / 'Info.plist').read_bytes())
    return info['CFBundleShortVersionString']


def revision(paths=('IsiXPluginKit',)):
    """The checkout's commit, with +modified when `paths` differ from it."""
    result = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    revision = result.stdout.strip() if result.returncode == 0 else 'unknown'
    dirty = subprocess.run(['git', '-C', str(ROOT), 'status', '--porcelain', '--', *paths],
                           capture_output=True, text=True).stdout.strip()
    return revision + ('+modified' if dirty else '')


def revision_time():
    """The commit date of the checkout: the date of every entry of a zip made from it."""
    result = subprocess.run(['git', '-C', str(ROOT), 'log', '-1', '--format=%ct'], capture_output=True, text=True)
    return int(result.stdout.strip()) if result.returncode == 0 and result.stdout.strip() else int(time.time())


def compiler():
    return subprocess.run(['xcrun', 'swiftc', '--version'], capture_output=True, text=True).stdout.strip().splitlines()[0]


def make_framework_skeleton(framework):
    """The versioned layout of a macOS framework, with its symbolic links."""
    version = framework / 'Versions' / 'A'
    (version / 'Modules' / f'{NAME}.swiftmodule').mkdir(parents=True, exist_ok=True)
    (version / 'Resources').mkdir(parents=True, exist_ok=True)
    links = {'Versions/Current': 'A', NAME: f'Versions/Current/{NAME}',
             'Modules': 'Versions/Current/Modules', 'Resources': 'Versions/Current/Resources'}
    for link, target in links.items():
        path = framework / link
        if not path.is_symlink():
            path.symlink_to(target)
    return version


def compile_framework(folder, archs, include_host_interface=True, extra=()):
    """IsiXPluginKit.framework in `folder`, compiled with swiftc for `archs`,
    with the private interface and binary modules unless told otherwise."""
    folder = Path(folder)
    framework = folder / f'{NAME}.framework'
    if framework.exists():
        shutil.rmtree(framework)
    version = make_framework_skeleton(framework)
    module = version / 'Modules' / f'{NAME}.swiftmodule'
    with tempfile.TemporaryDirectory() as scratch:
        thin = []
        for arch in archs:
            triple = f'{arch}-apple-macos'
            binary = Path(scratch) / f'{NAME}-{arch}'
            command = ['xcrun', 'swiftc', '-module-name', NAME, '-parse-as-library', '-swift-version', '6',
                       '-enable-library-evolution', '-emit-library', '-O',
                       '-target', f'{arch}-apple-macos{MINIMUM_SYSTEM}',
                       '-emit-module-interface-path', str(module / f'{triple}.swiftinterface'),
                       '-Xlinker', '-install_name', '-Xlinker', INSTALL_NAME,
                       '-o', str(binary)]
            if include_host_interface:
                command += ['-emit-private-module-interface-path', str(module / f'{triple}.private.swiftinterface'),
                            '-emit-module-path', str(module / f'{triple}.swiftmodule')]
            subprocess.run(command + list(extra) + [str(p) for p in sources()], check=True, cwd=scratch)
            thin.append(str(binary))
        subprocess.run(['xcrun', 'lipo', '-create', *thin, '-output', str(version / NAME)], check=True)
    info = plistlib.loads((KIT / 'Info.plist').read_bytes())
    info.update({'CFBundleExecutable': NAME, 'CFBundleIdentifier': 'thalesmms.isix.IsiXPluginKit', 'CFBundleName': NAME,
                 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': info.get('CFBundleShortVersionString', '1'),
                 'LSMinimumSystemVersion': MINIMUM_SYSTEM})
    (version / 'Resources' / 'Info.plist').write_bytes(plistlib.dumps(info))
    return framework


def strip_host_only(framework):
    """Removes from a framework what plugins must not compile against."""
    framework = Path(framework)
    for path in sorted(framework.rglob('*'), reverse=True):
        if path.is_symlink():
            continue
        if path.is_dir() and path.name in ('Project', '_CodeSignature'):
            shutil.rmtree(path)
        elif path.is_file() and path.name.endswith(HOST_ONLY):
            path.unlink()
    headers = framework / 'Versions' / 'A' / 'Headers'
    if headers.exists():
        # The Objective-C header Xcode generates for Swift: plugins use the Swift module.
        shutil.rmtree(headers)
        link = framework / 'Headers'
        if link.is_symlink():
            link.unlink()


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def architectures(binary):
    return subprocess.run(['xcrun', 'lipo', '-archs', str(binary)], capture_output=True, text=True,
                          check=True).stdout.split()


def embedding_bundle(framework):
    """The application or bundle `framework` is embedded in, or None."""
    parts = Path(framework).resolve().parts
    for index in range(len(parts) - 2, 0, -1):
        if parts[index] == 'Frameworks' and parts[index - 1] == 'Contents' and index >= 2:
            return Path(*parts[:index - 1])
    return None


def missing_interface(framework):
    """Why `framework` has no public .swiftinterface to export, or None when it has one."""
    framework = Path(framework)
    module = framework / 'Versions' / 'A' / 'Modules' / f'{NAME}.swiftmodule'
    if any(not p.name.endswith(HOST_ONLY) for p in module.glob('*.swiftinterface')):
        return None
    container = embedding_bundle(framework)
    if container is not None or not (framework / 'Versions' / 'A' / 'Modules').exists():
        where = f'the copy embedded in {container}' if container else 'a framework without its Modules folder'
        return (f'{framework}: no .swiftinterface; this is {where}. Xcode leaves Modules out when it embeds a '
                f'framework in an application. Export the framework Xcode built instead, '
                f'build/Build/Products/<configuration>/{NAME}.framework, or build one with --xcode Release, '
                f'the build an SDK is published from.')
    return f'{framework}: no .swiftinterface; build with BUILD_LIBRARY_FOR_DISTRIBUTION = YES'


def configuration_of(framework):
    """Debug or Release when `framework` is a product of Xcode's build, else 'prebuilt'."""
    parent = Path(framework).resolve().parent
    if parent.parent.name == 'Products' and parent.name in ('Debug', 'Release'):
        return parent.name
    return 'prebuilt'


def export(framework, output, configuration):
    problem = missing_interface(framework)
    if problem:
        raise SystemExit(problem)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    target = output / f'{NAME}.framework'
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(framework, target, symlinks=True)
    strip_host_only(target)
    module = target / 'Modules' / f'{NAME}.swiftmodule'
    interfaces = sorted(p.name for p in module.glob('*.swiftinterface'))
    description = {
        'name': NAME,
        'apiVersion': api_version(),
        'kitVersion': kit_version(),
        'revision': revision(),
        'configuration': configuration,
        'architectures': architectures(target / NAME),
        'interfaces': interfaces,
        'minimumSystem': MINIMUM_SYSTEM,
        'compiler': compiler(),
        'installName': INSTALL_NAME,
        'binarySHA256': sha256(target / 'Versions' / 'A' / NAME),
        'interfaceSHA256': {name: sha256(module / name) for name in interfaces},
    }
    (output / 'SDK.json').write_text(json.dumps(description, indent=2) + '\n')
    return target, description


def porting_entries(root):
    """{relative path: SHA-256 of a file, or 'symlink:<target>'} under root, as PORTING.json lists them."""
    entries = {}
    for path in sorted(Path(root).rglob('*')):
        relative = path.relative_to(root)
        if any(ignored(part) for part in relative.parts):
            continue
        if path.is_symlink():
            entries[relative.as_posix()] = f'symlink:{os.readlink(path)}'
        elif path.is_file():
            entries[relative.as_posix()] = sha256(path)
    return entries


def export_porting(output, source=ROOT):
    """Copies the porting kit and its scripts into <output>/LegacyPorting, with PORTING.json."""
    source, destination = Path(source), Path(output) / PORTING
    missing = [name for name in PORTING_SOURCES if not (source / name).exists()]
    if missing:
        raise SystemExit(f'{source} has no {", ".join(missing)}: the porting kit cannot be exported')
    if destination.exists():
        shutil.rmtree(destination)
    for name in PORTING_SOURCES:
        origin, target = source / name, destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if origin.is_dir():
            shutil.copytree(origin, target, symlinks=True,
                            ignore=lambda folder, names: [n for n in names if ignored(n)])
        else:
            shutil.copy2(origin, target)
    manifest = {'revision': revision(PORTING_SOURCES), 'files': porting_entries(destination)}
    (destination / PORTING_MANIFEST).write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return manifest


def check_porting(folder):
    """What differs between a LegacyPorting folder and its PORTING.json, as a list; empty when nothing."""
    folder = Path(folder)
    try:
        manifest = json.loads((folder / PORTING_MANIFEST).read_text())
    except (OSError, ValueError) as error:
        return [f'{PORTING_MANIFEST} cannot be read: {error}']
    present = porting_entries(folder)
    present.pop(PORTING_MANIFEST, None)
    expected = manifest.get('files', {})
    return ([f'{p} changed or missing' for p in sorted(expected) if present.get(p) != expected[p]]
            + [f'{p} not listed' for p in sorted(present) if p not in expected])


def release_entries(output, source=ROOT):
    """Puts in <output> what a release's SDK carries besides the framework and SDK.json.

    Returns the top-level names the zip holds."""
    output = Path(output)
    export_porting(output, source)
    for name in NOTICES:
        shutil.copy2(Path(source) / name, output / name)
    shutil.copy2(Path(source) / README, output / 'README.md')
    return sorted([f'{NAME}.framework', 'SDK.json', PORTING, 'README.md', *NOTICES])


def zip_info(name, mode, date_time):
    info = zipfile.ZipInfo(name, date_time)
    info.create_system = 3  # Unix: unzip and ditto take the type and permissions from external_attr
    info.external_attr = mode << 16
    if stat.S_ISDIR(mode):
        info.external_attr |= 0x10  # the MS-DOS directory flag
    return info


def write_zip(folder, names, archive, timestamp=None):
    """Writes `archive` with the entries `names` of `folder`, under a top folder named after the zip.

    Folders, files and symbolic links, each dated `timestamp` (by default the
    source revision's) with a normalized mode, 0755 or 0644. Links are stored as
    links, their target as content, which unzip and ditto restore as links.
    Nothing `ignored` names goes in. The zip is written beside `archive` and
    renamed into place.
    """
    folder, archive = Path(folder), Path(archive)
    top = archive.name[:-len('.zip')] if archive.name.endswith('.zip') else archive.name
    stamp = time.localtime(revision_time() if timestamp is None else timestamp)
    date_time = max(tuple(stamp[:6]), (1980, 1, 1, 0, 0, 0))

    def add(bundle, path, name):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            bundle.writestr(zip_info(name, stat.S_IFLNK | 0o755, date_time), os.readlink(path),
                            compress_type=zipfile.ZIP_STORED)
        elif stat.S_ISDIR(mode):
            bundle.writestr(zip_info(name + '/', stat.S_IFDIR | 0o755, date_time), b'',
                            compress_type=zipfile.ZIP_STORED)
            for child in sorted(os.listdir(path)):
                if not ignored(child):
                    add(bundle, path / child, f'{name}/{child}')
        elif stat.S_ISREG(mode):
            permissions = 0o755 if mode & 0o111 else 0o644
            bundle.writestr(zip_info(name, stat.S_IFREG | permissions, date_time), path.read_bytes(),
                            compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        else:
            raise SystemExit(f'{path}: neither a file, a folder nor a symbolic link')

    archive.parent.mkdir(parents=True, exist_ok=True)
    handle, partial = tempfile.mkstemp(prefix=f'.{archive.name}.', dir=archive.parent)
    os.close(handle)
    try:
        with zipfile.ZipFile(partial, 'w') as bundle:
            bundle.writestr(zip_info(top + '/', stat.S_IFDIR | 0o755, date_time), b'',
                            compress_type=zipfile.ZIP_STORED)
            for name in sorted(names):
                if not ignored(name):
                    add(bundle, Path(folder) / name, f'{top}/{name}')
        os.chmod(partial, 0o644)
        os.replace(partial, archive)
    finally:
        if os.path.exists(partial):
            os.unlink(partial)
    return archive


def build_with_xcode(configuration, archs, scratch):
    command = ['xcodebuild', '-project', str(ROOT / 'Horos.xcodeproj'), '-target', NAME,
               '-configuration', configuration, f'ARCHS={" ".join(archs)}', 'ONLY_ACTIVE_ARCH=NO',
               f'SYMROOT={scratch}/Products', f'OBJROOT={scratch}/Intermediates', 'CODE_SIGNING_ALLOWED=NO']
    log = Path(scratch) / 'xcodebuild.log'
    with open(log, 'w') as handle:
        if subprocess.run(command, stdout=handle, stderr=subprocess.STDOUT).returncode != 0:
            sys.stderr.write(log.read_text()[-4000:])
            raise SystemExit('xcodebuild failed')
    return Path(scratch) / 'Products' / configuration / f'{NAME}.framework'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--xcode', metavar='CONFIGURATION', choices=('Debug', 'Release'))
    mode.add_argument('--framework', type=Path)
    mode.add_argument('--swiftc', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--archs', default='arm64,x86_64')
    parser.add_argument('--keep-host-interface', action='store_true',
                        help='with --swiftc: also leave a copy with the private interface in <output>/host')
    parser.add_argument('--zip', type=Path, metavar='FILE.zip',
                        help='also put the porting kit, the license files and README.md in <output>, and write '
                             'the SDK a release publishes to FILE.zip')
    arguments = parser.parse_args()
    if arguments.zip and not arguments.zip.name.endswith('.zip'):
        parser.error('--zip takes the path of a .zip file')
    archs = [a for a in arguments.archs.split(',') if a]
    with tempfile.TemporaryDirectory() as scratch:
        if arguments.xcode:
            framework, configuration = build_with_xcode(arguments.xcode, archs, scratch), arguments.xcode
        elif arguments.framework:
            framework, configuration = arguments.framework, configuration_of(arguments.framework)
        else:
            host = arguments.output / 'host' if arguments.keep_host_interface else Path(scratch)
            framework, configuration = compile_framework(host, archs), 'swiftc'
        _, description = export(framework, arguments.output, configuration)
    if arguments.zip:
        write_zip(arguments.output, release_entries(arguments.output), arguments.zip)
        description = dict(description, zip=str(arguments.zip), zipSHA256=sha256(arguments.zip))
    print(json.dumps(description, indent=2))


if __name__ == '__main__':
    main()
