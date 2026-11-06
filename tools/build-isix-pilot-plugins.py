#!/usr/bin/env python3
"""Build the pilot plugins of Plugins/Pilots against an exported SDK.

    tools/build-isix-pilot-plugins.py --sdk <folder with IsiXPluginKit.framework> --output <folder>
        [--arch arm64|x86_64|universal] [--pilot InvertData ...]

Writes <output>/<Pilot>.isixplugin for each pilot (all of them by default),
signed ad hoc, linking the SDK's IsiXPluginKit and carrying no copy of it.
Each pilot is a folder of its own with an Info.plist and Sources/*.swift, and
uses IsiXPluginKit only. The application's build never builds them and they
are not part of the application bundle; the pilot test and the in-app check
call this script.
"""
from pathlib import Path
import argparse
import importlib.util
import sys

ROOT = Path(__file__).resolve().parents[1]
PILOTS = ROOT / 'Plugins' / 'Pilots'

spec = importlib.util.spec_from_file_location('builder', Path(__file__).resolve().parent / 'build-isix-example-plugin.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def pilots():
    return sorted(p.name for p in PILOTS.iterdir() if (p / 'Info.plist').is_file())


def build(sdk, output, name, arch='arm64', **changes):
    """<output>/<name>.isixplugin; `changes` go to the example builder (info_changes, ...)."""
    return builder.build(sdk, output, arch, name=name, module=name, plugin=PILOTS / name, **changes)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', default='arm64', choices=('arm64', 'x86_64', 'universal'))
    parser.add_argument('--pilot', action='append', choices=pilots(), help='one pilot; repeat for several (all by default)')
    arguments = parser.parse_args()
    if not (arguments.sdk / 'IsiXPluginKit.framework').is_dir():
        sys.exit(f'{arguments.sdk}: no IsiXPluginKit.framework; export one with tools/export-isix-plugin-kit.py')
    arguments.output.mkdir(parents=True, exist_ok=True)
    for name in arguments.pilot or pilots():
        print(build(arguments.sdk, arguments.output, name, arguments.arch))


if __name__ == '__main__':
    main()
