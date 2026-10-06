#!/usr/bin/env python3
"""Patient directions and marker positions of the production scroll preview."""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import is_swift, source_path  # noqa: E402

root = Path(__file__).resolve().parents[1]
code = r'''
#include "ScrollPositionPreviewGeometry.h"
#include <assert.h>
#include <stdio.h>
static void point(HorosPreviewOrientation o, double x, double y, double u, double v) {
 double actualU, actualV; HorosPreviewMapPoint(o,x,y,&actualU,&actualV);
 assert(fabs(actualU-u)<1e-9 && fabs(actualV-v)<1e-9);
}
int main(void) {
 float axial[9]={1,0,0,0,1,0,0,0,1};
 float coronal[9]={1,0,0,0,0,-1,0,1,0};
 float sagittal[9]={0,1,0,0,0,-1,-1,0,0};
 float acquiredRotated[9]={0,0,1,1,0,0,0,1,0};
 assert(HorosPreviewResliceAxis(axial)==0);
 assert(HorosPreviewResliceAxis(coronal)==0);
 assert(HorosPreviewResliceAxis(sagittal)==0);
 assert(HorosPreviewResliceAxis(acquiredRotated)==1);
 // A coronal preview has S at the top, I at the bottom, R on the left.
 HorosPreviewOrientation o=HorosPreviewDisplayOrientation(coronal);
 point(o,.25,.75,.25,.75);
 // A coronal source's reformat has an A-directed column: flip vertically.
 float fromCoronal[9]={1,0,0,0,-1,0,0,0,-1};
 o=HorosPreviewDisplayOrientation(fromCoronal);
 point(o,.25,.75,.25,.25);
 // A sagittal source produces Y across and X down: transpose. Its slice
 // marker must therefore become a vertical line in the axial thumbnail.
 float fromSagittal[9]={0,1,0,1,0,0,0,0,-1};
 o=HorosPreviewDisplayOrientation(fromSagittal);
 point(o,0,.3,.3,0); point(o,1,.3,.3,1); point(o,.2,.3,.3,.2);
 // All permutations and sign combinations preserve the patient coordinates
 // and the four corners, including upside-down and reversed acquisition.
 for(int transpose=0;transpose<2;transpose++) for(int fx=0;fx<2;fx++) for(int fy=0;fy<2;fy++) {
  float plane[9]={0};
  int row=transpose?3:0, col=transpose?0:3;
  plane[row]=fx?-1:1; plane[col+1]=fy?-1:1; plane[8]=1;
  o=HorosPreviewDisplayOrientation(plane);
  for(int i=0;i<11;i++) for(int j=0;j<11;j++) {
   double x=i/10.,y=j/10.;
   double expectedX=(transpose?y:x)*(fx?-1:1)+(fx?1:0);
   double expectedY=(transpose?x:y)*(fy?-1:1)+(fy?1:0);
   point(o,x,y,expectedX,expectedY);
  }
 }
 puts("PASS: three planes, rotated acquisition, marker direction and 968 orientation mappings");
}
'''
with tempfile.TemporaryDirectory(prefix='horos-scroll-preview-') as folder:
    folder = Path(folder)
    (folder/'test.c').write_text(code)
    subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',
                    '-I',str(root/'Horos/Sources'),str(folder/'test.c'),'-o',str(folder/'test')],check=True)
    subprocess.run([str(folder/'test')],check=True)

