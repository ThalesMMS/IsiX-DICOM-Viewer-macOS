#!/usr/bin/env python3
"""Swift is compiled without -ffast-math, and the CPR still generates the
bits of the Objective-C it replaced (#998).

Since #719 the Release configuration passed `-Xcc -ffast-math` to Swift, so
that the C samplers of CPRVolumeData.h inlined into Swift were compiled as the
Objective-C compiles them. swiftc then also marks every Swift function with
the fast-math attributes (`no-nans-fp-math`, `no-infs-fp-math`,
`unsafe-fp-math`, ...): with -O, `isFinite`, `isNaN` and `isInfinite` fold to
constants, and `a * b + c` is fused into one rounding, in all the Swift of the
app. The CPR's fill loops now call C functions of CPRVolumeData+CAPI.m, which
the target compiles with the Objective-C flags, and Swift has no fast-math.

Checked here:
- flags: no configuration of the project passes -ffast-math or -Ofast to
  Swift;
- probe: the NaN rectangle of the issue, compiled with swiftc -O and the
  Swift flags of the Horos target's Release and Debug, is not finite, and
  `a * b + c` is not fused; with -Xcc -ffast-math added, the probe tells;
- samplers: no Swift source calls the inline samplers of CPRVolumeData.h
  that compute (the ...ForSwift functions of CPRVolumeData+CAPI.m instead);
- CPR bits: the CPR generator, compiled as the target compiles it (Swift -O
  with the target's Swift flags, CPRVolumeData+CAPI.m with its per-file flags,
  Nitrogen with the Objective-C flags), generates the same bytes as the
  Objective-C classes of the public reference compiled the same way, in Release
  (-O3 -ffast-math) and Debug (-O0): straightened, stretched, transverse and
  oblique volumes, 3 interpolations x 4 projections x slabs, the path values
  and the volume's own samplers.

`<git revision>` as an optional argument reads the project and the Swift
sources from that revision, the negative control.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
REFERENCE = '4d46ba717f9dbd73265d0a9944e1d216f9d00736'


def source(path, rev=None):
    rev = rev or revision
    if rev:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{rev}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)
if subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{REFERENCE}^{{commit}}'], capture_output=True).returncode != 0:
    print(f'skipped: needs the reference revision {REFERENCE} in the history', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []
project = source('Horos.xcodeproj/project.pbxproj').decode()


def setting_values(text, name):
    """Every value of a build setting, a quoted string or a list, as one string each."""
    values = []
    for m in re.finditer(r'\b' + name + r' = (\((?:[^()]|\n)*?\)|"(?:[^"\\]|\\.)*"|[^;\n]+);', text):
        values.append(m.group(1))
    return values


# flags
for value in setting_values(project, 'OTHER_SWIFT_FLAGS') + setting_values(project, 'SWIFT_OPTIMIZATION_LEVEL'):
    if 'fast-math' in value or '-Ofast' in value:
        failures.append(f'flags: Swift is given fast math: {value}')


def target_configuration(name):
    m = re.search(r'/\* ' + name + r' configuration for PBXNativeTarget "Horos" \*/ = \{.*?buildSettings = \{(.*?)\n\t\t\t\};',
                  project, re.S)
    if not m:
        print(f'FAIL: no {name} configuration for the Horos target in the project')
        sys.exit(1)
    return m.group(1)


def swift_flags(configuration):
    flags = []
    for value in setting_values(target_configuration(configuration), 'OTHER_SWIFT_FLAGS'):
        value = value.strip('()')
        flags += [f.strip().strip(',').strip('"') for f in re.split(r'[\s,]+', value) if f.strip().strip(',').strip('"')]
    return [f for f in flags if f != '$(inherited)']


def per_file_flags(name):
    m = re.search(r'/\* ' + re.escape(name) + r' in Sources \*/ = \{isa = PBXBuildFile;[^\n]*?COMPILER_FLAGS = "([^"]*)"', project)
    return m.group(1).split() if m else []


SWIFT_FLAGS = {'release': ['-O', *swift_flags('Release')], 'debug': ['-O', '-D', 'DEBUG', *swift_flags('Debug')]}
# The Objective-C of the target: GCC_OPTIMIZATION_LEVEL, GCC_FAST_MATH and NDEBUG of the project.
OBJC_FLAGS = {'release': ['-O3', '-ffast-math', '-DNDEBUG'], 'debug': ['-O0']}
TARGET = ['-target', 'arm64-apple-macos26.0']

PROBE = r"""
import CoreGraphics
@inline(never) func keep(_ r: CGRect) -> Bool { r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite }
@inline(never) func fused(_ a: Double, _ b: Double, _ c: Double) -> Double { a * b + c }
let n = CommandLine.arguments.count > 5 ? 1.0 : CGFloat.nan
let a = CommandLine.arguments.count > 5 ? 2.0 : 1.0 + 0x1p-30
print(keep(CGRect(x: n, y: 0, width: 1, height: 1)), fused(a, a, -(1.0 + 0x1p-29)) != 0)
"""

DRIVER = r"""import Cocoa

