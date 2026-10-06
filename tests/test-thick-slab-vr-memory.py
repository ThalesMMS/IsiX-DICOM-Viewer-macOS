#!/usr/bin/env python3
"""The 2D viewer's volume-rendering slab changes thickness without touching memory it does not own.

ThickSlabVR composes the slab on the CPU when -[DCMPix computeThickSlab] asks:
for measurements, the 8-bit representation and exports; on screen, Metal
composes it. The issue reported heap corruption while the slab's
thickness was dragged. This builds ThickSlabVR.mm with Address Sanitizer and
drives it as DCMPix does - setImageData:::::: once with 100 slices, then, for
each image, setImageSource:: with the slices the slab covers, setWLWW:: and
renderSlab - over thicknesses that grow and shrink, at the first, a middle and
the last image, in both stack directions and both slice orders (modes 4 and 5).
Address Sanitizer stops the probe at the first read or write out of bounds.
The composite of a uniform slab is checked against the opacity it is built from.

`<git revision>` as an optional argument builds ThickSlabVR.mm from that
revision, the negative control: before d0f111c60 the threads' ranges
were not multiples of four and read and wrote up to three pixels past the end
of the buffers.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
install = root / 'build/Build/Intermediates.noindex/Horos.build/Release/VTK.build/Install'
if not (install / 'lib').is_dir():
    print('needs built VTK libraries in', install, file=sys.stderr)
    sys.exit(2)

code = r'''
#import <Cocoa/Cocoa.h>
#import "ThickSlabVR.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
int main(){@autoreleasepool{
 const long width=67,height=45,count=100,frame=width*height;
 std::vector<float> volume(frame*count);
 for(long i=0;i<frame*count;i++)volume[i]=float((i*37)%2000)-1000;
 int thicknesses[]={2,3,5,9,14,20,27,35,44,60,80,99,100,70,40,12,3,2,50,2};
 long positions[]={0,1,50,98,99};
 long renders=0;
 for(int flip=0;flip<2;flip++){
  ThickSlabVR *slab=[[ThickSlabVR alloc] initWithFrame:NSMakeRect(0,0,10,10)];
  [slab setImageData:width :height :100 :0.7f :0.7f :1.5f :flip];
  [slab setCLUT:nil :nil :nil];
  [slab setOpacity:[NSArray array]];
  for(int stack:thicknesses)for(long pixPos:positions)for(int direction=0;direction<2;direction++){
   // -[DCMPix computeThickSlab], modes 4 and 5.
   float *fImage=volume.data()+pixPos*frame;
   long stacksize;
   if(direction){stacksize=pixPos-stack<0?pixPos+1:stack+1;[slab setImageSource:fImage-(stacksize-1)*frame :stacksize];}
   else{stacksize=pixPos+stack<count?stack:count-pixPos;[slab setImageSource:fImage :stacksize];}
   [slab setWLWW:0 :2000];
   unsigned char *rgba=[slab renderSlab];
   assert(rgba);
   for(long i=0;i<frame;i++)assert(rgba[4*i]==255);
   free(rgba);renders++;
  }
  [slab release];
 }
 // A uniform slab: every slice at the top of the window, whose opacity is 1,
 // composes to the colour of that value at full weight.
 std::vector<float> uniform(frame*count,1000.f);
 ThickSlabVR *slab=[[ThickSlabVR alloc] initWithFrame:NSMakeRect(0,0,10,10)];
 [slab setImageData:width :height :100 :1 :1 :1 :YES];
 [slab setCLUT:nil :nil :nil];[slab setOpacity:[NSArray array]];
 [slab setImageSource:uniform.data() :7];[slab setWLWW:0 :2000];
 unsigned char *rgba=[slab renderSlab];
 for(long i=0;i<frame;i++)for(int c=1;c<4;c++)assert(std::abs(int(rgba[4*i+c])-255)<=1);
 free(rgba);[slab release];
 printf("PASS: %ld volume-rendering slabs, thickness 2 to 100 growing and shrinking, at the edges and the middle, both directions and slice orders, clean under Address Sanitizer; a uniform slab composes to its colour\n",renders);
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-thick-slab-vr-') as directory:
    p = Path(directory)
    (p / 'test.mm').write_text(code)
    source = root / 'Horos/Sources/ThickSlabVR.mm'
    if revision:
        source = p / 'ThickSlabVR.mm'
        source.write_bytes(subprocess.check_output(['git', '-C', str(root), 'show', revision + ':Horos/Sources/ThickSlabVR.mm']))
    # VTK as the app links it: the one archive Horos/Scripts/VTK/Make.sh wraps.
    libs = [install / 'wlib' / 'libVTK.a']
    # ThickSlabVR.h relies on the app's prefix header for AppKit.
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fsanitize=address', '-fno-objc-arc', '-w', '-include', 'Cocoa/Cocoa.h',
                    '-I' + str(install / 'include'), '-I' + str(root / 'Horos/Sources'),
                    str(p / 'test.mm'), str(source), *[str(x) for x in libs], '-lz',
                    '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
