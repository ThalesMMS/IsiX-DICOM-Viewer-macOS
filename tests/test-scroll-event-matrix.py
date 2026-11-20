#!/usr/bin/env python3
"""Run complete production wheel/drag handlers with controlled events and stacks.

No events are posted to the desktop. NSWindow/renderer/plugin side effects are
test doubles; preference policy, delta selection, index and sync logic are real.

-scrollWheel: (DCMView+Scrolling, with IsiXImaging's StackNavigation and
IsiXPreferences' ScrollSettings), -mouseDraggedImageScroll: (DCMView+MouseDragging)
and -getThickSlabThickness:location: (DCMView+WindowLevel+Coordinates) are Swift.
They are compiled as they are, with xcrun swiftc, as an extension of the
Objective-C double of DCMView, whose state has the names of DCMView.swift's
horos_* properties and which answers the view's StackNavigation over them and
the planar host's
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
import process_graph_stand_in  # noqa: E402  - the 2D viewer's sources read the catalog's keys through PreferencesSource
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
# The selector is a façade of the viewer's ViewerThickSlab, in the same file,
# made over the preferences of the viewer's graph: the standard ones here.
if 'ViewerThickSlab(' in adjust:
    a = thick.index('    func adjust(bySteps steps: Int) {')
    # The double of the viewer is not main-actor isolated: neither are these.
    # The scale of the slab at the image a view shows, which the steps and the
    # thickness ask, with the positions it keeps: over the doubles' images,
    # which hold their origin, orientation, location, thickness and interval
    # as DCMPix does.
    b = thick.index('    /// The scale of the slab at the image `view` shows')
    scale = thick[b:thick.index('    /// What the slider asks for now', b)]
    b = thick.index('/// Where the images of a viewer\'s lists stand along the normal')
    positions = thick[b:]
    slab = ('struct ViewerThickSlab {\n    let viewer: ViewerController\n    let preferences: any PreferenceStore\n\n'
            + thick[a:thick.index('    /// Fuses `stacks` slices in every movie', a)] + scale + '}\n' + positions +
            'final class HarnessSessionGraph {\n    var preferences: any PreferenceStore { UserDefaults.standard }\n}\n'
            'final class HarnessGeometryState {\n    let slabPositions = SlabPositions()\n    var slabRequestMillimetres: Double?\n}\n'
            'private let harnessGeometry = HarnessGeometryState()\n')
    adjust += '    var geometryState: HarnessGeometryState { harnessGeometry }\n'
    adjust += '    var sessionGraph: HarnessSessionGraph { HarnessSessionGraph() }\n'
else:
    slab = ''
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
# The view's StackNavigation, over the double's index, drag start and slab scroll.
stack = '''    var stackNavigation: StackNavigation {
        get {
            var stack = StackNavigation(current: self.horos_curImage, start: self.horos_startImage)
            stack.slabRemainder = self.horos_slabScrollRemainder
            stack.slabTimestamp = self.horos_slabScrollTimestamp
            stack.consumesSlabTail = self.horos_consumeSlabScrollTail
            return stack
        }
        set {
            self.horos_curImage = newValue.current; self.horos_startImage = newValue.start
            self.horos_slabScrollRemainder = newValue.slabRemainder
            self.horos_slabScrollTimestamp = newValue.slabTimestamp
            self.horos_consumeSlabScrollTail = newValue.consumesSlabTail
        }
    }
'''
extension = '''import Cocoa
import IsiXImaging
import IsiXPreferences
typealias ROI = NSObject
typealias HorosVolumeLengthROI = NSObject
// The selectors of DCMViewDraggingMessages the drag sends.
@objc private protocol DCMViewDraggingMessages {
    @objc(windowController) func draggingWindowController() -> AnyObject?
    @objc(adjustSlider) func draggingAdjustSlider()
}
''' + messages + helpers + object_helper + 'extension DCMView {\n' + stack + drag + thickness + wheel + '}\n' + show + \
    'extension ViewerController {\n' + movies + adjust + '}\n' + slab
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
// Every image says where it is, unless a test says the series is still loading.
@property BOOL loading;
-(BOOL)isEverythingLoaded;
@end
@interface Frame:NSObject {
@public double normalAxes[9];
}
@property NSInteger ordinal, frameNumber, stack;
@property double sliceLocation,sliceThickness;
@property(retain) NSArray *position, *orientation;
// What DCMPix holds without loading anything.
@property double horos_originX, horos_originY, horos_originZ, horos_sliceInterval;
@property(readonly) double horos_sliceLocation, horos_sliceThickness;
@property(readonly) double *horos_orientation;
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
// DCMView.swift's horos_* properties, on the same ivars.
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
-(BOOL)isEverythingLoaded{return !self.loading;}
-(void)popFusionAction:(id)sender {[self setFusionMode:self.refuse?0:self.selectedMode];[imageView sendSyncMessage:0];}
-(void)sliderFusionAction:(id)sender {
 self.projections++;stacksFusion.integerValue=sliderFusion.integerValue;
 [NSUserDefaults.standardUserDefaults setInteger:sliderFusion.integerValue forKey:@"stackThickness"];
 [imageView sendSyncMessage:0];
}
@end
@implementation Frame
-(double)horos_sliceLocation{return self.sliceLocation;}
-(double)horos_sliceThickness{return self.sliceThickness;}
-(double*)horos_orientation{return normalAxes;}
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
 [v scrollWheel:(NSEvent*)e];check(c->activatedFusion.state==NSOffState && c->sliderFusion.integerValue==1 && c->stacksFusion.integerValue==1);
 NSInteger calls=c.projections;[v scrollWheel:(NSEvent*)e];check(c.projections==calls && v->curImage==10);
 // Single slices and refused activations consume input without navigation.
 c->pixList[0]=@[v.curDCM];e.scrollY=-1000;[v scrollWheel:(NSEvent*)e];check(c.projections==calls && v->curImage==10);
 c->pixList[0]=v->dcmPixList;c.refuse=YES;[v scrollWheel:(NSEvent*)e];check(c.appliedMode==0 && v->curImage==10);
 c.refuse=NO;c.selectedMode=3;[v scrollWheel:(NSEvent*)e];check(c.appliedMode==3 && c->sliderFusion.integerValue==2);
 // A slab has its images on every image of the series, so the steps are
 // bounded by the series, 20 images, wherever the image shown is. Past them
 // no step changes anything.
 check(v->flippedData && v->curImage==10);
 [v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==20);
 calls=c.projections;[v scrollWheel:(NSEvent*)e];check(c.projections==calls && c->sliderFusion.integerValue==20);
 // Near the end of the series in the slab's direction, and on its last
 // image, a step is the step of any image: down from the request, up to the
 // series.
 v->curImage=4;calls=c.projections;[v scrollWheel:(NSEvent*)e];check(c.projections==calls && c->sliderFusion.integerValue==20);
 e.scrollY=2.5;[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==19 && c.projections==calls+1);
 v->curImage=0;[v scrollWheel:(NSEvent*)e];
 check(c->sliderFusion.integerValue==18 && c.projections==calls+2 && c->activatedFusion.state==NSOnState);
 e.scrollY=-1000;[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==20 && c.projections==calls+3);
 // Off, a step down changes nothing there, and a step up starts the slab at two images, as anywhere.
 [c setFusionMode:0];calls=c.projections;e.scrollY=2.5;[v scrollWheel:(NSEvent*)e];
 check(c.projections==calls && c->activatedFusion.state==NSOffState);
 e.scrollY=-1000;[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==2 && c->activatedFusion.state==NSOnState);
 // The other direction of the slab has the same steps.
 v->flippedData=NO;[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==20);
 v->curImage=19;e.scrollY=2.5;[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==19);
 e.scrollY=-1000;[v scrollWheel:(NSEvent*)e];check(c->sliderFusion.integerValue==20);
 v->flippedData=YES;v->curImage=10;
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
 // Physical thickness is valid at origin zero and clipped at either edge:
 // the thickness of one slice and the distance to the last one fused, along
 // the normal of the slices, by the scale of the slab the toolbar reads.
 NSArray *(^series)(int, double, double, NSArray*)=^NSArray*(int count,double thickness,double interval,NSArray *normal){
  NSMutableArray *list=[NSMutableArray array];
  double n[3]={[normal[0] doubleValue],[normal[1] doubleValue],[normal[2] doubleValue]};
  int dominant=fabs(n[0])>fabs(n[2])?0:2;
  for(int i=0;i<count;i++){Frame *f=[Frame new];f.stack=3;f.sliceThickness=thickness;f.horos_sliceInterval=interval;
   f.horos_originX=n[0]*i*interval;f.horos_originY=n[1]*i*interval;f.horos_originZ=n[2]*i*interval;
   f->normalAxes[6]=n[0];f->normalAxes[7]=n[1];f->normalAxes[8]=n[2];
   // The location is the coordinate on the dominant axis, as the image has it.
   f.sliceLocation=n[dominant]*i*interval;[list addObject:f];}
  return list;
 };
 c->sliderFusion.maxValue=128;
 v->dcmPixList=series(6,2,2,@[@0,@0,@1]);float mm,location;v->curImage=0;v->flippedData=NO;
 // Three images of 2 mm every 2 mm are 6 mm on every image. On the first
 // image the slab is images 0 to 2, and its location is the middle one's.
 [v getThickSlabThickness:&mm location:&location];check(mm==6 && location==2);
 // In the series it is centred on the image shown: its location is the image's own.
 for(int i=1;i<5;i++){v->curImage=i;[v getThickSlabThickness:&mm location:&location];check(mm==6 && location==2*i);}
 // On the last image it is images 3 to 5, as on the image before.
 v->curImage=5;[v getThickSlabThickness:&mm location:&location];check(mm==6 && location==8);
 v->flippedData=YES;[v getThickSlabThickness:&mm location:&location];check(mm==6 && location==8);
 for(int i=1;i<5;i++){v->curImage=i;[v getThickSlabThickness:&mm location:&location];check(mm==6 && location==2*i);}
 v->curImage=0;[v getThickSlabThickness:&mm location:&location];check(mm==6 && location==2);
 // An even slab has its image more on the side it goes: half an interval further that way.
 for(Frame *f in v->dcmPixList)f.stack=4;
 v->curImage=2;[v getThickSlabThickness:&mm location:&location];check(mm==8 && location==3);
 v->flippedData=NO;[v getThickSlabThickness:&mm location:&location];check(mm==8 && location==5);
 // More images than the series has: all of it, around its middle.
 for(Frame *f in v->dcmPixList)f.stack=9;
 for(int i=0;i<6;i++){v->curImage=i;[v getThickSlabThickness:&mm location:&location];check(mm==12 && location==5);}
 v->curImage=0;
 // Slices that overlap, 2 mm every 1 mm: three cover 4 mm.
 v->dcmPixList=series(6,2,1,@[@0,@0,@1]);v->flippedData=NO;
 [v getThickSlabThickness:&mm location:&location];check(mm==4 && location==1);
 // Slices that do not say their thickness count the distance between two:
 // three of them are 3 mm, not the 2 mm between the first and the last.
 v->dcmPixList=series(6,0,1,@[@0,@0,@1]);
 [v getThickSlabThickness:&mm location:&location];check(mm==3 && location==1);
 // Without a slab the image's own thickness, none here, is not made up.
 for(Frame *f in v->dcmPixList)f.stack=1;
 [v getThickSlabThickness:&mm location:&location];check(mm==0 && location==0);
 // An oblique series, 1 mm apart along its normal: 0.8 mm on its dominant axis.
 v->dcmPixList=series(6,1,1,@[@0.6,@0,@0.8]);
 [v getThickSlabThickness:&mm location:&location];check(fabsf(mm-3)<1e-5 && fabsf(location-0.8f)<1e-5);
 // While the series loads, nothing asks an image where it is: its interval stands for the distances.
 c.loading=YES;v->dcmPixList=series(6,2,1,@[@0,@0,@1]);for(Frame *f in v->dcmPixList)f.horos_originZ=NAN;
 [v getThickSlabThickness:&mm location:&location];check(mm==4);
 c.loading=NO;
 // A slider that can ask for fewer images than the series has bounds the slab's scale.
 c->sliderFusion.maxValue=2;v->dcmPixList=series(6,2,2,@[@0,@0,@1]);
 [v getThickSlabThickness:&mm location:&location];check(mm==4);
 c->sliderFusion.maxValue=128;
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
    # PreciseMouse reads the catalog's keys: IsiXPreferences, beside IsiXImaging, and the source's stand-in.
    preferences = process_graph_stand_in.swift_flags(p/'module')
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','Horos','-wmo',*module,
                    '-import-objc-header',str(p/'bridge.h'),
                    '-emit-objc-header','-emit-objc-header-path',str(p/'Horos-Swift.h'),'-c',
                    str(root/'Horos/Sources/ScrollDirection.swift'),str(root/'Horos/Sources/PreciseMouse.swift'),str(p/'drag.swift'),
                    *preferences,'-o',str(p/'policy.o')],check=True)
    subprocess.run(['xcrun','clang','-c',str(p/'test.m'),'-o',str(p/'test.o'),'-I',str(p),
                    '-fno-objc-arc','-Wno-deprecated-declarations','-Wno-objc-method-access',
                    '-fsanitize=undefined,float-cast-overflow','-fno-sanitize-recover=all'],check=True)
    subprocess.run(['xcrun','swiftc',str(p/'policy.o'),str(p/'test.o'),*module,*preferences[1:],'-framework','AppKit',
                    '-sanitize=undefined','-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
