#!/usr/bin/env python3
"""Exercise production blended windowing without mutating primary WL/WW.

The drag is Swift (VRView+Mouse.swift): its fused-series case and the window
it computes (draggedWindow) are compiled into a Swift stand-in of the view, the
defaults registered for each PET windowing mode. A revision whose drag is
still in VRView.m runs the Objective-C case instead."""
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
path='Horos/Sources/VRView.m'
def read(name, encoding):
    try:
        return (subprocess.check_output(['git','show',sys.argv[1]+':'+name],stderr=subprocess.DEVNULL) if len(sys.argv)>1 else (root/name).read_bytes()).decode(encoding)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ''
s=read(path,'latin1')
mouse=read('Horos/Sources/VRView+Mouse.swift','utf-8')
swift_drag='- (void)mouseDragged:' not in s
if swift_drag:
    a=mouse.index('            case .tWLBlended:',mouse.index('public override func mouseDragged(with theEvent: NSEvent)'))
    b=mouse.index('            case .tWL:',a)
    block=mouse[a:b].replace('case .tWLBlended:', 'case 0:')
    c=mouse.index('    private func draggedWindow(')
    dragged=mouse[c:mouse.index('\n    }\n',c)+7].replace('NSEvent','Event')
else:
    a=s.index('            case tWLBlended:',s.index('- (void)mouseDragged:'))
    b=s.index('            case tWL:',a)
    block=s[a:b].replace('case tWLBlended:', 'case 0:')
code=r'''
#import <Cocoa/Cocoa.h>
#include <cmath>
static NSInteger mode;
@interface TestDefaults:NSObject
+ (id)standardUserDefaults;
- (NSInteger)integerForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation TestDefaults
+ (id)standardUserDefaults { return [[[self alloc] init] autorelease]; }
- (NSInteger)integerForKey:(NSString *)key { return [key isEqualToString:@"PETWindowingMode"]?mode:0; }
- (BOOL)boolForKey:(NSString *)key { return YES; }
@end
#define NSUserDefaults TestDefaults
@interface Event:NSObject { @public double dx,dy; }
- (double)deltaX; - (double)deltaY;
@end
@implementation Event
- (double)deltaX {return dx;} - (double)deltaY {return dy;}
@end
@interface Controller:NSObject { @public NSString *kind; }
- (id)blendingController; - (NSString *)modality;
@end
@implementation Controller
- (id)blendingController {return self;} - (NSString *)modality {return kind;}
@end
@interface Harness:NSObject { @public float wl,ww,blendingWl,blendingWw; Controller *controller; }
- (void)apply:(Event *)theEvent;
@end
@implementation Harness
- (void)setBlendingWLWW:(float)level :(float)width { blendingWl=level;blendingWw=width; }
- (void)setNeedsDisplay:(BOOL)value {}
- (void)apply:(Event *)theEvent {
 float _startWW,_startWL,_startMin,_startMax,WWAdapter,endlevel,startlevel;
 switch(0) { BLOCK }
}
@end
int main(){ @autoreleasepool {
 int count=0;
 for(NSString *modality in @[@"PT",@"NM",@"CT"])for(mode=0;mode<3;mode++)for(int drag=0;drag<4;drag++) {
  Controller *controller=[Controller new];controller->kind=modality;
  Harness *h=[Harness new];h->controller=controller;h->wl=150;h->ww=1000;h->blendingWl=50;h->blendingWw=100;
  Event *event=[Event new];event->dx=drag==1?20:drag==3?-200:0;event->dy=drag==1?10:drag==2?200:0;
  [h apply:event];
  if(h->wl!=150 || h->ww!=1000){fprintf(stderr,"FAIL: %s mode %ld drag %d changed primary WL/WW to %g/%g\n",modality.UTF8String,(long)mode,drag,h->wl,h->ww);return 1;}
  if(!std::isfinite(h->blendingWl)||h->blendingWw<.09999)return 2;
  if(![modality isEqualToString:@"CT"] && mode>0 && h->blendingWl-h->blendingWw/2 < -1e-6)return 3;
  if(drag==0 && (h->blendingWl!=50 || h->blendingWw!=100))return 4;
  [event release];[h release];[controller release];count++;
 }
 printf("PASS: %d production blended-window cases preserve primary WL/WW, width limits and PET/NM lower bounds\n",count);
}}
'''.replace('BLOCK',block)
SWIFT=r'''import Foundation
final class Event { let deltaX: CGFloat, deltaY: CGFloat; init(_ dx: CGFloat, _ dy: CGFloat) { deltaX = dx; deltaY = dy } }
final class Controller { let kind: String; init(_ kind: String) { self.kind = kind }
    func blendingController() -> Controller? { self }; func modality() -> String? { kind } }
final class Harness {
    var horos_wl: Float = 150, horos_ww: Float = 1000, horos_blendingWl: Float = 50, horos_blendingWw: Float = 100
    var horos_startWW: Float = 0, horos_startWL: Float = 0, horos_startMin: Float = 0, horos_startMax: Float = 0
    var horos_controller: Controller?
    var needsDisplay = false
    func setBlendingWLWW(_ level: Float, _ width: Float) { horos_blendingWl = level; horos_blendingWw = width }
    func apply(_ theEvent: Event) {
        switch 0 {
BLOCK
        default: break
        }
    }
DRAGGED
}
var count = 0
for modality in ["PT", "NM", "CT"] { for mode in 0..<3 { for drag in 0..<4 {
    UserDefaults.standard.register(defaults: ["PETWindowingMode": mode, "mouseWindowingNM": true, "PETMinimumValue": 0])
    let h = Harness(); h.horos_controller = Controller(modality)
    let event = Event(drag == 1 ? 20 : drag == 3 ? -200 : 0, drag == 1 ? 10 : drag == 2 ? 200 : 0)
    h.apply(event)
    if h.horos_wl != 150 || h.horos_ww != 1000 { print("FAIL: \(modality) mode \(mode) drag \(drag) changed primary WL/WW"); exit(1) }
    if !h.horos_blendingWl.isFinite || h.horos_blendingWw < 0.09999 { exit(2) }
    if modality != "CT" && mode > 0 && h.horos_blendingWl - h.horos_blendingWw / 2 < -1e-6 { exit(3) }
    if drag == 0 && (h.horos_blendingWl != 50 || h.horos_blendingWw != 100) { exit(4) }
    count += 1
} } }
print("PASS: \(count) production blended-window cases preserve primary WL/WW, width limits and PET/NM lower bounds")
'''
with tempfile.TemporaryDirectory(prefix='horos-vr-window-') as d:
    p=Path(d)
    if swift_drag:
        (p/'main.swift').write_text(SWIFT.replace('BLOCK',block).replace('DRAGGED',dragged))
        subprocess.run(['xcrun','swiftc','-swift-version','5',str(p/'main.swift'),str(root/'Modules/IsiXVolumeRendering/Sources/CConversion.swift'),'-o',str(p/'test')],check=True)
    else:
        (p/'test.mm').write_text(code)
        subprocess.run(['xcrun','clang++','-std=c++11',str(p/'test.mm'),'-framework','Cocoa','-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
