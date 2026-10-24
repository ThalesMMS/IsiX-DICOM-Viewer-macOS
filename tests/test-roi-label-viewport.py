#!/usr/bin/env python3
"""Exercise production label placement including offscreen anchors/collisions."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parents[1]
def read(name):
 path='Horos/Sources/'+name
 return (subprocess.check_output(['git','show',sys.argv[1]+':'+path]) if len(sys.argv)>1 else (root/path).read_bytes()).decode('latin1' if name.endswith('.m') else 'utf8')
s=read('ROI.m');a=s.index('- (NSRect) findAnEmptySpaceForMyRect:');b=s.index('- (BOOL) isTextualDataDisplayed',a)
offsetStart=s.index('- (void) setTextBoxOffset:');offsetEnd=s.index('- (void) addPointUnderMouse:',offsetStart)
code=r'''
#import <Cocoa/Cocoa.h>
#import "Presentation-Swift.h"
@interface View:NSObject
@property NSRect drawingFrameRect;
@property(retain) NSMutableArray*rectArray;
- (NSPoint)ConvertFromView2GL:(NSPoint)point;
@end
@implementation View
- (NSPoint)ConvertFromView2GL:(NSPoint)point{return NSMakePoint(point.y / 2, -point.x / 2);}
@end
@interface ROI:NSObject {@public View*curView; NSRect contour, drawRect; NSPoint originAnchor; CGFloat offsetTextBox_x, offsetTextBox_y;}
@end
@implementation ROI
- (NSRect)textualDataContourRect{return contour;}
OFFSET
METHOD
@end
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 for(int scale=1;scale<=2;scale++)for(int columns=1;columns<=3;columns++){
  ROI*r=[ROI new];r->curView=[View new];NSRect frame=NSMakeRect(0,0,1200.0*scale/columns,800*scale);r->curView.drawingFrameRect=frame;
  NSRect viewport=NSMakeRect(-frame.size.width/2,-frame.size.height/2,frame.size.width,frame.size.height);
  for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++)for(int registry=0;registry<2;registry++){
   r->curView.rectArray=registry?[NSMutableArray array]:nil;BOOL moved=NO;
   NSRect input=NSMakeRect(x*3000,y*3000,150*scale,70*scale);
   NSRect placed=[r findAnEmptySpaceForMyRect:input :&moved];
   check(NSContainsRect(viewport,placed));check(NSEqualSizes(input.size,placed.size));
   if(x||y)check(moved);
   else check(!moved && placed.origin.x==8 && placed.origin.y==8);
  }
  r->curView.rectArray=[NSMutableArray arrayWithObject:[NSValue valueWithRect:viewport]];
  BOOL moved=NO;NSRect result=[r findAnEmptySpaceForMyRect:NSMakeRect(0,0,150*scale,70*scale) :&moved];
  check(NSContainsRect(viewport,result));
  check(NSEqualRects([r->curView.rectArray.lastObject rectValue],result));
  NSRect annotation=NSMakeRect(viewport.origin.x,NSMaxY(viewport)-100*scale,viewport.size.width,100*scale);
  r->curView.rectArray=[NSMutableArray arrayWithObject:[NSValue valueWithRect:annotation]];
  result=[r findAnEmptySpaceForMyRect:NSMakeRect(0,3000,150*scale,70*scale) :&moved];
  check(NSContainsRect(viewport,result) && !NSIntersectsRect(annotation,result));

 }
 for(int scale=1;scale<=2;scale++){
  ROI*r=[ROI new];r->curView=[View new];r->curView.drawingFrameRect=NSMakeRect(0,0,200*scale,200*scale);
  NSRect vertical=NSMakeRect(-10*scale,-100*scale,20*scale,200*scale);
  NSRect horizontal=NSMakeRect(-100*scale,-10*scale,200*scale,20*scale);
  r->curView.rectArray=[NSMutableArray arrayWithObjects:[NSValue valueWithRect:vertical],[NSValue valueWithRect:horizontal],nil];
  BOOL moved=NO;NSRect result=[r findAnEmptySpaceForMyRect:NSMakeRect(-8,-8,40*scale,40*scale) :&moved];
  check(!NSIntersectsRect(result,vertical) && !NSIntersectsRect(result,horizontal));
  check(NSContainsRect(NSMakeRect(-100*scale,-100*scale,200*scale,200*scale),result) && moved);
 }
 // Small ROIs at every viewport edge retain a clear contour.
 for(int scale=1;scale<=2;scale++)for(int x=-1;x<=1;x++)for(int y=-1;y<=1;y++) {
  ROI*r=[ROI new];r->curView=[View new];r->curView.drawingFrameRect=NSMakeRect(0,0,400*scale,300*scale);
  r->curView.rectArray=[NSMutableArray array];
  NSRect viewport=NSMakeRect(-200*scale,-150*scale,400*scale,300*scale);
  r->contour=NSMakeRect(x*175*scale-10*scale,y*125*scale-10*scale,20*scale,20*scale);
  NSRect input=NSMakeRect(NSMinX(r->contour)-8,NSMinY(r->contour)-8,100*scale,40*scale);
  BOOL moved=NO;NSRect result=[r findAnEmptySpaceForMyRect:input :&moved];
  check(NSContainsRect(viewport,result) && !NSIntersectsRect(result,r->contour) && moved);
  // Freeze the displayed position into the persisted image-space offset.
  r->drawRect=result;r->originAnchor=input.origin;
  NSPoint anchor=[r->curView ConvertFromView2GL:r->originAnchor];
  NSPoint displayed=[r->curView ConvertFromView2GL:NSMakePoint(result.origin.x-8,result.origin.y-8)];
  [r setTextBoxOffset:NSMakePoint(2,3)];
  check(fabs(r->offsetTextBox_x-(displayed.x-anchor.x+2))<0.001);
  check(fabs(r->offsetTextBox_y-(displayed.y-anchor.y+3))<0.001);
  [r setTextBoxOffset:NSMakePoint(1,1)];
  check(fabs(r->offsetTextBox_x-(displayed.x-anchor.x+3))<0.001);
  // Manual placement remains authoritative even over the contour/annotations.
  r->curView.rectArray=[NSMutableArray arrayWithObject:[NSValue valueWithRect:viewport]];
  result=[r findAnEmptySpaceForMyRect:input :&moved];
  check(NSEqualRects(result,[HorosROILabelPresentation constrainLabelRect:NSOffsetRect(input,8,8) toViewport:viewport]));
 }
 // The widest available side wins when the original label covers the ROI.
 NSRect vp=NSMakeRect(0,0,500,300), roi=NSMakeRect(80,130,20,20), label=NSMakeRect(80,130,100,40);
 NSRect placed=[HorosROILabelPresentation placeLabelRect:label inViewport:vp avoiding:@[] roiBounds:roi manuallyPlaced:NO];
 check(NSMinX(placed)>=NSMaxX(roi) && NSContainsRect(vp,placed));
 // An occupied preferred side falls back to a free alternative.
 NSRect right=NSMakeRect(100,0,400,300);
 placed=[HorosROILabelPresentation placeLabelRect:label inViewport:vp avoiding:@[[NSValue valueWithRect:right]] roiBounds:roi manuallyPlaced:NO];
 check(!NSIntersectsRect(placed,roi));
 NSLog(@"PASS: viewport edges/corners, small ROI avoidance, largest side, manual placement/first drag, offscreen anchors, annotations, one/three panes and 1x/2x");
}}
'''.replace('METHOD',s[a:b]).replace('OFFSET',s[offsetStart:offsetEnd])
with tempfile.TemporaryDirectory(prefix='horos-label-viewport-') as d:
 p=Path(d);(p/'test.m').write_text(code);(p/'Presentation.swift').write_text(read('ROILabelPresentation.swift'))
 subprocess.run(['xcrun','swiftc',str(p/'Presentation.swift'),'-emit-library','-module-name','Presentation','-emit-objc-header-path',str(p/'Presentation-Swift.h'),'-o',str(p/'libPresentation.dylib')],check=True)
 subprocess.run(['xcrun','clang','-fno-objc-arc','-fsanitize=undefined','-framework','Cocoa','-I',d,str(p/'test.m'),'-L',d,'-lPresentation','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
