#!/usr/bin/env python3
"""Verify VR export readback covers the full drawable with correct orientation,
and that the DICOM export keeps every row of it (#1026).

The second part runs the statements of -[DICOMExport writeDCMFile:] that come
between the pixels and the Rows and Pixel Data it writes, then writes and reads
back through DCMTK as the export does, for the capture sizes of the first part:
odd and even widths and heights, at 1x and 2x, 8-bit RGB (the capture and the
full-depth composite) and 8-bit and 16-bit grey. Rows, Columns and every pixel
must come back. `<git revision>` as an optional argument reads DICOMExport.mm
from that revision, the negative control: before #1026 an odd width by an odd
height lost its last row.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
revision=sys.argv[1] if len(sys.argv)>1 else None
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
 int dimensions[][2]={{101,67},{120,80},{3,2},{1,1},{685,465},{685,464}};
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
 puts("PASS: full top-down RGB capture across twelve target sizes including odd widths and heights, and the right buffer; every pixel and declared dimension verified");
}
'''
sys.path.insert(0,str(root/'tests'))
import vtk_pattern_window
with tempfile.TemporaryDirectory(prefix='horos-framebuffer-capture-') as directory:
    p=Path(directory);(p/'vtk_pattern_window.h').write_text(vtk_pattern_window.WINDOW);(p/'test.mm').write_text(code)
    vtk_pattern_window.compile(install,root,p/'test.mm',p/'test')
    subprocess.run([str(p/'test')],check=True)


# ------------------------------------------------ the DICOM export of a capture (#1026)
import private_tmpdir  # noqa: E402,F401  - its own TMPDIR for the tools it runs (#803)
from dcmtk_build import dcmtk_flags  # noqa: E402

exporter=(subprocess.check_output(['git','-C',str(root),'show',revision+':Horos/Sources/DICOMExport.mm']) if revision
          else (root/'Horos/Sources/DICOMExport.mm').read_bytes()).decode('latin1')
# In -writeDCMFile:, what comes after the pixels are final (the byte swap of a
# big-endian Mac) and before the tags that describe them.
match=re.search(r'InverseShorts\([^\n]*\n\s*\}\s*\n\s*#endif\s*\n(.*?)\n\s*int highBit;',exporter,re.S)
if not match:
    print('FAIL: -[DICOMExport writeDCMFile:] no longer has the byte swap followed by int highBit;', file=sys.stderr)
    sys.exit(1)
rule=match.group(1)
export=r"""
#import <Foundation/Foundation.h>
#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmdata/dctk.h"
#include <cstdio>
#include <vector>
// The statements of -writeDCMFile: between the final pixels and their tags.
static void exportRule(long &height, long &width, long &spp, long &bps)
{
@@RULE@@
}
static unsigned char sample(long x, long y, long c) { return (unsigned char)(x * 7 + y * 13 + c * 101 + (x * y) % 5); }
int main(int argc, char **argv)
{
 int failures = 0;
 long dimensions[][2] = {{101,67},{120,80},{3,2},{1,1},{685,465},{685,464}};
 struct { long spp, bps; const char *what; } kinds[] = {{3,8,"8-bit RGB"},{1,8,"8-bit grey"},{1,16,"16-bit grey"}};
 for (auto &d : dimensions) for (long scale = 1; scale <= 2; scale++) for (auto &k : kinds)
 {
  long width = d[0] * scale, height = d[1] * scale, spp = k.spp, bps = k.bps;
  const long w = width, h = height, bytes = w * h * spp * bps / 8;
  std::vector<unsigned char> pixels(bytes);
  for (long y = 0; y < h; y++) for (long x = 0; x < w; x++) for (long c = 0; c < spp * bps / 8; c++)
   pixels[(y * w + x) * spp * bps / 8 + c] = sample(x, y, c);
  exportRule(height, width, spp, bps);
  DcmFileFormat file;
  DcmDataset *dataset = file.getDataset();
  dataset->putAndInsertString(DCM_SOPClassUID, UID_SecondaryCaptureImageStorage);
  dataset->putAndInsertString(DCM_SOPInstanceUID, "1.2.826.0.1.3680043.10.1026.1");
  dataset->putAndInsertUint16(DCM_SamplesPerPixel, spp);
  dataset->putAndInsertString(DCM_PhotometricInterpretation, spp == 3 ? "RGB" : "MONOCHROME2");
  if (spp == 3) dataset->putAndInsertUint16(DCM_PlanarConfiguration, 0);
  dataset->putAndInsertUint16(DCM_BitsAllocated, bps);
  dataset->putAndInsertUint16(DCM_BitsStored, bps);
  dataset->putAndInsertUint16(DCM_HighBit, bps - 1);
  dataset->putAndInsertUint16(DCM_PixelRepresentation, 0);
  // As -writeDCMFile: writes them: Rows and Columns from its height and width, the pixels by their size.
  dataset->putAndInsertString(DCM_Rows, [[NSString stringWithFormat: @"%d", (int) height] UTF8String]);
  dataset->putAndInsertString(DCM_Columns, [[NSString stringWithFormat: @"%d", (int) width] UTF8String]);
  if (bps == 16)
   dataset->putAndInsertUint16Array(DCM_PixelData, (const Uint16 *) pixels.data(), height * width * spp);
  else
   dataset->putAndInsertUint8Array(DCM_PixelData, pixels.data(), height * width * spp);
  NSString *path = [NSString stringWithFormat: @"%s/%ldx%ld-%ld-%ld.dcm", argv[1], w, h, spp, bps];
  if (file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit).bad())
  { fprintf(stderr, "FAIL %ldx%ld %s: not written\n", w, h, k.what); failures++; continue; }
  DcmFileFormat read;
  Uint16 rows = 0, columns = 0;
  const Uint8 *stored = nullptr;
  unsigned long count = 0;
  DcmElement *element = nullptr;
  if (read.loadFile(path.fileSystemRepresentation).bad() ||
      read.getDataset()->findAndGetUint16(DCM_Rows, rows).bad() ||
      read.getDataset()->findAndGetUint16(DCM_Columns, columns).bad() ||
      read.getDataset()->findAndGetElement(DCM_PixelData, element).bad())
  { fprintf(stderr, "FAIL %ldx%ld %s: not read back\n", w, h, k.what); failures++; continue; }
  if (bps == 16) { const Uint16 *words = nullptr; element->getUint16Array(OFconst_cast(Uint16 *&, words)); stored = (const Uint8 *) words; }
  else element->getUint8Array(OFconst_cast(Uint8 *&, stored));
  count = element->getLength();
  if (rows != h || columns != w)
  { fprintf(stderr, "FAIL %ldx%ld (scale %ld) %s: the file is %ux%u\n", w, h, scale, k.what, columns, rows); failures++; continue; }
  if (count % 2 != 0 || (long) count < bytes || (long) count > bytes + 1 || !stored || memcmp(stored, pixels.data(), bytes) != 0)
  { fprintf(stderr, "FAIL %ldx%ld %s: %lu bytes of pixel data, not the %ld of the capture padded to even\n", w, h, k.what, count, bytes); failures++; continue; }
 }
 if (failures) return 1;
 puts("PASS: the DICOM export keeps every row and column of the capture, odd and even, at 1x and 2x, RGB and grey, and DCMTK pads the odd 8-bit pixel data to even");
 return 0;
}
""".replace('@@RULE@@', rule)
flags=dcmtk_flags()
with tempfile.TemporaryDirectory(prefix='horos-vr-export-rows-') as directory:
    p=Path(directory);(p/'export.mm').write_text(export)
    subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-Wno-unused-variable',str(p/'export.mm'),*flags,
                    '-framework','Foundation','-o',str(p/'export')],check=True)
    subprocess.run([str(p/'export'),str(p)],check=True)
