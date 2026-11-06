"""Build Nitrogen's N3 geometry for a test that links it.

The N3 geometry (N3Geometry.h, N3BezierCore.h, N3BezierCoreAdditions.h and
N3BezierPath.h) is Swift: the module IsiXGeometry, and the Nitrogen files
that give it its C functions and Objective-C classes (Nitrogen/Sources/N3*.swift).
`build(folder, configuration)` compiles both into static libraries in
`folder`, with the headers beside them, and answers the flags a clang
compilation needs to include the headers, and those its link needs.

`build_reference(folder, revision, configuration)` compiles instead the
Objective-C N3 files of an earlier revision, read from git, with their
headers, for the tests that compare the two.

Debug is the app's Debug (Swift -Onone, Objective-C -O0), Release its Release
(Swift -O, Objective-C -O3 -DNDEBUG); IsiXGeometry itself is -O in both, as
Modules/Package.swift compiles it.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TARGET = ['-target', 'arm64-apple-macos15.0']
HEADERS = ('N3Geometry.h', 'N3BezierCore.h', 'N3BezierCoreAdditions.h', 'N3BezierPath.h')
NAMES = ('N3Geometry', 'N3BezierCore', 'N3BezierCoreAdditions', 'N3BezierPath')
SWIFT_FLAGS = {'debug': ['-Onone', '-D', 'DEBUG'], 'release': ['-O']}
OBJC_FLAGS = {'debug': ['-O0'], 'release': ['-O3', '-DNDEBUG']}
FRAMEWORKS = ['-framework', 'Cocoa', '-framework', 'QuartzCore', '-framework', 'Accelerate']


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=600, **kwargs)
    if result.returncode:
        raise RuntimeError('%s\n%s%s' % (' '.join(map(str, command)), result.stdout, result.stderr))
    return result


def swift_runtime_flags():
    toolchain = Path(run(['xcrun', '--find', 'swiftc']).stdout.strip()).parents[1]
    return ['-L/usr/lib/swift', '-L' + str(toolchain / 'lib/swift/macosx'), '-Wl,-rpath,/usr/lib/swift']


def build(folder, configuration='debug', headers=None):
    """Compiles IsiXGeometry and Nitrogen's N3 Swift files in `folder`, with
    the headers of this checkout (or those of `headers`). Answers (clang
    flags, clang link flags); a link through swiftc takes libraries(folder)."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    include = folder / 'include'
    include.mkdir(exist_ok=True)
    for name in HEADERS:
        source = Path(headers or ROOT / 'Nitrogen/Sources') / name
        (include / name).write_bytes(source.read_bytes())
    swift = SWIFT_FLAGS[configuration]
    module = folder / 'libIsiXGeometry.a'
    if not module.exists():
        # -O, as Modules/Package.swift compiles IsiXGeometry in every configuration.
        run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-O', *TARGET, '-module-name', 'IsiXGeometry',
             '-emit-library', '-static', '-emit-module', '-emit-module-path', str(folder / 'IsiXGeometry.swiftmodule'),
             '-o', str(module), *map(str, sorted((ROOT / 'Modules/IsiXGeometry/Sources').glob('*.swift')))])
    library = folder / 'libN3Geometry.a'
    if not library.exists():
        bridge = folder / 'N3Bridge.h'
        bridge.write_text('#import <Cocoa/Cocoa.h>\n' + ''.join(f'#import "{name}"\n' for name in HEADERS))
        run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', *swift, *TARGET, '-module-name', 'N3Geometry',
             '-I', str(folder), '-import-objc-header', str(bridge), '-Xcc', '-I' + str(include),
             '-emit-library', '-static', '-o', str(library),
             *map(str, sorted((ROOT / 'Nitrogen/Sources').glob('N3*.swift')))])
    return ['-I', str(include)], [*libraries(folder), *FRAMEWORKS, *swift_runtime_flags()]


def libraries(folder):
    """The static libraries build(folder) made, for a link through swiftc,
    which adds the Swift runtime itself."""
    return [str(Path(folder) / 'libN3Geometry.a'), str(Path(folder) / 'libIsiXGeometry.a')]


def build_reference(folder, revision, configuration='debug'):
    """Compiles the N3 Objective-C of `revision` in `folder`. Answers (clang
    flags, link flags)."""
    folder = Path(folder)
    include = folder / 'include'
    include.mkdir(parents=True, exist_ok=True)
    objects = []
    for name in NAMES:
        for extension in ('.h', '.m'):
            (include / (name + extension)).write_bytes(
                subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{revision}:Nitrogen/Sources/{name}{extension}']))
        obj = folder / (name + '.o')
        run(['xcrun', 'clang', '-x', 'objective-c', *TARGET, '-include', 'Cocoa/Cocoa.h', '-fno-objc-arc', '-fvisibility=default',
             '-w', *OBJC_FLAGS[configuration], '-I', str(include), '-c', str(include / (name + '.m')), '-o', str(obj)])
        objects.append(str(obj))
    return ['-I', str(include)], [*objects, *FRAMEWORKS]
