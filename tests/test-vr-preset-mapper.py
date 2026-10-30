#!/usr/bin/env python3
"""Verify real VTK mapper isolation and shared input for preset previews, and
that a preview takes the view's Metal hook with its own context.

The preview's -setMapper: is VRView's -horosAdoptPreviewMapper:, Swift
(VRView+Subclasses.swift): compiled here over a stand-in of the VTK adapter
whose one call runs the adapter's Objective-C++ body on the stand-in
preview's objects. A revision whose method is still in VRView.m compiles that
Objective-C instead."""
from pathlib import Path
import subprocess, tempfile, sys
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
import vtk_pattern_window
def read(path):
    return (subprocess.check_output(['git','show',sys.argv[1]+':'+path]) if len(sys.argv)>1 else (root/path).read_bytes()).decode('latin1')
# VRPresetPreview is Swift; its -setMapper: hands the main view's mapper to
# VRView's -horosAdoptPreviewMapper:, which has the VTK adapter
# (IsiXVTKVolumePipeline.mm) build the preview's own. Both run here, the
# adapter's objects being the stand-in preview's own instance variables.
try:
    s=read('Horos/Sources/VRView.m')
except (OSError, subprocess.CalledProcessError):
    s=''
swift_method=None
if '- (void) horosAdoptPreviewMapper:(void*) sourceMapper' in s:
    a=s.index('- (void) horosAdoptPreviewMapper:(void*) sourceMapper');b=s.index('\n- (',a+1)
    method=s[a:b].replace('- (void) horosAdoptPreviewMapper:(void*) sourceMapper','- (void)setMapper:(void*) sourceMapper',1)
    method=method.replace('[vtk adoptPreviewMapperOf: sourceMapper]','[self adoptPreviewMapperOf: sourceMapper]')
else:
    subclasses=read('Horos/Sources/VRView+Subclasses.swift')
    a=subclasses.index('    func horosAdoptPreviewMapper(_ source: UnsafeMutableRawPointer?) {')
    swift_method=subclasses[a:subclasses.index('\n    }\n',a)+7]
    if 'horos_vtk.adoptPreviewMapper(of: source)' not in swift_method:
        sys.exit('FAIL: -horosAdoptPreviewMapper: no longer asks the adapter: ' + swift_method)
    method='- (void)setMapper:(void*) sourceMapper { engine = HorosSwiftAdoptPreviewMapper((__bridge void *)self, sourceMapper, engine); }'
