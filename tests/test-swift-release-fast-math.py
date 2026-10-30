#!/usr/bin/env python3
"""Swift is compiled without -ffast-math, and the CPR still generates the
bits of the Objective-C it replaced.

The Release configuration passed `-Xcc -ffast-math` to Swift, so
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
  and the same N3 geometry on both sides: the Swift one, or the Objective-C
  with the Objective-C flags when the revision still has it), generates the same bytes as the
  Objective-C classes of the last revision that has them, compiled the same way, with the
  Objective-C flags the project set for Release (-O3 -ffast-math -DNDEBUG) and Debug
  (-O0 -DDEBUG=1) at that revision, read from its project (see OBJC_FLAGS for why
  not today's): straightened, stretched, transverse and
  oblique volumes, 3 interpolations x 4 projections x slabs, the path values
  and the volume's own samplers.

`<git revision>` as an optional argument reads the project and the Swift
sources from that revision, the negative control.
"""
from pathlib import Path
import re
import argparse
import contextlib
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('revision', nargs='?')
parser.add_argument('--case', choices=('all', 'cpr-wait', 'cpr-latest'), default='all')
parser.add_argument('--optimization', choices=('debug', 'release'), default='release')
parser.add_argument('--benchmark', action='store_true')
parser.add_argument('--keep', type=Path)
args = parser.parse_args()
revision = args.revision
# The Objective-C CPR generator the Swift one must match, from the last
# revision that has it.
import history_reference
import n3_geometry_harness
REFERENCE = history_reference.before_removal('Horos/Sources/CPRGenerator.m')


def source(path, rev=None):
    rev = rev or revision
    if rev:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{rev}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)
if REFERENCE is None and args.case == 'all':
    print('skipped: needs the history back to the Objective-C CPR generator; a shallow clone does not carry it', file=sys.stderr)
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


def target_configuration(name, text=None):
    m = re.search(r'/\* ' + name + r' configuration for PBXNativeTarget "Horos" \*/ = \{.*?buildSettings = \{(.*?)\n\t\t\t\};',
                  text or project, re.S)
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


def project_configuration(name, text):
    m = re.search(r'/\* ' + name + r' configuration for PBXProject "Horos" \*/ = \{.*?buildSettings = \{(.*?)\n\t\t\t\};',
                  text, re.S)
    if not m:
        print(f'FAIL: no {name} configuration for the project')
        sys.exit(1)
    return m.group(1)


def setting_list(value):
    value = value.strip().strip('()')
    return [f.strip().strip(',').strip('"') for f in re.split(r'[\s,]+', value) if f.strip().strip(',').strip('"')]


def objc_setting(configuration, name, text):
    """A setting of the Horos target's Objective-C in the project `text`, as
    Xcode resolves it: the target's value over the project's, with
    $(inherited) standing for the project's; None when neither sets it."""
    inherited = None
    for settings in (project_configuration(configuration, text), target_configuration(configuration, text)):
        values = setting_values(settings, name)
        if values:
            value = setting_list(values[-1])
            inherited = [*(inherited or [])] + [v for v in value if v != '$(inherited)'] if '$(inherited)' in value else value
    return inherited


def objc_flags(configuration, text):
    """The clang flags the Horos target of the project `text` gives its
    Objective-C in `configuration`: GCC_OPTIMIZATION_LEVEL, GCC_FAST_MATH
    (-ffast-math when YES; NO, Xcode's default, passes nothing) and
    GCC_PREPROCESSOR_DEFINITIONS."""
    level = objc_setting(configuration, 'GCC_OPTIMIZATION_LEVEL', text)
    if not level:
        print(f'FAIL: no GCC_OPTIMIZATION_LEVEL for the {configuration} Objective-C of the Horos target')
        sys.exit(1)
    flags = [f'-O{level[0]}']
    if (objc_setting(configuration, 'GCC_FAST_MATH', text) or ['NO'])[0] == 'YES':
        flags.append('-ffast-math')
    return flags + [f'-D{d}' for d in objc_setting(configuration, 'GCC_PREPROCESSOR_DEFINITIONS', text) or []]


