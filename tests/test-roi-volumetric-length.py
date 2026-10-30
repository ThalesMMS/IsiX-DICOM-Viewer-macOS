#!/usr/bin/env python3
"""Execute the real patient-space ROI subclass: projection, selection, edit and archive.

The click-session methods are Swift, in DCMView+LengthClick.swift, with the
messages they send the window controller (DCMView+Tools.swift); -mouseDragged:
is in DCMView+MouseDragging.swift. They, and the length-click replay of
-mouseDragged:, the part before the curImage guard, are compiled as they are,
with xcrun swiftc, as an extension of the Objective-C double of DCMView, whose
state has the names of DCMView.swift's stored horos_* properties.
So is -removeROIFromSliceOrVolume: of DCMView+ROIEditing.swift. The click
session creates its lengths as a double of HorosVolumeLengthROI that answers
with IsiXROI's geometry, as the class does.

HorosVolumeLengthROI itself - its geometry, projection, hit test, edit, copy
and archive - is this checkout's, linked as the application's build compiled
it (tests/roi_harness.py); without a build that part is skipped.
"""
from pathlib import Path
import re, subprocess, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
import isix_modules  # noqa: E402
import roi_harness  # noqa: E402
root=Path(__file__).resolve().parents[1]
length_source=source_text('DCMView+LengthClick')
gesture=length_source[length_source.index('extension DCMView {\n')+len('extension DCMView {\n'):length_source.rindex('\n}\n')]
tools=source_text('DCMView+Tools')
messages=re.search(r'@objc protocol DCMViewInputMessages \{.*?\n\}\n', tools, re.S).group(0)
messages+=re.search(r'@inline\(__always\)\nfunc inputMessages\(.*?\n\}\n', tools, re.S).group(0)
editing=source_text('DCMView+ROIEditing')
remove=editing[editing.index('    @objc(removeROIFromSliceOrVolume:)'):]
remove=remove[:remove.index('\n    }\n')+7]
assert remove.count('roi is HorosVolumeLengthROI')==1 and remove.count('(fromSliceOrVolume roi: ROI!)')==1
remove=remove.replace('(fromSliceOrVolume roi: ROI!)','(fromSliceOrVolume roi: NSObject!)')
swift=source_text('DCMView+MouseDragging')
drag=swift[swift.index('    @objc(mouseDragged:)'):];drag=drag[:drag.index('        if self.horos_curImage < 0 {')]+'        self.dragReplayCount += 1\n    }\n'
extension='import Cocoa\n'+messages+'extension DCMView {\n'+drag+remove+gesture+'}\n'
bridge=r'''
#import <Cocoa/Cocoa.h>
#import "HorosAlertPanel.h"
@class ViewerController;
typedef NS_ENUM(short, ToolMode) { tMesure = 5, t2DPoint = 19 };
enum {ROI_sleep,ROI_drawing,ROI_selected,ROI_selectedModify};
@interface DCMPix:NSObject { id imageObjValue; }
@property double pixelSpacingX,pixelSpacingY,originX,originY,originZ,sliceThickness,pixelRatio;
@property NSInteger stack,pwidth,pheight;
@property BOOL generated;
-(NSObject*)imageObj;
-(void)setImageObj:(id)o;
+(NSPoint)originCorrectedAccordingToOrientation:(id)p;
@property(copy) NSString *frameofReferenceUID;
@property NSArray *orientation;
-(void)orientationDouble:(double*)v;
@end
@interface TestWindow:NSObject
@property double backingScaleFactor;
@property NSInteger windowNumber;
@end
@class ROI;
@interface DCMView:NSResponder {
@public NSEvent *lengthClickEvent; BOOL replayingLengthDrag,drawingROI;
NSDictionary *lengthFirstEndpoint;ROI *lengthPendingMarker;NSMutableArray *curRoiList;
NSArray *dcmRoiList;float scaleValue;ToolMode currentMouseEventTool;int dragReplayCount;
}
@property DCMPix *curDCM;
@property NSArray *dcmPixList;
@property NSInteger curImage;
@property BOOL flippedData;
@property TestWindow *window;
@property BOOL viewer2D;
@property ViewerController *controller;
@property BOOL needsDisplay;
// DCMView.swift's stored horos_* properties, on the same ivars. The event, the
// endpoint and the marker are owned by the view: their setters below retain
// (declared assign so that Swift sees the classes, as it sees the view's).
@property(nonatomic, assign) NSEvent *horos_lengthClickEvent;
@property BOOL horos_replayingLengthDrag;
@property(nonatomic, assign) NSDictionary *horos_lengthFirstEndpoint;
@property(nonatomic, assign) ROI *horos_lengthPendingMarker;
@property BOOL horos_drawingROI;
@property float horos_scaleValue;
@property ToolMode horos_currentMouseEventTool;
@property int dragReplayCount;
@property(readonly) NSMutableArray *horos_curRoiList;
@property(readonly) NSArray *horos_dcmRoiList;
@property(class, nonatomic, assign) NSDictionary *horos_static__hotKeyDictionary;
-(BOOL)is2DViewer;
-(id)windowController;
-(ToolMode)getTool:(NSEvent*)event;
-(void)deleteMouseDownTimer;
-(NSPoint)convertPoint:(NSPoint)p fromView:(NSView*)v;
-(NSPoint)convertPoint:(NSPoint)p toView:(NSView*)v;
-(NSPoint)ConvertFromNSView2GL:(NSPoint)p;
-(NSPoint)ConvertFromGL2NSView:(NSPoint)p;
-(void)mouseDown:(NSEvent*)event;
-(void)mouseUp:(NSEvent*)event;
// The planar path a click that became a drag, or two clicks on one image, are replayed into.
@property(retain) NSEvent *replayedDown, *replayedUp;
@end
@interface ROI:NSObject<NSCoding,NSCopying>{
@protected NSMutableArray *points; DCMView *curView; NSInteger mode;
struct{float red,green,blue;} color; float opacity;
}
@property BOOL isAliased,selectable,hidden,locked,isTextualDataDisplayed;
@property NSInteger originalIndexForAlias;
@property(retain) NSString *textualBoxLine1,*textualBoxLine2,*textualBoxLine3,*textualBoxLine4,*textualBoxLine5,*textualBoxLine6;
@property(assign) DCMView *curView;
@property(copy) NSString *name;
@property(getter=ROImode, setter=setROIMode:) NSInteger roImode;
-(id)initWithType:(ToolMode)t :(float)sx :(float)sy :(NSPoint)origin;
-(NSInteger)clickInROI:(NSPoint)point :(float)width :(float)height :(float)scale :(BOOL)test;
@end
@interface HorosVolumeLengthROI:ROI
@property(copy) NSDictionary *volumeLength;
@property(readonly) double distanceMM;
+(NSDictionary*)referenceForPix:(DCMPix*)p NS_SWIFT_NAME(reference(for:));
+(NSArray*)patientPoint:(NSPoint)pt pix:(DCMPix*)p;
+(BOOL)validPayload:(NSDictionary*)d;
@end
@interface DCMView (LengthContract)
-(void)cancelLengthPlacement;
-(BOOL)beginLengthClick:(NSEvent*)event;
-(void)finishLengthClick:(NSEvent*)event;
-(void)removeROIFromSliceOrVolume:(id)roi;
@end
'''
code=r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "HorosAlertPanel.h"
#import "LengthPresentation-Swift.h"
// The patient-space geometry is IsiXROI's.
#import "IsiXROI-Swift.h"
#import <OpenGL/gl.h>
#include <math.h>
// The drawing goes to the view's canvas; nothing here draws.
static inline id ROICanvasCurrent(void){return nil;}
static inline void roiSyncTransformFromGL(void){}
static inline void roiPushAttrib(GLbitfield m){}
static inline void roiPopAttrib(void){}
static inline void roiEnable(GLenum c){}
static inline void roiDisable(GLenum c){}
static inline void roiBlendFunc(GLenum a,GLenum b){}
static inline void roiColor4f(GLfloat r,GLfloat g,GLfloat b,GLfloat a){}
static inline void roiLineWidth(GLfloat w){}
static inline void roiLineStipple(GLint f,GLushort p){}
static inline void roiPointSize(GLfloat s){}
static inline void roiBegin(GLenum m){}
static inline void roiEnd(void){}
static inline void roiVertex2f(GLfloat x,GLfloat y){}
static NSUInteger alertCalls;
static NSModalResponse TestAlertRun(NSAlert *alert, SEL selector) {
 if (alert.alertStyle != NSAlertStyleInformational || ![alert.messageText isEqual:@"Length"]) abort();
 alertCalls++; return NSAlertFirstButtonReturn;
}
NSString *OsirixROIChangeNotification=@"changed";
static void ROIPostChange(id roi,NSDictionary *userInfo){[[NSNotificationCenter defaultCenter] postNotificationName:OsirixROIChangeNotification object:roi userInfo:userInfo];}
#import "bridge.h"
@interface MyPoint:NSObject<NSCoding,NSCopying>
@property NSPoint point;
+(id)point:(NSPoint)p;
@end
@implementation MyPoint
+(id)point:(NSPoint)p{MyPoint*r=[MyPoint new];r.point=p;return [r autorelease];}
-(void)encodeWithCoder:(NSCoder*)c{[c encodePoint:self.point];}
-(id)initWithCoder:(NSCoder*)c{if((self=[super init]))self.point=[c decodePoint];return self;}
-(id)copyWithZone:(NSZone*)z{return [[MyPoint point:self.point] retain];}
@end
@implementation DCMPix
-(id)imageObj{return imageObjValue;}
-(void)setImageObj:(id)o{imageObjValue=o;}
+(NSPoint)originCorrectedAccordingToOrientation:(id)p{return NSZeroPoint;}
-(void)orientationDouble:(double*)v{for(int i=0;i<9;i++)v[i]=[self.orientation[i] doubleValue];}
@end
@implementation TestWindow @end
@interface ViewerController:NSObject
@property NSInteger undoCount;
@property short curMovieIndex;
@property NSMutableArray *added;
@end
@implementation ViewerController
-(void)addToUndoQueue:(NSString*)kind{self.undoCount++;}
-(void)addVolumeLengthROI:(id)roi{if(!self.added)self.added=[NSMutableArray array];[self.added addObject:roi];}
@end
static NSDictionary *_hotKeyDictionary;
@implementation DCMView
@synthesize horos_lengthClickEvent=lengthClickEvent,horos_replayingLengthDrag=replayingLengthDrag,dragReplayCount;
@synthesize horos_lengthFirstEndpoint=lengthFirstEndpoint,horos_lengthPendingMarker=lengthPendingMarker,horos_drawingROI=drawingROI;
-(void)setHoros_lengthClickEvent:(NSEvent*)e{[e retain];[lengthClickEvent release];lengthClickEvent=e;}
-(void)setHoros_lengthFirstEndpoint:(NSDictionary*)d{[d retain];[lengthFirstEndpoint release];lengthFirstEndpoint=d;}
-(void)setHoros_lengthPendingMarker:(ROI*)m{[m retain];[lengthPendingMarker release];lengthPendingMarker=m;}
@synthesize horos_scaleValue=scaleValue,horos_currentMouseEventTool=currentMouseEventTool;
+(NSDictionary*)horos_static__hotKeyDictionary{return _hotKeyDictionary;}
+(void)setHoros_static__hotKeyDictionary:(NSDictionary*)d{_hotKeyDictionary=d;}
-(BOOL)needsDisplay{return NO;}
-(BOOL)is2DViewer{return self.viewer2D;}
-(NSMutableArray*)horos_curRoiList{return curRoiList;}
-(NSArray*)horos_dcmRoiList{return dcmRoiList;}
-(void)setNeedsDisplay:(BOOL)b{}
-(void)deleteMouseDownTimer{}
-(ToolMode)getTool:(NSEvent*)event{return tMesure;}
-(NSPoint)convertPoint:(NSPoint)p fromView:(NSView*)v{return p;}
-(NSPoint)ConvertFromNSView2GL:(NSPoint)p{return p;}
-(NSPoint)convertPoint:(NSPoint)p toView:(NSView*)v{return p;}
-(NSPoint)ConvertFromGL2NSView:(NSPoint)p{return p;}
-(ViewerController*)windowController{return self.controller;}
-(void)mouseDown:(NSEvent*)event{if(![self beginLengthClick:event]){dragReplayCount++;self.replayedDown=event;}}
-(void)mouseUp:(NSEvent*)event{self.replayedUp=event;}
@end
@implementation ROI
@synthesize curView;
-(id)initWithType:(ToolMode)t :(float)sx :(float)sy :(NSPoint)origin{return [self init];}
-(id)init{if((self=[super init])){points=[NSMutableArray new];self.selectable=YES;}return self;}
-(void)encodeWithCoder:(NSCoder*)c{[c encodeObject:points];}
-(id)initWithCoder:(NSCoder*)c{if((self=[self init])){[points release];points=[[c decodeObject] mutableCopy];}return self;}
-(id)copyWithZone:(NSZone*)z{ROI*r=[[[self class] alloc] init];[r->points addObjectsFromArray:points];return r;}
-(NSInteger)clickInROI:(NSPoint)point :(float)width :(float)height :(float)scale :(BOOL)test{return ROI_sleep;}
-(void)recompute{}
-(void)prepareTextualData:(NSPoint)p{}
-(NSPoint)lowerRightPoint{return NSZeroPoint;}
-(void)setROIMode:(NSInteger)m{mode=m;}
-(NSInteger)ROImode{return mode;}
-(void)dealloc{[points release];[super dealloc];}
@end
// What the click session asks of a patient-space length, answered as
// HorosVolumeLengthROI answers it, with IsiXROI's geometry.
static IsiXROIImagePlane *Plane(DCMPix *p){
 if(!p)return nil;double o[9];[p orientationDouble:o];
 return [[[IsiXROIImagePlane alloc] initWithOriginX:p.originX y:p.originY z:p.originZ orientation:o spacingX:p.pixelSpacingX spacingY:p.pixelSpacingY hasFrameOfReference:p.frameofReferenceUID.length>0] autorelease];
}
@implementation HorosVolumeLengthROI
+(NSDictionary*)referenceForPix:(DCMPix*)p{
 id image=p.imageObj;double orientation[9];[p orientationDouble:orientation];
 return @{@"sopInstanceUID":[image valueForKey:@"sopInstanceUID"]?:@"",@"frame":[image valueForKey:@"frameID"]?:@0,@"generated":@(p.generated),
  @"imagePositionPatient":@[@(p.originX),@(p.originY),@(p.originZ)],
  @"imageOrientationPatient":@[@(orientation[0]),@(orientation[1]),@(orientation[2]),@(orientation[3]),@(orientation[4]),@(orientation[5])],
  @"pixelSpacing":@[@(p.pixelSpacingX),@(p.pixelSpacingY)]};
}
+(NSArray*)patientPoint:(NSPoint)pt pix:(DCMPix*)p{return [Plane(p) patientPointOf:pt];}
+(BOOL)validPayload:(NSDictionary*)d{return [IsiXROIPatientSpaceLength isValidPayload:d];}
-(double)distanceMM{return [IsiXROIPatientSpaceLength distanceOfPayload:self.volumeLength];}
@end
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__);exit(1);}}while(0)
static DCMPix* pix(NSArray*o,double z){DCMPix*p=[DCMPix new];p.orientation=o;p.originZ=z;p.pixelSpacingX=.5;p.pixelSpacingY=2;p.pixelRatio=4;p.sliceThickness=1;p.stack=1;p.frameofReferenceUID=@"frame";return [p autorelease];}
int main(){@autoreleasepool{
 method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)TestAlertRun);
 NSEvent *(^event)(NSEventType,CGFloat,CGFloat)=^NSEvent*(NSEventType type,CGFloat x,CGFloat y){return [NSEvent mouseEventWithType:type location:NSMakePoint(x,y) modifierFlags:0 timestamp:1 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];};
 NSArray *axial=@[@1,@0,@0,@0,@1,@0,@0,@0,@1];
 DCMPix*p=pix(axial,0);
 // Real click-session methods: A survives a slice change, commits one undo,
 // slab suspends B, coincidence does not create an orphan, and a real drag
 // replays the original down into the existing planar drawing path.
 DCMView*g=[DCMView new];g.viewer2D=YES;g.curDCM=p;g.controller=[ViewerController new];g->curRoiList=[NSMutableArray array];g->scaleValue=1;
 p.imageObj=@{@"series":@{@"seriesDICOMUID":@"series"},@"sopInstanceUID":@"sop",@"frameID":@0};p.pwidth=p.pheight=32;
 check([g beginLengthClick:event(NSEventTypeLeftMouseDown,2,3)]);[g finishLengthClick:event(NSEventTypeLeftMouseUp,2,3)];
 check(g->lengthFirstEndpoint&&g.controller.undoCount==0);
 p.originZ=12;p.stack=2;[g beginLengthClick:event(NSEventTypeLeftMouseDown,2,3)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,2,3)];check(g->lengthFirstEndpoint&&g.controller.added.count==0);
 p.stack=1;[g beginLengthClick:event(NSEventTypeLeftMouseDown,2,3)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,2,3)];check(!g->lengthFirstEndpoint&&g.controller.undoCount==1&&g.controller.added.count==1);check(fabs([(HorosVolumeLengthROI*)g.controller.added[0] distanceMM]-12)<1e-12);
 [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,5)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,4,5)];
 [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,5)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,4,5)];check(g->lengthFirstEndpoint&&g.controller.undoCount==1);
 [g cancelLengthPlacement];check(!g->lengthFirstEndpoint&&!g->lengthClickEvent);
 // Two clicks on one image are the drag between them, not a length through
 // the volume: nothing is added here, the first point goes, and the planar
 // path is replayed from A to B without the modifier held at the second click.
 {
  int replays=g->dragReplayCount;NSUInteger added=g.controller.added.count;NSInteger undo=g.controller.undoCount;
  NSEvent *(^held)(NSEventType,CGFloat,CGFloat)=^NSEvent*(NSEventType type,CGFloat x,CGFloat y){return [NSEvent mouseEventWithType:type location:NSMakePoint(x,y) modifierFlags:NSEventModifierFlagShift timestamp:1 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];};
  [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,5)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,4,5)];check(g->lengthFirstEndpoint);
  check([g beginLengthClick:held(NSEventTypeLeftMouseDown,14,9)]);[g finishLengthClick:held(NSEventTypeLeftMouseUp,14,9)];
  check(!g->lengthFirstEndpoint&&!g->lengthPendingMarker&&!g->lengthClickEvent&&!g->replayingLengthDrag);
  check(g.controller.added.count==added&&g.controller.undoCount==undo);
  check(g->dragReplayCount==replays+2);
  check(g.replayedDown.type==NSEventTypeLeftMouseDown&&NSEqualPoints(g.replayedDown.locationInWindow,NSMakePoint(4,5))&&g.replayedDown.modifierFlags==0&&g.replayedDown.clickCount==1);
  check(g.replayedUp.type==NSEventTypeLeftMouseUp&&NSEqualPoints(g.replayedUp.locationInWindow,NSMakePoint(14,9))&&g.replayedUp.modifierFlags==0);
  // Another slice between the two clicks, and back: still one image.
  replays=g->dragReplayCount;
  [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,5)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,4,5)];
  p.originZ=30;p.originZ=12;
  [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,15)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,4,15)];
  check(!g->lengthFirstEndpoint&&g->dragReplayCount==replays+2&&g.controller.added.count==added);
  // Different slices still give the length through the volume, and so do two
  // images that only their place in the stack tells apart.
  [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,5)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,4,5)];
  p.originZ=0;[g beginLengthClick:event(NSEventTypeLeftMouseDown,14,9)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,14,9)];
  check(!g->lengthFirstEndpoint&&g->dragReplayCount==replays+2&&g.controller.added.count==added+1&&g.controller.undoCount==undo+1);
  [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,5)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,4,5)];
  g.curImage=1;[g beginLengthClick:event(NSEventTypeLeftMouseDown,14,9)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,14,9)];
  check(!g->lengthFirstEndpoint&&g->dragReplayCount==replays+2&&g.controller.added.count==added+2);
  g.curImage=0;p.originZ=12;[g.controller.added removeObjectsInRange:NSMakeRange(added,2)];g.controller.undoCount=undo;g->dragReplayCount=0;
 }
 // A double-click with an action in Hot Keys is not a second endpoint: the
 // endpoint of its first click goes, and the click is left to -mouseDown:.
 // Without an action it measures as before; over a ROI it stays the ROI's.
 NSEvent *(^twice)(CGFloat,CGFloat)=^NSEvent*(CGFloat x,CGFloat y){return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(x,y) modifierFlags:0 timestamp:1 windowNumber:0 context:nil eventNumber:0 clickCount:2 pressure:1];};
 NSUInteger addedBeforeDouble=g.controller.added.count;NSInteger undoBeforeDouble=g.controller.undoCount;
 [g beginLengthClick:event(NSEventTypeLeftMouseDown,20,21)];[g finishLengthClick:event(NSEventTypeLeftMouseUp,20,21)];check(g->lengthFirstEndpoint);
 _hotKeyDictionary=@{@"dbl-click":@19};
 check(![g beginLengthClick:twice(20,21)]&&!g->lengthFirstEndpoint&&!g->lengthClickEvent);
 check(g.controller.added.count==addedBeforeDouble&&g.controller.undoCount==undoBeforeDouble);
 _hotKeyDictionary=@{@"dbl-click + alt":@19};
 check([g beginLengthClick:twice(20,21)]&&g->lengthClickEvent);[g cancelLengthPlacement];
 _hotKeyDictionary=nil;
 [g beginLengthClick:event(NSEventTypeLeftMouseDown,4,5)];[g mouseDragged:event(NSEventTypeLeftMouseDown,4,5)];check(g->lengthClickEvent&&g->dragReplayCount==0);
 [g mouseDragged:event(NSEventTypeLeftMouseDragged,5,6)];check(g->lengthClickEvent&&g->dragReplayCount==0);
 [g mouseDragged:event(NSEventTypeLeftMouseDragged,9,5)];check(!g->lengthClickEvent&&g->dragReplayCount==2);
 NSMutableArray *sliceA=[NSMutableArray arrayWithArray:g.controller.added], *sliceB=[NSMutableArray arrayWithArray:g.controller.added];
 g->dcmRoiList=@[sliceA,sliceB];g->curRoiList=sliceB;
 [g removeROIFromSliceOrVolume:g.controller.added[0]];check(sliceA.count==0&&sliceB.count==0);
 // Shift is the lens of a ROI tool: with it a click outside a ROI places A and
 // then B as without it. Command, Option and Control keep their own gestures.
 NSEvent *(^shifted)(NSEventType,CGFloat,CGFloat,NSEventModifierFlags)=^NSEvent*(NSEventType type,CGFloat x,CGFloat y,NSEventModifierFlags f){return [NSEvent mouseEventWithType:type location:NSMakePoint(x,y) modifierFlags:f timestamp:1 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];};
 NSUInteger addedBefore=g.controller.added.count;
 p.originZ=0;check([g beginLengthClick:shifted(NSEventTypeLeftMouseDown,2,3,NSEventModifierFlagShift)]);[g finishLengthClick:shifted(NSEventTypeLeftMouseUp,2,3,NSEventModifierFlagShift)];check(g->lengthFirstEndpoint);
 p.originZ=12;check([g beginLengthClick:shifted(NSEventTypeLeftMouseDown,2,3,NSEventModifierFlagShift)]);[g finishLengthClick:shifted(NSEventTypeLeftMouseUp,2,3,NSEventModifierFlagShift)];
 check(!g->lengthFirstEndpoint&&g.controller.added.count==addedBefore+1);
 for(NSNumber*f in @[@(NSEventModifierFlagShift|NSEventModifierFlagCommand),@(NSEventModifierFlagOption),@(NSEventModifierFlagControl)])check(![g beginLengthClick:shifted(NSEventTypeLeftMouseDown,2,3,f.unsignedIntegerValue)]);
 g.viewer2D=NO;check(![g beginLengthClick:event(NSEventTypeLeftMouseDown,2,3)]);p.originZ=0;
 p.pixelSpacingX=.5;p.orientation=@[@1,@0,@0,@1,@0,@0,@0,@0,@0];
 // Without valid patient geometry a click is still a point of its own image:
 // it is kept without an alert, a second click on that image is the drag
 // between them, and only a second click on another image, which would need
 // the geometry, reports through the production alert bridge and keeps the
 // first point. The slab branch only beeps.
 NSInteger undoBefore = g.controller.undoCount;NSUInteger addedAtEnd = g.controller.added.count;int replaysBefore = g->dragReplayCount;
 g->curRoiList=[NSMutableArray array];
 [g finishLengthClick:event(NSEventTypeLeftMouseUp,2,3)];
 check(g->lengthFirstEndpoint && !g->lengthFirstEndpoint[@"point"] && alertCalls == 0);
 g.curImage=3;[g finishLengthClick:event(NSEventTypeLeftMouseUp,12,3)];
 check(alertCalls == 1 && g->lengthFirstEndpoint && g->dragReplayCount == replaysBefore);
 g.curImage=0;[g finishLengthClick:event(NSEventTypeLeftMouseUp,12,3)];
 check(alertCalls == 1 && !g->lengthFirstEndpoint && g->dragReplayCount == replaysBefore+2);
 check(NSEqualPoints(g.replayedDown.locationInWindow,NSMakePoint(2,3)) && NSEqualPoints(g.replayedUp.locationInWindow,NSMakePoint(12,3)));
 check(g.controller.undoCount == undoBefore && g.controller.added.count == addedAtEnd);
 NSLog(@"PASS: the click session: a length through the volume, slab, two clicks on one image, Hot Keys double-click, removal and invalid geometry");
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-volume-length-') as d:
 p=Path(d);(p/'test.m').write_text(code);(p/'bridge.h').write_text(bridge);(p/'drag.swift').write_text(extension)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','Harness',
   '-import-objc-header',str(p/'bridge.h'),'-Xcc','-I'+str(root/'Horos/Sources'),'-c',str(p/'drag.swift'),'-o',str(p/'drag.o')],check=True)
 isix_modules.build_module('IsiXROI',p)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','LengthPresentation',
   '-emit-objc-header-path',str(p/'LengthPresentation-Swift.h'),'-c',str(root/'Horos/Sources/LengthPresentation.swift'),'-o',str(p/'length.o')],check=True)
 subprocess.run(['xcrun','clang','-c','-Werror','-fblocks','-fno-objc-arc','-Wno-deprecated-declarations','-Wno-objc-property-no-attribute','-fsanitize=undefined','-I',str(p),'-I',str(root/'Horos/Sources'),str(p/'test.m'),'-o',str(p/'test.o')],check=True)
 subprocess.run(['xcrun','clang','-c','-Werror','-Wdeprecated-declarations','-fblocks',str(root/'Horos/Sources/HorosAlertPanel.m'),'-I',str(root/'Horos/Sources'),'-o',str(p/'alert.o')],check=True)
 subprocess.run(['xcrun','swiftc',str(p/'drag.o'),str(p/'test.o'),str(p/'alert.o'),str(p/'length.o'),'-L',d,'-lIsiXROI','-framework','Cocoa','-framework','OpenGL','-sanitize=undefined','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)


PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

@interface ProbePix (VolumeLength)
- (void) lengthStack:(short) s;
- (void) lengthOrientation:(NSArray*) o;
- (void) lengthZ:(double) z;
- (void) lengthSpacingX:(double) x;
@end
@implementation ProbePix (VolumeLength)
// A slab of `s` images: DCMPix answers its stack only in a stack mode.
- (void) lengthStack:(short) s { PIX_IVAR( self, short, stack) = s; PIX_IVAR( self, short, stackMode) = s > 1; }
- (void) lengthOrientation:(NSArray*) o { for( int i = 0; i < 9; i++) PIX_ORIENTATION( self)[ i] = [o[ i] doubleValue]; }
- (void) lengthZ:(double) z { PIX_IVAR( self, double, originZ) = z; }
// DCMPix's setter refuses a spacing of zero, which an image without one has.
- (void) lengthSpacingX:(double) x { PIX_IVAR( self, double, pixelSpacingX) = x; }
- (id) imageObj { return @{@"sopInstanceUID": @"sop", @"frameID": @0}; }
@end

// An image of the series: 0.5 by 2 mm pixels, 1 mm thick, at `z`.
static ProbePix *pix( NSArray *o, double z)
{
    ProbePix *p = [ProbePix pixWithSpacing: 0.5 originZ: z];
    double origin[ 3] = { 0, 0, z};
    [p setOriginDouble: origin];
    [p lengthOrientation: o];
    p.pixelSpacingY = 2; p.pixelRatio = 4; p.sliceThickness = 1;
    p.frameofReferenceUID = @"frame";
    [p lengthStack: 1];
    return p;
}

/// The projection's fields, as IsiXROIPlaneCrossing has them; all NO when it is not visible.
typedef struct { NSPoint a, b, intersection; BOOL visible, handleA, handleB, crossesPlane; } Projection;
static Projection project( ROI *r)
{
    Projection p = {NSZeroPoint, NSZeroPoint, NSZeroPoint, NO, NO, NO, NO};
    id c = [r performSelector: @selector( volumeProjection)];
    if( !c) return p;
    p.visible = [[c valueForKey: @"visible"] boolValue];
    p.handleA = [[c valueForKey: @"handleA"] boolValue]; p.handleB = [[c valueForKey: @"handleB"] boolValue];
    p.crossesPlane = [[c valueForKey: @"crossesPlane"] boolValue];
    p.a = [[c valueForKey: @"a"] pointValue]; p.b = [[c valueForKey: @"b"] pointValue];
    p.intersection = [[c valueForKey: @"intersection"] pointValue];
    return p;
}

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    NSArray *axial = @[@1,@0,@0,@0,@1,@0,@0,@0,@1];
    ProbePix *p = pix( axial, 0);
    check( [HorosVolumeLengthROI validGeometry: p]);
    NSArray *a = [HorosVolumeLengthROI patientPoint: NSMakePoint( 2, 3) pix: p];
    check( [a[ 0] doubleValue] == 1 && [a[ 1] doubleValue] == 6);
    double depth; NSPoint pt = [HorosVolumeLengthROI projectPoint: @[@1,@6,@7] pix: p depth: &depth];
    check( pt.x == 2 && pt.y == 3 && depth == 7);
    ProbeView *v = view;
    v.curDCM = p; v.is2DViewer = YES; v.curImage = 0; v.flippedData = NO;
    HorosVolumeLengthROI *r = [[[HorosVolumeLengthROI alloc] initWithType: tMesure : 0.5 : 2 : NSZeroPoint] autorelease];
    [r setCurView: (DCMView*) v];
    r.volumeLength = @{@"version":@1,@"id":@"uuid",@"series":@"series",@"frameOfReference":@"frame",@"temporalIndex":@0,@"a":@[@0,@0,@0],@"b":@[@3,@4,@12]};
    check( [r valid] && fabs( r.distanceMM - 13) < 1e-12);
    Projection pr = project( r); check( pr.visible && pr.handleA && !pr.handleB && pr.crossesPlane);
    check( [r clickInROI: NSMakePoint( 100, 100) :0 :0 :10 :NO] == ROI_sleep);
    check( [r clickInROI: pr.a :0 :0 :10 :NO] == ROI_selectedModify);
    check( [r clickInROI: NSMakePoint( 100, 100) :0 :0 :10 :NO] == ROI_sleep);
    [p lengthZ: 6]; pr = project( r); check( pr.visible && !pr.handleA && !pr.handleB);
    check( fabs( pr.intersection.x - 3) < 1e-12 && fabs( pr.intersection.y - 1) < 1e-12);
    check( [r clickInROI: pr.intersection :0 :0 :10 :NO] == ROI_selected);
    [p lengthZ: 20]; check( !project( r).visible); check( [r clickInROI: NSZeroPoint :0 :0 :10 :NO] == ROI_sleep);
    [p lengthZ: 12]; pr = project( r); check( pr.handleB); check( [r clickInROI: pr.b :0 :0 :10 :NO] == ROI_selectedModify);
    [r setROIMode: ROI_selectedModify]; check( [r mouseRoiDragged: NSMakePoint( 6, 2.5) :0 :10]); check( fabs( r.distanceMM - sqrt( 178)) < 1e-10);
    [p lengthStack: 3]; check( ![r mouseRoiDragged: NSMakePoint( 9, 9) :0 :10]); [p lengthStack: 1];
    // Archive/copy preserve the physical identity, even when transient projections change.
    HorosVolumeLengthROI *copy = [[r copy] autorelease]; check( [copy.volumeIdentifier isEqual: r.volumeIdentifier]); check( copy.distanceMM == r.distanceMM);
    NSData *archive = [NSArchiver archivedDataWithRootObject: r]; HorosVolumeLengthROI *back = [NSUnarchiver unarchiveObjectWithData: archive];
    check( back && [back.volumeLength isEqual: r.volumeLength] && back.distanceMM == r.distanceMM);
    // Perpendicular segment remains measurable/selectable although x/y coincide.
    NSMutableDictionary *d = [[r.volumeLength mutableCopy] autorelease]; d[@"a"] = @[@1,@6,@0]; d[@"b"] = @[@1,@6,@12]; r.volumeLength = d; [p lengthZ: 6];
    pr = project( r); check( pr.visible && NSEqualPoints( pr.a, pr.b) && r.distanceMM == 12); check( [r clickInROI: pr.a :0 :0 :10 :NO] == ROI_selected);
    // Reversed slab clips by actual endpoint positions, not average slice spacing.
    ProbePix *last = pix( axial, 2); v.dcmPixList = [NSMutableArray arrayWithObjects: last, pix( axial, 3), p, nil]; v.curImage = 2; v.flippedData = YES; [p lengthStack: 3];
    pr = project( r); check( pr.visible); [p lengthStack: 1];
    // Same-plane and oblique endpoints; orientation transforms never change length.
    double c = sqrt( .5); [p lengthOrientation: @[@(c),@(c),@0,@0,@0,@1,@(c),@(-c),@0]]; [p lengthZ: 0];
    check( [HorosVolumeLengthROI validGeometry: p]); a = [HorosVolumeLengthROI patientPoint: NSMakePoint( 4, 3) pix: p];
    pt = [HorosVolumeLengthROI projectPoint: a pix: p depth: &depth]; check( fabs( pt.x - 4) < 1e-10 && fabs( pt.y - 3) < 1e-10 && fabs( depth) < 1e-10);
    [p lengthSpacingX: 0]; check( ![HorosVolumeLengthROI patientPoint: NSZeroPoint pix: p]); [p lengthSpacingX: .5];
    [p lengthOrientation: @[@1,@0,@0,@1,@0,@0,@0,@0,@0]]; check( ![HorosVolumeLengthROI validGeometry: p]);
    d[@"b"] = d[@"a"]; check( ![HorosVolumeLengthROI validPayload: d]); d[@"b"] = @[@(NAN),@1,@2]; check( ![HorosVolumeLengthROI validPayload: d]);
    v.is2DViewer = NO; check( !project( r).visible);
    [window release];
    printf( "PASS: HorosVolumeLengthROI: physical distance, anisotropy, oblique planes, projection/hit, edit, slab, copy and archive\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
