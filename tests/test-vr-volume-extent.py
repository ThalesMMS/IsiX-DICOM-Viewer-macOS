#!/usr/bin/env python3
"""Check production VR import extents against real VTK and boundary-marked buffers.

The importers are the VTK adapter's (IsiXVTKVolumePipeline.mm); the view hands
them the series' width, height and number of images."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[1]


def read(path):
    return (subprocess.check_output(['git', 'show', sys.argv[1]+':'+path])
            if len(sys.argv)>1 else (root/path).read_bytes()).decode('latin1')


try:
    view = read('Horos/Sources/VRView.m')
except (OSError, subprocess.CalledProcessError):
    # The class is Swift since (VRView.swift).
    view = ''
preview_objc = '[vtk makePreviewImport: isRGB ? (void*) data : (void*) data8 rgb: isRGB width: [firstObject pwidth] height: [firstObject pheight] depth: (long)[pixList count] error: &vtkError]'
if view:
    calls = [preview_objc]
else:
    # The preset previews' pipeline is Swift (VRView+Subclasses.swift).
    view = read('Horos/Sources/VRView+Subclasses.swift')
    calls = ['try vtk.makePreviewImport(voxels, rgb: isRGB, width: firstObject.pwidth, height: firstObject.pheight,\n'
             '                                      depth: pix.count)']
if '-(short) setPixSource:' in view:
    calls += ['[vtk importVolume: isRGB ? (void*) data : (void*) data8 rgb: isRGB width: [firstObject pwidth] height: [firstObject pheight] depth: [pixList count] error: &vtkError]',
              'width: [blendingFirstObject pwidth] height: [blendingFirstObject pheight] depth: [blendingPixList count]']
else:
    # The volumes are built in Swift (VRView+Volume.swift), an extension of the view.
    view += read('Horos/Sources/VRView+Volume.swift')
    calls += ['let voxels = isRGB ? UnsafeMutableRawPointer(horos_data) : UnsafeMutableRawPointer(horos_data8)',
              'try vtk.importVolume(voxels!, rgb: isRGB, width: Int(firstObject?.pwidth ?? 0), height: Int(firstObject?.pheight ?? 0),\n'
              '                                              depth: horos_pixList?.count ?? 0)',
              'let count = blendingPixList?.count ?? 0\n'
              '            let pheight = Int(blendingFirstObject?.pheight ?? 0), pwidth = Int(blendingFirstObject?.pwidth ?? 0)',
              'rgb: isBlendingRGB, width: pwidth, height: pheight, depth: count,']
for call in calls:
    assert call in view, 'the view no longer hands the importer the series\' size: ' + call
source = read('Horos/Sources/Adapters/VTK/IsiXVTKVolumePipeline.mm')
expressions = re.findall(r'o->(?:reader|blendingReader)->SetWholeExtent\(([^;]+)\);', source)
# The volume, the fused volume, the RGB volume and the preset preview's volume.
assert len(expressions) in (3, 4), expressions
for old, new in [('[firstObject pwidth]', 'width'), ('[firstObject pheight]', 'height'),
                 ('[blendingFirstObject pwidth]', 'width'), ('[blendingFirstObject pheight]', 'height'),
                 ('[pixList count]', 'depth'), ('[blendingPixList count]', 'depth')]:
    expressions = [s.replace(old, new) for s in expressions]
install = root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install/'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)
code = r'''
#include <vtkImageImport.h>
#include <vtkImageData.h>
#include <vector>
#include <cmath>
#include <cstdio>
int main() {
 int count=0;
 for(int variant=0;variant<VARIANTS;variant++)for(int depth: {16,3,2,1})for(double spacing: {1.,2.5}) {
  const int width=4,height=3;
  for(int components: {1,4}) {
   std::vector<unsigned short> scalar(width*height*depth);
   std::vector<unsigned char> rgb(width*height*depth*4);
   for(int z=0;z<depth;z++)for(int y=0;y<height;y++)for(int x=0;x<width;x++) {
    int offset=(z*height+y)*width+x;scalar[offset]=1000*z+10*y+x;
    for(int c=0;c<4;c++)rgb[4*offset+c]=10*z+c;
   }
   auto reader=vtkImageImport::New();
   if(components==1){reader->SetDataScalarTypeToUnsignedShort();reader->SetImportVoidPointer(scalar.data());}
   else {reader->SetDataScalarTypeToUnsignedChar();reader->SetImportVoidPointer(rgb.data());}
   reader->SetNumberOfScalarComponents(components);
   switch(variant) { CASES }
   reader->SetDataExtentToWholeExtent();reader->SetDataSpacing(.7,1.2,spacing);reader->Update();
   auto image=reader->GetOutput();int extent[6];image->GetExtent(extent);
   if(extent[4]!=0 || extent[5]!=depth-1) {
    std::fprintf(stderr,"FAIL: path %d depth %d imports Z [%d,%d], expected [0,%d]\n",variant,depth,extent[4],extent[5],depth-1);return 1;
   }
   double bounds[6];image->GetBounds(bounds);
   if(std::abs(bounds[4])>1e-12 || std::abs(bounds[5]-(depth-1)*spacing)>1e-12)return 2;
   for(int z=0;z<depth;z++)for(int y=0;y<height;y++)for(int x=0;x<width;x++)for(int c=0;c<components;c++) {
    double expected=components==1?1000*z+10*y+x:10*z+c;
    if(image->GetScalarComponentAsDouble(x,y,z,c)!=expected)return 3;
   }
   reader->Delete();count++;
  }
 }
 std::printf("PASS: %d VTK imports preserve all samples, boundary slices and physical Z bounds\n",count);
}
'''.replace('VARIANTS', str(len(expressions))).replace('CASES', '\n'.join(f'case {i}: reader->SetWholeExtent({e}); break;' for i,e in enumerate(expressions)))
with tempfile.TemporaryDirectory(prefix='horos-vr-extent-') as d:
    p=Path(d); (p/'test.cxx').write_text(code)
    # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
    libs = [install / 'wlib' / 'libVTK.a']
    subprocess.run(['xcrun','clang++','-std=c++17','-fsanitize=address','-I'+str(install/'include'),str(p/'test.cxx'),*[str(x) for x in libs],'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
