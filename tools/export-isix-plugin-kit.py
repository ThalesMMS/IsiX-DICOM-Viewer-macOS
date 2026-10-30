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
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'IsiXPluginKit'
NAME = 'IsiXPluginKit'
INSTALL_NAME = f'@rpath/{NAME}.framework/Versions/A/{NAME}'
MINIMUM_SYSTEM = '15.0'
HOST_ONLY = ('.private.swiftinterface', '.package.swiftinterface', '.swiftmodule', '.abi.json', '.swiftsourceinfo')


def sources():
    return sorted((KIT / 'Sources').glob('*.swift'))


def api_version():
    text = (KIT / 'Sources' / 'IsiXPlugin.swift').read_text()
    return int(re.search(r'public let IsiXPluginAPIVersion: Int = (\d+)', text).group(1))


def kit_version():
    info = plistlib.loads((KIT / 'Info.plist').read_bytes())
    return info['CFBundleShortVersionString']


def revision():
    result = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    revision = result.stdout.strip() if result.returncode == 0 else 'unknown'
    dirty = subprocess.run(['git', '-C', str(ROOT), 'status', '--porcelain', '--', 'IsiXPluginKit'],
                           capture_output=True, text=True).stdout.strip()
    return revision + ('+modified' if dirty else '')


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
    arguments = parser.parse_args()
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
    print(json.dumps(description, indent=2))


if __name__ == '__main__':
    main()
