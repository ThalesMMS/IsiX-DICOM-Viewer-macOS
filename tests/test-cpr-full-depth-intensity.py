#!/usr/bin/env python3
"""The CPU projection used by CPR preserves calibrated intensities on every render."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vtk_pattern_window import WINDOW, SCENE, compile

root = Path(__file__).resolve().parents[1]
install = root / ('build/Build/Intermediates.noindex/Horos.build/' +
                  os.environ.get('HOROS_TEST_CONFIGURATION', 'Release') + '/VTK.build/Install')
if not (install / 'wlib/libVTK.a').is_file():
    print('needs the built VTK install:', install, file=sys.stderr)
    sys.exit(2)
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(name):
    path = 'Horos/Sources/' + name
    if revision:
        return subprocess.check_output(['git', 'show', revision + ':' + path]).decode('utf-8')
    return (root / path).read_text()


header = source('vtkHorosFixedPointVolumeRayCastMapper.h')
enable = ('mapper->SetFullDepthCapture(true);' if 'SetFullDepthCapture' in header else
          'for (int i=0;i<32767;++i) mapper->GetScalarOpacityTable(0)[i]=i;')
disable = 'mapper->SetFullDepthCapture(false);' if 'SetFullDepthCapture' in header else ''
code = WINDOW + SCENE + r'''
#include "vtkHorosFixedPointVolumeRayCastMapper.cxx"
#include "vtkHorosFixedPointVolumeRayCastMIPHelper.cxx"
#include <vtkImageData.h>
#include <vtkPiecewiseFunction.h>
#include <vtkColorTransferFunction.h>
#include <vtkVolumeProperty.h>
#include <vtkFixedPointRayCastImage.h>
#include "VRImageImport.h"
#include <cstdio>
#include <cmath>
int main() {
 for (bool linear: {false,true}) {
 for (unsigned short lower: {0,230}) {
 vtkNew<PatternWindow> window; window->SetSize(64,64);
 vtkNew<PatternRenderer> renderer; window->AddRenderer(renderer);
 unsigned short pixels[512];
 // Stored word 1064 corresponds to 40 HU, with an offset of 1024.
 std::fill_n(pixels,512,1064); pixels[0]=lower; pixels[511]=11000;
 vtkNew<HorosVRImageImport> importer;
 importer->SetImportVoidPointer(pixels);
 importer->SetWholeExtent(0,7,0,7,0,7); importer->SetDataExtentToWholeExtent();
 importer->SetDataScalarTypeToUnsignedShort(); importer->SetNumberOfScalarComponents(1);
 importer->Update();
 // VRView updates spacing after the first import; later frames reuse the buffer.
 importer->SetDataSpacing(.5,.5,.5); importer->Update();
 auto image=importer->GetOutput();
 if(image->GetPointData()->GetScalars()->GetNumberOfTuples()!=512){
  std::fprintf(stderr,"FAIL: repeated volume import lost its scalar tuple count\n");return 1;
 }
 vtkNew<vtkHorosFixedPointVolumeRayCastMapper> mapper;
 mapper->SetInputConnection(importer->GetOutputPort()); mapper->SetBlendModeToMaximumIntensity();
 mapper->SetAutoAdjustSampleDistances(0); mapper->SetSampleDistance(0.25);
 mapper->SetMinimumImageSampleDistance(1); mapper->SetMaximumImageSampleDistance(1);
 mapper->SetIntermixIntersectingGeometry(0);
 vtkNew<vtkPiecewiseFunction> opacity; opacity->AddPoint(0,0); opacity->AddPoint(11000,1);
 vtkNew<vtkColorTransferFunction> colour; colour->AddRGBPoint(0,0,0,0); colour->AddRGBPoint(11000,1,1,1);
 vtkNew<vtkVolumeProperty> property; property->SetScalarOpacity(opacity); property->SetColor(colour);
 property->SetInterpolationTypeToNearest();
 if(linear)property->SetInterpolationTypeToLinear();
 vtkNew<vtkVolume> volume; volume->SetMapper(mapper); volume->SetProperty(property);
 renderer->AddVolume(volume); renderer->ResetCamera();
 renderer->GetActiveCamera()->ParallelProjectionOn();
 // Exactly the preparation/readback sequence of the hidden CPR renderer.
 window->Render();
 mapper->PerVolumeInitialization(renderer,volume);
 ENABLE
 for (int pass=0;pass<3;++pass) {
  if(pass==1) mapper->SetSampleDistance(0.5);
  if(pass==2) {colour->AddRGBPoint(4000,.5,.5,.5); importer->Modified();}
  window->Render();
  auto cast=mapper->GetRayCastImage();
  int *memory=cast->GetImageMemorySize(),*size=cast->GetImageInUseSize();
  if(size[0]<=0||size[1]<=0)return 2;
  unsigned short *frame=cast->GetImage();
  int hits=0;
  for(int y=0;y<size[1];++y)for(int x=0;x<size[0];++x) {
   if(x<size[0]*.4||x>size[0]*.6||y<size[1]*.4||y>size[1]*.6)continue;
   unsigned short value=frame[4*(y*memory[0]+x)+3];
   if(!value||value==lower||value==11000)continue;
   double hu=value-1024.;
   if(std::abs(hu-40)>1) {
    std::fprintf(stderr,"FAIL: CPR CPU pass %d maps 40 HU to %.0f HU (word %u)\n",pass,hu,value);
    return 1;
   }
   ++hits;
  }
  if(hits<20){std::fprintf(stderr,"FAIL: no useful projected tissue pixels\n");return 1;}
 }
 DISABLE
 opacity->Modified(); window->Render();
 auto cast=mapper->GetRayCastImage();
 int *memory=cast->GetImageMemorySize(),*size=cast->GetImageInUseSize();
 unsigned short centre=cast->GetImage()[4*((size[1]/2)*memory[0]+size[0]/2)+3];
 if(centre==1064){std::fprintf(stderr,"FAIL: normal projection still uses raw intensity as opacity\n");return 1;}
 }
 }
 std::puts("PASS: CPR CPU projection preserves 40 HU after ray-step and colour-table changes, with shifted lookup ranges; normal opacity is restored");
}
'''.replace('ENABLE', enable).replace('DISABLE', disable)

with tempfile.TemporaryDirectory(prefix='horos-cpr-intensity-') as directory:
    work = Path(directory)
    for name in ('vtkHorosFixedPointVolumeRayCastMapper.h', 'vtkHorosFixedPointVolumeRayCastMapper.cxx',
                 'vtkHorosFixedPointVolumeRayCastMIPHelper.h', 'vtkHorosFixedPointVolumeRayCastMIPHelper.cxx'):
        (work / name).write_text(source(name))
    (work / 'probe.cxx').write_text(code)
    compile(install, root, work / 'probe.cxx', work / 'probe', scene=True)
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0:halt_on_error=1')
    subprocess.run([str(work / 'probe')], env=env, check=True)
