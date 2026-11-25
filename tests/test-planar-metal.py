#!/usr/bin/env python3
"""Compare the actual planar Metal shader with an independent scalar oracle.

No app or window is launched. Fixtures and GPU readback remain in memory.
Tolerance fixed before comparison: one 8-bit level per channel; nearest and
constant/discrete-CLUT cases are exact where no rounding boundary is involved.

The high-quality interpolation of a scalar image (the host's software scale) is
a Catmull-Rom in the fragment over the samples held within the window, kept
within the four texels a linear sample reads: the float samples are uploaded as
they are, the oracle computes the same cubic, and an edge from a CT's padding
outside its field of view (-8192 HU) to tissue (40 HU) never comes out brighter
than the tissue, where the former Lanczos enlargement of the samples in HU rang
to white, and ramps across the texel instead of snapping to the texel grid;
the same holds against bone on the high side, with the window inverted too,
and the result is kept within the four texels a linear sample reads, not all
sixteen.
"""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile
from sources import class_text
import process_graph_stand_in  # the Metal sources read their development switches through PreferencesSource

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--renderer-source', type=Path, default=root/'Horos/Sources/PlanarMetalRenderer.swift')
args = parser.parse_args()
# Compile the real host RGB windowing rule as the control. Copying its formula
# into the Swift oracle would let the same quantization mistake pass both sides.
# DCMPix hands the rule to the IsiXImaging module (WindowRendering.colourTable);
# a revision that still has it in Objective-C is compiled from DCMPix.m.
pix = class_text('DCMPix')
if '// ***** SOURCE IMAGE IS RGBA' not in pix:
    # The 8-bit picture is DCMPix+Display.swift's, which windows colour through the module.
    display = (root/'Horos/Sources/DCMPix+Display.swift').read_text()
    assert 'WindowRendering.colourTable(level: iwl, window: iww' in display, 'DCMPix no longer windows a colour image through the module'
    rgb, span = '', None
else:
    rgb = pix[pix.index('// ***** SOURCE IMAGE IS RGBA'):]
    span = re.search(r'long\s+diff = max - min, val;', rgb)
if span:
    loop = re.search(r'for\( long i = 0; i < 256; i\+\+\)\s*\{[^{}]*convTable\[i\] = val;\s*\}', rgb).group()
    bounds = re.search(r'min = iwl - iww / 2;\s*max = iwl \+ iww / 2;', pix).group()
    host_rule = 'void hostRGBTable(float iwl, float iww, unsigned char *convTable) { float min, max;\n' + bounds + '\n' + span.group() + '\n' + loop + '\n}\n'
else:
    assert not rgb or 'renderColour:' in rgb, 'DCMPix no longer windows a colour image through the module'
    host_rule = None
