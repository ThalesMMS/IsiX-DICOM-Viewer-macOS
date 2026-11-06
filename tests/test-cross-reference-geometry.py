#!/usr/bin/env python3
"""Exercise production intersection/conversion methods with known physical planes.

DCMPix's conversions are IsiXImaging's (Geometry, ImagePlaneCoordinates, which
-[DCMPix convertPixX:...] and -[DCMPix convertDICOMCoords:...] hand the plane
to); at a revision where they are still in DCMPix.m, that Objective-C. The
slice intersection is IsiXImaging's too (ViewGeometry,
PlaneGeometry.sliceIntersection, which -[DCMView computeSliceIntersection:...]
hands the conversions to), compiled with swiftc; at a revision where it is
still in DCMView.m, that Objective-C.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
def source(name):
    path = 'Horos/Sources/' + name
    return (subprocess.check_output(['git', 'show', sys.argv[1] + ':' + path])
            if len(sys.argv) > 1 else (root / path).read_bytes()).decode('latin1')

def block(text, start):
    a = text.index(start)
    opening = text.index('{', a)
    depth = 1
    i = opening + 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}')
        i += 1
    return text[a:i]

# DCMView.m is gone once the class is Swift: the geometry is IsiXImaging's.
try:
    view = source('DCMView.m')
except (OSError, subprocess.CalledProcessError):
    view = ''
# So is DCMPix.m once DCMPix is: the conversions are DCMPix+Geometry.swift's.
try:
    pix = source('DCMPix.m')
except (OSError, subprocess.CalledProcessError):
    pix = ''
code = r'''
#import <Foundation/Foundation.h>
#include <math.h>
#include <string.h>
#define SMALL_NUM 0.00000001
#define DOT(a,b) (a[0]*b[0]+a[1]*b[1]+a[2]*b[2])
INTERSECTION
@interface DCMPix : NSObject {
@public float orientation[9], originX, originY, originZ, pixelSpacingX, pixelSpacingY;
}
@property(readonly) float pixelSpacingX, pixelSpacingY;
@property(readonly) int pwidth, pheight;
@end
@implementation DCMPix
-(float)pixelSpacingX{return pixelSpacingX;}
-(float)pixelSpacingY{return pixelSpacingY;}
-(int)pwidth{return 32;}
-(int)pheight{return 32;}
PIX_TO_DICOM
DICOM_TO_SLICE
@end
@interface DCMView : NSObject
@property(retain) DCMPix *curDCM;
@end
@implementation DCMView
SLICE_INTERSECTION
@end
static void rotate(float *v, float angle) {
    // Rotate about a non-axis-aligned unit vector (1,1,1)/sqrt(3).
    float c=cosf(angle), s=sinf(angle), q=(1-c)*(v[0]+v[1]+v[2])/3;
    float r[3]={c*v[0]+s*(v[2]-v[1])/sqrtf(3)+q,
                c*v[1]+s*(v[0]-v[2])/sqrtf(3)+q,
                c*v[2]+s*(v[1]-v[0])/sqrtf(3)+q};
    memcpy(v,r,sizeof(r));
}
static DCMPix *makePix(int axis, float angle, float position) {
    DCMPix *p=[DCMPix new];
    float bases[3][9]={{1,0,0,0,1,0,0,0,1}, {0,1,0,0,0,1,1,0,0}, {1,0,0,0,0,1,0,-1,0}};
    memcpy(p->orientation,bases[axis],sizeof(p->orientation));
    for(int i=0;i<9;i+=3)rotate(p->orientation+i,angle);
    p->originX=position*p->orientation[6];
    p->originY=position*p->orientation[7];
    p->originZ=position*p->orientation[8];
    p->pixelSpacingX=0.7;p->pixelSpacingY=1.3;
    return p;
}
#define check(...) do {if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
    DCMView *v=[DCMView new];
    for(int a=0;a<3;a++)for(int b=0;b<3;b++)if(a!=b)
    for(int rot=0;rot<3;rot++) {
        float angle=rot*0.37;
        DCMPix *src=makePix(a,angle,0), *dst=makePix(b,angle,0);
        v.curDCM=dst;
        float origin[3]={dst->originX,dst->originY,dst->originZ}, original[3];
        memcpy(original,origin,sizeof(origin));
        float previous[2][3];
        for(int repeat=0;repeat<4;repeat++) {
            float line[2][3];
            [v computeSliceIntersection:src sliceFromTo:line vector:dst->orientation origin:origin];
            for(int end=0;end<2;end++) {
                check(isfinite(line[end][0]) && isfinite(line[end][1]));
                check(fabsf(line[end][2])<1e-4); // Must lie on the actual target plane.
                float physical[3];
                [dst convertPixX:line[end][0]/dst.pixelSpacingX pixY:line[end][1]/dst.pixelSpacingY toDICOMCoords:physical pixelCenter:YES];
                check(fabsf(DOT(physical,(src->orientation+6)))<1e-4);
            }
            check(memcmp(origin,original,sizeof(origin))==0);
            if(repeat)for(int i=0;i<2;i++)for(int j=0;j<3;j++)check(fabsf(line[i][j]-previous[i][j])<1e-4);
            memcpy(previous,line,sizeof(line));
        }
    }
    // Known fixture: sagittal x=8 projects to axial column center 8.5 mm.
    DCMPix *src=makePix(1,0,8), *dst=makePix(0,0,0);v.curDCM=dst;
    src->pixelSpacingX=src->pixelSpacingY=dst->pixelSpacingX=dst->pixelSpacingY=1;
    float origin[3]={0,0,0}, line[2][3];
    [v computeSliceIntersection:src sliceFromTo:line vector:dst->orientation origin:origin];
    check(fabsf(line[0][0]-8.5f)<1e-5 && fabsf(line[1][0]-8.5f)<1e-5);
    NSLog(@"PASS: orthogonal/oblique planes, anisotropic spacing, repeat stability and pixel-center convention");
}}
'''

HEADER = r'''
#import <Foundation/Foundation.h>
@interface DCMPix : NSObject {
@public float orientation[9], originX, originY, originZ, pixelSpacingX, pixelSpacingY;
}
@property(readonly) float pixelSpacingX, pixelSpacingY;
@property(readonly) int pwidth, pheight;
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter NS_SWIFT_NAME(convertPix(x:y:to:pixelCenter:));
- (void) convertDICOMCoords: (float*) dc toSliceCoords: (float*) sc pixelCenter:(BOOL) pixelCenter NS_SWIFT_NAME(convertDICOM(_:toSlice:pixelCenter:));
- (void) setPlane:(const float *) o origin:(const float *) origin spacingX:(float) x spacingY:(float) y;
- (const float *) orientationValues;
- (const float *) originValues;
@end
'''

PIX = r'''
#import "Pix.h"
@implementation DCMPix
-(float)pixelSpacingX{return pixelSpacingX;}
-(float)pixelSpacingY{return pixelSpacingY;}
-(int)pwidth{return 32;}
-(int)pheight{return 32;}
- (void) setPlane:(const float *) o origin:(const float *) origin spacingX:(float) x spacingY:(float) y
{ memcpy(orientation, o, sizeof orientation); originX = origin[0]; originY = origin[1]; originZ = origin[2]; pixelSpacingX = x; pixelSpacingY = y; }
- (const float *) orientationValues { return orientation; }
- (const float *) originValues { return &originX; }
PIX_TO_DICOM
DICOM_TO_SLICE
@end
'''

MAIN = r'''
import Foundation

func check(_ condition: Bool, _ what: String) {
    if !condition { print("FAIL: " + what); exit(1) }
}
func rotate(_ v: inout [Float], _ at: Int, _ angle: Float) {
    // Rotate about a non-axis-aligned unit vector (1,1,1)/sqrt(3).
    let c = cosf(angle), s = sinf(angle), q = (1 - c) * (v[at] + v[at + 1] + v[at + 2]) / 3
    let r: [Float] = [c * v[at] + s * (v[at + 2] - v[at + 1]) / sqrtf(3) + q,
                      c * v[at + 1] + s * (v[at] - v[at + 2]) / sqrtf(3) + q,
                      c * v[at + 2] + s * (v[at + 1] - v[at]) / sqrtf(3) + q]
    v[at] = r[0]; v[at + 1] = r[1]; v[at + 2] = r[2]
}
func makePix(_ axis: Int, _ angle: Float, _ position: Float) -> DCMPix {
    let bases: [[Float]] = [[1,0,0,0,1,0,0,0,1], [0,1,0,0,0,1,1,0,0], [1,0,0,0,0,1,0,-1,0]]
    var o = bases[axis]
    for i in stride(from: 0, to: 9, by: 3) { rotate(&o, i, angle) }
    let origin = [position * o[6], position * o[7], position * o[8]]
    let pix = DCMPix()
    pix.setPlane(o, origin: origin, spacingX: 0.7, spacingY: 1.3)
    return pix
}
/// What -[DCMView computeSliceIntersection:...] does: the module, with the
/// image's conversions.
func intersection(_ source: DCMPix, shown: DCMPix, vector: UnsafeMutablePointer<Float>, origin: UnsafeMutablePointer<Float>) -> [Float] {
    var sft = [Float](repeating: 0, count: 6)
    PlaneGeometry.sliceIntersection(width: Float(source.pwidth), height: Float(source.pheight), normal: vector + 6, point: origin,
                                    toDICOM: { x, y, d in source.convertPix(x: x, y: y, to: d, pixelCenter: true) },
                                    toSlice: { d, s in shown.convertDICOM(d, toSlice: s, pixelCenter: true) },
                                    into: &sft)
    return sft
}
func dot(_ a: [Float], _ b: UnsafePointer<Float>) -> Float { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }

for a in 0..<3 { for b in 0..<3 where a != b { for rot in 0..<3 {
    let angle = Float(rot) * 0.37
    let src = makePix(a, angle, 0), dst = makePix(b, angle, 0)
    var vector = Array(UnsafeBufferPointer(start: dst.orientationValues(), count: 9))
    var origin: [Float] = [0, 0, 0]
    let original = origin
    var previous: [Float]? = nil
    for _ in 0..<4 {
        let line = intersection(src, shown: dst, vector: &vector, origin: &origin)
        for end in 0..<2 {
            check(line[3 * end].isFinite && line[3 * end + 1].isFinite, "a line end is finite")
            check(abs(line[3 * end + 2]) < 1e-4, "the line lies on the target plane")
            var physical: [Float] = [0, 0, 0]
            dst.convertPix(x: line[3 * end] / dst.pixelSpacingX, y: line[3 * end + 1] / dst.pixelSpacingY, to: &physical, pixelCenter: true)
            check(abs(dot(physical, src.orientationValues() + 6)) < 1e-4, "the line lies on the source plane")
        }
        check(origin == original, "the origin is left as it was")
        if let previous { for i in 0..<6 { check(abs(line[i] - previous[i]) < 1e-4, "the same line each time") } }
        previous = line
    }
}}}
// Known fixture: sagittal x=8 projects to axial column center 8.5 mm.
let src = makePix(1, 0, 8), dst = makePix(0, 0, 0)
var o = Array(UnsafeBufferPointer(start: src.orientationValues(), count: 9))
src.setPlane(o, origin: [8 * o[6], 8 * o[7], 8 * o[8]], spacingX: 1, spacingY: 1)
o = Array(UnsafeBufferPointer(start: dst.orientationValues(), count: 9))
dst.setPlane(o, origin: [0, 0, 0], spacingX: 1, spacingY: 1)
var vector = o, origin: [Float] = [0, 0, 0]
let line = intersection(src, shown: dst, vector: &vector, origin: &origin)
check(abs(line[0] - 8.5) < 1e-5 && abs(line[3] - 8.5) < 1e-5, "the sagittal plane at x = 8 crosses the axial image at 8.5 mm")
print("PASS: orthogonal/oblique planes, anisotropic spacing, repeat stability and pixel-center convention")
'''


# What DCMPix+Geometry.swift does with the image's plane, on this stub's
# float origin, orientation and spacing.
CONVERSIONS = r'''
import Foundation
extension DCMPix {
    private func plane() -> (origin: [Double], orientation: [Double]) {
        (origin: (0..<3).map { Double(originValues()[$0]) }, orientation: (0..<9).map { Double(orientationValues()[$0]) })
    }
    @objc(convertPixX:pixY:toDICOMCoords:pixelCenter:)
    func convertPix(x: Float, y: Float, to d: UnsafeMutablePointer<Float>, pixelCenter: Bool) {
        let (origin, orientation) = plane()
        let p = orientation.withUnsafeBufferPointer {
            ImagePlaneCoordinates.patientPoint(x: x, y: y, pixelCenter: pixelCenter, originX: origin[0], originY: origin[1], originZ: origin[2],
                                               orientation: $0.baseAddress!, spacingX: Double(pixelSpacingX), spacingY: Double(pixelSpacingY))
        }
        d[0] = p.x; d[1] = p.y; d[2] = p.z
    }
    @objc(convertDICOMCoords:toSliceCoords:pixelCenter:)
    func convertDICOM(_ dc: UnsafeMutablePointer<Float>, toSlice sc: UnsafeMutablePointer<Float>, pixelCenter: Bool) {
        let (origin, orientation) = plane()
        let s = orientation.withUnsafeBufferPointer {
            ImagePlaneCoordinates.slicePoint(SIMD3(dc[0], dc[1], dc[2]), pixelCenter: pixelCenter, originX: origin[0], originY: origin[1],
                                             originZ: origin[2], orientation: $0.baseAddress!, spacingX: Double(pixelSpacingX),
                                             spacingY: Double(pixelSpacingY))
        }
        sc[0] = s.x; sc[1] = s.y; sc[2] = s.z
    }
}
'''

PIX_START = '-(void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter:'
SLICE_START = '-(void) convertDICOMCoords: (float*) dc toSliceCoords: (float*) sc pixelCenter:'


def swift_check():
    code = PIX
    header = HEADER
    folders = [root / f for f in ('Modules/IsiXImaging/Sources/ViewGeometry', 'Modules/IsiXImaging/Sources/Geometry')]
    module = sorted(str(f) for folder in folders if folder.is_dir() for f in folder.glob('*.swift') if f.name != 'ImageRendering.swift')
    in_swift = PIX_START not in pix
    for key, start in {'PIX_TO_DICOM': PIX_START, 'DICOM_TO_SLICE': SLICE_START}.items():
        code = code.replace('\n' + key + '\n', '\n' + ('' if in_swift else block(pix, start)) + '\n')
    if in_swift:
        header = '\n'.join(l for l in header.splitlines() if 'convertPixX' not in l and 'convertDICOMCoords' not in l) + '\n'
    with tempfile.TemporaryDirectory(prefix='horos-cross-reference-') as directory:
        path = Path(directory)
        (path / 'Pix.h').write_text(header)
        (path / 'Pix.m').write_text(code)
        (path / 'main.swift').write_text(MAIN)
        if in_swift:
            (path / 'Conversions.swift').write_text(CONVERSIONS)
            module.append(str(path / 'Conversions.swift'))
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fsanitize=undefined', '-I', str(path), str(path / 'Pix.m'),
                        '-o', str(path / 'Pix.o')], check=True)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-sanitize=undefined', '-import-objc-header', str(path / 'Pix.h'),
                        str(path / 'main.swift'), *module, str(path / 'Pix.o'), '-framework', 'Foundation', '-o', str(path / 'test')],
                       check=True)
        subprocess.run([str(path / 'test')], check=True)


if '#define SMALL_NUM' not in view:
    swift_check()
    sys.exit(0)

for key, value in {
    'INTERSECTION': block(view, 'int intersect3D_SegmentPlane('),
    'PIX_TO_DICOM': block(pix, '-(void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter:'),
    'DICOM_TO_SLICE': block(pix, '-(void) convertDICOMCoords: (float*) dc toSliceCoords: (float*) sc pixelCenter:'),
    'SLICE_INTERSECTION': block(view, '- (void) computeSliceIntersection:'),
}.items():
    code = code.replace('\n' + key + '\n', '\n' + value + '\n')
with tempfile.TemporaryDirectory(prefix='horos-cross-reference-') as directory:
    path=Path(directory)
    (path/'test.m').write_text(code)
    subprocess.run(['xcrun','clang','-fno-objc-arc','-fsanitize=undefined','-framework','Foundation',str(path/'test.m'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
