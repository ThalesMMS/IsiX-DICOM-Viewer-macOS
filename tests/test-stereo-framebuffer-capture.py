#!/usr/bin/env python3
"""Verify the stereo readback covers both drawables and keeps the eyes apart.

A stereo export reads one VTK window per eye and lays them side by side. Sized
from the view's bounds it read the lower left quarter of each Retina drawable;
sized from the windows it has to cover both of them, put the left eye on the
left, keep the halves the same width, and come out top-down.
"""
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
if not (install/'include').is_dir():
    print('needs built VTK libraries in %s' % install, file=sys.stderr)
    raise SystemExit(2)
code=r'''
#include "vtk_pattern_window.h"
#include "VRFramebufferCapture.h"
#include <cassert>
#include <cstdio>
// Each eye is painted its own colour and then has its lower left quadrant -
// in VTK's bottom-up frame - painted a second one, so a half that is flipped,
// cropped from the wrong corner or taken from the other window shows up as a
// wrong pixel rather than as a plausible image.
static const unsigned char kEyeColour[2][2][3]={{{255,0,0},{0,255,0}},{{0,0,255},{255,255,0}}};
static PatternWindow *paint(int w,int h,int eye){
 auto window=PatternWindow::New();window->Allocate(w,h);
 window->Fill(0,0,0,w,h,kEyeColour[eye][0]);window->Fill(0,0,0,w/2,h/2,kEyeColour[eye][1]);
 return window;
}
int main(){
 // Equal eyes at 1x and 2x, an odd width, and two mismatched pairs: the
 // narrower and the shorter window has to govern both halves.
 int cases[][4]={{101,67,101,67},{202,134,202,134},{120,80,120,80},{3,2,3,2},
                 {100,60,90,60},{90,60,100,60},{100,60,100,50}};
 for(auto &c:cases){
  auto left=paint(c[0],c[1],0);
  auto right=paint(c[2],c[3],1);
  long width=-1,height=-1;
  auto pixels=HorosCopyVRStereoFramebuffer(left,right,&width,&height);
  const int eyeWidth=c[0]<c[2]?c[0]:c[2],eyeHeight=c[1]<c[3]?c[1]:c[3];
  if(!pixels||width!=2*eyeWidth||height!=eyeHeight){
   fprintf(stderr,"FAIL %dx%d + %dx%d gave %ld x %ld\n",c[0],c[1],c[2],c[3],width,height);return 1;}
  for(long y=0;y<height;y++)for(long x=0;x<width;x++){
   const int eye=x<eyeWidth?0:1;
   const int sourceWidth=eye?c[2]:c[0],sourceHeight=eye?c[3]:c[1];
   const long ex=eye?x-eyeWidth:x;
   // The readback is top-down; the paint above is in VTK's bottom-up frame.
   const long glY=sourceHeight-1-y;
   const bool quadrant=ex<sourceWidth/2&&glY<sourceHeight/2;
   const unsigned char *want=kEyeColour[eye][quadrant?1:0];
   for(int channel=0;channel<3;channel++)
    if(pixels[3*(y*width+x)+channel]!=want[channel]){
     fprintf(stderr,"FAIL %dx%d + %dx%d at %ld,%ld channel %d got %d expected %d\n",
             c[0],c[1],c[2],c[3],x,y,channel,pixels[3*(y*width+x)+channel],want[channel]);return 1;}
  }
  free(pixels);
  left->Delete();right->Delete();
 }
 // A missing window is not half an image.
 auto only=paint(40,30,0);
 long w=1,h=1;assert(!HorosCopyVRStereoFramebuffer(only,nullptr,&w,&h)&&w==0&&h==0);
 w=1;h=1;assert(!HorosCopyVRStereoFramebuffer(nullptr,only,&w,&h)&&w==0&&h==0);
 w=1;h=1;assert(!HorosCopyVRStereoFramebuffer(nullptr,nullptr,&w,&h)&&w==0&&h==0);
 only->Delete();
 puts("PASS: side-by-side stereo capture across seven pairs including 2x, an odd width and mismatched eyes; every pixel and declared dimension verified");
}
'''
sys.path.insert(0,str(root/'tests'))
import vtk_pattern_window
with tempfile.TemporaryDirectory(prefix='horos-stereo-capture-') as directory:
    p=Path(directory);(p/'vtk_pattern_window.h').write_text(vtk_pattern_window.WINDOW);(p/'test.mm').write_text(code)
    vtk_pattern_window.compile(install,root,p/'test.mm',p/'test')
    subprocess.run([str(p/'test')],check=True)
