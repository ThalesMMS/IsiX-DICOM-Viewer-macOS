#!/usr/bin/env python3
"""Run complete production wheel/drag handlers with controlled events and stacks.

No events are posted to the desktop. NSWindow/renderer/plugin side effects are
test doubles; preference policy, delta selection, index and sync logic are real.

-scrollWheel: (DCMView+Scrolling, with IsiXImaging's WheelSteps),
-mouseDraggedImageScroll: (DCMView+MouseDragging) and
-getThickSlabThickness:location: (DCMView+WindowLevel+Coordinates) are Swift.
They are compiled as they are, with xcrun swiftc, as an extension of the
Objective-C double of DCMView, whose state has the names of DCMView.swift's
stored horos_* properties, which also answers the planar host's
-horosPlanarPerformanceTrace the wheel asks for; the messages to the window
controller and the frames go through the production inputMessages,
msg/windowControllerOf and objcObject helpers. -adjustThickSlabBySteps:
(ViewerController+ThickSlab, with IsiXImaging's StackFusion) is compiled the
same way in an extension of the double of ViewerController.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
import harness_defaults  # the harness's preferences stay in its own process
import isix_modules  # noqa: E402
import re

root = Path(__file__).resolve().parents[1]
scrolling = source_text('DCMView+Scrolling')
start = scrolling.index('    @objc(scrollWheel:)\n')
wheel = scrolling[start:scrolling.index('    // MARK: - Scrolling through the study', start)]
tools = source_text('DCMView+Tools')
messages = re.search(r'@objc protocol DCMViewInputMessages \{.*?\n\}\n', tools, re.S).group(0)
messages += re.search(r'@inline\(__always\)\nfunc inputMessages\(.*?\n\}\n', tools, re.S).group(0)
messages += re.search(r'@inline\(__always\)\nfunc inputBeyondLast\(.*?\n\}\n', tools, re.S).group(0)
show = tools[tools.rindex('extension DCMView {'):]
thick = source_text('ViewerController+ThickSlab')
a = thick.index('    @objc(adjustThickSlabBySteps:)')
adjust = thick[a:thick.index('    /// The thick slab\'s on/off button', a)]
movies = re.search(r'    var horos_movieCount: Int \{[^\n]*\}\n', source_text('ViewerController+ImagePipelineSupport')).group(0)
swift = source_text('DCMView+MouseDragging')
start = swift.index('    @objc(mouseDraggedImageScroll:)')
drag = swift[start:swift.index('    @objc(mouseDraggedBlending:)', start)]
helpers = swift[swift.index('@inline(__always)\nprivate func msg('):
                swift.index('/// [NSUserDefaults standardUserDefaults].')]
coordinates = source_text('DCMView+WindowLevel+Coordinates')
a = coordinates.index('    @objc(getThickSlabThickness:location:)')
thickness = coordinates[a:coordinates.index('    @objc(displayedScaleValue)', a)]
a = coordinates.index('@inline(__always)\nprivate func objcObject<T: AnyObject>(')
object_helper = coordinates[a:coordinates.index('/// An `id` that may be nil', a)]
extension = '''import Cocoa
import IsiXImaging
typealias ROI = NSObject
typealias HorosVolumeLengthROI = NSObject
// The selectors of DCMViewDraggingMessages the drag sends.
@objc private protocol DCMViewDraggingMessages {
    @objc(windowController) func draggingWindowController() -> AnyObject?
    @objc(adjustSlider) func draggingAdjustSlider()
}
''' + messages + helpers + object_helper + 'extension DCMView {\n' + drag + thickness + wheel + '}\n' + show + \
    'extension ViewerController {\n' + movies + adjust + '}\n'
bridge = r'''
#import <AppKit/AppKit.h>
@class ViewerController, DCMView;
@interface HorosPlanarPerformanceTrace:NSObject
-(uint64_t)beginScroll:(id)e fromIndex:(NSInteger)i NS_SWIFT_NAME(beginScroll(_:fromIndex:));
-(void)endScroll:(uint64_t)s index:(NSInteger)i;
@end
@interface PluginManager:NSObject
+(BOOL)isComPACS;
@end
@interface TestWindow:NSObject
@property(readonly) BOOL isVisible, isMainWindow;
-(void)makeKeyAndOrderFront:(id)sender;
@end
@interface Control:NSObject
@property NSInteger integerValue;
@property NSControlStateValue state;
@property double maxValue;
@property BOOL enabled;
@property int intValue;
@end
@interface ViewerController:NSObject {
@public BOOL windowWillClose; short maxMovieIndex;
 NSArray *pixList[3]; Control *sliderFusion,*stacksFusion,*activatedFusion; id popFusion; DCMView *imageView;
}
@property BOOL refuse;
@property short curMovieIndex;
@property NSInteger selectedMode,appliedMode,projections;
// The accessors of ViewerController+SwiftIvars.h, on the same ivars.
@property(readonly) BOOL horos_windowWillClose;
@property(readonly) short horos_maxMovieIndex;
@property(readonly) Control *horos_sliderFusion, *horos_stacksFusion, *horos_activatedFusion;
@property(readonly) id horos_popFusion;
@property(readonly) DCMView *horos_imageView;
-(NSArray*)horos_pixListAt:(NSInteger)index;
+(BOOL)isFrontMost2DViewer:(id)w;
-(void)setFusionMode:(NSInteger)mode;
-(void)popFusionAction:(id)sender;
-(void)sliderFusionAction:(id)sender;
@end
@interface Frame:NSObject
@property NSInteger ordinal, frameNumber, stack;
@property double sliceLocation,sliceThickness;
@property(retain) NSArray *position, *orientation;
@end
// The Swift reads the frames as DCMPix.
@compatibility_alias DCMPix Frame;
@interface DCMView:NSResponder {
@public NSInteger curImage,startImage; long scrollMode; NSPoint start,pointer,origin;
 NSArray *dcmPixList; char listType; NSMatrix *matrix; NSString *stringID;
 BOOL flippedData,drawing; int _imageRows,_imageColumns; id blendingView;
 float blendingFactor,scaleValue; NSInteger syncDelta;
 double slabScrollRemainder; NSTimeInterval slabScrollTimestamp; BOOL consumeSlabScrollTail;
 BOOL openingFitPending;
}
@property NSRect frame;
@property(retain) TestWindow *window;
@property(retain) ViewerController *controller;
@property(readonly) Frame *curDCM;
@property BOOL drawing, needsDisplay;
@property(readonly) NSString *stringID;
@property(readonly) id blending;
@property(nonatomic) float scaleValue;
@property float horos_blendingFactor, horos_scaleValue;
@property NSPoint horos_origin;
@property int horos_imageRows, horos_imageColumns;
@property double horos_slabScrollRemainder;
@property NSTimeInterval horos_slabScrollTimestamp;
@property BOOL horos_consumeSlabScrollTail;
-(id)windowController;
-(HorosPlanarPerformanceTrace*)horosPlanarPerformanceTrace;
-(void)cancelOpeningScaleToFitForInteraction;
-(BOOL)scrollThroughSeriesIfNecessary:(int)i;
-(void)setBlendingFactor:(float)v;
-(void)setOriginX:(float)x Y:(float)y;
// DCMView.swift's stored horos_* properties, on the same ivars.
@property NSInteger horos_curImage,horos_startImage;
@property long horos_scrollMode;
@property NSPoint horos_start;
@property(nonatomic, assign) NSArray *horos_dcmPixList;
@property char horos_listType;
@property(nonatomic, assign) NSMatrix *horos_matrix;
@property(nonatomic, assign) NSString *horos_stringID;
@property BOOL horos_flippedData;
-(NSPoint)currentPointInView:(NSEvent*)e;
-(void)setIndex:(NSInteger)i;
-(void)setIndexWithReset:(NSInteger)i :(BOOL)b;
-(BOOL)is2DViewer;
-(void)sendSyncMessage:(NSInteger)i;
-(void)horosShowScrollPreviewAtWindowPoint:(NSPoint)point;
@end
'''
code = r'''
#import "bridge.h"
#import "Horos-Swift.h"
#include <limits.h>
#include <math.h>
@implementation PluginManager
+(BOOL)isComPACS{return NO;}
@end
@implementation TestWindow
-(BOOL)isVisible{return YES;}
-(BOOL)isMainWindow{return YES;}
-(void)makeKeyAndOrderFront:(id)sender{}
@end
@implementation Control
-(int)intValue{return (int)self.integerValue;}
-(void)setIntValue:(int)n{self.integerValue=n;}
@end
@interface ViewerController (Thickness)
-(void)adjustThickSlabBySteps:(NSInteger)steps;
@end
@implementation ViewerController
+(BOOL)isFrontMost2DViewer:(id)w{return YES;}
-(BOOL)windowWillClose{return NO;}
-(BOOL)horos_windowWillClose{return windowWillClose;}
-(short)horos_maxMovieIndex{return maxMovieIndex;}
-(Control*)horos_sliderFusion{return sliderFusion;}
-(Control*)horos_stacksFusion{return stacksFusion;}
-(Control*)horos_activatedFusion{return activatedFusion;}
-(id)horos_popFusion{return popFusion;}
-(DCMView*)horos_imageView{return imageView;}
-(NSArray*)horos_pixListAt:(NSInteger)index{return pixList[index];}
-(short)maxMovieIndex{return maxMovieIndex;}
-(void)setMovieIndex:(short)i{self.curMovieIndex=i;}
-(void)adjustSlider{}
-(void)propagateSettings{}
-(void)windowDidBecomeMain:(id)n{}
-(void)setFusionMode:(NSInteger)mode {
 self.appliedMode=mode;activatedFusion.state=mode?NSOnState:NSOffState;
 sliderFusion.enabled=mode!=0;self.projections++;
}
-(void)popFusionAction:(id)sender {[self setFusionMode:self.refuse?0:self.selectedMode];[imageView sendSyncMessage:0];}
-(void)sliderFusionAction:(id)sender {
 self.projections++;stacksFusion.integerValue=sliderFusion.integerValue;
 [NSUserDefaults.standardUserDefaults setInteger:sliderFusion.integerValue forKey:@"stackThickness"];
 [imageView sendSyncMessage:0];
}
@end
@implementation Frame
@end
#define DCMPix Frame
@interface Event:NSObject
@property BOOL precise, inverted;
@property CGFloat dy, scrollY, dx;
@property NSEventPhase phase,momentumPhase;
@property NSTimeInterval timestamp;
@property NSEventModifierFlags flags;
@end
@implementation Event
-(NSPoint)locationInWindow{return NSZeroPoint;}
-(CGFloat)deltaY{return self.dy;}
-(CGFloat)deltaX{return self.dx;}
-(CGFloat)scrollingDeltaY{return self.scrollY;}
-(CGFloat)scrollingDeltaX{return self.dx;}
-(BOOL)hasPreciseScrollingDeltas{return self.precise;}
-(BOOL)isDirectionInvertedFromDevice{return self.inverted;}
-(NSEventModifierFlags)modifierFlags{return self.flags;}
@end
@implementation DCMView
@synthesize horos_curImage=curImage,horos_startImage=startImage,horos_scrollMode=scrollMode,horos_start=start,
 horos_dcmPixList=dcmPixList,horos_listType=listType,horos_matrix=matrix,horos_stringID=stringID,horos_flippedData=flippedData,
 horos_blendingFactor=blendingFactor,horos_scaleValue=scaleValue,horos_origin=origin,horos_imageRows=_imageRows,horos_imageColumns=_imageColumns,
 horos_slabScrollRemainder=slabScrollRemainder,horos_slabScrollTimestamp=slabScrollTimestamp,horos_consumeSlabScrollTail=consumeSlabScrollTail,
 drawing=drawing;
-(id)windowController{return self.controller;}
-(HorosPlanarPerformanceTrace*)horosPlanarPerformanceTrace{return nil;}
-(NSString*)stringID{return stringID;}
-(id)blending{return blendingView;}
-(float)scaleValue{return scaleValue;}
-(BOOL)needsDisplay{return NO;}
-(void)horosShowScrollPreviewAtWindowPoint:(NSPoint)point{}
-(void)mouseMoved:(NSEvent*)event{}
-(void)cancelOpeningScaleToFitForInteraction{openingFitPending=NO;}
-(BOOL)is2DViewer{return YES;}
-(Frame*)curDCM{return dcmPixList[curImage];}
-(NSPoint)currentPointInView:(id)e{return pointer;}
-(void)setIndex:(NSInteger)i{curImage=i;}
-(void)setIndexWithReset:(NSInteger)i :(BOOL)b{curImage=i;}
-(void)sendSyncMessage:(NSInteger)i{syncDelta=i;}
-(BOOL)scrollThroughSeriesIfNecessary:(int)i{return NO;}
-(void)setBlendingFactor:(float)v{blendingFactor=v;}
-(void)setScaleValue:(float)v{scaleValue=v;}
-(void)setOriginX:(float)x Y:(float)y{origin=NSMakePoint(x,y);}
-(void)setNeedsDisplay:(BOOL)v{}
@end
#define check(...) do { if(!(__VA_ARGS__)) { NSLog(@"FAIL %s",#__VA_ARGS__); return 1; } } while(0)
int main(){@autoreleasepool{
 check([NSEvent pressedMouseButtons]==0);
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
 [defaults setBool:NO forKey:@"SelectWindowScrollWheel"];
 [defaults setBool:NO forKey:@"loopScrollWheel"];
 DCMView *v=[DCMView new];v.window=[TestWindow new];v.controller=[ViewerController new];v.controller->maxMovieIndex=3;
 v->drawing=YES;v->listType='i';v->_imageRows=v->_imageColumns=1;v->openingFitPending=YES;
 v.frame=NSMakeRect(0,0,400,200);
 // Axial, coronal, sagittal and an oblique normal. Identifiers remain in
 // acquisition order; a reversed backing array must not reverse user intent.
 NSArray *normals=@[@[@0,@0,@1],@[@0,@1,@0],@[@1,@0,@0],@[@0.6,@0,@0.8]];
 NSUInteger scenarios=0,gestures=0;
 for(NSArray *normal in normals)for(int multi=0;multi<2;multi++)
 for(int flipped=0;flipped<2;flipped++)for(int natural=0;natural<2;natural++)
 for(int reversed=0;reversed<2;reversed++)for(int precise=0;precise<2;precise++){
  NSMutableArray *frames=[NSMutableArray array];
  for(int i=0;i<20;i++){
   Frame *f=[Frame new];f.ordinal=i;f.frameNumber=multi?i:0;f.stack=3;
   f.position=@[@([normal[0] doubleValue]*i),@([normal[1] doubleValue]*i),@([normal[2] doubleValue]*i)];
   f.orientation=normal;[frames addObject:f];
  }
  v->dcmPixList=flipped?frames.reverseObjectEnumerator.allObjects:frames;
  v->flippedData=flipped;
  [defaults setBool:reversed forKey:HorosScrollDirection.reversedPreferenceKey];
  for(int down=-1;down<=1;down+=2){
   v->curImage=10;NSInteger before=v.curDCM.ordinal;
   Event *event=[Event new];event.precise=precise;event.inverted=natural;
   CGFloat deviceY=-down*(natural?-1:1);
   // Opposite, much larger values in the unused accessor detect choosing the
   // wrong field. A test that sets both fields alike would miss that defect.
   event.dy=precise?deviceY:-deviceY*20;
   event.scrollY=precise?-deviceY*20:deviceY;
   [v scrollWheel:(NSEvent*)event];
   check(v->openingFitPending); // navigating while analysis is pending must still allow its delivery
   NSInteger expected=before+down*(reversed?1:-1);
   check(v.curDCM.ordinal==expected);
   check(v.curDCM.frameNumber==(multi?expected:0));
   for(int axis=0;axis<3;axis++)check(fabs([v.curDCM.position[axis] doubleValue]-expected*[normal[axis] doubleValue])<1e-12);
   check(v->syncDelta==v->curImage-10);gestures++;
   for(int axis=1;axis<=2;axis++){
    v->curImage=v->startImage=10;v->start=NSZeroPoint;v->scrollMode=axis;
    // Height and width differ by two. The matching movements both walk one
    // frame: five points vertically, ten points horizontally.
    v->pointer=axis==1?NSMakePoint(0,-5*down):NSMakePoint(10*down,0);
    [v mouseDraggedImageScroll:nil];check(v.curDCM.ordinal==expected);
    for(int component=0;component<3;component++)check(fabs([v.curDCM.position[component] doubleValue]-expected*[normal[component] doubleValue])<1e-12);
    check(v->syncDelta==v->curImage-10);gestures++;
   }
  }
  check([defaults boolForKey:HorosScrollDirection.reversedPreferenceKey]==reversed);
  scenarios++;
 }
 // Execute the new controller action behind the real wheel handler.
 ViewerController *c=v.controller;c->maxMovieIndex=1;c->imageView=v;
 c->pixList[0]=v->dcmPixList;c->sliderFusion=[Control new];c->sliderFusion.maxValue=128;
 c->sliderFusion.integerValue=20;c->stacksFusion=[Control new];c->activatedFusion=[Control new];
 c.selectedMode=2;c->popFusion=[NSObject new];
 Event *e=[Event new];e.flags=NSEventModifierFlagOption;e.scrollY=-2.5;
 v->curImage=10;v->scaleValue=3;v->origin=NSMakePoint(4,5);
 [defaults setBool:YES forKey:HorosScrollDirection.reversedPreferenceKey];
 [v scrollWheel:(NSEvent*)e];
 check(c->sliderFusion.integerValue==2 && c->stacksFusion.integerValue==2 && c.appliedMode==2);
 check(v->curImage==10 && v->scaleValue==3 && c.curMovieIndex==0 && v->origin.x==4);
 check([defaults integerForKey:@"stackThickness"]==2);
 [v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==3);
 e.scrollY=2.5;[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==2);
 [v scrollWheel:(NSEvent*)e];check(c->activatedFusion.state==NSOffState && c->sliderFusion.integerValue==2 && c->stacksFusion.integerValue==1);
 NSInteger calls=c.projections;[v scrollWheel:(NSEvent*)e];check(c.projections==calls && v->curImage==10);
 // Single slices and refused activations consume input without navigation.
 c->pixList[0]=@[v.curDCM];e.scrollY=-1000;[v scrollWheel:(NSEvent*)e];check(c.projections==calls && v->curImage==10);
 c->pixList[0]=v->dcmPixList;c.refuse=YES;[v scrollWheel:(NSEvent*)e];check(c.appliedMode==0 && v->curImage==10);
 c.refuse=NO;c.selectedMode=3;[v scrollWheel:(NSEvent*)e];check(c.appliedMode==3 && c->sliderFusion.integerValue==2);
 [v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==20); // bounded by series
 calls=c.projections;[v scrollWheel:(NSEvent*)e];check(c.projections==calls);
 // Fractions, natural scrolling and flipped order must preserve thickness intent.
 for(int natural=0;natural<2;natural++)for(int flipped=0;flipped<2;flipped++) {
  [c setFusionMode:0];v->flippedData=flipped;v->slabScrollRemainder=0;
  e.precise=YES;e.inverted=natural;e.dy=natural?.5:-.5;e.flags=NSEventModifierFlagOption;
  e.phase=NSEventPhaseBegan;e.momentumPhase=NSEventPhaseNone;
  calls=c.projections;
  for(int n=0;n<4;n++){[v scrollWheel:(NSEvent*)e];e.phase=NSEventPhaseChanged;}
  check(c.projections==calls);[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==2 && c->activatedFusion.state==NSOnState);
  calls=c.projections;NSInteger index=v->curImage;
  e.flags=0;e.phase=NSEventPhaseChanged;[v scrollWheel:(NSEvent*)e];check(v->curImage==index);
  e.phase=NSEventPhaseNone;e.momentumPhase=NSEventPhaseBegan;[v scrollWheel:(NSEvent*)e];
  e.momentumPhase=NSEventPhaseChanged;[v scrollWheel:(NSEvent*)e];
  e.momentumPhase=NSEventPhaseEnded;[v scrollWheel:(NSEvent*)e];check(v->curImage==index && c.projections==calls);
  e.momentumPhase=NSEventPhaseNone;e.phase=NSEventPhaseBegan;[v scrollWheel:(NSEvent*)e];check(v->curImage!=index);
 }
 // With Option held, the gesture's momentum keeps changing the thickness,
 // and the slice stays where it is.
 [c setFusionMode:0];v->flippedData=NO;v->slabScrollRemainder=0;v->consumeSlabScrollTail=NO;
 e.precise=YES;e.inverted=NO;e.dx=0;e.dy=-2.5;e.flags=NSEventModifierFlagOption;
 e.phase=NSEventPhaseBegan;e.momentumPhase=NSEventPhaseNone;[v scrollWheel:(NSEvent*)e];
 check(c->sliderFusion.integerValue==2 && c->activatedFusion.state==NSOnState);
 e.phase=NSEventPhaseEnded;e.dy=0;[v scrollWheel:(NSEvent*)e];
 NSInteger held=v->curImage;e.phase=NSEventPhaseNone;e.dy=-2.5;
 e.momentumPhase=NSEventPhaseBegan;[v scrollWheel:(NSEvent*)e];
 e.momentumPhase=NSEventPhaseChanged;[v scrollWheel:(NSEvent*)e];
 check(c->sliderFusion.integerValue==4 && v->curImage==held);
 e.momentumPhase=NSEventPhaseEnded;e.dy=0;[v scrollWheel:(NSEvent*)e];e.momentumPhase=NSEventPhaseNone;
 // Invalid and horizontal-only Option input never changes zoom or the slice.
 v->curImage=10;v->flippedData=NO;e.phase=NSEventPhaseBegan;e.flags=NSEventModifierFlagOption;
 e.inverted=NO;e.dy=0;e.dx=20;calls=c.projections;
 [defaults setBool:YES forKey:@"ZoomWithHorizonScroll"];
 [v scrollWheel:(NSEvent*)e];check(v->scaleValue==3 && v->curImage==10 && c.projections==calls);
 e.dx=0;e.dy=NAN;[v scrollWheel:(NSEvent*)e];e.dy=INFINITY;[v scrollWheel:(NSEvent*)e];
 check(c.projections==calls && v->curImage==10);
 // Explicit modifier precedence: Option+Shift changes time, Command wins over both.
 e.precise=NO;e.phase=NSEventPhaseNone;e.scrollY=-2.5;c->maxMovieIndex=3;
 v->consumeSlabScrollTail=NO;e.flags=NSEventModifierFlagOption|NSEventModifierFlagShift;
 [v scrollWheel:(NSEvent*)e];check(c.curMovieIndex==1 && v->curImage==10 && c.projections==calls);
 v->blendingView=[NSObject new];e.flags|=NSEventModifierFlagCommand;
 [v scrollWheel:(NSEvent*)e];check(v->blendingFactor!=0 && c.curMovieIndex==1 && v->curImage==10 && c.projections==calls);
 e.flags=NSEventModifierFlagShift;[v scrollWheel:(NSEvent*)e];check(v->curImage==13 && v->openingFitPending);
 // A horizontal gesture cancels only when it actually changes the zoom.
 e.flags=0;e.dx=2;e.dy=e.scrollY=0;v->consumeSlabScrollTail=NO;
 [defaults setBool:NO forKey:@"ZoomWithHorizonScroll"];
 float previousScale=v->scaleValue;[v scrollWheel:(NSEvent*)e];
 check(v->openingFitPending && v->scaleValue==previousScale);
 [defaults setBool:YES forKey:@"ZoomWithHorizonScroll"];
 [v scrollWheel:(NSEvent*)e];
 check(!v->openingFitPending && v->scaleValue!=previousScale && v->curImage==13);
 NSLog(@"PASS: pending opening fit survives wheel/trackpad navigation and cancels for manual horizontal zoom");
 // Physical thickness is valid at origin zero and clipped at either edge.
 NSMutableArray *physical=[NSMutableArray array];
 for(int n=0;n<6;n++){Frame *f=[Frame new];f.sliceLocation=n*2;f.sliceThickness=2;f.stack=3;[physical addObject:f];}
 v->dcmPixList=physical;float mm,location;v->curImage=0;v->flippedData=NO;
 [v getThickSlabThickness:&mm location:&location];check(mm==6 && location==2);
 v->curImage=5;[v getThickSlabThickness:&mm location:&location];check(mm==2 && location==10);
 v->flippedData=YES;[v getThickSlabThickness:&mm location:&location];check(mm==6 && location==8);
 v->curImage=0;[v getThickSlabThickness:&mm location:&location];check(mm==2 && location==0);
 NSLog(@"PASS: slab activation, fractions, bounds, refusal, modifier precedence, momentum (released and held) and physical thickness");
 NSLog(@"PASS: %lu scenarios, %lu gestures; precise/classic accessor, natural/reverse/flipped, four acquisition normals, single/multiframe, both drag axes and sync deltas",(unsigned long)scenarios,(unsigned long)gestures);
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-scroll-events-') as directory:
    p = Path(directory); (p/'test.m').write_text(code + harness_defaults.OBJC)
    (p/'bridge.h').write_text(bridge); (p/'drag.swift').write_text(extension)
    # Swift traps a float-to-integer conversion that overflows, as the
    # float-cast-overflow sanitizer did for the Objective-C drag.
    module = isix_modules.module_flags('IsiXImaging', p/'module')
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','Horos','-wmo',*module,
                    '-import-objc-header',str(p/'bridge.h'),
                    '-emit-objc-header','-emit-objc-header-path',str(p/'Horos-Swift.h'),'-c',
                    str(root/'Horos/Sources/ScrollDirection.swift'),str(root/'Horos/Sources/PreciseMouse.swift'),str(p/'drag.swift'),
                    '-o',str(p/'policy.o')],check=True)
    subprocess.run(['xcrun','clang','-c',str(p/'test.m'),'-o',str(p/'test.o'),'-I',str(p),
                    '-fno-objc-arc','-Wno-deprecated-declarations','-Wno-objc-method-access',
                    '-fsanitize=undefined,float-cast-overflow','-fno-sanitize-recover=all'],check=True)
    subprocess.run(['xcrun','swiftc',str(p/'policy.o'),str(p/'test.o'),*module,'-framework','AppKit',
                    '-sanitize=undefined','-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