pipeline=read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm')
a=pipeline.index('- (BOOL)adoptPreviewMapperOf:(void *)sourceMapper');b=pipeline.index('\n- (',a+1)
adopt=pipeline[a:b].replace('IsiXVTKVolumeViewObjects *o = _o;','Preview *o = self;')
install=root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install/'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)
code=r'''
#import <Cocoa/Cocoa.h>
#include <vtkAutoInit.h>
#include "vtk_pattern_scene.h"
#include "vtkHorosFixedPointVolumeRayCastMapper.h"
#include <vtkVolume.h>
#include <vtkImageData.h>
#include <vtkTrivialProducer.h>
#include <vtkWeakPointer.h>
#include <cassert>
#include <initializer_list>
static bool hook(void *, vtkHorosFixedPointVolumeRayCastMapper *, vtkRenderer *, vtkVolume *) { return false; }
template <typename Body>
static void IsiXVTKVolumeRun(const char *, std::initializer_list<vtkObject *>, Body &&body) { body(); }
@interface Preview:NSObject { @public vtkHorosFixedPointVolumeRayCastMapper *volumeMapper; vtkVolume *volume; int engine; }
- (void)setMapper:(void*)source;
- (BOOL)adoptPreviewMapperOf:(void *)sourceMapper;
@end
extern "C" int HorosSwiftAdoptPreviewMapper(void *preview, void *source, int engine);
@implementation Preview
ADOPT
METHOD
@end
extern "C" bool HorosAdapterAdoptPreviewMapper(void *preview, void *source) { return [(__bridge Preview *)preview adoptPreviewMapperOf: source]; }
int main(){@autoreleasepool {
 auto image=vtkImageData::New();image->SetDimensions(4,4,4);image->AllocateScalars(VTK_UNSIGNED_SHORT,1);
 auto input=vtkTrivialProducer::New();input->SetOutput(image);image->Delete();
 auto main=vtkHorosFixedPointVolumeRayCastMapper::New();main->SetInputConnection(input->GetOutputPort());main->SetSampleDistance(.7);main->SetMinimumImageSampleDistance(1.2);main->SetMaximumImageSampleDistance(2.4);main->SetAutoAdjustSampleDistances(0);main->SetBlendModeToMaximumIntensity();main->SetImageRenderer(hook,nullptr);
 for(int i=0;i<20;i++){
  Preview *a=[Preview new],*b=[Preview new];a->volume=vtkVolume::New();b->volume=vtkVolume::New();
  [a setMapper:main];[b setMapper:main];
  if(a->volumeMapper==main || b->volumeMapper==main || a->volumeMapper==b->volumeMapper){fprintf(stderr,"FAIL: preview shares context-owned mapper\n");return 1;}
  assert(a->volumeMapper->GetInputConnection(0,0)==main->GetInputConnection(0,0));
  assert(a->volumeMapper->GetBlendMode()==main->GetBlendMode());
  assert(a->volumeMapper->GetSampleDistance()==main->GetSampleDistance());
  assert(a->volumeMapper->GetMinimumImageSampleDistance()==main->GetMinimumImageSampleDistance());
  assert(a->volumeMapper->GetMaximumImageSampleDistance()==main->GetMaximumImageSampleDistance());
  assert(a->volumeMapper->GetAutoAdjustSampleDistances()==0);
  if(a->volumeMapper->GetImageRenderer()!=hook || a->engine!=2){fprintf(stderr,"FAIL: the preview does not draw with the view's Metal hook\n");return 1;}
  a->volumeMapper->SetBlendModeToComposite();assert(b->volumeMapper->GetBlendMode()==main->GetBlendMode());
  vtkWeakPointer<vtkVolumeMapper> previous=a->volumeMapper;
  [a setMapper:main];assert(previous==nullptr);assert(a->volume->GetMapper()==a->volumeMapper);
  [a setMapper:a->volumeMapper];assert(a->volume->GetMapper()==a->volumeMapper);
  for(Preview *p in @[a,b]){vtkWeakPointer<vtkVolumeMapper> owned=p->volumeMapper;p->volumeMapper->Delete();p->volume->Delete();assert(owned==nullptr);[p release];}
 }
 main->Delete();input->Delete();puts("PASS: 20 mapper pairs isolate rendering state, share input, preserve sampling, draw with Metal and release ownership");
}}
'''.replace('METHOD',method).replace('ADOPT',adopt)
with tempfile.TemporaryDirectory(prefix='horos-preset-mapper-') as d:
 p=Path(d);(p/'test.mm').write_text(code);(p/'vtk_pattern_scene.h').write_text(vtk_pattern_window.WINDOW+vtk_pattern_window.SCENE)
 # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
 libs = [install / 'wlib' / 'libVTK.a']
 sources=[str(p/'test.mm'),str(root/'Horos/Sources/Adapters/VTK/SceneFactory.cxx'),str(root/'Horos/Sources/Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.cxx'),str(root/'Horos/Sources/Adapters/VTK/vtkHorosFixedPointVolumeRayCastMIPHelper.cxx')]
 if swift_method is None:
  subprocess.run(['xcrun','clang++','-std=c++17','-fsanitize=address','-I'+str(install/'include'),'-I'+str(root/'Horos/Sources/Adapters/VTK'),'-I'+str(root/'Horos/Sources'),*sources,*[str(x) for x in libs],'-lz','-framework','Cocoa','-o',str(p/'test')],check=True)
 else:
  # The Swift method, as an extension of a stand-in preview whose adapter's
  # one call is the Objective-C++ body above.
  (p/'harness.h').write_text('#include <stdbool.h>\nbool HorosAdapterAdoptPreviewMapper(void *preview, void *source);\n')
  (p/'method.swift').write_text('''import Foundation
final class AdapterStandIn {
    let preview: UnsafeMutableRawPointer
    init(_ preview: UnsafeMutableRawPointer) { self.preview = preview }
    func adoptPreviewMapper(of source: UnsafeMutableRawPointer) -> Bool { HorosAdapterAdoptPreviewMapper(preview, source) }
}
final class VRView: NSObject {
    var horos_engine: Int32 = 0
    let horos_vtk: AdapterStandIn
    init(_ preview: UnsafeMutableRawPointer, engine: Int32) { horos_vtk = AdapterStandIn(preview); horos_engine = engine }
}
extension VRView {
METHOD}
@_cdecl("HorosSwiftAdoptPreviewMapper")
public func HorosSwiftAdoptPreviewMapper(_ preview: UnsafeMutableRawPointer, _ source: UnsafeMutableRawPointer?, _ engine: Int32) -> Int32 {
    let view = VRView(preview, engine: engine)
    view.horosAdoptPreviewMapper(source)
    return view.horos_engine
}
'''.replace('METHOD',swift_method))
  subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-import-objc-header',str(p/'harness.h'),'-c',str(p/'method.swift'),'-o',str(p/'method.o')],check=True)
  objects=[]
  for i,source in enumerate(sources):
   objects.append(str(p/('part%d.o'%i)))
   subprocess.run(['xcrun','clang++','-std=c++17','-fsanitize=address','-I'+str(install/'include'),'-I'+str(root/'Horos/Sources/Adapters/VTK'),'-I'+str(root/'Horos/Sources'),'-c',source,'-o',objects[-1]],check=True)
  subprocess.run(['xcrun','swiftc','-sanitize=address',*objects,str(p/'method.o'),*[str(x) for x in libs],'-lz','-lc++','-Xlinker','-framework','-Xlinker','Cocoa','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