HOST_SWIFT = '''
import IsiXImaging
func hostRGBTable(_ level: Float, _ width: Float, _ table: UnsafeMutablePointer<UInt8>) {
    for (index, value) in WindowRendering.colourTable(level: level, window: width, table: nil).enumerated() { table[index] = value }
}
'''
driver = r'''
import Foundation
import Metal

@main struct Check {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("skipped: Metal device unavailable"); exit(2) }
        let renderer = try PlanarMetalRenderer(device: device)
        // Device/source/descriptor identity determines a pipeline, never the renderer instance.
        let secondRenderer = try PlanarMetalRenderer(device: device)
        precondition(renderer.queue !== secondRenderer.queue)
        precondition(renderer.pipeline === secondRenderer.pipeline && renderer.fusionPipeline === secondRenderer.fusionPipeline)
        precondition(renderer.bufferPipeline === secondRenderer.bufferPipeline && renderer.bufferFusionPipeline === secondRenderer.bufferFusionPipeline)
        let compileLock = NSLock()
        var identities = [ObjectIdentifier]()
        // A new source key forces concurrent cold requests down the cache's compilation path.
        let source = PlanarMetalRenderer.shader + "\n// concurrent cache test"
        let key = PlanarMetalRenderer.PipelineCache.Key(vertex: "planarVertex", fragment: "planarFragment",
            colorFormat: .bgra8Unorm, sampleCount: 1, blending: false)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let state = try! PlanarMetalRenderer.PipelineCache.pipeline(device: device, source: source, key: key)
            compileLock.withLock { identities.append(ObjectIdentifier(state)) }
        }
        precondition(Set(identities).count == 1, "same key compiled concurrently into different objects")
        let different = PlanarMetalRenderer.PipelineCache.Key(vertex: "planarVertex", fragment: "planarFragment",
            colorFormat: .rgba8Unorm, sampleCount: 1, blending: true)
        let changedState = try PlanarMetalRenderer.PipelineCache.pipeline(device: device, source: source, key: different)
        precondition(ObjectIdentifier(changedState) != identities[0], "descriptor variants collided")
        let missing = PlanarMetalRenderer.PipelineCache.Key(vertex: "missingVertex", fragment: "planarFragment",
            colorFormat: .bgra8Unorm, sampleCount: 1, blending: false)
        for _ in 0..<2 {
            do { _ = try PlanarMetalRenderer.PipelineCache.pipeline(device: device, source: source, key: missing)
                 preconditionFailure("missing function accepted") } catch { }
        }
        let afterFailure = try PlanarMetalRenderer.PipelineCache.pipeline(device: device, source: source, key: key)
        precondition(ObjectIdentifier(afterFailure) == identities[0], "failure poisoned existing pipelines")
        let w=8, h=5
        let values = (0..<w*h).map { Float(($0*31)%256) }
        let floats = values.withUnsafeBytes { Data($0) }
        var argb=[UInt8](), clut=[UInt8]()
        for i in 0..<w*h { argb += [255,UInt8((i*31)%256),UInt8(255-(i*31)%256),UInt8((i*11)%256)] }
        // Deliberately discrete: interpolating colours would create forbidden green.
        for i in 0..<256 { clut += i < 128 ? [0,0,255,255] : [255,255,0,255] }
        func payload(color:Bool, nearest:Bool) -> NSMutableDictionary {
            ["width":w,"height":h,"pixels":color ? Data(argb) : floats,"clut":Data(clut),
             "frameIdentity":"synthetic/1","level":128.0,"widthWindow":256.0,
             "screenToPixel":[0.0,0.0,8.0,0.0,0.0,5.0],"viewSize":[8.0,5.0],
             "isColor":color,"nearest":nearest]
        }
        func byte(_ value:Double) -> Int { Int((min(1,max(0,value))*255+0.5).rounded(.down)) }
        func catmullRom(_ t:Double) -> [Double] {
            let t2=t*t, t3=t2*t
            return [-0.5*t3+t2-0.5*t, 1.5*t3-2.5*t2+1, -1.5*t3+2*t2+0.5*t, 0.5*t3-0.5*t2]
        }
        func expected(_ frame:PlanarFrame, _ outW:Int, _ outH:Int, _ color:Bool, _ nearest:Bool, cubic:Bool = false) -> [UInt8] {
            var result=[UInt8]()
            let scale=min(Double(outW)/8,Double(outH)/5), sx=8*scale, sy=5*scale
            func scalar(_ x:Int,_ y:Int,_ c:Int)->Double {
                let index=min(h-1,max(0,y))*w+min(w-1,max(0,x))
                return color ? Double(argb[index*4+c+1]) : Double(values[index])
            }
            for row in 0..<outH { for column in 0..<outW {
                let u=(Double(column)+0.5-(Double(outW)-sx)/2)/sx
                let v=(Double(row)+0.5-(Double(outH)-sy)/2)/sy
                let x=Double(frame.mapping.x)+u*Double(frame.mapping.z)+v*Double(frame.geometry.x)
                let y=Double(frame.mapping.y)+u*Double(frame.mapping.w)+v*Double(frame.geometry.y)
                if u<0 || u>=1 || v<0 || v>=1 || x<0 || x>=Double(w) || y<0 || y>=Double(h) {
                    result += [0,0,0,255]; continue
                }
                var rgb=[UInt8]()
                for channel in 0..<3 {
                    let intensity:Double
                    if nearest { intensity=scalar(Int(floor(x)),Int(floor(y)),channel) }
                    else if cubic {
                        let a=Double(frame.window.x)-Double(frame.window.y)/2, b=Double(frame.window.x)+Double(frame.window.y)/2
                        let margin=abs(Double(frame.window.y))/2
                        func shown(_ v:Double) -> Double { min(max(v,min(a,b)-margin),max(a,b)+margin) }
                        let xx=x-0.5, yy=y-0.5, x0=Int(floor(xx)), y0=Int(floor(yy))
                        let wx=catmullRom(xx-floor(xx)), wy=catmullRom(yy-floor(yy))
                        var sum=0.0, low=shown(scalar(x0,y0,channel)), high=low
                        for j in 0..<4 {
                            var row=0.0
                            for i in 0..<4 {
                                let c=shown(scalar(x0-1+i,y0-1+j,channel)); row+=wx[i]*c
                                if (i==1||i==2) && (j==1||j==2) { low=min(low,c); high=max(high,c) }
                            }
                            sum+=wy[j]*row
                        }
                        intensity=min(max(sum,low),high)
                    }
                    else {
                        let xx=x-0.5, yy=y-0.5, x0=Int(floor(xx)), y0=Int(floor(yy))
                        let dx=xx-Double(x0),dy=yy-Double(y0)
                        intensity=scalar(x0,y0,channel)*(1-dx)*(1-dy)
                            + scalar(x0+1,y0,channel)*dx*(1-dy)
                            + scalar(x0,y0+1,channel)*(1-dx)*dy
                            + scalar(x0+1,y0+1,channel)*dx*dy
                    }
                    let minimum=Double(frame.window.x)-Double(frame.window.y)/2
                    let index = color
                        ? Int(min(255,max(0,(intensity-minimum)*255/Double(Int(frame.window.y)))))
                        : byte((intensity-minimum)/Double(frame.window.y))
                    rgb.append(clut[4*index+channel])
                }
                result += [rgb[2],rgb[1],rgb[0],255]
            }}
            return result
        }
        var checked=0
        // Exact host conversion-table comparison, including a CLUT transition
        // between entries 0 and 1: fixed8 RGB black must stay entry 0, not red.
        let bytePixels=Data((0..<256).flatMap { [UInt8(255),UInt8($0),UInt8($0),UInt8($0)] })
        for (level,widthWindow) in [(127.0,256.0),(128.0,256.0),(127.0,251.75)] {
            var host=[UInt8](repeating:0,count:256)
            host.withUnsafeMutableBufferPointer { hostRGBTable(Float(level),Float(widthWindow),$0.baseAddress!) }
            if level==127 && widthWindow==256 { assert(host[0]==0 && host[1]==1) }
            for boundaryOnly in [true,false] {
                let table=(0..<256).flatMap { i -> [UInt8] in
                    if boundaryOnly { return i==0 ? [0,0,0,255] : [255,0,0,255] }
                    return [UInt8(i),UInt8(255-i),UInt8((i*73)%256),255]
                }
                let frame=try PlanarFrame([
                    "width":256,"height":1,"pixels":bytePixels,"clut":Data(table),
                    "frameIdentity":"synthetic/host-rgb","level":level,"widthWindow":widthWindow,
                    "screenToPixel":[0.0,0.0,256.0,0.0,0.0,1.0],"viewSize":[256.0,1.0],
                    "isColor":true,"nearest":true])
                try renderer.update(frame)
                let actual=[UInt8](try renderer.renderBGRA(width:256,height:1))
                for i in 0..<256 {
                    let offset=Int(host[i])*4
                    let expected=[table[offset+2],table[offset+1],table[offset],255]
                    assert(Array(actual[i*4..<i*4+4])==expected,
                        "DCMPix RGB mismatch pixel=\(i) level=\(level) width=\(widthWindow) boundary=\(boundaryOnly)")
                }
                checked += 256
            }
        }
        for color in [false,true] { for inverted in (color ? [false] : [false,true]) { for nearest in [false,true] {
          for cubic in (color || nearest ? [false] : [false,true]) { for transform in 0..<3 {
            let value=payload(color:color,nearest:nearest)
            if cubic { value["softwareScale"]=2 }
            var frame=try PlanarFrame(value)
            precondition(frame.softwareScale == 1 && (frame.window.w == 2) == cubic, "float samples enlarged on the CPU")
            if inverted { frame.window.y = -frame.window.y }
            if transform==1 { frame.mapping=SIMD4(8,0,-8,0) }
            if transform==2 { frame.mapping=SIMD4(1,0.3,4,1);frame.geometry.x = -1;frame.geometry.y=3 }
            try renderer.update(frame)
            for size in [(8,5),(17,11),(6,16)] {
                let actual=[UInt8](try renderer.renderBGRA(width:size.0,height:size.1))
                let reference=expected(frame,size.0,size.1,color,nearest,cubic:cubic)
                let errors=zip(actual,reference).map { abs(Int($0)-Int($1)) }
                guard errors.max()! <= 1 else {
                    fatalError("pixel mismatch color=\(color) nearest=\(nearest) cubic=\(cubic) transform=\(transform) size=\(size) max=\(errors.max()!) index=\(errors.firstIndex(where:{$0>1})!)")
                }
                checked += size.0*size.1
            }
        }}}}}
        // A CT's padding outside its field of view next to tissue: -8192 HU,
        // then 40 HU, in a 45/310 window whose bottom is -110 HU. Enlarged in HU
        // by Lanczos, the tissue at the edge rang to +889 HU, white. The bounded
        // cubic never leaves the four texels around a sample: nothing is
        // brighter than the tissue, and the tissue away from the edge is itself.
        do {
            let ew=16, eh=4
            let edge=(0..<ew*eh).map { Float($0 % ew < 6 ? -8192 : 40) }
            let gray:[UInt8]=(0..<256).flatMap { i -> [UInt8] in [UInt8(i),UInt8(i),UInt8(i),255] }
            let tissue=byte((40.0-(45.0-155.0))/310.0)
            for scale in [2,3] {
                let frame=try PlanarFrame(["width":ew,"height":eh,"pixels":edge.withUnsafeBytes { Data($0) },"clut":Data(gray),
                    "frameIdentity":"synthetic/edge","level":45.0,"widthWindow":310.0,
                    "screenToPixel":[0.0,0.0,Double(ew),0.0,0.0,Double(eh)],"viewSize":[Double(ew*8),Double(eh*8)],
                    "softwareScale":scale])
                try renderer.update(frame)
                let shown=[UInt8](try renderer.renderBGRA(width:ew*8,height:eh*8))
                let brightest=stride(from:0,to:shown.count,by:4).map { Int(shown[$0]) }.max()!
                precondition(brightest <= tissue, "the edge of the field of view rang to \(brightest), tissue is \(tissue)")
                precondition(Int(shown[4*(ew*8*16+ew*8-2)]) == tissue, "tissue away from the edge is not itself")
                // Held within the widened window first, the padding is half a
                // window below its bottom: the edge still ramps over part of
                // the texel, eight pixels wide here, where the padding as it
                // is would cross the window within a hundredth of it.
                let row=(0..<ew*8).map { Int(shown[4*(ew*8*16+$0)]) }
                let ramp=row.filter { $0 > 0 && $0 < tissue }.count
                precondition(ramp >= 3, "the edge snaps to the texel grid: \(ramp) intermediate pixels")
                checked += ew*eh*64
            }
        }
        // The high side of the window, and an inverted window, whose bounds
        // swap: tissue (40 HU) next to bone (3000 HU) ramps across the texel
        // between what the window shows of each, and the tissue away from the
        // edge keeps its own grey.
        do {
            let ew=16, eh=4
            let bone=(0..<ew*eh).map { Float($0 % ew < 8 ? 40 : 3000) }
            let gray:[UInt8]=(0..<256).flatMap { i -> [UInt8] in [UInt8(i),UInt8(i),UInt8(i),255] }
            for inverted in [false,true] {
                var frame=try PlanarFrame(["width":ew,"height":eh,"pixels":bone.withUnsafeBytes { Data($0) },"clut":Data(gray),
                    "frameIdentity":"synthetic/bone","level":45.0,"widthWindow":310.0,
                    "screenToPixel":[0.0,0.0,Double(ew),0.0,0.0,Double(eh)],"viewSize":[Double(ew*8),Double(eh*8)],
                    "softwareScale":2])
                if inverted { frame.window.y = -frame.window.y }
                try renderer.update(frame)
                let shown=[UInt8](try renderer.renderBGRA(width:ew*8,height:eh*8))
                let row=(0..<ew*8).map { Int(shown[4*(ew*8*16+$0)]) }
                let minimum=Double(frame.window.x)-Double(frame.window.y)/2
                func index(_ v:Double) -> Int { Int((min(1,max(0,(v-minimum)/Double(frame.window.y)))*255+0.5).rounded(.down)) }
                let tissue=index(40), boneShown=index(3000)
                precondition(row[2] == tissue && row[ew*8-3] == boneShown, "inverted=\(inverted): tissue \(row[2]) or bone \(row[ew*8-3]) is not what the window shows")
                let ramp=row.filter { $0 > min(tissue,boneShown) && $0 < max(tissue,boneShown) }.count
                precondition(ramp >= 4, "inverted=\(inverted): the edge against bone snaps to the texel grid: \(ramp) intermediate pixels")
                checked += ew*eh*64
            }
        }
        // The result is kept within the four texels a linear sample reads, not
        // within all sixteen: where an outer texel is beyond the inner ones the
        // two bounds differ, and the shader follows the inner four.
        do {
            // Between the two 200s of 0, 200, 200, 250 the cubic gives about 209:
            // above the inner four, below the largest of the sixteen.
            let pattern:[Float]=[0,0,200,200,250,250,250,0,0,200,200,250,100,100,0,0]
            let ew=pattern.count, eh=4, zoom=8
            let image=(0..<ew*eh).map { pattern[$0 % ew] }
            let gray:[UInt8]=(0..<256).flatMap { i -> [UInt8] in [UInt8(i),UInt8(i),UInt8(i),255] }
            let frame=try PlanarFrame(["width":ew,"height":eh,"pixels":image.withUnsafeBytes { Data($0) },"clut":Data(gray),
                "frameIdentity":"synthetic/bound","level":128.0,"widthWindow":256.0,
                "screenToPixel":[0.0,0.0,Double(ew),0.0,0.0,Double(eh)],"viewSize":[Double(ew*zoom),Double(eh*zoom)],
                "softwareScale":2])
            try renderer.update(frame)
            let shown=[UInt8](try renderer.renderBGRA(width:ew*zoom,height:eh*zoom))
            func v(_ i:Int) -> Double { Double(pattern[min(ew-1,max(0,i))]) }
            var power=0
            for x in 0..<ew*zoom {
                let tx=(Double(x)+0.5)/Double(zoom)-0.5, b=Int(floor(tx)), wx=catmullRom(tx-floor(tx))
                let sum=(0..<4).reduce(0.0) { $0+wx[$1]*v(b-1+$1) }
                let inner=min(max(sum,min(v(b),v(b+1))),max(v(b),v(b+1)))
                let outer=min(max(sum,(0..<4).map { v(b-1+$0) }.min()!),(0..<4).map { v(b-1+$0) }.max()!)
                func index(_ r:Double) -> Int { byte((r-0)/256) }
                if abs(index(inner)-index(outer)) > 2 { power += 1 }
                let actual=Int(shown[4*(ew*zoom*(eh*zoom/2)+x)])
                precondition(abs(actual-index(inner)) <= 1, "column \(x): \(actual), the inner-four bound gives \(index(inner)), all sixteen \(index(outer))")
            }
            precondition(power > 0, "the pattern does not tell the inner four from all sixteen")
            checked += ew*eh*zoom*zoom
        }
        // Reuse follows uploaded bytes and the CLUT independently, not presentation geometry.
        func textureBytes(_ texture: MTLTexture) -> Data {
            let stride = texture.pixelFormat == .r8Unorm ? 1 : 4
            var bytes = Data(count: texture.width * texture.height * stride)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * stride,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return bytes
        }
        func reuse(_ frame: PlanarFrame, after old: PlanarTextures, image: Bool, table: Bool) throws -> PlanarTextures {
            let oldBytes = textureBytes(old.image)
            let next = try PlanarTextures(frame, reusing: old, device: device)
            let fresh = try PlanarTextures(frame, reusing: nil, device: device)
            precondition((next.image === old.image) == image, "wrong image reuse")
            precondition((next.clut === old.clut) == table, "wrong CLUT reuse")
            precondition(textureBytes(next.image) == textureBytes(fresh.image), "reused upload differs from fresh")
            precondition(textureBytes(next.clut) == textureBytes(fresh.clut), "reused table differs from fresh")
            precondition(textureBytes(old.image) == oldBytes, "published texture was overwritten")
            return next
        }
        let plain = try PlanarFrame(payload(color: false, nearest: false))
        let original = try PlanarTextures(plain, reusing: nil, device: device)
        var moved = plain; moved.mapping.x += 2; moved.geometry.y *= -1
        _ = try reuse(moved, after: original, image: true, table: true)
        moved.window.x += 40
        _ = try reuse(moved, after: original, image: true, table: true)
        let changed = payload(color: false, nearest: false)
        var colours = clut; colours[0] ^= 255; changed["clut"] = Data(colours)
        _ = try reuse(PlanarFrame(changed), after: original, image: true, table: false)
        changed["clut"] = Data(clut); changed["pixels"] = Data(count: w*h*4)
        _ = try reuse(PlanarFrame(changed), after: original, image: false, table: true)
        // Float samples are not enlarged: the fragment interpolates them, so
        // the high-quality interpolation keeps the texture.
        let enlarged = payload(color: false, nearest: false); enlarged["softwareScale"] = 2
        _ = try reuse(PlanarFrame(enlarged), after: original, image: true, table: true)
        let tabled = payload(color: false, nearest: false)
        tabled["transferFunction"] = (0..<4096).map { Float($0)/4095 }.withUnsafeBytes { Data($0) }
        tabled["transferLevel"] = 128; tabled["transferWidth"] = 256
        let transferTextures = try reuse(PlanarFrame(tabled), after: original, image: false, table: true)
        tabled["transferLevel"] = 100
        _ = try reuse(PlanarFrame(tabled), after: transferTextures, image: false, table: true)
        let filtered = payload(color: false, nearest: false)
        filtered["convolutionSize"] = 1
        filtered["convolutionKernel"] = ([Float(2)] + Array(repeating: Float(0), count: 24)).withUnsafeBytes { Data($0) }
        filtered["convolutionNormalization"] = 1
        _ = try reuse(PlanarFrame(filtered), after: original, image: false, table: true)
        let slab = payload(color: false, nearest: false)
        slab["slabMode"] = 2; slab["slabCount"] = 2; slab["slabSlices"] = Data(count: w*h*4)
        _ = try reuse(PlanarFrame(slab), after: original, image: false, table: true)
        let colour = payload(color: true, nearest: false); colour["hostBytes"] = Data(argb)
        colour["colourTable"] = Data((0..<1024).map { UInt8($0 % 256) })
        let colourTextures = try PlanarTextures(PlanarFrame(colour), reusing: nil, device: device)
        colour["colourTable"] = Data((0..<1024).map { UInt8(255 - $0 % 256) })
        _ = try reuse(PlanarFrame(colour), after: colourTextures, image: false, table: true)
        // A large layer uses a buffer; geometry changes must keep that resource as well.
        let wide = payload(color: false, nearest: false)
        wide["width"] = 16385; wide["height"] = 1; wide["pixels"] = Data(count: 16385*4)
        var wideFrame = try PlanarFrame(wide)
        let wideTextures = try PlanarTextures(wideFrame, reusing: nil, device: device)
        wideFrame.mapping.x += 1
        let wideMoved = try PlanarTextures(wideFrame, reusing: wideTextures, device: device)
        precondition(wideMoved.buffer!.pixels === wideTextures.buffer!.pixels)
        // Original float values survive every display operation unchanged.
        assert(floats == values.withUnsafeBytes { Data($0) })
        for key in ["pixels","clut","widthWindow","screenToPixel"] {
            let bad=payload(color:false,nearest:false)
            if key=="pixels" || key=="clut" { bad[key]=Data() }
            if key=="widthWindow" { bad[key]=0 }
            if key=="screenToPixel" { bad[key]=[Double.nan,0,8,0,0,5] }
            do { _=try PlanarFrame(bad);fatalError("accepted invalid \(key)") } catch {}
        }
        let emptyRGBSpan=payload(color:true,nearest:true)
        emptyRGBSpan["widthWindow"]=0.5
        do { _=try PlanarFrame(emptyRGBSpan);fatalError("accepted zero integer RGB span") } catch {}
        let registry=VolumeSessionRegistry()
        let identity=VolumeIdentity(studyInstanceUID:"1",seriesInstanceUID:"2")!
        let session=registry.open(identity:identity,owner:"host")!
        weak var retired: VolumeLoadToken?
        do { let completed=registry.makeLoadToken(for:session)!; retired=completed; assert(completed.deliver()) }
        let cancelled=registry.makeLoadToken(for:session)!
        assert(retired == nil, "completed frame tokens accumulate in the session")
        // Closing the session cancels every frame still outstanding.
        registry.close(session)
        assert(cancelled.isCancelled && registry.openSessionCount==0)
        renderer.clear();assert(renderer.image == nil)
        print("PASS: \(checked) GPU pixels, scalar/ARGB, discrete CLUT, interpolation, transforms, letterbox; token teardown")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='horos-planar-metal-') as temporary:
    work = Path(temporary)
    (work/'Check.swift').write_text(driver)
    if host_rule:
        (work/'HostRGB.c').write_text(host_rule)
        (work/'HostRGB.h').write_text('void hostRGBTable(float level, float width, unsigned char *table);\n')
        subprocess.run(['xcrun','clang','-O0','-c',str(work/'HostRGB.c'),'-o',str(work/'HostRGB.o')],check=True)
        host = [str(work/'HostRGB.o'),'-import-objc-header',str(work/'HostRGB.h')]
    else:
        import sys
        sys.path.insert(0, str(root/'tests'))
        from isix_modules import module_flags
        (work/'HostRGB.swift').write_text(HOST_SWIFT)
        host = [str(work/'HostRGB.swift'), *module_flags('IsiXImaging', work/'modules')]
    sources = ['VolumeAllocation.swift', 'VolumeSession.swift', 'MPRMetalReslicer.swift',
               'MetalPerformanceTrace.swift', 'MetalComputePipelineCache.swift', 'Metal4ComputeSubmitter.swift']
    subprocess.run(['xcrun','swiftc','-parse-as-library',*[str(root/'Horos/Sources'/name) for name in sources],
                    str(args.renderer_source),*host,*process_graph_stand_in.swift_flags(work/'modules'),
                    str(work/'Check.swift'),'-o',str(work/'check')],check=True)
    result = subprocess.run([str(work/'check')],timeout=30)
    if result.returncode == 2:
        raise SystemExit(2)
    result.check_returncode()
