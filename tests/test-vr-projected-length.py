#!/usr/bin/env python3
"""Validate production length math using real VTK projection and known phantom spacing.

The view reads the line's points and turns them into world points through the
VTK adapter; the adapter's calls run here in place of the view's messages. The
length is Swift (-computeLength in VRView+Measure.swift): its block is compiled
in Swift over a stand-in of the adapter whose two calls run the adapter's
bodies on real VTK objects."""
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
import re
import vtk_pattern_window
measure=(root/'Horos/Sources/VRView+Measure.swift').read_text()
a=measure.index('            var point1 = [Double](repeating: 0, count: 4)',measure.index('func computeLength()'))
b=measure.index('\n',measure.index('            let length = ',a))+1
swift_block=measure[a:b]
camera_adapter=(root/'Horos/Sources/Adapters/VTK/IsiXVTKVolumeCamera.mm').read_bytes().decode('latin1')
actors_adapter=(root/'Horos/Sources/Adapters/VTK/IsiXVTKVolumeActors.mm').read_bytes().decode('latin1')
def adapter_body(source, signature, opening):
    start=source.index(opening, source.index(signature))+len(opening)
    return source[start:source.index('});',start)]
world_body=adapter_body(camera_adapter,'- (void)worldPointOfDisplayX:(double)x y:(double)y z:(double)z into:(double *)world','ISIX_RENDERER("displayToWorld", {')
point_body=adapter_body(actors_adapter,'- (void)getActiveLinePoint:(long)index into:(double *)point','[&] {').replace('data->GetPoints()','pts')
calls=set(re.findall(r'vtk\.(\w+)\(',swift_block))
if calls-{'getActiveLinePoint','worldPoint'}:
    sys.exit('FAIL: computeLength sends the adapter a message this test does not model: ' + swift_block)
install=root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install/'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)
code=r'''
#include <vtkPoints.h>
#include <vtkRenderer.h>
#include <vtkRenderWindow.h>
#include <vtkCamera.h>
#include "vtk_pattern_scene.h"
#include <cmath>
#include <cstdio>
static vtkRenderer *gRenderer; static vtkPoints *gPoints;
extern "C" void hGetActiveLinePoint(long index,double *point) { vtkPoints *pts=gPoints; POINT_BODY }
extern "C" void hWorldPoint(double x,double y,double z,double *world) { vtkRenderer *aRenderer=gRenderer; WORLD_BODY }
extern "C" double swiftMeasuredCM(double factor);
double measuredCM(vtkRenderer *aRenderer,vtkPoints *pts,double factor) {
 gRenderer=aRenderer; gPoints=pts;
 return swiftMeasuredCM(factor);
}
int main(){
 auto window=vtkRenderWindow::New();auto renderer=vtkRenderer::New();window->AddRenderer(renderer);
 auto camera=vtkCamera::New();renderer->SetActiveCamera(camera);camera->SetParallelProjection(true);camera->SetClippingRange(.01,10000);
 auto points=vtkPoints::New();points->SetDataTypeToDouble();points->SetNumberOfPoints(2);
 struct Fixture {double spacing[3];double delta[3];};
 Fixture fixtures[]={{{1,1,1},{31,0,0}},{{1,1,1},{12,16,0}},{{1,1,1},{.3,.4,0}},{{.7,1.2,2.5},{20,10,4}}};
 int sizes[][2]={{800,600},{1695,938},{512,512},{2100,400}};int count=0;
 for(auto fixture:fixtures)for(int axis=0;axis<3;axis++)for(int backing=1;backing<=2;backing++)for(auto size:sizes)for(double sampling:{1.,2.}) {
  double factor=sampling/fixture.spacing[0];window->SetSize(size[0]*backing,size[1]*backing);
  double position[3]={0,0,0};position[axis]=100*factor;camera->SetPosition(position);camera->SetFocalPoint(0,0,0);
  camera->SetViewUp(0,axis==2?1:0,axis==2?0:1);camera->SetParallelScale(40*factor);
  double expectedSquared=0;
  for(int endpoint=0;endpoint<2;endpoint++) {
   double world[3];for(int j=0;j<3;j++)world[j]=endpoint*fixture.delta[j]*fixture.spacing[j]*factor;
   renderer->SetWorldPoint(world[0],world[1],world[2],1);renderer->WorldToDisplay();
   double *display=renderer->GetDisplayPoint();points->SetPoint(endpoint,display[0],display[1],0);
  }
  for(int j=0;j<3;j++)if(j!=axis)expectedSquared+=std::pow(fixture.delta[j]*fixture.spacing[j],2);
  double expected=std::sqrt(expectedSquared)/10;double actual=measuredCM(renderer,points,factor);
  if(!std::isfinite(actual)||std::abs(actual-expected)>1e-8){std::fprintf(stderr,"FAIL: case %d expected %.12g cm, got %.12g cm\n",count,expected,actual);return 1;}
  count++;
 }
 points->Delete();camera->Delete();renderer->Delete();window->Delete();
 std::printf("PASS: %d real VTK orthographic cases: isotropic/anisotropic spacing, three camera axes, submillimeter/diagonal lengths, viewport/backing/sampling changes\n",count);
}
'''.replace('POINT_BODY',point_body).replace('WORLD_BODY',world_body)
HEADER='''void hGetActiveLinePoint(long index, double *point);
void hWorldPoint(double x, double y, double z, double *world);
'''
SWIFT='''import Foundation
/// The adapter's two calls -computeLength makes, on the test's VTK objects.
final class Adapter {
    func getActiveLinePoint(_ index: Int, into point: UnsafeMutablePointer<Double>) { hGetActiveLinePoint(index, point) }
    func worldPoint(ofDisplayX x: Double, y: Double, z: Double, into world: UnsafeMutablePointer<Double>) { hWorldPoint(x, y, z, world) }
}
@_cdecl("swiftMeasuredCM") public func swiftMeasuredCM(_ factor: Double) -> Double {
    let vtk = Adapter()
BLOCK
    return length / (10.0 * factor)
}
'''.replace('BLOCK',swift_block)
with tempfile.TemporaryDirectory(prefix='horos-vr-length-') as d:
    p=Path(d);(p/'test.cxx').write_text(code);(p/'vtk_pattern_scene.h').write_text(vtk_pattern_window.WINDOW+vtk_pattern_window.SCENE)
    # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
    libs = [install / 'wlib' / 'libVTK.a']
    (p/'harness.h').write_text(HEADER);(p/'length.swift').write_text(SWIFT)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-import-objc-header',str(p/'harness.h'),'-c',str(p/'length.swift'),'-o',str(p/'length.o')],check=True)
    subprocess.run(['xcrun','clang++','-std=c++17','-I'+str(install/'include'),'-c',str(p/'test.cxx'),'-o',str(p/'test.o')],check=True)
    subprocess.run(['xcrun','clang++','-std=c++17','-I'+str(install/'include'),'-c',str(root/'Horos/Sources/Adapters/VTK/SceneFactory.cxx'),'-o',str(p/'scene.o')],check=True)
    subprocess.run(['xcrun','swiftc',str(p/'test.o'),str(p/'scene.o'),str(p/'length.o'),*[str(x) for x in libs],'-lz','-lc++','-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
