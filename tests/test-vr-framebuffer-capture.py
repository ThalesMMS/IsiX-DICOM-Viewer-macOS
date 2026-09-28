#!/usr/bin/env python3
"""Verify VR export readback covers the full drawable with correct orientation."""
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
# Whichever configuration has been built; Release first, since that is what a
# distribution build produces.
install=next((c for c in (root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install',
                          root/'build/Build/Intermediates.noindex/Horos.build/Debug/VTK.build/Install')
              if (c/'include').is_dir()),
             root/'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install')
if not (install/'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)
code=r'''
#include "vtk_pattern_window.h"
#include "VRFramebufferCapture.h"
#include <cassert>
#include <cstdio>
int main(){
 static const unsigned char red[3]={255,0,0},green[3]={0,255,0},blue[3]={0,0,255},yellow[3]={255,255,0};
 int dimensions[][2]={{101,67},{120,80},{3,2},{1,1}};
 for(auto &d:dimensions)for(int scale=1;scale<=2;scale++){
  int w=d[0]*scale,h=d[1]*scale;
  auto window=PatternWindow::New();window->Allocate(w,h);
  // Rows from the bottom, as VTK reads them: blue, the left half red, the
  // upper right quarter green. The right buffer is yellow.
  window->Fill(0,0,0,w,h,blue);window->Fill(0,0,0,w/2,h,red);window->Fill(0,w/2,h/2,w,h,green);
  window->Fill(1,0,0,w,h,yellow);
  long width=-1,height=-1;auto pixels=HorosCopyVRFramebuffer(window,&width,&height);
  assert(pixels && width==w && height==h);
  for(int y=0;y<h;y++)for(int x=0;x<w;x++){
   int glY=h-y-1;int channel=x<w/2?0:(glY>=h/2?1:2);
   for(int c=0;c<3;c++)if(pixels[3*(y*w+x)+c]!=(c==channel?255:0)){fprintf(stderr,"FAIL size %dx%d at %d,%d channel %d got %d expected %d\n",w,h,x,y,c,pixels[3*(y*w+x)+c],c==channel?255:0);return 1;}
  }
  free(pixels);
  pixels=HorosCopyVRFramebuffer(window,&width,&height,1);
  assert(pixels && width==w && height==h);
  for(long i=0;i<long(w)*h;i++)if(pixels[3*i]!=255||pixels[3*i+1]!=255||pixels[3*i+2]!=0){fprintf(stderr,"FAIL size %dx%d: the right buffer is not the right eye\n",w,h);return 1;}
  free(pixels);window->Delete();
 }
 long w=1,h=1;assert(!HorosCopyVRFramebuffer(nullptr,&w,&h) && w==0 && h==0);
 puts("PASS: full top-down RGB capture across eight target sizes including odd widths, and the right buffer; every pixel and declared dimension verified");
}
'''
sys.path.insert(0,str(root/'tests'))
import vtk_pattern_window
with tempfile.TemporaryDirectory(prefix='horos-framebuffer-capture-') as directory:
    p=Path(directory);(p/'vtk_pattern_window.h').write_text(vtk_pattern_window.WINDOW);(p/'test.mm').write_text(code)
    vtk_pattern_window.compile(install,root,p/'test.mm',p/'test')
    subprocess.run([str(p/'test')],check=True)