// Writes every generated float, and a few values of the paths, to argv[1].
func unwrap<T>(_ x: T?) -> T { x! }
let outPath = CommandLine.arguments[1]
var out = Data()

func put(_ p: UnsafeRawPointer, _ n: Int) { out.append(p.assumingMemoryBound(to: UInt8.self), count: n) }
func putD(_ v: CGFloat) { var v = Double(v); put(&v, 8) }
func putV(_ v: N3Vector) { putD(v.x); putD(v.y); putD(v.z) }

// The driver itself does no floating-point arithmetic that the flags could
// round differently (a * b + c, a division by a constant): its inputs are the
// same bits whatever it is compiled with.
// A 72x64x40 volume, a smooth integer pattern plus noise in 1/256ths, with an
// oblique, anisotropic transform.
let W: UInt = 72, H: UInt = 64, D: UInt = 40
let count = Int(W * H * D)
let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
var seed: UInt32 = 12345
for z in 0..<Int(D) { for y in 0..<Int(H) { for x in 0..<Int(W) {
    seed = seed &* 1664525 &+ 1013904223
    let smooth = (x - 36) * (x - 36) / 3 - (y - 30) * (y - 20) / 2 + (z - 18) * (x - y) + 7 * z
    data[x + y * Int(W) + z * Int(W * H)] = Float(smooth) + Float(Int(seed >> 16) - 32768) / 256
}}}
// dicom -> pixel
var toPixel = N3AffineTransformMakeTranslation(-11.3, 7.9, -3.1)
toPixel = N3AffineTransformConcat(toPixel, N3AffineTransformMakeRotationAroundVector(0.37, N3VectorNormalize(N3VectorMake(0.3, -0.5, 1))))
toPixel = N3AffineTransformConcat(toPixel, N3AffineTransformMakeScale(1.25, 1.125, 0.75))
toPixel = N3AffineTransformConcat(toPixel, N3AffineTransformMakeTranslation(30.2, 28.6, 17.4))
let toDicom = N3AffineTransformInvert(toPixel)
func dicom(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> N3Vector { N3VectorApplyTransform(N3VectorMake(x, y, z), toDicom) }

let volume: CPRVolumeData = CPRVolumeData(floatBytesNoCopy: data, pixelsWide: W, pixelsHigh: H, pixelsDeep: D,
                                          volumeTransform: toPixel, outOfBoundsValue: -1024, freeWhenDone: false)

func putVolume(_ v: CPRVolumeData?) {
    guard let v = v else { var z: UInt32 = 0xdeadbeef; put(&z, 4); return }
    var ib = CPRVolumeDataInlineBuffer()
    if v.aquireInlineBuffer(&ib) {
        let n = Int(ib.pixelsWide * ib.pixelsHigh * ib.pixelsDeep)
        var dims = [UInt64(ib.pixelsWide), UInt64(ib.pixelsHigh), UInt64(ib.pixelsDeep)]
        put(&dims, 24)
        put(ib.floatBytes!, n * 4)
        var t = ib.volumeTransform
        put(&t, MemoryLayout<N3AffineTransform>.size)
    }
#if OBJC_REF
    v.release(&ib)
#else
    v.releaseInlineBuffer(&ib)
#endif
}

func makePaths() -> [CPRCurvedPath] {
    let nodeSets: [[(CGFloat, CGFloat, CGFloat)]] = [
        [(5, 8, 4), (30, 20, 12), (60, 30, 30)],
        [(10, 50, 6), (20, 30, 10), (35, 25, 20), (50, 35, 28), (62, 55, 33)],
        [(4, 4, 2), (14, 30, 8), (26, 50, 12), (40, 44, 20), (48, 20, 24), (58, 10, 30), (66, 30, 34), (68, 58, 37)],
    ]
    return nodeSets.map { nodes in
        let path = unwrap(CPRCurvedPath())
        for n in nodes { path.addPatientNode(dicom(n.0, n.1, n.2)) }
        path.thickness = 3
        path.angle = 0.2
        path.transverseSectionSpacing = 4
        path.transverseSectionPosition = 0.4
        return path
    }
}

func run() {
    let paths = makePaths()
    let interps: [CPRInterpolationMode] = [CPRInterpolationMode(CPRInterpolationModeLinear.rawValue),
                                           CPRInterpolationMode(CPRInterpolationModeNearestNeighbor.rawValue),
                                           CPRInterpolationMode(CPRInterpolationModeCubic.rawValue)]
    let projections: [CPRProjectionMode] = [CPRProjectionMode(CPRProjectionModeNone.rawValue), CPRProjectionMode(CPRProjectionModeMIP.rawValue),
                                            CPRProjectionMode(CPRProjectionModeMinIP.rawValue), CPRProjectionMode(CPRProjectionModeMean.rawValue)]
    let slabs: [CGFloat] = [0, 2.5, 7]
    for path in paths {
        putV(path.initialNormal); putV(path.stretchedProjectionNormal())
        putD(path.leftTransverseSectionPosition); putD(path.rightTransverseSectionPosition)
        for i in 0..<path.nodes.count { putD(path.relativePositionForNode(at: UInt(i))) }
        putD(path.relativePosition(for: NSPoint(x: 21.7, y: 33.1), transform: toPixel))
        let transverse = path.transverseSliceRequests(forSpacing: 3, outputWidth: 48, outputHeight: 48, mmWide: 30) as NSArray
        for case let r as CPRGeneratorRequest in transverse {
            r.interpolationMode = CPRInterpolationMode(CPRInterpolationModeCubic.rawValue)
            putVolume(CPRGenerator.synchronousRequestVolume(r, volumeData: volume))
        }
        for interp in interps { for projection in projections { for slab in slabs {
            let s = CPRStraightenedGeneratorRequest()
            s.pixelsWide = 180; s.pixelsHigh = 64
            s.slabWidth = slab; s.interpolationMode = interp; s.projectionMode = projection
            s.bezierPath = path.bezierPath; s.initialNormal = path.initialNormal
            putVolume(CPRGenerator.synchronousRequestVolume(s, volumeData: volume))

            let t = CPRStretchedGeneratorRequest()
            t.pixelsWide = 180; t.pixelsHigh = 64
            t.slabWidth = slab; t.interpolationMode = interp; t.projectionMode = projection
            t.bezierPath = path.bezierPath; t.projectionNormal = N3VectorNormalize(N3VectorMake(0.1, 0.2, 1))
            t.midHeightPoint = dicom(36, 32, 20)
            putVolume(CPRGenerator.synchronousRequestVolume(t, volumeData: volume))
        }}}
    }
    let interps2 = interps
    for (i, basis) in [(N3VectorMake(0.9, 0.1, 0), N3VectorMake(-0.1, 0.8, 0.3)), (N3VectorMake(0.5, 0.5, 0.5), N3VectorMake(0.6, -0.6, 0))].enumerated() {
        for interp in interps2 { for projection in projections { for slab in [CGFloat(0), 4] {
            let o = unwrap(CPRObliqueSliceGeneratorRequest(center: dicom(36 + CGFloat(i), 30, 18), pixelsWide: 96, pixelsHigh: 80, xBasis: basis.0, yBasis: basis.1))
            o.slabWidth = slab; o.interpolationMode = interp; o.projectionMode = projection
            putVolume(CPRGenerator.synchronousRequestVolume(o, volumeData: volume))
        }}}
    }
    // The volume's own samplers.
    var f: Float = 0
    for i in 0..<3000 {
        let p = dicom(CGFloat((i % 71) * 1037 - 512) / 1024, CGFloat(((i * 7) % 63) * 1045 - 410) / 1024, CGFloat(((i * 13) % 39) * 1031 - 307) / 1024)
        volume.getLinearInterpolatedFloat(&f, atDicomVector: p); put(&f, 4)
        volume.getNearestNeighborInterpolatedFloat(&f, atDicomVector: p); put(&f, 4)
        volume.getCubicInterpolatedFloat(&f, atDicomVector: p); put(&f, 4)
    }
    try! out.write(to: URL(fileURLWithPath: outPath))
}

run()
"""

DCMPIX_H = r"""#import <Cocoa/Cocoa.h>
// DCMPix as -[CPRVolumeData initWithWithPixList:volume:] reads it; no case builds a volume from a pixel list.
@interface DCMPix : NSObject
@property (readonly) double sliceInterval, sliceThickness, pixelSpacingX, pixelSpacingY, originX, originY, originZ;
@property (readonly) long pwidth, pheight;
- (void)orientationDouble:(double *)orientation;
@end
"""

DCMPIX_M = r"""#import "DCMPix.h"
@implementation DCMPix
- (double)sliceInterval { return 0; }
- (double)sliceThickness { return 0; }
- (double)pixelSpacingX { return 0; }
- (double)pixelSpacingY { return 0; }
- (double)originX { return 0; }
- (double)originY { return 0; }
- (double)originZ { return 0; }
- (long)pwidth { return 0; }
- (long)pheight { return 0; }
- (void)orientationDouble:(double *)orientation {}
@end
"""

NITROGEN = ['N3Geometry', 'N3BezierCore', 'N3BezierCoreAdditions', 'N3BezierPath']
OBJC_CPR = ['CPRGenerator', 'CPRGeneratorRequest', 'CPRGeneratorOperation', 'CPRStraightenedOperation', 'CPRStretchedOperation',
            'CPRObliqueSliceOperation', 'CPRHorizontalFillOperation', 'CPRProjectionOperation', 'CPRVolumeData',
            'CPRUnsignedInt16ImageRep', 'CPRCurvedPath']
SWIFT_CPR = ['CPRCurvedPath', 'CPRDisplayInfo', 'CPRGeneratorRequest', 'CPRGeneratorOperation', 'CPRStraightenedOperation',
             'CPRStretchedOperation', 'CPRObliqueSliceOperation', 'CPRHorizontalFillOperation', 'CPRProjectionOperation',
             'CPRVolumeData', 'CPRUnsignedInt16ImageRep', 'CPRGenerator', 'IdentityToken']
SWIFT_HEADERS = ['CPRVolumeData', 'CPRProjectionOperation', 'CPRCurvedPath', 'CPRUnsignedInt16ImageRep', 'HorosObjCException',
                 'CPRGenerator', 'CPRGeneratorRequest', 'CPRDisplayInfo']
CAPI = [('HorosObjCException.m', ['-fobjc-exceptions']), ('CPRVolumeData+CAPI.m', []), ('CPRCurvedPath+CAPI.m', []),
        ('CPRGenerator+CAPI.m', [])]


def run(command):
    return subprocess.run(command, check=True, capture_output=True, text=True)


def clang(directory, name, flags):
    obj = directory / (Path(name).stem + '.o')
    # The app's prefix header brings Cocoa into every source; CPRVolumeData.m used vDSP.
    run(['xcrun', 'clang', '-x', 'objective-c', *TARGET, '-include', 'Cocoa/Cocoa.h', '-include', 'Accelerate/Accelerate.h',
         '-fvisibility=default', '-w', '-iquote', str(directory), *flags, '-c', str(directory / name), '-o', str(obj)])
    return str(obj)


def build(directory, kind, configuration):
    """The CPR generator of `kind` ('objc': REFERENCE, 'swift': the sources under test), with the driver."""
    directory.mkdir()
    objc = OBJC_FLAGS[configuration]
    objects = []
    # Nitrogen is the same on both sides, manual retain/release as in the app.
    for name in NITROGEN:
        for ext in ('.h', '.m'):
            (directory / (name + ext)).write_bytes(source(f'Nitrogen/Sources/{name}{ext}', 'HEAD' if not revision else None))
        objects.append(clang(directory, name + '.m', [*objc, '-fno-objc-arc']))
    (directory / 'DCMPix.h').write_text(DCMPIX_H)
    (directory / 'DCMPix.m').write_text(DCMPIX_M)
    objects.append(clang(directory, 'DCMPix.m', [*objc, '-fno-objc-arc']))
    (directory / 'main.swift').write_text(DRIVER)
    swift = ['xcrun', 'swiftc', *TARGET, '-swift-version', '5', '-module-name', 'Horos', *SWIFT_FLAGS[configuration],
             '-Xcc', '-iquote', '-Xcc', str(directory), '-framework', 'Cocoa', '-framework', 'Accelerate', '-framework', 'QuartzCore']
    if kind == 'objc':
        for name in OBJC_CPR:
            for ext in ('.h', '.m'):
                (directory / (name + ext)).write_bytes(source(f'Horos/Sources/{name}{ext}', REFERENCE))
        (directory / 'WaitRendering.h').write_text('#import <Cocoa/Cocoa.h>\n')
        (directory / 'Notifications.h').write_text('#import <Cocoa/Cocoa.h>\n')
        for name in OBJC_CPR:
            objects.append(clang(directory, name + '.m', [*objc, '-fno-objc-arc']))
        (directory / 'bridge.h').write_text('#import <Cocoa/Cocoa.h>\n' + ''.join(f'#import "{n}.h"\n' for n in NITROGEN + OBJC_CPR))
        run([*swift, '-D', 'OBJC_REF', '-import-objc-header', str(directory / 'bridge.h'), str(directory / 'main.swift'),
             *objects, '-o', str(directory / 'harness')])
    else:
        for name in SWIFT_CPR:
            (directory / f'{name}.swift').write_bytes(source(f'Horos/Sources/{name}.swift'))
        for name in SWIFT_HEADERS:
            (directory / f'{name}.h').write_bytes(source(f'Horos/Sources/{name}.h'))
        for name, extra in CAPI:
            (directory / name).write_bytes(source(f'Horos/Sources/{name}'))
            # The per-file flags of the target come after its own, as Xcode passes them.
            objects.append(clang(directory, name, [*objc, '-DHOROS_BRIDGING_HEADER=1', *extra, *per_file_flags(name)]))
        (directory / 'bridge.h').write_text(
            '#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n#import "DCMPix.h"\n'
            + ''.join(f'#import "{n}.h"\n' for n in NITROGEN + ['CPRVolumeData', 'CPRProjectionOperation', 'CPRCurvedPath',
                                                                 'CPRUnsignedInt16ImageRep']))
        run([*swift, '-wmo', '-import-objc-header', str(directory / 'bridge.h'),
             *[str(directory / f'{n}.swift') for n in SWIFT_CPR], str(directory / 'main.swift'), *objects,
             '-o', str(directory / 'harness')])
    return directory / 'harness'


# samplers
INLINE_SAMPLER = re.compile(r'\bCPRVolumeData(?:Linear|NearestNeighbor|Cubic)InterpolatedFloatAt(?:Dicom|Volume)(?:Vector|Coordinate)s?\s*\(')
swift_files = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision or 'HEAD', 'Horos/Sources', 'Nitrogen/Sources']).decode().split()
if not revision:
    swift_files = sorted({*swift_files, *[str(p.relative_to(root)) for p in (root / 'Horos/Sources').glob('*.swift')]})
for path in swift_files:
    if not path.endswith('.swift') or (not revision and not (root / path).exists()):
        continue
    for m in INLINE_SAMPLER.finditer(source(path).decode(errors='replace')):
        failures.append(f'samplers: {path} calls the inline sampler {m.group(0).rstrip("(").strip()} (Swift compiles it without the flags of the Objective-C)')

with tempfile.TemporaryDirectory(prefix='horos-swift-fast-math-') as tmp:
    tmp = Path(tmp)
    # probe
    (tmp / 'probe.swift').write_text(PROBE)
    control = None
    for configuration, flags in [*SWIFT_FLAGS.items(), ('control', ['-O', '-Xcc', '-ffast-math'])]:
        run(['xcrun', 'swiftc', *TARGET, *flags, str(tmp / 'probe.swift'), '-o', str(tmp / f'probe-{configuration}')])
        output = run([str(tmp / f'probe-{configuration}')]).stdout.split()
        if configuration == 'control':
            control = output
            if output != ['true', 'true']:
                failures.append(f'probe: with -Xcc -ffast-math the probe printed {output}; it cannot tell fast math')
        elif output != ['false', 'false']:
            failures.append(f'probe: with the {configuration} Swift flags {flags[1:] or "(none)"} a NaN rectangle is finite '
                            f'or a * b + c is fused ({output})')
    if control == ['true', 'true']:
        print('ok: probe - with the Swift flags of Release and Debug, NaN is not finite and a * b + c is not fused')

    # CPR bits
    for configuration in ('release', 'debug'):
        outputs = {}
        for kind in ('objc', 'swift'):
            try:
                harness = build(tmp / f'{kind}-{configuration}', kind, configuration)
            except subprocess.CalledProcessError as e:
                print(f'FAIL: the {kind} {configuration} harness did not build:', (e.stderr or '')[-3000:])
                sys.exit(1)
            result = subprocess.run([str(harness), str(tmp / f'{kind}-{configuration}.bin')], capture_output=True, text=True, timeout=300)
            if result.returncode != 0:
                failures.append(f'CPR bits: the {kind} {configuration} harness failed: {(result.stdout + result.stderr).strip()[-500:]}')
                break
            outputs[kind] = (tmp / f'{kind}-{configuration}.bin').read_bytes()
        else:
            reference, candidate = outputs['objc'], outputs['swift']
            if reference == candidate:
                print(f'ok: CPR bits - {configuration}: {len(candidate):,} bytes, the same as the Objective-C of {REFERENCE}')
            else:
                differing = sum(1 for a, b in zip(reference, candidate) if a != b) + abs(len(reference) - len(candidate))
                first = next((i for i, (a, b) in enumerate(zip(reference, candidate)) if a != b), min(len(reference), len(candidate)))
                failures.append(f'CPR bits: {configuration}: {differing:,} of {len(reference):,} bytes differ from the Objective-C '
                                f'of {REFERENCE}, the first at byte {first}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: Swift has no fast math, and the CPR generates the bytes of the Objective-C in Release and Debug')
