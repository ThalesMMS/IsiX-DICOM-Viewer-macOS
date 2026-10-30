"""Compile the app's internal modules for a test that compiles app sources.

The app imports its internal modules (Modules/<Name>, see Modules/Package.swift)
the way it imports any Swift package. A test that compiles a slice of an app
source with swiftc or clang, rather than building the app, needs the module
the slice imports: `module_flags('IsiXStorage', folder)` compiles it once into
`folder` and returns the swiftc flags that import and link it;
`clang_module_flags` returns the clang flags for an Objective-C file that says
`@import IsiXStorage;`.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LOGGING = 'IsiXLogging'


def module_sources(name):
    return sorted((ROOT / 'Modules' / name / 'Sources').rglob('*.swift'))


def dependencies(name):
    """The internal modules `name` depends on, directly or not, as
    Modules/Package.swift declares them, those it depends on first."""
    text = (ROOT / 'Modules/Package.swift').read_text(encoding='utf-8')
    declared = re.search(r'\.target\(name: "%s", dependencies: \[([^\]]*)\]' % re.escape(name), text)
    found = []
    for dependency in re.findall(r'"(\w+)"', declared.group(1)) if declared else []:
        for each in dependencies(dependency) + [dependency]:
            if each not in found:
                found.append(each)
    return found


def build_module(name, folder, extra=()):
    """The static library and module of `name`, with its Objective-C header, in
    `folder`, and those of the internal modules it depends on beside them."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    library = folder / f'lib{name}.a'
    if not library.exists():
        imported = dependencies(name)
        for dependency in imported:
            build_module(dependency, folder, extra)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', name,
                        '-emit-library', '-static', '-emit-module', '-emit-module-path', str(folder / f'{name}.swiftmodule'),
                        '-emit-objc-header', '-emit-objc-header-path', str(folder / f'{name}-Swift.h'),
                        '-o', str(library), *extra, *(['-I', str(folder)] if imported else []),
                        *map(str, module_sources(name))],
                       check=True, cwd=folder)
        if LOGGING in imported:
            # Every module that logs writes through IsiXLogging, as the package
            # product carries it: its library carries it too, so a harness that
            # links the library alone still links. IsiXLogging defines no
            # Objective-C class, so a harness that links two such libraries
            # takes it from the first one and never loads it twice.
            subprocess.run(['xcrun', 'libtool', '-static', '-no_warning_for_no_symbols', '-o', str(library),
                            str(library), str(folder / f'lib{LOGGING}.a')], check=True, capture_output=True)
        # One module map for every module built in the folder.
        maps = folder / 'module.modulemap'
        entry = f'module {name} {{\n    header "{name}-Swift.h"\n    requires objc\n    export *\n}}\n'
        existing = maps.read_text() if maps.exists() else ''
        if f'module {name} {{' not in existing:
            maps.write_text(existing + entry)
    return library


def module_flags(name, folder, extra=()):
    """swiftc flags that import and link `name`, and the modules it depends on."""
    build_module(name, folder, extra)
    return ['-I', str(folder), '-L', str(folder), f'-l{name}', *(f'-l{each}' for each in dependencies(name))]


def clang_module_flags(name, folder, extra=()):
    """clang flags for an Objective-C file that imports `name`; link with link_flags."""
    build_module(name, folder, extra)
    return ['-fmodules', '-I', str(folder)]


def link_flags(name, folder):
    """Linker flags for the static library and those of the modules it depends
    on, with the Swift runtime they need."""
    return [str(Path(folder) / f'lib{each}.a') for each in [name] + dependencies(name)[::-1]] + ['-L/usr/lib/swift']


def dicom_file_flags(folder):
    """For an Objective-C++ harness that compiles an adapter importing
    "IsiXDICOMFile-Swift.h" (the DICOM tag, date and character set types):
    the clang flags that find the header, and the linker flags for the module,
    the modules below it and the Swift runtime."""
    folder = Path(folder)
    target = ['-target', 'arm64-apple-macos15.0']
    build_module('IsiXImaging', folder, target)
    build_module('IsiXDICOMFile', folder, [*target, '-I', str(folder)])
    toolchain = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parents[1]
    return (['-I', str(folder)],
            [str(folder / f'lib{each}.a') for each in ['IsiXDICOMFile'] + dependencies('IsiXDICOMFile')[::-1]]
            + ['-L/usr/lib/swift', '-L' + str(toolchain / 'lib/swift/macosx'), '-Wl,-rpath,/usr/lib/swift'])


def module_driver(name, main, output, extra=()):
    """An executable of `main` (Swift top-level code) compiled in one module
    with the sources of `name`, so that it reaches the module's internal
    functions, and linked with the modules `name` depends on, built beside
    `output`. `extra` goes to swiftc (-sanitize=address, say)."""
    output = Path(output)
    folder = output.parent / 'modules'
    target = ['-target', 'arm64-apple-macos15.0']
    for dependency in dependencies(name):
        build_module(dependency, folder, target)
    driver = output.parent / 'main.swift'
    driver.write_text(main)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', name + 'Driver', *target, *extra,
                    '-I', str(folder), '-L', str(folder), *(f'-l{each}' for each in dependencies(name)),
                    *map(str, module_sources(name)), str(driver), '-o', str(output)],
                   check=True, capture_output=True, text=True)
    return output


def module_names():
    """The internal modules, as folders of Modules/ with sources."""
    return sorted(path.parent.name for path in (ROOT / 'Modules').glob('*/Sources') if path.is_dir())


def objc_class_names(name):
    """The Objective-C names of the classes module `name` exposes."""
    names = set()
    for path in module_sources(name):
        names.update(re.findall(r'@objc\((IsiX\w+)\)', path.read_text(encoding='utf-8')))
    return names


def object_link_flags(obj, folder):
    """For an object compiled from an app source: swiftc flags that link the
    internal modules it refers to, and the Objective-C classes those define,
    which a probe must not stub."""
    listing = subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
    referenced = set(re.findall(r'_OBJC_CLASS_\$_(\w+)', listing))
    flags, classes = [], set()
    for name in module_names():
        defined = objc_class_names(name)
        # A Swift object names a module's types and functions by their mangled names.
        if defined & referenced or f'_$s{len(name)}{name}' in listing:
            # One folder for all: modules built with their dependencies beside
            # them, in folders of their own, would map one module twice.
            flags += module_flags(name, Path(folder))
            classes |= defined
    return flags, classes