# Execute the real OrthogonalReslice implementation against an owned ramp.
# Only DCMPix's storage/metadata shell is substituted; reslicing, threading,
# boundaries and the cache layout are production code. OrthogonalReslice is
# Swift: it is compiled with ResliceCacheLayout against this
# DCMPix interface, which declares the members it reaches as DCMPix.h does.
assert is_swift('OrthogonalReslice'), 'OrthogonalReslice is expected in Swift'
interface = r'''
#import <Cocoa/Cocoa.h>
@interface DCMPix:NSObject { float *_pixels; float _cosines[9]; }
@property long pwidth,pheight;
@property double pixelSpacingX,pixelSpacingY,pixelRatio,sliceInterval,sliceThickness,sliceLocation,originX,originY,originZ;
@property BOOL isRGB,displayInverted;
@property(retain) NSString *frameofReferenceUID,*modalityString;
@property(setter=setID:) long ID;
@property long frameNo;
@property(getter=Tot, setter=setTot:) long Tot;
-(id)initWithData:(float*)data :(short)bits :(long)w :(long)h :(float)sx :(float)sy :(float)x :(float)y :(float)z :(BOOL)rgb;
@property(readonly) float* fImage;
-(void)orientation:(float*)o; -(void)setOrientation:(float*)o; -(void)setOrigin:(float*)o;
-(void)copySUVfrom:(DCMPix*)p;
-(void)computeSliceLocation;
@end
extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);
'''
pixel = r'''
#import <Cocoa/Cocoa.h>
#import "DCMPix.h"
#import "Horos-Swift.h"
#include <assert.h>
void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%@", e); }
@implementation DCMPix
@synthesize ID, frameNo, Tot;
-(id)initWithData:(float*)data :(short)bits :(long)w :(long)h :(float)sx :(float)sy :(float)x :(float)y :(float)z :(BOOL)rgb {
 if((self=[super init])) {self.pwidth=w;self.pheight=h;self.pixelSpacingX=sx;self.pixelSpacingY=sy;
  self.originX=x;self.originY=y;self.originZ=z;self.isRGB=rgb;_pixels=calloc(w*h,sizeof(float));
  _cosines[0]=_cosines[4]=_cosines[8]=1;}
 return self;
}
-(float*)fImage{return _pixels;}
-(void)orientation:(float*)o{memcpy(o,_cosines,sizeof(_cosines));}
-(void)setOrientation:(float*)o{memcpy(_cosines,o,sizeof(_cosines));
 _cosines[6]=o[1]*o[5]-o[2]*o[4];_cosines[7]=o[2]*o[3]-o[0]*o[5];_cosines[8]=o[0]*o[4]-o[1]*o[3];}
-(void)setOrigin:(float*)o{self.originX=o[0];self.originY=o[1];self.originZ=o[2];}
-(void)copySUVfrom:(DCMPix*)p{}
-(void)computeSliceLocation{self.sliceLocation=self.originX*_cosines[6]+self.originY*_cosines[7]+self.originZ*_cosines[8];}
-(void)dealloc{free(_pixels);[_frameofReferenceUID release];[_modalityString release];[super dealloc];}
@end
'''
driver = r'''
int main(void){@autoreleasepool{
 NSUserDefaults *defaults=[[[NSUserDefaults alloc]initWithSuiteName:@"org.horosproject.scroll-preview-test"]autorelease];
 [defaults setVolatileDomain:@{} forName:NSArgumentDomain];
 assert(HorosScrollPreviewIsEnabled(defaults));
 for(id off in @[@NO, @"NO", @"0"]) {
  [defaults setVolatileDomain:@{@"ShowScrollPositionPreview":off} forName:NSArgumentDomain];
  assert(!HorosScrollPreviewIsEnabled(defaults));
 }
 for(id on in @[@YES, @"YES", @"1"]) {
  [defaults setVolatileDomain:@{@"ShowScrollPositionPreview":on} forName:NSArgumentDomain];
  assert(HorosScrollPreviewIsEnabled(defaults));
 }
 for(int reversed=0;reversed<2;reversed++) {
  NSMutableArray *slices=[NSMutableArray array];
  for(int z=0;z<3;z++) {
   DCMPix *p=[[[DCMPix alloc]initWithData:NULL :32 :7 :5 :1 :1 :0 :0 :(reversed?-z:z) :NO]autorelease];
   p.sliceInterval=reversed?-1:1;[p computeSliceLocation];
   for(int y=0;y<5;y++)for(int x=0;x<7;x++)p.fImage[y*7+x]=x+10*y+100*z;
   [slices addObject:p];
  }
  OrthogonalReslice *r=[[[OrthogonalReslice alloc]initWithOriginalDCMPixList:slices]autorelease];
  r.useYcache=NO;
  for(int axis=0;axis<2;axis++)for(int requested=-1;requested<=(axis?7:5);requested++) {
   int position=MAX(0,MIN(requested,(axis?7:5)-1));
   [r axeReslice:axis :requested];
   NSArray *planes=axis?r.yReslicedDCMPixList:r.xReslicedDCMPixList;assert(planes.count==1);
   DCMPix *p=planes[0];assert(p.pheight==3 && p.pwidth==(axis?5:7));
   for(int y=0;y<3;y++)for(int x=0;x<p.pwidth;x++) {
    int z=reversed?y:2-y;
    float expected=axis?position+10*x+100*z:x+10*position+100*z;
    assert(p.fImage[y*p.pwidth+x]==expected);
   }
  }
 }
 puts("PASS: production orthogonal reslicer, all rows/columns, both stack orders and endpoint clamps");
}}
'''
# The DCMView category is a Swift extension: the production policy,
# a private Swift function, is compiled with the reslicer under a C name the
# Objective-C driver calls.
assert is_swift('ScrollPositionPreview'), 'ScrollPositionPreview is expected in Swift'
preview = (root/'Horos/Sources/ScrollPositionPreview.swift').read_text()
# The Viewer preferences show the switch, and it starts on.
for language in ('Base','ja-JP'):
    tree = ET.parse(root/f'Preference Panes/OSIViewerPreferencePane/{language}.lproj/OSIViewerPreferencePanePref.xib')
    assert len(tree.findall('.//binding[@keyPath="values.ShowScrollPositionPreview"]')) == 1, language