SWIFT_FLAGS = {'release': ['-O', *swift_flags('Release')], 'debug': ['-O', '-D', 'DEBUG', *swift_flags('Debug')]}
# The Objective-C on both sides of the CPR comparison is compiled with the
# flags the project gave the target at REFERENCE, the build the Objective-C CPR
# classes shipped in: Release -O3 -ffast-math -DNDEBUG (GCC_FAST_MATH = YES),
# Debug -O0 -DDEBUG=1. They are not this project's flags on purpose. The
# project turned GCC_FAST_MATH off (Release -O3 -DNDEBUG) only after those
# classes had become Swift, and that change alone rounds the C kernels the
# Swift still calls (CPRVolumeData+CAPI.m) differently, in the last bits of
# some voxels; compiled with today's flags, the Swift side cannot match the
# reference bit for bit whatever the conversion does. With the same flags on
# both sides, any difference is the conversion's. The Swift is compiled with
# this project's Swift flags, as the app compiles it (the probe checks
# they carry no fast math); where the former Release arithmetic differed from
# Debug, the Swift reproduces it under #if !DEBUG (CPRCurvedPath's node
# positions, for one).
FLAGS_PROJECT = source('Horos.xcodeproj/project.pbxproj', REFERENCE).decode() if REFERENCE else project
OBJC_FLAGS = {'release': objc_flags('Release', FLAGS_PROJECT), 'debug': objc_flags('Debug', FLAGS_PROJECT)}
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
CAPI = [('HorosObjCException.m', ['-fobjc-exceptions']), ('CPRVolumeData+CAPI.m', [])]


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stderr)
        result.check_returncode()
    return result


def clang(directory, name, flags):
    obj = directory / (Path(name).stem + '.o')
    # The app's prefix header brings Cocoa into every source; CPRVolumeData.m used vDSP.
    run(['xcrun', 'clang', '-x', 'objective-c', *TARGET, '-include', 'Cocoa/Cocoa.h', '-include', 'Accelerate/Accelerate.h',
         '-fvisibility=default', '-w', '-iquote', str(directory), *flags, '-c', str(directory / name), '-o', str(obj)])
    return str(obj)


def build(directory, kind, configuration):
    """The CPR generator of `kind` ('objc': REFERENCE, 'swift': the sources under test), with the driver."""
    directory.mkdir(exist_ok=True)
    objc = OBJC_FLAGS[configuration]
    objects = []
    # The N3 geometry is the same on both sides: the Objective-C (manual
    # retain/release, as in the app) where the revision has it, otherwise the
    # Swift of this checkout.
    n3_revision = revision or 'HEAD'
    if subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{n3_revision}:Nitrogen/Sources/N3Geometry.m'],
                      capture_output=True).returncode == 0 and (revision or (root / 'Nitrogen/Sources/N3Geometry.m').exists()):
        for name in NITROGEN:
            for ext in ('.h', '.m'):
                (directory / (name + ext)).write_bytes(source(f'Nitrogen/Sources/{name}{ext}', n3_revision))
            objects.append(clang(directory, name + '.m', [*objc, '-fno-objc-arc']))
    else:
        for name in NITROGEN:
            (directory / (name + '.h')).write_bytes(source(f'Nitrogen/Sources/{name}.h'))
        n3_geometry_harness.build(directory / 'n3', configuration, headers=directory)
        objects += n3_geometry_harness.libraries(directory / 'n3')
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



