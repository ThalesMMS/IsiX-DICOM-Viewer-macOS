#!/usr/bin/env python3
"""Build the version 1 example plugin, Examples/IsiXPluginExample, against an exported SDK.

    tools/build-isix-example-plugin.py --sdk <folder with IsiXPluginKit.framework> --output <folder>
        [--arch arm64|x86_64] [--name IsiXPluginExample] [--principal-class <name>] [--info KEY=JSON ...]

Writes <output>/<name>.isixplugin, signed ad hoc. The bundle links the SDK's
IsiXPluginKit by its install name and carries no copy of it: the application
provides the framework at run time. The application's own build never builds
this; the plugin tests and the in-app check call this script.

--principal-class and --info change the Info.plist, for tests that need a
bundle with a wrong entry or metadata; --source adds or replaces sources.
"""
from pathlib import Path
import argparse
import json
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / 'Examples' / 'IsiXPluginExample'
MINIMUM_SYSTEM = '15.0'


def build(sdk, output, arch='arm64', name='IsiXPluginExample', module='IsiXPluginExample',
          principal_class=None, info_changes=None, sources=None, link_kit=True, extra=(), plugin=EXAMPLE):
    """<output>/<name>.isixplugin from `plugin`, a folder with an Info.plist and
    Sources/*.swift (the example by default). `arch` is arm64, x86_64 or
    universal (both, joined with lipo)."""
    sdk, output, plugin = Path(sdk), Path(output), Path(plugin)
    bundle = output / f'{name}.isixplugin'
    if bundle.exists():
        shutil.rmtree(bundle)
    macos = bundle / 'Contents' / 'MacOS'
    macos.mkdir(parents=True)
    info = plistlib.loads((plugin / 'Info.plist').read_bytes())
    info['CFBundleExecutable'] = module
    if principal_class is not None:
        info['NSPrincipalClass'] = principal_class
    for key, value in (info_changes or {}).items():
        if value is None:
            info.pop(key, None)
        else:
            info[key] = value
    (bundle / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
    files = [str(p) for p in (sources or sorted((plugin / 'Sources').glob('*.swift')))]
    slices = []
    for slice_arch in (('arm64', 'x86_64') if arch == 'universal' else (arch,)):
        binary = macos / (module if arch != 'universal' else f'{module}-{slice_arch}')
        command = ['xcrun', 'swiftc', '-module-name', module, '-parse-as-library', '-swift-version', '6',
                   '-target', f'{slice_arch}-apple-macos{MINIMUM_SYSTEM}', '-Xlinker', '-bundle',
                   '-o', str(binary), *extra, *files]
        if link_kit:
            command[2:2] = ['-F', str(sdk), '-framework', 'IsiXPluginKit']
        subprocess.run(command, check=True)
        slices.append(binary)
    if arch == 'universal':
        subprocess.run(['xcrun', 'lipo', '-create', *map(str, slices), '-output', str(macos / module)], check=True)
        for binary in slices:
            binary.unlink()
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', default='arm64', choices=('arm64', 'x86_64', 'universal'))
    parser.add_argument('--name', default='IsiXPluginExample')
    parser.add_argument('--principal-class')
    parser.add_argument('--info', action='append', default=[], metavar='KEY=JSON',
                        help='set an Info.plist key to a JSON value (null removes it)')
    arguments = parser.parse_args()
    if not (arguments.sdk / 'IsiXPluginKit.framework').is_dir():
        sys.exit(f'{arguments.sdk}: no IsiXPluginKit.framework; export one with tools/export-isix-plugin-kit.py')
    changes = {}
    for item in arguments.info:
        key, _, value = item.partition('=')
        changes[key] = json.loads(value)
    bundle = build(arguments.sdk, arguments.output, arguments.arch, arguments.name,
                   principal_class=arguments.principal_class, info_changes=changes)
    print(bundle)


if __name__ == '__main__':
    main()
