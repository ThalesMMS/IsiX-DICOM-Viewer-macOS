#!/usr/bin/env python3
"""Exercise the production fusion-frame branch with real vImage and VTK import.

The branch is Swift (VRView+Volume.swift, an extension of VRView): it is
compiled as an extension of a stand-in host whose properties are the view's,
over a stand-in of the VTK adapter whose two calls are the adapter's own
bodies around a real vtkImageImport. A revision whose branch is still in
VRView.m compiles the Objective-C instead."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
path='Horos/Sources/VRView.m'
# A checkout without VRView.m has the class in Swift: its Swift branch is read.
source=(subprocess.check_output(['git','show',sys.argv[1]+':'+path]) if len(sys.argv)>1 else
        (root/path).read_bytes() if (root/path).exists() else b'').decode('latin1')
swift_branch='if( blendingData != [blendingController volumePtr])' not in source
if swift_branch:
    volume_path='Horos/Sources/VRView+Volume.swift'
    volume=(subprocess.check_output(['git','show',sys.argv[1]+':'+volume_path]) if len(sys.argv)>1 else (root/volume_path).read_bytes()).decode('utf-8')
    anchor=volume.index('if horos_blendingData != blendingController.volumePtr() {')
    a=volume.index('                if horos_isBlendingRGB {',anchor)
    b=volume.index('                vtk.updateBlendingImport()',a)+len('                vtk.updateBlendingImport()')
    block=volume[a:b]
else:
    anchor=source.index('if( blendingData != [blendingController volumePtr])')
    a=anchor+re.search(r'                if\( (?:isRGB|isBlendingRGB)\)',source[anchor:]).start()
    b=source.index('                [vtk updateBlendingImport];',a)+len('                [vtk updateBlendingImport];')
    block=source[a:b]
# The importer is the VTK adapter's: its calls replace the view's messages.
pipeline=(subprocess.check_output(['git','show',sys.argv[1]+':Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm']) if len(sys.argv)>1 else (root/'Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm').read_bytes()).decode('latin1')
def lambda_body(signature):
    start=pipeline.index('[&] {',pipeline.index(signature))+len('[&] {')
    return pipeline[start:pipeline.index('});',start)].replace('o->blendingReader','blendingReader')
set_voxels=lambda_body('- (void)setBlendingImportVoxels:(void *)voxels')
update=lambda_body('- (void)updateBlendingImport')
if not swift_branch:
    block=re.sub(r'\[vtk setBlendingImportVoxels: (\w+)\];',lambda m:'{ void *voxels='+m.group(1)+';'+set_voxels+'}',block)
    block=block.replace('[vtk updateBlendingImport];','{'+update+'}')
install=root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install/'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)
code=r'''
#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>
#include <vtkImageImport.h>
#include <vtkImageData.h>
#include <vector>
#include <cstdio>
#include <cassert>
static int conversions;
@interface BrowserController : NSObject
+ (void)multiThreadedImageConvert:(NSString *)what :(vImage_Buffer *)src :(vImage_Buffer *)dst :(float)offset :(float)scale;
@end
@implementation BrowserController
+ (void)multiThreadedImageConvert:(NSString *)what :(vImage_Buffer *)src :(vImage_Buffer *)dst :(float)offset :(float)scale {
 assert([what isEqualToString:@"FTo16U"]);conversions++;
 assert(vImageConvert_FTo16U(src,dst,offset,scale,kvImageDoNotTile)==kvImageNoError);
}
@end
int main(){ @autoreleasepool {
 int cases=0;
 for(bool isRGB: {false,true})for(bool isBlendingRGB: {false,true}) {
  std::vector<float> scalar(24);std::vector<unsigned char> rgba(96);std::vector<unsigned short> converted(24);
  auto blendingReader=vtkImageImport::New();blendingReader->SetWholeExtent(0,3,0,2,0,1);blendingReader->SetDataExtentToWholeExtent();
  if(isBlendingRGB){blendingReader->SetDataScalarTypeToUnsignedChar();blendingReader->SetNumberOfScalarComponents(4);blendingReader->SetImportVoidPointer(rgba.data());}
  else {blendingReader->SetDataScalarTypeToUnsignedShort();blendingReader->SetNumberOfScalarComponents(1);blendingReader->SetImportVoidPointer(converted.data());}
  blendingReader->Update();
  for(int frame=0;frame<3;frame++) {
   for(int i=0;i<24;i++)scalar[i]=100+frame*200+i;
   for(int i=0;i<96;i++)rgba[i]=(17*i+31*frame)%251;
   void *blendingData=isBlendingRGB?(void*)rgba.data():(void*)scalar.data();
   void *blendingData8=converted.data();
   float blendingOFFSET16=100,blendingValueFactor=2;
   vImage_Buffer blendingSrcf={blendingData,6,4,4*sizeof(float)};
   vImage_Buffer blendingDst8={blendingData8,6,4,4*sizeof(unsigned short)};
   conversions=0;
   BLOCK
   if(conversions!=(isBlendingRGB?0:1)) {std::fprintf(stderr,"FAIL: primary RGB=%d, fusion RGB=%d used wrong conversion path\n",isRGB,isBlendingRGB);return 1;}
   for(int z=0;z<2;z++)for(int y=0;y<3;y++)for(int x=0;x<4;x++)for(int c=0;c<(isBlendingRGB?4:1);c++) {
    int i=(z*3+y)*4+x;
    double expected=isBlendingRGB?rgba[4*i+c]:(scalar[i]+100)*2;
    double actual=blendingReader->GetOutput()->GetScalarComponentAsDouble(x,y,z,c);
    if(actual!=expected){std::fprintf(stderr,"FAIL: frame %d sample %d component %d expected %g got %g\n",frame,i,c,expected,actual);return 2;}
   }
   cases++;
  }
  blendingReader->Delete();
 }
 std::printf("PASS: %d fusion-frame imports across all primary/fusion scalar-RGBA combinations preserve every component\n",cases);
}}
'''.replace('BLOCK',block)
# The Swift branch runs as an extension of a host with the view's properties,
# over the adapter's stand-in; the frame loop sets them as the Objective-C
# branch's locals.
HARNESS_H = r'''
#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>
NS_ASSUME_NONNULL_BEGIN
@interface StubVTK : NSObject
- (void)setBlendingImportVoxels:(void *)voxels;
- (void)updateBlendingImport;
@end
@interface BrowserController : NSObject
+ (void)multiThreadedImageConvert:(NSString *)what :(vImage_Buffer *)src :(vImage_Buffer *)dst :(float)offset :(float)scale;
@end
@interface FrameHost : NSObject
@property BOOL horos_isBlendingRGB;
@property (nullable) float *horos_blendingData;
@property (nullable) char *horos_blendingData8;
@property (readonly) vImage_Buffer *horos_blendingSrcf NS_RETURNS_INNER_POINTER;
@property (readonly) vImage_Buffer *horos_blendingDst8 NS_RETURNS_INNER_POINTER;
@property float horos_blendingOFFSET16, horos_blendingValueFactor;
@end
#ifdef __cplusplus
extern "C"
#endif
void runFrame(FrameHost *host, StubVTK *vtk);
NS_ASSUME_NONNULL_END
'''
SWIFT = '''import Foundation
@_cdecl("runFrame") public func runFrame(_ host: FrameHost, _ vtk: StubVTK) {
    host.frame(vtk)
}
extension FrameHost {
    func frame(_ vtk: StubVTK) {
BLOCK
    }
}
'''
SWIFT_OBJC = r'''
#import "harness.h"
@interface StubVTK () { @public vtkImageImport *blendingReader; }
@end
@implementation StubVTK
- (void)setBlendingImportVoxels:(void *)voxels {SET_VOXELS}
- (void)updateBlendingImport {UPDATE}
@end
@interface FrameHost () { @public vImage_Buffer srcf, dst8; }
@end
@implementation FrameHost
- (vImage_Buffer *)horos_blendingSrcf { return &srcf; }
- (vImage_Buffer *)horos_blendingDst8 { return &dst8; }
@end
'''.replace('SET_VOXELS', set_voxels).replace('UPDATE', update)
if swift_branch:
    code=code.replace('@interface BrowserController : NSObject\n+ (void)multiThreadedImageConvert:(NSString *)what :(vImage_Buffer *)src :(vImage_Buffer *)dst :(float)offset :(float)scale;\n@end\n', SWIFT_OBJC)
    code=code.replace('   conversions=0;\n   '+block,
                      '   conversions=0;\n   StubVTK *vtk=[StubVTK new]; vtk->blendingReader=blendingReader;\n'
                      '   FrameHost *host=[FrameHost new]; host.horos_isBlendingRGB=isBlendingRGB; host.horos_blendingData=(float *)blendingData;\n'
                      '   host.horos_blendingData8=(char *)blendingData8; host->srcf=blendingSrcf; host->dst8=blendingDst8;\n'
                      '   host.horos_blendingOFFSET16=blendingOFFSET16; host.horos_blendingValueFactor=blendingValueFactor;\n'
                      '   runFrame(host, vtk);')
    assert 'runFrame(host, vtk);' in code

with tempfile.TemporaryDirectory(prefix='horos-vr-fusion-') as d:
    p=Path(d);(p/'test.mm').write_text(code)
    # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
    libs = [install / 'wlib' / 'libVTK.a']
    if swift_branch:
        (p/'harness.h').write_text(HARNESS_H)
        (p/'frame.swift').write_text(SWIFT.replace('BLOCK', block))
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-import-objc-header',str(p/'harness.h'),
                        '-c',str(p/'frame.swift'),'-o',str(p/'frame.o')],check=True)
        subprocess.run(['xcrun','clang++','-std=c++17','-fno-objc-arc','-I'+str(install/'include'),'-I'+str(p),'-c',str(p/'test.mm'),
                        '-o',str(p/'test.o')],check=True)
        subprocess.run(['xcrun','swiftc',str(p/'test.o'),str(p/'frame.o'),*[str(x) for x in libs],'-lz','-lc++','-framework','Cocoa',
                        '-framework','Accelerate','-o',str(p/'test')],check=True)
    else:
        subprocess.run(['xcrun','clang++','-std=c++17','-I'+str(install/'include'),str(p/'test.mm'),*[str(x) for x in libs],'-lz','-framework','Cocoa','-framework','Accelerate','-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
