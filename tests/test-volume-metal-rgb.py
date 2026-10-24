#!/usr/bin/env python3
"""An RGB volume draws with the Metal ray cast of the 3D view.

VTK's ray caster holds an RGB series' ARGB bytes as four independent
components: alpha, weighted 0, and red, green and blue, each with its colour
function and one opacity function over the byte. In composite it combines a
sample's components as `VTKKWRCHelper_LookupAndCombineIndependentColorsUS`
does - the colour the sum of each component's colour times its opacity, the
opacity the sum of the squared opacities over their sum - and in a projection
it keeps each component's own extreme. The Metal renderer used to refuse the
volume ("RGB volumes keep the original renderer."); it now uploads the bytes
as an RGBA texture and runs the same arithmetic, and the host paints a
projection's three values with the mapper's own tables.

Checked here:
- in the sources, the snapshot no longer refuses an RGB volume, takes VTK's
  component colour functions and opacity function over 0...255, and the hook
  paints a projection with the mapper's tables;
- on the GPU, a volume whose only non-zero component is red draws, in
  composite, what the scalar renderer draws of that channel with the same
  table, within two levels (the two textures filter in their own precision);
- rays down a column of voxels give, for each component, the maximum,
  minimum and mean of the column's samples.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import argparse
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('revision', nargs='?')
parser.add_argument('--case', choices=['renderer', 'host-conversion'], default='renderer')
parser.add_argument('--optimization', choices=['debug', 'release'], default='release')
parser.add_argument('--benchmark', action='store_true')
arguments = parser.parse_args()
revision = arguments.revision


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('utf-8')
    return (root / path).read_text()


def host_conversion():
    # Compile the actual controller method and picture helper, without the
    # surrounding VTK window. The renderer and colour conversion are real.
    source = read('Horos/Sources/VRHostBridge.mm')
    start = source.index('- (NSData *)horosVolumeMetalRender:', source.index('/// Renders one volume'))
    methods = source[start:source.index('- (NSString *)horosVolumeMetalFallbackReason', start)]
    declarations = []
    import re
    for match in re.finditer(r'- \(NSData \*\)horosVolumeMetalRender:[^{]+\{', methods):
        declarations.append(match.group(0)[:-1] + ';')
    picture = source[source.index('static NSData *HorosVolumePicture'):source.index('// Why the mapper refused')]
    has_internal = 'forVTK:(BOOL)forVTK' in methods
    if not revision:
        assert has_internal and 'scalarOut:opacity forVTK:YES' in source
        assert 'scalarOut:scalarOut forVTK:NO' in methods and 'if (!forVTK && bytes' in methods
    driver = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>
#import "Probe-Swift.h"
#include <cmath>
#include <algorithm>
#include <cstdio>
static char rendererKey, fusedRendererKey, uploadedKey, fusedUploadedKey, reasonKey, fusedReasonKey, millisecondsKey, fusedMillisecondsKey;
@interface ProbeController : NSObject
DECLARATIONS
@end
@implementation ProbeController
METHODS
@end
PICTURE
static void require(BOOL ok, const char *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } }
int main(int argc, char **argv) { @autoreleasepool {
    ProbeController *controller = [ProbeController new];
    NSMutableData *volume = [NSMutableData dataWithLength:8*8*8*4];
    unsigned char *v = (unsigned char *)volume.mutableBytes;
    for (int i=0;i<512;i++) { v[4*i]=255; v[4*i+1]=(i*17)%256; v[4*i+2]=(i*31)%256; v[4*i+3]=(i*13)%256; }
    NSMutableData *clut = [NSMutableData dataWithLength:3*256*4];
    NSMutableData *opacityTable = [NSMutableData dataWithLength:256*4];
    NSMutableArray *tables = [NSMutableArray array];
    for (int c=0;c<3;c++) {
        NSMutableData *col = [NSMutableData dataWithLength:256*6], *op = [NSMutableData dataWithLength:256*2];
        for (int i=0;i<256;i++) {
            ((unsigned char *)clut.mutableBytes)[(c*256+i)*4+c]=i;
            ((unsigned char *)clut.mutableBytes)[(c*256+i)*4+3]=255;
            ((float *)opacityTable.mutableBytes)[i]=i/255.0f;
            ((unsigned short *)col.mutableBytes)[3*i+c]=(i*32767+127)/255;
            ((unsigned short *)op.mutableBytes)[i]=(i*32767+127)/255;
        }
        [tables addObject:@{@"component":@(c+1),@"weight":@1,@"shift":@0,@"scale":@1,@"size":@256,@"colour":col,@"opacity":op}];
    }
    NSMutableDictionary *s = [@{@"volume":volume,@"volumeWidth":@8,@"volumeHeight":@8,@"volumeDepth":@8,
        @"transform":@[@1,@0,@0,@0,@0,@1,@0,@0,@0,@0,@1,@0,@0,@0,@0,@1],@"colourVolume":@YES,
        @"camera":@[@3.5,@3.5,@-10,@3.5,@3.5,@3.5,@0,@1,@0,@1,@4,@30],@"near":@0,@"far":@-1,
        @"level":@127.5,@"width":@255,@"clut":clut,@"opacity":@[],@"opacityTable":opacityTable,
        @"mode":@1,@"shading":@[@0,@0.15,@0.9,@0.3,@15],@"clippingPlanes":@[],@"sampleStep":@1,
        @"scalarBackground":@-1,@"anchoredProjection":@NO,@"componentTables":tables} mutableCopy];
    NSMutableData *scalar = [NSMutableData data], *other = [NSMutableData data];
    for (NSNumber *mode in @[@1,@2,@3]) for (NSNumber *fused in @[@NO,@YES]) {
        s[@"mode"]=mode; NSError *error=nil;
        NSData *publicBytes = [controller horosVolumeMetalRender:s fused:fused.boolValue width:37 height:29 imageRegion:@[] geometryDepth:nil scalarOut:scalar error:&error];
        require(publicBytes.length==37*29*4 && !error,"public render failed");
        NSData *expected = HorosVolumePicture(publicBytes,scalar,s);
        NSData *raw = [controller horosVolumeMetalRender:s fused:fused.boolValue width:37 height:29 imageRegion:@[] geometryDepth:nil scalarOut:other INTERNAL error:&error];
        NSData *actual = HorosVolumePicture(raw,other,s);
        require([expected isEqual:actual] && [scalar isEqual:other],"internal picture/scalar differs");
        const unsigned short *p=(const unsigned short *)expected.bytes; const unsigned char *b=(const unsigned char *)publicBytes.bytes;
        for(int i=0;i<37*29;i++) require(b[4*i]==(p[4*i+2]>>7) && b[4*i+1]==(p[4*i+1]>>7) && b[4*i+2]==(p[4*i]>>7) && b[4*i+3]==255,"public BGRA changed");
        s[@"componentTables"]=@[@{}];
        raw=[controller horosVolumeMetalRender:s fused:fused.boolValue width:37 height:29 imageRegion:@[] geometryDepth:nil scalarOut:other INTERNAL error:&error];
        require(!raw || !HorosVolumePicture(raw,other,s),"invalid table published a picture");
        s[@"componentTables"]=tables;
    }
    if (argc>1) {
        NSMutableDictionary *report=[NSMutableDictionary dictionary]; s[@"mode"]=@1;
        for(NSNumber *side in @[@128,@512,@1024]) {
            int n=side.intValue; NSMutableArray *times=[NSMutableArray array];
            for(int i=-10;i<40;i++) { @autoreleasepool {
                double start=NSProcessInfo.processInfo.systemUptime; NSError *error=nil;
                NSData *raw=[controller horosVolumeMetalRender:s fused:NO width:n height:n imageRegion:@[] geometryDepth:nil scalarOut:scalar INTERNAL error:&error];
                NSData *out=HorosVolumePicture(raw,scalar,s);
                double elapsed=(NSProcessInfo.processInfo.systemUptime-start)*1000;
                require(out.length==(NSUInteger)n*n*8 && !error,"benchmark render failed");
                if(i>=0) [times addObject:@(elapsed)];
            } }
            report[side.stringValue]=times;
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    } else puts("PASS: real host method RGB MIP/MinIP/mean, public BGRA, internal RGBA16, fused ownership and invalid tables");
} }
'''
    driver = driver.replace('DECLARATIONS', '\n'.join(declarations)).replace('METHODS', methods).replace('PICTURE', picture)
    driver = driver.replace('INTERNAL', 'forVTK:YES' if has_internal else '')
    with tempfile.TemporaryDirectory(prefix='horos-vr-host-') as name:
        work = Path(os.environ.get('HOROS_BENCH_KEEP', name)); work.mkdir(parents=True, exist_ok=True)
        sources = ['VolumeAllocation.swift','VolumeSession.swift','MPRMetalReslicer.swift','VolumeMetalRenderer.swift',
                   'MetalPerformanceTrace.swift','MetalComputePipelineCache.swift','Metal4ComputeSubmitter.swift']
        for s in sources: (work/s).write_text(read('Horos/Sources/'+s))
        (work/'Check.mm').write_text(driver)
        opt = arguments.optimization
        subprocess.run(['xcrun','swiftc','-Onone' if opt=='debug' else '-O','-emit-library','-emit-objc-header',
                        '-emit-objc-header-path',str(work/'Probe-Swift.h'),'-module-name','Probe','-suppress-warnings',
                        *[str(work/s) for s in sources],'-o',str(work/'libProbe.dylib')],check=True)
        subprocess.run(['xcrun','clang++','-O0' if opt=='debug' else '-O2','-std=c++17','-w','-fobjc-arc',
                        str(work/'Check.mm'),'-L'+str(work),'-lProbe','-Wl,-rpath,'+str(work),
                        '-framework','Foundation','-framework','Accelerate','-o',str(work/'check')],check=True)
        subprocess.run([str(work/'check')],check=True,timeout=120)
        if arguments.benchmark:
            for replica in range(2):
                result=subprocess.check_output([str(work/'check'),'bench'],timeout=300,text=True)
                parsed=json.loads(result)
                (work/f'replica-{replica+1}.json').write_text(json.dumps(parsed)+'\n')
                print(json.dumps({'replica':replica+1,'samples':parsed}),flush=True)


if arguments.case == 'host-conversion':
    host_conversion()
    raise SystemExit(0)


failures = []
bridge = read('Horos/Sources/VRHostBridge.mm')
renderer = read('Horos/Sources/VolumeMetalRenderer.swift')
snapshot = bridge[bridge.index('- (NSDictionary *)horosVolumeSnapshot {'):]
snapshot = snapshot[:snapshot.index('\n}\n')]
if 'RGB volumes keep the original renderer.' in snapshot:
    failures.append('the snapshot still refuses an RGB volume')
if 'property->GetRGBTransferFunction(component)->GetTable(0, 255, 256, colours);' not in bridge or \
        'property->GetScalarOpacity(1)->GetTable(0, 255, 256, alphas);' not in bridge or \
        'HorosColourTables(volumeProperty, samplesPerMillimetre, &clut, &opacityTable, &projectionOpacityTable)' not in bridge:
    failures.append('the RGB tables are not VTK\'s own component functions over the byte')
if 'pictureWithComponents:scalar count:(NSInteger)(bgra.length / 4) tables:projection[@"componentTables"]' not in bridge or \
        'snapshot[@"componentTables"] = [self horosColourTablesFused:NO refresh:NO][@"tables"]' not in bridge:
    failures.append('an RGB projection is not painted with the mapper\'s tables')
if 'uploadColourVolume:slices' not in bridge or 'func uploadColourVolume(' not in renderer:
    failures.append('the ARGB bytes are not uploaded as a colour volume')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

DRIVER = r'''
import Foundation
import Metal
import simd

func expect(_ ok: Bool, _ reason: @autoclosure () -> String) { if !ok { print("FAIL: " + reason()); exit(1) } }

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: no Metal device"); exit(2) }
        let colourEngine = try VolumeMetalRenderer(device: device), scalarEngine = try VolumeMetalRenderer(device: device)
        let w = 12, h = 10, d = 8
        func red(_ i: Int, _ j: Int, _ k: Int) -> Int { (i * 19 + j * 7 + k * 23) % 256 }
        var argb = [UInt8](), floats = [Float]()
        for k in 0..<d { for j in 0..<h { for i in 0..<w { argb += [255, UInt8(red(i, j, k)), 0, 0]; floats.append(Float(red(i, j, k))) } } }
        try colourEngine.upload(try ResliceVolume(width: w, height: h, depth: d, voxels: Data(argb), voxelToWorld: matrix_identity_float4x4), colour: true)
        try scalarEngine.upload(try ResliceVolume(width: w, height: h, depth: d, voxels: floats.withUnsafeBufferPointer { Data(buffer: $0) },
                                                  voxelToWorld: matrix_identity_float4x4))
        let opacity: [Float] = (0..<256).map { $0 == 0 ? 0 : Float($0) / 255 * 0.3 }
        var ramp = [UInt8](); for i in 0..<256 { ramp += [UInt8(i), UInt8(i / 2), UInt8(255 - i), 255] }
        let three = Data(ramp + [UInt8](repeating: 0, count: 2048))    // green and blue tables: black, and never lit
        let camera = try VolumeCamera(position: SIMD3(5.5, 4.5, -30), focalPoint: SIMD3(5.5, 4.5, 3.5), viewUp: SIMD3(0, -1, 0),
                                      parallel: true, parallelScale: 6, viewAngle: 30, clippingRange: nil)
        func request(_ transfer: VolumeTransferFunction, _ mode: VolumeRenderingMode, width: Int = 16, height: Int = 14, step: Float = 0.5) throws -> VolumeRenderRequest {
            try VolumeRenderRequest(camera: camera, transfer: transfer, mode: mode, shading: VolumeShading(enabled: false), crop: nil,
                                    width: width, height: height, sampleStep: step)
        }
        let colourTransfer = try VolumeTransferFunction(level: 127.5, width: 255, colour: three, opacity: opacity)
        let scalarTransfer = try VolumeTransferFunction(level: 127.5, width: 255, colour: Data(ramp), opacity: opacity)
        let colour = [UInt8](try colourEngine.render(try request(colourTransfer, .composite)).bgra)
        let scalar = [UInt8](try scalarEngine.render(try request(scalarTransfer, .composite)).bgra)
        let worst = zip(colour, scalar).map { abs(Int($0) - Int($1)) }.max()!
        expect(worst <= 2, "one red component composes \(worst) levels from the scalar composite of that channel")
        expect(colour.contains { $0 > 20 }, "the composite drew nothing")

        // Through voxel centres: a parallel view down z whose pixel (x, y) is voxel column (x, y).
        let axial = try VolumeCamera(position: SIMD3(5.5, 4.5, -30), focalPoint: SIMD3(5.5, 4.5, 3.5), viewUp: SIMD3(0, -1, 0),
                                     parallel: true, parallelScale: 5, viewAngle: 30, clippingRange: nil)
        var mixed = [UInt8]()
        for k in 0..<d { for j in 0..<h { for i in 0..<w { mixed += [255, UInt8(red(i, j, k)), UInt8((i * 5 + k * 31) % 256), UInt8((j * 13 + k * 3) % 256)] } } }
        try colourEngine.upload(try ResliceVolume(width: w, height: h, depth: d, voxels: Data(mixed), voxelToWorld: matrix_identity_float4x4), colour: true)
        for mode in [VolumeRenderingMode.maximum, .minimum, .mean] {
            let result = try colourEngine.render(try VolumeRenderRequest(camera: axial, transfer: colourTransfer, mode: mode,
                shading: VolumeShading(enabled: false), crop: nil, width: 12, height: 10, sampleStep: 1, scalarBackground: -1))
            let values = result.scalar.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            expect(values.count == 3 * 12 * 10, "a colour projection does not hand back three values a pixel")
            for y in 1..<9 { for x in 1..<11 {
                for c in 0..<3 {
                    // The ray enters at z = -0.5 and samples every voxel: at
                    // -0.5, 0.5, ... d - 0.5, each the mean of the two
                    // neighbouring voxels, the first and the last the edge ones.
                    let column = (0..<d).map { Float(mixed[4 * (($0 * h + y) * w + x) + c + 1]) }
                    let samples = [column[0]] + (0..<(d - 1)).map { (column[$0] + column[$0 + 1]) / 2 } + [column[d - 1]]
                    let expected = mode == .maximum ? samples.max()! : mode == .minimum ? samples.min()! : samples.reduce(0, +) / Float(samples.count)
                    let got = values[3 * (y * 12 + x) + c]
                    expect(abs(got - expected) <= 0.51,
                           "mode \(mode), column (\(x), \(y)), component \(c + 1): \(got), the column gives \(expected)")
                }
            } }
        }
        for backend in [MetalComputeBackend.metal3, .metal4] {
            if backend == .metal4 && !Metal4ComputeSubmitter.isSupported(device) { continue }
            let resized = try VolumeMetalRenderer(device: device, backend: backend)
            let reference = try VolumeMetalRenderer(device: device, backend: backend)
            let volume = try ResliceVolume(width: w, height: h, depth: d, voxels: Data(mixed), voxelToWorld: matrix_identity_float4x4)
            try resized.upload(volume, colour: true)
            for mode in [VolumeRenderingMode.composite, .maximum, .composite, .minimum, .mean] {
                let request = try VolumeRenderRequest(camera: axial, transfer: colourTransfer, mode: mode,
                    shading: VolumeShading(enabled: false), crop: nil, width: 128, height: 128, sampleStep: 1)
                let oldImage = resized.outputIdentities[0]
                let got = try resized.render(request)
                if let oldImage { expect(resized.outputIdentities[0] == oldImage, "RGB scalar growth reallocated BGRA") }
                reference.release(); try reference.upload(volume, colour: true)
                let expected = try reference.render(request)
                expect(got.bgra == expected.bgra && got.scalar == expected.scalar, "RGB capacity reuse changed pixels")
            }
            expect(resized.outputAllocations == [1, 2, 0], "RGB scalar capacity did not grow independently")
            expect(resized.outputCapacities == [65536, 196608, 0], "unexpected retained capacity")
            resized.release()
            expect(resized.outputCapacities == [0, 0, 0], "release retained output capacity")
        }

        // The unskipped renderer is the oracle: each channel can reach its
        // extreme in a different brick, and a halo voxel may change that extreme.
        // Reupload on the same engine verifies invalidation of the bounds.
        var comparisons = 0
        for backend in [MetalComputeBackend.metal3, .metal4] {
            if backend == .metal4 && !Metal4ComputeSubmitter.isSupported(device) { continue }
            for hardware in [false, true] {
                let fast = try VolumeMetalRenderer(device: device, hardwareFiltering: hardware, backend: backend)
                let oracle = try VolumeMetalRenderer(device: device, hardwareFiltering: hardware, emptySpaceSkipping: false, backend: backend)
                let side = 33
                for pattern in 0..<12 {
                    var bytes = [UInt8](repeating:0,count:side*side*side*4)
                    for z in 0..<side { for y in 0..<side { for x in 0..<side {
                        let i = ((z*side+y)*side+x)*4
                        bytes[i] = 255
                        for c in 0..<3 {
                            let dense = (x*31+y*17+z*11+c*47)%256
                            let spike = (z == 7+c*8 || x == 8+c*8) && y >= 8 && y <= 24
                            bytes[i+c+1] = UInt8(pattern == 0 ? (spike ? 255-c*35 : 7+c*11) : pattern == 1 ? dense : [0,1,2,3,7,31,127,128,254,255][pattern-2])
                        }
                    } } }
                    let data = try ResliceVolume(width:side,height:side,depth:side,voxels:Data(bytes),voxelToWorld:matrix_identity_float4x4)
                    try fast.upload(data,colour:true); try oracle.upload(data,colour:true)
                    for reverse in [false,true] {
                        let cam = try VolumeCamera(position: reverse ? SIMD3(61,43,95) : SIMD3(-29,-11,-63),
                            focalPoint:SIMD3(16,16,16),viewUp:SIMD3(0,-1,0),parallel:true,parallelScale:24,viewAngle:30,clippingRange:nil)
                        for anchored in [false,true] {
                            for mode in [VolumeRenderingMode.maximum,.minimum,.mean,.composite] {
                                let depth = [Float](repeating:110,count:29*25).withUnsafeBufferPointer { Data(buffer:$0) }
                                let q = try VolumeRenderRequest(camera:cam,transfer:colourTransfer,mode:mode,shading:VolumeShading(enabled:false),
                                    crop:(SIMD3(0,1,2),SIMD3(32,31,30)),width:29,height:25,sampleStep:0.37,
                                    scalarBackground:-1234,anchoredProjection:anchored,clippingPlanes:[SIMD4(1,0,0,-2)],geometryDepth:depth)
                                let got=try fast.render(q), expected=try oracle.render(q)
                                comparisons += 1
                                expect(got.scalar == expected.scalar && got.bgra == expected.bgra,
                                    "RGB skipping changed pixels: backend \(backend), hardware \(hardware), pattern \(pattern), reverse \(reverse), anchored \(anchored), mode \(mode)")
                            }
                        }
                    }
                }
                fast.release(); oracle.release()
            }
        }

        print("PASS: \(comparisons) exact RGB renderer comparisons")
        if CommandLine.arguments.contains("bench") {
            guard Metal4ComputeSubmitter.isSupported(device) else {
                print("SKIP: benchmark requires Metal 4; renderer correctness checks passed")
                exit(2)
            }
            var measurements: [[String:Any]] = []
            for pattern in ["sparse", "dense"] {
                let n = 128
                var bytes = [UInt8](repeating:0,count:n*n*n*4)
                for z in 0..<n { for y in 0..<n { for x in 0..<n {
                    let i=((z*n+y)*n+x)*4; bytes[i]=255
                    let interior = x>40 && x<88 && y>40 && y<88 && z>40 && z<88
                    for c in 0..<3 { bytes[i+c+1] = UInt8(pattern == "dense" ? (x*31+y*17+z*11+c*47)%256 : interior ? 200+c*20 : 5+c*7) }
                } } }
                let volume = try ResliceVolume(width:n,height:n,depth:n,voxels:Data(bytes),voxelToWorld:matrix_identity_float4x4)
                let off=try VolumeMetalRenderer(device:device,emptySpaceSkipping:false,backend:.metal4)
                let on=try VolumeMetalRenderer(device:device,emptySpaceSkipping:true,backend:.metal4)
                let cam=try VolumeCamera(position:SIMD3(-20,35,-180),focalPoint:SIMD3(64,64,64),viewUp:SIMD3(0,-1,0),parallel:true,parallelScale:80,viewAngle:30,clippingRange:nil)
                let q=try VolumeRenderRequest(camera:cam,transfer:colourTransfer,mode:.maximum,shading:VolumeShading(enabled:false),crop:nil,width:192,height:160,sampleStep:0.285714,anchoredProjection:true)
                for pass in 0..<2 {
                    for (label,engine) in (pass == 0 ? [("off",off),("on",on)] : [("on",on),("off",off)]) {
                        let start=ProcessInfo.processInfo.systemUptime
                        try engine.upload(volume,colour:true)
                        let upload=(ProcessInfo.processInfo.systemUptime-start)*1000
                        var samples:[Double]=[]
                        for i in -5..<25 {
                            let start=ProcessInfo.processInfo.systemUptime
                            let result=try engine.render(q)
                            let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000
                            expect(!result.scalar.isEmpty,"empty benchmark image")
                            if i>=0 { samples.append(elapsed) }
                        }
                        measurements.append(["pattern":pattern,"skip":label,"pass":pass,"upload_ms":upload,"render_ms":samples])
                    }
                }
            }
            let data=try JSONSerialization.data(withJSONObject:measurements,options:[.sortedKeys])
            print("BENCHMARK: "+String(decoding:data,as:UTF8.self))
        }
        print("PASS: one red component composes within \(worst) levels of the scalar channel; MIP, MinIP and mean of three components down each column equal its samples'")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-volume-rgb-') as name:
    work = Path(name)
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift', 'VolumeMetalRenderer.swift',
               'MetalPerformanceTrace.swift', 'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    for source in sources:
        (work / source).write_text(read('Horos/Sources/' + source))
    (work / 'Check.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-Onone' if arguments.optimization == 'debug' else '-O', '-parse-as-library', '-suppress-warnings',
                            *[str(work / s) for s in sources], str(work / 'Check.swift'), '-o', str(work / 'check')])
    if build.returncode:
        print('FAIL: the renderer does not build with the RGB driver')
        raise SystemExit(1)
    raise SystemExit(subprocess.run([str(work / 'check')] + (['bench'] if arguments.benchmark else []), timeout=300).returncode)
