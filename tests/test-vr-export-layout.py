#!/usr/bin/env python3
"""Exercise the Swift export layout with real AppKit constraints and controlled scales."""
from pathlib import Path
import re, subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
code=r'''
import AppKit
final class ScaledView: NSView {
    var scale: CGFloat = 1
    override func convertFromBacking(_ size: NSSize) -> NSSize {
        NSSize(width: size.width / scale, height: size.height / scale)
    }
}
@main struct Test {
    static func main() {
        _ = NSApplication.shared
        precondition(HorosCheckVRImageDrawing(), "Production VR image drawing must be opaque and fill the nil-image background")
        for scale: CGFloat in [1, 2] {
            for pixels: CGFloat in [0, 512, 768] {
                let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
                let view = ScaledView(frame: .zero)
                view.scale = scale
                view.translatesAutoresizingMaskIntoConstraints = false
                view.autoresizingMask = [.width, .height]
                root.addSubview(view)
                let constraints = [view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 7),
                    view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: 8),
                    view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -14),
                    view.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -28)]
                NSLayoutConstraint.activate(constraints)
                root.layoutSubtreeIfNeeded()
                let before = view.frame
                precondition(before.size == NSSize(width: 986, height: 772))
                let requestedFrame = pixels == 0 ? NSRect(x: 3, y: 9, width: 854, height: 503) : before
                if pixels == 0 { view.frame = requestedFrame }
                let layout = VRExportLayout(view: view, pixelSize: pixels)
                root.layoutSubtreeIfNeeded()
                if pixels == 0 {
                    for _ in 0..<5 {
                        root.needsLayout = true
                        root.layoutSubtreeIfNeeded()
                        precondition(view.frame == requestedFrame, "Current frame changed between exported frames")
                    }
                } else {
                    precondition(view.frame.width * scale == pixels && view.frame.height * scale == pixels)
                    precondition(view.frame.midX == root.bounds.midX && view.frame.midY == root.bounds.midY)
                }
                precondition(constraints.allSatisfy { !$0.isActive })
                layout.restore()
                precondition(view.frame == before)
                precondition(constraints.allSatisfy { $0.isActive })
                precondition(!view.translatesAutoresizingMaskIntoConstraints)
                precondition(view.autoresizingMask == [.width, .height])
                layout.restore()
                precondition(view.frame == before)
            }
        }
        print("PASS: production VR drawing is opaque with nil-image black background; Current and 512/768 pixel targets at controlled 1x/2x scales survive AppKit layout and restore frame, constraints and autoresizing")
    }
}
'''
def objc_method(source, signature):
 start=source.index(signature)
 masked=re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', lambda match: ' ' * len(match.group()), source, flags=re.S)
 brace=masked.index('{',start); depth=1; end=brace+1
 while depth:
  if masked[end]=='{': depth+=1
  elif masked[end]=='}': depth-=1
  end+=1
 return source[start:end]

vr_source=(root/'Horos/Sources/VRView.mm').read_text(encoding='latin1')
drawing=objc_method(vr_source, '- (void)drawImage:(NSImage *)image inBounds:(NSRect)rect')
def dragging_methods(source):
 return '\n'.join(objc_method(source, signature) for signature in [
  '- (NSDragOperation)horosSourceOperationMask',
  '- (NSDragOperation)draggingSession:',
  '- (NSDragOperation)draggingSourceOperationMaskForLocal:'])
