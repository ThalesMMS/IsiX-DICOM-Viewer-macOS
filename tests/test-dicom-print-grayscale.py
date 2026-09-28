#!/usr/bin/env python3
from pathlib import Path
import subprocess,tempfile
from sources import source_text
root=Path(__file__).resolve().parent.parent
# AYNSImageToDicom is Swift since #717: the method is compiled as it is in the app.
source=source_text('AYNSImageToDicom')
start=source.index('    func _convertRGB(toGrayscale image: NSImage!) -> rawData {',source.index('public final class AYNSImageToDicom'))
end=source.find('\n    //********',start)
method=source[start:end]
program=r'''
import AppKit
struct rawData { var bytesWritten = 0, height = 0, width = 0 }
final class Converter: NSObject {
 var m_ImageDataBytes: NSMutableData?
 func data() -> NSData? { return m_ImageDataBytes }
METHOD
}
func check(_ v: Bool, _ what: String) { if !v { print("failed: " + what); exit(1) } }
for channels in 3...4 {
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:channels,hasAlpha:channels==4,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:64*channels+16,bitsPerPixel:channels*8)!
 for y in 0..<32 { for x in 0..<64 { var pixel:[Int]=[40,100,180,255]; rep.setPixel(&pixel,atX:x,y:y) } }
 let image=NSImage(size:NSMakeSize(32,16));image.addRepresentation(rep)
 let converter=Converter();let raw=converter._convertRGB(toGrayscale:image)
 check(raw.width==64 && raw.height==32 && raw.bytesWritten==2048, "raw.width==64 && raw.height==32 && raw.bytesWritten==2048")
 let bytes=converter.data()!.bytes.assumingMemoryBound(to:UInt8.self)
 for i in 0..<2048 { check(bytes[i]==91, "bytes[i]==91") }
}
print("PASS: RGB/RGBA, row padding, grayscale weights and pixel dimensions independent of logical image size")
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-print-gray-') as directory:
 p=Path(directory);(p/'main.swift').write_text(program)
 subprocess.run(['xcrun','swiftc','-sanitize=address',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
