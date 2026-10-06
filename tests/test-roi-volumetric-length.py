#!/usr/bin/env python3
"""Execute the real patient-space ROI subclass: projection, selection, edit and archive.

The click-session methods stay in DCMView.m; -mouseDragged: is Swift,
in DCMView+MouseDragging.swift. Its length-click replay, the part before the
curImage guard, is compiled as it is, with xcrun swiftc, as an extension of
the Objective-C double of DCMView, which reaches the ivars through the same
horos_* accessors as DCMView+SwiftIvars.h.
"""
from pathlib import Path
import subprocess, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
root=Path(__file__).resolve().parents[1]
source=(root/'Horos/Sources/ROI.m').read_text()
implementation=source[source.index('typedef struct {',source.index('#pragma mark - Patient-space Length')):]
header=(root/'Horos/Sources/ROI.h').read_bytes().decode('latin1')
header=header[header.index('@interface HorosVolumeLengthROI'):]
view_source=(root/'Horos/Sources/DCMView.m').read_text()
gesture=view_source[view_source.index('- (void)cancelLengthPlacement'):view_source.index('- (void)drawPendingLength')]
gesture += view_source[view_source.index('- (void)removeROIFromSliceOrVolume:'):view_source.index('- (void)deleteROIGroupID:')]
swift=source_text('DCMView+MouseDragging')
drag=swift[swift.index('    @objc(mouseDragged:)'):];drag=drag[:drag.index('        if self.horos_curImage < 0 {')]+'        self.dragReplayCount += 1\n    }\n'
extension='import Cocoa\nextension DCMView {\n'+drag+'}\n'
bridge=r'''
#import <Cocoa/Cocoa.h>
@class DCMPix, TestWindow, ViewerController, ROI;
@interface DCMView:NSResponder {
@public NSEvent *lengthClickEvent; BOOL replayingLengthDrag,drawingROI;
NSDictionary *lengthFirstEndpoint;ROI *lengthPendingMarker;NSMutableArray *curRoiList;
NSArray *dcmRoiList;float scaleValue;int currentMouseEventTool,dragReplayCount;
}
@property DCMPix *curDCM;
@property NSArray *dcmPixList;
@property NSInteger curImage;
@property BOOL flippedData;
@property TestWindow *window;
@property BOOL viewer2D;
@property ViewerController *controller;
// The accessors of DCMView+SwiftIvars.h, on the same ivars.
@property(nonatomic, assign) NSEvent *horos_lengthClickEvent;
@property BOOL horos_replayingLengthDrag;
@property int dragReplayCount;
-(NSPoint)convertPoint:(NSPoint)p fromView:(NSView*)v;
-(void)mouseDown:(NSEvent*)event;
@end
@interface DCMView (LengthContract)
-(void)cancelLengthPlacement;
-(BOOL)beginLengthClick:(NSEvent*)event;
-(void)finishLengthClick:(NSEvent*)event;
@end
'''
code=r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "HorosAlertPanel.h"
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
enum {ROI_sleep,ROI_drawing,ROI_selected,ROI_selectedModify,tMesure,t2DPoint};
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
@interface DCMPix:NSObject
@property double pixelSpacingX,pixelSpacingY,originX,originY,originZ,sliceThickness,pixelRatio;
@property NSInteger stack,pwidth,pheight;
@property BOOL generated;
@property NSDictionary *imageObj;
+(NSPoint)originCorrectedAccordingToOrientation:(id)p;
@property(copy) NSString *frameofReferenceUID;
@property NSArray *orientation;
@end
@implementation DCMPix
+(NSPoint)originCorrectedAccordingToOrientation:(id)p{return NSZeroPoint;}
-(void)orientationDouble:(double*)v{for(int i=0;i<9;i++)v[i]=[self.orientation[i] doubleValue];}
@end
@interface TestWindow:NSObject
@property double backingScaleFactor;
@end
@implementation TestWindow @end
@class ROI;
@interface ViewerController:NSObject
@property NSInteger undoCount,curMovieIndex;
@property NSMutableArray *added;
@end
@implementation ViewerController
-(void)addToUndoQueue:(NSString*)kind{self.undoCount++;}
-(void)addVolumeLengthROI:(id)roi{if(!self.added)self.added=[NSMutableArray array];[self.added addObject:roi];}
@end
#import "bridge.h"
@implementation DCMView
@synthesize horos_lengthClickEvent=lengthClickEvent,horos_replayingLengthDrag=replayingLengthDrag,dragReplayCount;
-(BOOL)is2DViewer{return self.viewer2D;}
-(void)setNeedsDisplay:(BOOL)b{}
-(void)deleteMouseDownTimer{}
-(int)getTool:(NSEvent*)event{return tMesure;}
-(NSPoint)convertPoint:(NSPoint)p fromView:(NSView*)v{return p;}
-(NSPoint)ConvertFromNSView2GL:(NSPoint)p{return p;}
-(ViewerController*)windowController{return self.controller;}
-(void)mouseDown:(NSEvent*)event{if(![self beginLengthClick:event])dragReplayCount++;}
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
-(id)initWithType:(int)t :(float)sx :(float)sy :(NSPoint)origin;
-(void)setROIMode:(NSInteger)m;
-(NSInteger)clickInROI:(NSPoint)point :(float)width :(float)height :(float)scale :(BOOL)test;
@end
@implementation ROI
@synthesize curView;
-(id)initWithType:(int)t :(float)sx :(float)sy :(NSPoint)origin{return [self init];}
-(id)init{if((self=[super init])){points=[NSMutableArray new];self.selectable=YES;}return self;}
-(void)encodeWithCoder:(NSCoder*)c{[c encodeObject:points];}
-(id)initWithCoder:(NSCoder*)c{if((self=[self init])){[points release];points=[[c decodeObject] mutableCopy];}return self;}
-(id)copyWithZone:(NSZone*)z{ROI*r=[[[self class] alloc] init];[r->points addObjectsFromArray:points];return r;}
-(NSInteger)clickInROI:(NSPoint)point :(float)width :(float)height :(float)scale :(BOOL)test{return ROI_sleep;}
-(void)recompute{}
-(void)prepareTextualData:(NSPoint)p{}
-(NSPoint)lowerRightPoint{return NSZeroPoint;}
-(void)setROIMode:(NSInteger)m{mode=m;}
-(void)dealloc{[points release];[super dealloc];}
@end
HEADER
IMPLEMENTATION
@implementation DCMView (LengthTest)
GESTURE
@end
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__);exit(1);}}while(0)
static DCMPix* pix(NSArray*o,double z){DCMPix*p=[DCMPix new];p.orientation=o;p.originZ=z;p.pixelSpacingX=.5;p.pixelSpacingY=2;p.pixelRatio=4;p.sliceThickness=1;p.stack=1;p.frameofReferenceUID=@"frame";return [p autorelease];}
int main(){@autoreleasepool{
 method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)TestAlertRun);
 NSEvent *(^event)(NSEventType,CGFloat,CGFloat)=^NSEvent*(NSEventType type,CGFloat x,CGFloat y){return [NSEvent mouseEventWithType:type location:NSMakePoint(x,y) modifierFlags:0 timestamp:1 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];};
 NSArray *axial=@[@1,@0,@0,@0,@1,@0,@0,@0,@1];
 DCMPix*p=pix(axial,0);check([HorosVolumeLengthROI validGeometry:p]);
 NSArray*a=[HorosVolumeLengthROI patientPoint:NSMakePoint(2,3) pix:p];check([a[0] doubleValue]==1&&[a[1] doubleValue]==6);
 double depth;NSPoint pt=[HorosVolumeLengthROI projectPoint:@[@1,@6,@7] pix:p depth:&depth];check(pt.x==2&&pt.y==3&&depth==7);
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
 DCMView*v=[DCMView new];v.curDCM=p;v.viewer2D=YES;v.window=[TestWindow new];v.window.backingScaleFactor=2;
 HorosVolumeLengthROI*r=[HorosVolumeLengthROI new];r.curView=v;
 r.volumeLength=@{@"version":@1,@"id":@"uuid",@"series":@"series",@"frameOfReference":@"frame",@"temporalIndex":@0,@"a":@[@0,@0,@0],@"b":@[@3,@4,@12]};
 check([r valid]&&fabs(r.distanceMM-13)<1e-12);
 HorosLengthProjection pr=[r volumeProjection];check(pr.visible&&pr.handleA&&!pr.handleB&&pr.crossesPlane);
 check([r clickInROI:NSMakePoint(100,100) :0 :0 :10 :NO]==ROI_sleep);
 check([r clickInROI:pr.a :0 :0 :10 :NO]==ROI_selectedModify);
 check([r clickInROI:NSMakePoint(100,100) :0 :0 :10 :NO]==ROI_sleep);
 p.originZ=6;pr=[r volumeProjection];check(pr.visible&&!pr.handleA&&!pr.handleB);check(fabs(pr.intersection.x-3)<1e-12&&fabs(pr.intersection.y-1)<1e-12);
 check([r clickInROI:pr.intersection :0 :0 :10 :NO]==ROI_selected);
 p.originZ=20;check(![r volumeProjection].visible);check([r clickInROI:NSZeroPoint :0 :0 :10 :NO]==ROI_sleep);
 p.originZ=12;pr=[r volumeProjection];check(pr.handleB);check([r clickInROI:pr.b :0 :0 :10 :NO]==ROI_selectedModify);
 [r setROIMode:ROI_selectedModify];check([r mouseRoiDragged:NSMakePoint(6,2.5) :0 :10]);check(fabs(r.distanceMM-sqrt(178))<1e-10);
 p.stack=3;check(![r mouseRoiDragged:NSMakePoint(9,9) :0 :10]);p.stack=1;
 // Archive/copy preserve the physical identity, even when transient projections change.
 HorosVolumeLengthROI*copy=[[r copy] autorelease];check([copy.volumeIdentifier isEqual:r.volumeIdentifier]);check(copy.distanceMM==r.distanceMM);
 NSData*archive=[NSArchiver archivedDataWithRootObject:r];HorosVolumeLengthROI*back=[NSUnarchiver unarchiveObjectWithData:archive];check(back&&[back.volumeLength isEqual:r.volumeLength]&&back.distanceMM==r.distanceMM);
 // Perpendicular segment remains measurable/selectable although x/y coincide.
 NSMutableDictionary*d=[[r.volumeLength mutableCopy] autorelease];d[@"a"]=@[@1,@6,@0];d[@"b"]=@[@1,@6,@12];r.volumeLength=d;p.originZ=6;
 pr=[r volumeProjection];check(pr.visible&&NSEqualPoints(pr.a,pr.b)&&r.distanceMM==12);check([r clickInROI:pr.a :0 :0 :10 :NO]==ROI_selected);
 // Reversed slab clips by actual endpoint positions, not average slice spacing.
 DCMPix*last=pix(axial,2);v.dcmPixList=@[last,pix(axial,3),p];v.curImage=2;v.flippedData=YES;p.stack=3;
 pr=[r volumeProjection];check(pr.visible);p.stack=1;
 // Same-plane and oblique endpoints; orientation transforms never change length.
 double c=sqrt(.5);p.orientation=@[@(c),@(c),@0,@0,@0,@1,@(c),@(-c),@0];p.originZ=0;
 check([HorosVolumeLengthROI validGeometry:p]);a=[HorosVolumeLengthROI patientPoint:NSMakePoint(4,3) pix:p];
 pt=[HorosVolumeLengthROI projectPoint:a pix:p depth:&depth];check(fabs(pt.x-4)<1e-10&&fabs(pt.y-3)<1e-10&&fabs(depth)<1e-10);
 p.pixelSpacingX=0;check(![HorosVolumeLengthROI patientPoint:NSZeroPoint pix:p]);p.pixelSpacingX=.5;p.orientation=@[@1,@0,@0,@1,@0,@0,@0,@0,@0];check(![HorosVolumeLengthROI validGeometry:p]);
 d[@"b"]=d[@"a"];check(![HorosVolumeLengthROI validPayload:d]);d[@"b"]=@[@(NAN),@1,@2];check(![HorosVolumeLengthROI validPayload:d]);
 v.viewer2D=NO;check(![r volumeProjection].visible);
 // Invalid patient geometry must report through the production alert bridge
 // without committing an endpoint or an undo entry. The slab branch only beeps.
 NSInteger undoBefore = g.controller.undoCount;
 [g finishLengthClick:event(NSEventTypeLeftMouseUp,2,3)];
 check(g.controller.undoCount == undoBefore && !g->lengthFirstEndpoint);
 check(alertCalls == 1);
 NSLog(@"PASS: physical distance, anisotropy, oblique planes, projection/hit, edit, slab, archive and invalid geometry");
}}
'''.replace('HEADER',header).replace('IMPLEMENTATION',implementation).replace('GESTURE',gesture)
with tempfile.TemporaryDirectory(prefix='horos-volume-length-') as d:
 p=Path(d);(p/'test.m').write_text(code);(p/'bridge.h').write_text(bridge);(p/'drag.swift').write_text(extension)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','Harness',
   '-import-objc-header',str(p/'bridge.h'),'-c',str(p/'drag.swift'),'-o',str(p/'drag.o')],check=True)
 subprocess.run(['xcrun','clang','-c','-Werror','-fblocks','-fno-objc-arc','-Wno-deprecated-declarations','-Wno-objc-property-no-attribute','-fsanitize=undefined','-I',str(p),'-I',str(root/'Horos/Sources'),str(p/'test.m'),'-o',str(p/'test.o')],check=True)
 subprocess.run(['xcrun','clang','-c','-Werror','-Wdeprecated-declarations','-fblocks',str(root/'Horos/Sources/HorosAlertPanel.m'),'-I',str(root/'Horos/Sources'),'-o',str(p/'alert.o')],check=True)
 subprocess.run(['xcrun','swiftc',str(p/'drag.o'),str(p/'test.o'),str(p/'alert.o'),'-framework','Cocoa','-framework','OpenGL','-sanitize=undefined','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