# Uses the existing production CPR build, selecting only queue ownership.
WAIT_DRIVER = r"""import Cocoa
final class WaitRequest: CPRGeneratorRequest {
    override func operationClass() -> AnyClass? { WaitOperation.self }
}
final class WaitOperation: CPRGeneratorOperation, @unchecked Sendable {
    static let entered = DispatchSemaphore(value: 0)
    static let gate = DispatchSemaphore(value: 0)
    override func main() {
        if request!.pixelsWide == 0 {
            Self.entered.signal()
            precondition(Self.gate.wait(timeout: .now() + 5) == .success)
        }
        if request!.pixelsWide == 3 { cancel() }
        if request!.pixelsWide < 2 { generatedVolume = volumeData }
    }
}
let storage = UnsafeMutablePointer<Float>.allocate(capacity: 8)
storage.initialize(repeating: 42, count: 8)
let volume = CPRVolumeData(floatBytesNoCopy: storage, pixelsWide: 2, pixelsHigh: 2, pixelsDeep: 2,
                          volumeTransform: N3AffineTransformIdentity, outOfBoundsValue: 0, freeWhenDone: false)
let benchmark = CommandLine.arguments.contains("benchmark")
func request(_ kind: UInt) -> WaitRequest { let r = WaitRequest(); r.pixelsWide = kind; return r }
var samples = [Double](), isolated = [Double]()
for i in 0..<13 {
    let all = DispatchGroup()
    all.enter()
    DispatchQueue.global().async {
        precondition(CPRGenerator.synchronousRequestVolume(request(0), volumeData: volume) === volume)
        all.leave()
    }
    precondition(WaitOperation.entered.wait(timeout: .now() + 5) == .success)
    let returned = DispatchSemaphore(value: 0)
    let started = ProcessInfo.processInfo.systemUptime
    var elapsed = 0.0
    all.enter()
    DispatchQueue.global().async {
        let value = CPRGenerator.synchronousRequestVolume(request(UInt(i % 3 + 1)), volumeData: volume)
        precondition(i % 3 == 0 ? value === volume : value == nil)
        elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        returned.signal(); all.leave()
    }
    if benchmark {
        // Fixed unrelated work, identical in A and B. It is deliberately not timed as B's work.
        Thread.sleep(forTimeInterval: 0.04)
        WaitOperation.gate.signal()
        precondition(returned.wait(timeout: .now() + 5) == .success)
    } else {
        let independent = returned.wait(timeout: .now() + 0.5) == .success
        WaitOperation.gate.signal()
        precondition(independent, "finished request waited for unrelated work")
    }
    precondition(all.wait(timeout: .now() + 5) == .success)
    if i >= 3 { samples.append(elapsed) }
    let t = ProcessInfo.processInfo.systemUptime
    precondition(CPRGenerator.synchronousRequestVolume(request(1), volumeData: volume) === volume)
    if i >= 3 { isolated.append((ProcessInfo.processInfo.systemUptime-t)*1000) }
}
print(String(data: try! JSONSerialization.data(withJSONObject: ["contended_ms":samples,"isolated_ms":isolated]), encoding:.utf8)!)
storage.deallocate()
"""
LATEST_DRIVER = r"""import Cocoa
final class LatestRequest: CPRGeneratorRequest {
    override func operationClass() -> AnyClass? { LatestOperation.self }
}
final class LatestOperation: CPRGeneratorOperation, @unchecked Sendable {
    static let entered = DispatchSemaphore(value: 0)
    static let start = DispatchSemaphore(value: 0)
    private let childLock = NSLock()
    private var child: CPRHorizontalFillOperation?
    override func cancel() {
        super.cancel()
        childLock.withLock { child?.cancel() }
    }
    override func main() {
        let side = Int(request!.pixelsWide)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: side * side)
        out.initialize(repeating: -1, count: side * side)
        defer { out.deallocate() }
        var vectors = [N3Vector](repeating: N3VectorMake(1,1,1), count: side)
        var normals = [N3Vector](repeating: N3VectorZero, count: side)
        let fill = vectors.withUnsafeMutableBufferPointer { v in normals.withUnsafeMutableBufferPointer { n in
            CPRHorizontalFillOperation(volumeData: volumeData, interpolationMode: CPRInterpolationMode(CPRInterpolationModeLinear.rawValue),
                floatBytes: out, width: UInt(side), height: UInt(side), vectors: v.baseAddress!, normals: n.baseAddress!)
        } }
        childLock.withLock { child = fill; if isCancelled { fill.cancel() } }
        if side > 64 {
            Self.entered.signal()
            precondition(Self.start.wait(timeout: .now()+10) == .success)
        }
        fill.start()
        if !isCancelled {
            // Pixel validation is a correctness check, not work performed by
            // the application. Keep its full-buffer scan out of the timing.
            if !benchmark {
                precondition((0..<(side*side)).allSatisfy { out[$0] == 42 }, "actual fill pixels differ")
            }
            generatedVolume = volumeData
        }
        childLock.withLock { child = nil }
    }
}
final class Receiver: NSObject, CPRGeneratorDelegate {
    var delivered: [UInt] = []
    var finalTime = 0.0
    var abandoned = 0
    func generator(_ generator: CPRGenerator, didGenerateVolume volume: CPRVolumeData, request: CPRGeneratorRequest) {
        delivered.append(request.pixelsHigh)
        if request.pixelsWide == 32 { finalTime = ProcessInfo.processInfo.systemUptime }
    }
    func generator(_ generator: CPRGenerator, didAbandonRequest request: CPRGeneratorRequest) { abandoned += 1 }
}
func request(_ side: UInt, _ serial: UInt) -> LatestRequest { let r=LatestRequest(); r.pixelsWide=side; r.pixelsHigh=serial; return r }
let storage=UnsafeMutablePointer<Float>.allocate(capacity: 64)
storage.initialize(repeating:42,count:64)
let volume=CPRVolumeData(floatBytesNoCopy:storage,pixelsWide:4,pixelsHigh:4,pixelsDeep:4,
                       volumeTransform:N3AffineTransformIdentity,outOfBoundsValue:0,freeWhenDone:false)
let benchmark=CommandLine.arguments.contains("benchmark")
var finalTimes=[Double](), cpuTimes=[Double]()
var missingLatest = 0
for trial in 0..<(benchmark ? 13 : 3) {
    try autoreleasepool {
        let generator=CPRGenerator(volumeData:volume), receiver=Receiver(); generator.delegate=receiver
        func submit(_ request: LatestRequest) { generator.SUBMIT(request) }
        submit(request(2048,1))
        precondition(LatestOperation.entered.wait(timeout:.now()+10) == .success)
        submit(request(2048,2))
        precondition(LatestOperation.entered.wait(timeout:.now()+10) == .success)
        let cpu=clock()
        LatestOperation.start.signal(); LatestOperation.start.signal()
        // Both children execute real CPR interpolation before replacement.
        Thread.sleep(forTimeInterval:0.005)
        let requested=ProcessInfo.processInfo.systemUptime
        for serial in 3...10 { submit(request(serial == 10 ? 32 : 64,UInt(serial))) }
        // Deliberately batch finished callbacks in the correctness run: an old
        // preview ending last must not hide the newer completed result.
        if !benchmark { Thread.sleep(forTimeInterval: 1) }
        generator.runUntilAllRequestsAreFinished()
        REQUIRE_LATEST
        REQUIRE_ORDER
        if trial>=3 {
            if receiver.finalTime > 0 { finalTimes.append((receiver.finalTime-requested)*1000) }
            else { missingLatest += 1 }
            cpuTimes.append(Double(clock()-cpu)/Double(CLOCKS_PER_SEC)*1000)
        }
        // Explicit cancellation drains without publishing a partial fill.
        let before=receiver.delivered.count
        submit(request(64,11)); generator.cancelOutstandingRequests(); generator.runUntilAllRequestsAreFinished()
        precondition(receiver.delivered.count == before)
    }
}
if !benchmark {
    let generator=CPRGenerator(volumeData:volume), receiver=Receiver(); generator.delegate=receiver
    for serial in 20...40 {
        generator.SUBMIT(request(64,UInt(serial)))
        _ = RunLoop.main.run(mode:.default,before:Date(timeIntervalSinceNow:0.005))
    }
    precondition(!receiver.delivered.isEmpty, "continuous input starved every preview")
    generator.runUntilAllRequestsAreFinished()
}
print(String(data:try! JSONSerialization.data(withJSONObject:["latest_ms":finalTimes,"cpu_ms":cpuTimes,"missing_latest":missingLatest]),encoding:.utf8)!)
storage.deallocate()
"""
if args.case in ('cpr-wait', 'cpr-latest'):
    direct = b'requestInteractiveVolume' in source('Horos/Sources/CPRGenerator.swift')
    if args.case == 'cpr-latest':
        if not revision: assert direct
        DRIVER = LATEST_DRIVER.replace('SUBMIT', 'requestInteractiveVolume' if direct else 'requestVolume')
        # Old generators may discard the final callback when finished workers
        # arrive in one batch. Record every miss, rather than retrying/selecting
        # successful baseline trials or inventing a completion time for them.
        DRIVER = DRIVER.replace('REQUIRE_LATEST', 'precondition(receiver.finalTime > 0, "latest result missing")' if direct else 'if !benchmark { precondition(receiver.finalTime > 0, "latest result missing") }')
        DRIVER = DRIVER.replace('REQUIRE_ORDER', 'precondition(receiver.delivered.last == 10 && zip(receiver.delivered,receiver.delivered.dropFirst()).allSatisfy { $0 < $1 }, "older preview overwrote newer result")' if direct else '')
    else:
        DRIVER = WAIT_DRIVER
    SWIFT_FLAGS['debug'] = ['-Onone', '-D', 'DEBUG', *swift_flags('Debug')]
    if args.keep:
        args.keep.mkdir(parents=True, exist_ok=True)
    with (contextlib.nullcontext(str(args.keep)) if args.keep else tempfile.TemporaryDirectory(prefix='horos-cpr-wait-')) as tmp:
        binary = build(Path(tmp) / args.optimization, 'swift', args.optimization)
        for _ in range(2 if args.benchmark else 1):
            result = run([str(binary), 'benchmark' if args.benchmark else 'check'])
            print(result.stdout.strip())
    raise SystemExit(0)

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
    print(f'CPR bits: Objective-C flags of {REFERENCE or "HEAD"}\'s project: '
          + '; '.join(f'{c} {" ".join(f)}' for c, f in OBJC_FLAGS.items()))
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
