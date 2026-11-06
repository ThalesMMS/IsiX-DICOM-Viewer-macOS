#!/usr/bin/env python3
"""Exercise production drag updates with the locally built VTK point arrays.

The view moves the line's last point through the VTK adapter
(IsiXVTKVolumeActors.mm), whose update runs here."""
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
def read(path):
    return (subprocess.check_output(['git','show',sys.argv[1]+':'+path]) if len(sys.argv)>1 else (root/path).read_bytes()).decode('latin1')
try:
    view=read('Horos/Sources/VRView.m')
except (OSError, subprocess.CalledProcessError):
    # The class is Swift since (VRView.swift): the drag is read below.
    view=''
if '- (void)mouseDragged:' in view:
    drag=view[view.index('- (void)mouseDragged:'):]
    drag=drag[:drag.index('\n}\n')]
    moves='[vtk moveLastActiveLinePointX: tempPoint[0] y: tempPoint[ 1]];'
else:
    # The drag is Swift (VRView+Mouse.swift), an extension of the view.
    mouse=read('Horos/Sources/VRView+Mouse.swift')
    drag=mouse[mouse.index('public override func mouseDragged(with theEvent: NSEvent)'):]
    drag=drag[:drag.index('\n    }\n')]
    moves='vtk.moveLastActiveLinePointX(tempPoint[0], y: tempPoint[1])'
if moves not in drag:
    print('FAIL: the drag no longer moves the line\'s last point through the adapter', file=sys.stderr)
    sys.exit(1)
source=read('Horos/Sources/Adapters/VTK/IsiXVTKVolumeActors.mm')
a=source.index('[&] {',source.index('- (void)moveLastActiveLinePointX:(double)x y:(double)y'))+len('[&] {')
b=source.index('    });',a)
block=source[a:b]
cell=source[source.index('static vtkCellArray *IsiXVTKClosedCell(vtkPoints *pts)'):source.index('static void IsiXVTKEmptyPolyData')]
install=root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install/'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)
code=r'''
#include <vtkPoints.h>
#include <vtkPolyData.h>
#include <vtkCellArray.h>
#include <vtkDataArray.h>
#include <cassert>
#include <cstdio>
CELL
void update(vtkPolyData *data,double *tempPoint) {
 double x=tempPoint[0],y=tempPoint[1];
 BLOCK
}
int main(){
 auto data=vtkPolyData::New();auto pts=vtkPoints::New();
 pts->InsertNextPoint(0,0,0);pts->InsertNextPoint(0,0,0);data->SetPoints(pts);pts->Delete();
 for(int i=1;i<=20;i++){
  auto previous=pts->GetData()->GetMTime();
  double target[3]={double(20*i),double(10*i),0};update(data,target);
  if(pts->GetData()->GetMTime()<=previous){std::fprintf(stderr,"FAIL: production drag did not invalidate point array at step %d\n",i);return 1;}
  double p[3];pts->GetPoint(1,p);assert(p[0]==target[0] && p[1]==target[1]);
 }
 data->Delete();std::puts("PASS: 20 production drag updates invalidate real VTK point buffers and retain endpoint coordinates");
}
'''.replace('BLOCK',block).replace('CELL',cell)
with tempfile.TemporaryDirectory(prefix='horos-vr-points-') as d:
    p=Path(d);(p/'test.cxx').write_text(code)
    # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
    libs = [install / 'wlib' / 'libVTK.a']
    subprocess.run(['xcrun','clang++','-std=c++17','-I'+str(install/'include'),str(p/'test.cxx'),*[str(x) for x in libs],'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