assert 'setObject: @"1" forKey: @"ShowScrollPositionPreview"' in (root/'Horos/Sources/DefaultsOsiriX.m').read_text()
start = preview.index('private func HorosScrollPreviewIsEnabled(')
policy_swift = ('import Foundation\n@_cdecl("HorosScrollPreviewIsEnabled")\npublic '
                + preview[start + len('private '):preview.index('\n}\n', start) + 3])
policy = 'BOOL HorosScrollPreviewIsEnabled(NSUserDefaults *defaults);\n'
with tempfile.TemporaryDirectory(prefix='horos-preview-reslice-') as folder:
    folder = Path(folder)
    (folder/'DCMPix.h').write_text(interface)
    (folder/'bridge.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import "DCMPix.h"\n#import "HorosObjCException.h"\n')
    (folder/'test.m').write_text(pixel + policy + driver)
    (folder/'policy.swift').write_text(policy_swift)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-wmo','-module-name','Horos','-sanitize=address',
                    '-import-objc-header',str(folder/'bridge.h'),'-Xcc','-I'+str(folder),
                    '-Xcc','-I'+str(root/'Horos/Sources'),
                    '-emit-objc-header','-emit-objc-header-path',str(folder/'Horos-Swift.h'),
                    '-c',str(source_path('OrthogonalReslice')),str(root/'Horos/Sources/ResliceCacheLayout.swift'),
                    str(folder/'policy.swift'),
                    '-o',str(folder/'reslice.o')],check=True)
    subprocess.run(['xcrun','clang','-fno-objc-arc','-Wno-incompatible-pointer-types','-Wno-deprecated-declarations',
                    '-c',str(folder/'test.m'),'-I',str(folder),'-o',str(folder/'test.o'),
                    '-fsanitize=address,undefined'],check=True)
    subprocess.run(['xcrun','clang','-fobjc-arc','-c',str(root/'Horos/Sources/HorosObjCException.m'),
                    '-I',str(root/'Horos/Sources'),'-o',str(folder/'exception.o')],check=True)
    subprocess.run(['xcrun','swiftc',str(folder/'reslice.o'),str(folder/'test.o'),str(folder/'exception.o'),
                    '-framework','Cocoa','-sanitize=address','-sanitize=undefined','-o',str(folder/'test')],check=True)
    subprocess.run([str(folder/'test')],check=True)