sr_source=(root/'Horos/Sources/SRView.mm').read_text(encoding='latin1')
probe=r'''#import <AppKit/AppKit.h>
@interface ImageDrawingProbe : NSObject
- (void)drawImage:(NSImage *)image inBounds:(NSRect)rect;
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal;
@end
@implementation ImageDrawingProbe
PRODUCTION_DRAWING
VR_DRAGGING
@end
@interface SurfaceDraggingProbe : NSObject
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal;
@end
@implementation SurfaceDraggingProbe
SR_DRAGGING
@end
BOOL HorosCheckVRImageDrawing(void) { @autoreleasepool {
 ImageDrawingProbe *probe=[ImageDrawingProbe new];
 SurfaceDraggingProbe *surface=[SurfaceDraggingProbe new];
 for(id source in @[probe,surface]) {
  if([source draggingSourceOperationMaskForLocal:YES]!=NSDragOperationGeneric || [source draggingSourceOperationMaskForLocal:NO]!=NSDragOperationGeneric) return NO;
 }
 for (NSInteger variant=0; variant<3; ++variant) {
  NSBitmapImageRep *pixels=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:32 pixelsHigh:32 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  NSImage *image=nil;
  if (variant<2) {
   NSInteger w=variant==0 ? 4:2, h=variant==0 ? 2:4;
   NSBitmapImageRep *input=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
   for(NSInteger y=0;y<h;++y)for(NSInteger x=0;x<w;++x)[input setColor:[NSColor colorWithDeviceRed:1 green:0 blue:0 alpha:1] atX:x y:y];
   image=[[NSImage alloc] initWithSize:NSMakeSize(w,h)]; [image addRepresentation:input];
  }
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:pixels]];
  [probe drawImage:image inBounds:NSMakeRect(0,0,32,32)];
  [[NSGraphicsContext currentContext] flushGraphics];
  [NSGraphicsContext restoreGraphicsState];
  NSColor *center=[[pixels colorAtX:16 y:16] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
  NSColor *corner=[[pixels colorAtX:0 y:0] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
  if(center.alphaComponent<0.99 || corner.alphaComponent<0.99) return NO;
  if(variant<2 && (center.redComponent<0.99 || center.greenComponent>0.01 || center.blueComponent>0.01)) return NO;
  if(variant==2 && (center.redComponent>0.01 || center.greenComponent>0.01 || center.blueComponent>0.01 || corner.redComponent>0.01 || corner.greenComponent>0.01 || corner.blueComponent>0.01)) return NO;
 }
 return YES;
}}
#ifdef HOROS_NEGATIVE_DRAWING
int main(void) { @autoreleasepool { [NSApplication sharedApplication]; return HorosCheckVRImageDrawing() ? 1 : 0; }}
#endif
'''.replace('PRODUCTION_DRAWING', drawing).replace('VR_DRAGGING', dragging_methods(vr_source)).replace('SR_DRAGGING', dragging_methods(sr_source))

with tempfile.TemporaryDirectory(prefix='horos-export-layout-') as d:
 p=Path(d);(p/'test.swift').write_text(code)
 (p/'drawing.m').write_text(probe)
 (p/'Drawing.h').write_text('#import <Foundation/Foundation.h>\nBOOL HorosCheckVRImageDrawing(void);\n')
 subprocess.run(['xcrun','clang','-c','-fobjc-arc','-Werror',str(p/'drawing.m'),'-o',str(p/'drawing.o')],check=True)
 source = subprocess.check_output(['git','show',sys.argv[1]+':Horos/Sources/VRExportLayout.swift']) if len(sys.argv)>1 else (root/'Horos/Sources/VRExportLayout.swift').read_bytes()
 (p/'layout.swift').write_bytes(source)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-import-objc-header',str(p/'Drawing.h'),str(p/'drawing.o'),str(p/'layout.swift'),str(p/'test.swift'),'-framework','AppKit','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
 # The historical Carbon 'fraction' constant resolved to zero opacity.
 # The same pixel assertions must reject that actual drawing behavior.
 (p/'negative.m').write_text(probe.replace('fraction:1.0', 'fraction:0.0'))
 subprocess.run(['xcrun','clang','-fobjc-arc','-Werror','-DHOROS_NEGATIVE_DRAWING',str(p/'negative.m'),'-framework','AppKit','-o',str(p/'negative')],check=True)
 subprocess.run([str(p/'negative')],check=True)
