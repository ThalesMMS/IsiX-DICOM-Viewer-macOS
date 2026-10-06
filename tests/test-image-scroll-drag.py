#!/usr/bin/env python3
"""Run production drag navigation with controlled geometry and pointer positions.

-mouseDraggedImageScroll: is Swift, in DCMView+MouseDragging.swift.
The method is compiled as it is, with xcrun swiftc, as an extension of an
Objective-C double of DCMView that reaches the ivars through the same horos_*
accessors as DCMView+SwiftIvars.h; the messages to the window controller go
through the production msg/windowControllerOf helpers. A revision given as
the argument that predates the Swift translation runs its Objective-C method instead.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess,sys,tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
import harness_defaults  # the harness's preferences stay in its own process
root=Path(__file__).resolve().parents[1]
SWIFT_PATH='Horos/Sources/DCMView+MouseDragging.swift'

def at_revision(path):
 """The file at the revision of the argument, or None where it did not exist."""
 run=subprocess.run(['git','show',sys.argv[1]+':'+path],cwd=root,capture_output=True)
 return run.stdout.decode('utf-8' if path.endswith('.swift') else 'latin1') if run.returncode==0 else None

if len(sys.argv)>1:
 swift=at_revision(SWIFT_PATH)
 s=None if swift else subprocess.check_output(['git','show',sys.argv[1]+':Horos/Sources/DCMView.m'],cwd=root).decode('latin1')
else:
 swift=source_text('DCMView+MouseDragging');s=None

if swift:
 a=swift.index('    @objc(mouseDraggedImageScroll:)');b=swift.index('    @objc(mouseDraggedBlending:)',a)
 method=''
 helpers=swift[swift.index('@inline(__always)\nprivate func msg('):swift.index('/// [NSUserDefaults standardUserDefaults].')]
 extension='''import Cocoa
// The selectors of DCMViewDraggingMessages the method sends.
@objc private protocol DCMViewDraggingMessages {
    @objc(windowController) func draggingWindowController() -> AnyObject?
    @objc(adjustSlider) func draggingAdjustSlider()
}
'''+helpers+'extension DCMView {\n'+swift[a:b]+'}\n'
else:
 a=s.index('- (void)mouseDraggedImageScroll:');b=s.index('\n- (void)mouseDraggedBlending:',a)
 method=s[a:b];extension=None

bridge=r'''
#import <AppKit/AppKit.h>
@interface DCMView:NSObject { @public short curImage,startImage;long scrollMode;NSPoint start,current;NSArray*dcmPixList;char listType;NSMatrix*matrix;NSString*stringID;NSInteger syncDelta;BOOL flippedData; }
@property NSRect frame;
// The accessors of DCMView+SwiftIvars.h, on the same ivars.
@property short horos_curImage,horos_startImage;
@property long horos_scrollMode;
@property NSPoint horos_start;
@property(nonatomic) NSArray *horos_dcmPixList;
@property char horos_listType;
@property(nonatomic) NSMatrix *horos_matrix;
@property(nonatomic) NSString *horos_stringID;
@property BOOL horos_flippedData;
-(NSPoint)currentPointInView:(NSEvent*)e;
-(void)setIndex:(short)i;-(void)setIndexWithReset:(short)i :(BOOL)b;
-(BOOL)is2DViewer;-(id)windowController;-(void)adjustSlider;-(void)sendSyncMessage:(short)i;
-(void)horosShowScrollPreviewAtWindowPoint:(NSPoint)point;
@end
'''
code=r'''
#import "bridge.h"
#import "Horos-Swift.h"
#include <limits.h>
#include <math.h>
@implementation DCMView
@synthesize horos_curImage=curImage,horos_startImage=startImage,horos_scrollMode=scrollMode,horos_start=start,
 horos_dcmPixList=dcmPixList,horos_listType=listType,horos_matrix=matrix,horos_stringID=stringID,horos_flippedData=flippedData;
-(void)horosShowScrollPreviewAtWindowPoint:(NSPoint)point{}
-(NSPoint)currentPointInView:(NSEvent*)e{return current;}
-(void)setIndex:(short)i{curImage=i;}-(void)setIndexWithReset:(short)i :(BOOL)b{curImage=i;}
-(BOOL)is2DViewer{return NO;}-(id)windowController{return nil;}-(void)adjustSlider{}
-(void)sendSyncMessage:(short)i{syncDelta=i;}
METHOD
@end
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 // Direction now comes from the shared policy; pin it to the shipped default so
 // these geometry expectations stay comparable with the historical ones.
 [[NSUserDefaults standardUserDefaults] setBool:YES
     forKey:HorosScrollDirection.reversedPreferenceKey];
 DCMView*v=[DCMView new];v->dcmPixList=@[@0,@1,@2,@3,@4,@5,@6,@7,@8,@9];v->startImage=v->curImage=5;v->start=NSZeroPoint;v.frame=NSMakeRect(0,0,100,200);
 v->scrollMode=1;v->current=NSMakePoint(0,-20);[v mouseDraggedImageScroll:nil];check(v->curImage==7 && v->syncDelta==2);
 v->scrollMode=2;v->current=NSMakePoint(20,0);[v mouseDraggedImageScroll:nil];check(v->curImage==9);
 v->current=NSMakePoint(1e12,0);[v mouseDraggedImageScroll:nil];check(v->curImage==9);
 v->current=NSMakePoint(-1e12,0);[v mouseDraggedImageScroll:nil];check(v->curImage==0);
 v->curImage=5;v.frame=NSZeroRect;v->current=NSMakePoint(20,0);[v mouseDraggedImageScroll:nil];check(v->curImage==5);
 v.frame=NSMakeRect(0,0,100,200);v->current=NSMakePoint(NAN,0);[v mouseDraggedImageScroll:nil];check(v->curImage==5);
 v->current=NSMakePoint(10,0);v->dcmPixList=@[];[v mouseDraggedImageScroll:nil];check(v->curImage==5);
 NSLog(@"PASS: axis-specific sensitivity, large drags, empty lists and invalid geometry");
}}
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory(prefix='horos-drag-') as d:
 p=Path(d);(p/'test.m').write_text(code + harness_defaults.OBJC);(p/'bridge.h').write_text(bridge)
 swift_sources=[str(root/'Horos/Sources/ScrollDirection.swift')]
 bridging=[]
 if extension:
  (p/'drag.swift').write_text(extension);swift_sources.append(str(p/'drag.swift'))
  bridging=['-import-objc-header',str(p/'bridge.h')]
 # Swift traps a float-to-integer conversion that overflows, as the
 # float-cast-overflow sanitizer does for the Objective-C method.
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','Horos','-wmo',*bridging,
   '-emit-objc-header','-emit-objc-header-path',str(p/'Horos-Swift.h'),
   '-c',*swift_sources,'-o',str(p/'scroll.o')],check=True)
 subprocess.run(['xcrun','clang','-c',str(p/'test.m'),'-o',str(p/'test.o'),'-I',str(p),
   '-fobjc-arc','-fsanitize=undefined,float-cast-overflow'],check=True)
 subprocess.run(['xcrun','swiftc',str(p/'scroll.o'),str(p/'test.o'),'-o',str(p/'test'),
   '-framework','AppKit','-sanitize=undefined'],check=True)
 subprocess.run([str(p/'test')],check=True)
