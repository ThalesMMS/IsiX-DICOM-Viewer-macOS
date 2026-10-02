#!/usr/bin/env python3
"""Read synthetic A111 presentation inputs, uploaded textures and native output.

All interaction happens through the UI. LLDB reads the uploaded shared Metal
textures and production capture output without driving UI. Captures remain local.
"""
import argparse
import json
import hashlib
from pathlib import Path
import re
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('label')
parser.add_argument('--pid',required=True,type=int)
parser.add_argument('--title-prefix',required=True,
                    choices=('A111 NM low contrast','A111 PT low contrast','Fusion CT Primary','Fusion PT Secondary'),
                    help='synthetic series-name prefix, independent of the displayed window title')
parser.add_argument('--prepare-only', action='store_true', help='write commands without attaching or collecting evidence')
parser.add_argument('--bundle-id', default='thalesmms.isis.workstation.planar-performance', help='explicit isolated host identifier')
parser.add_argument('--output',required=True,type=Path)
args = parser.parse_args()
if args.pid <= 0 or not re.fullmatch('[a-z0-9-]+',args.label):
    parser.error('Use a positive PID and lowercase snapshot label')
args.output.mkdir(parents=True,exist_ok=True)
prefix = (args.output/args.label).resolve()
if prefix.with_suffix('.json').exists():
    parser.error('Capture already exists; choose a new label to preserve evidence')
staged = prefix.with_suffix('.'+uuid.uuid4().hex+'.partial')
expression = r'''
id a111Owner=nil; int a111Matches=0;
for (id candidate in (NSArray*)(id)[(id)objc_getClass("ViewerController") get2DViewers]) {
 NSString *a111SeriesName=(id)[(NSObject*)candidate valueForKeyPath:@"currentSeries.name"];
 if ([a111SeriesName hasPrefix:TITLE]) { a111Owner=candidate; a111Matches++; }
}
id a111Main=(id)[a111Owner imageView]; id a111Blend=(id)[a111Main blendingView];
NSArray *a111Views=a111Blend ? @[a111Main,a111Blend] : (a111Main ? @[a111Main] : @[]);
BOOL a111Synthetic=a111Matches==1 && [NSThread isMainThread] && [[NSBundle mainBundle].bundleIdentifier isEqual:BUNDLE];
for (id a111View in a111Views) {
 id a111Vc=(id)[a111View windowController];
 NSString *a111Patient=(id)[(NSObject*)a111Vc valueForKeyPath:@"currentStudy.patientID"];
 if (![@[@"QA-A111-ONLY",@"LOCAL-FUSION-CT-PT"] containsObject:a111Patient]) a111Synthetic=NO;
}
if (a111Synthetic) {
 NSRect a111Bounds=[(NSView*)a111Main bounds];
 NSRect a111Backing=[(NSView*)a111Main convertRectToBacking:a111Bounds];
 NSMutableDictionary *a111State=[NSMutableDictionary dictionaryWithDictionary:@{
  @"viewSize":@[@(a111Backing.size.width),@(a111Backing.size.height)],
  @"viewPointSize":@[@(a111Bounds.size.width),@(a111Bounds.size.height)],
  @"metalEnabled":@((BOOL)[a111Owner horosPlanarMetalEnabled]),
  @"fallback":(id)[a111Main horosPlanarFallbackReason] ?: @"",
  @"blendingFactor":[(NSObject*)a111Main valueForKey:@"blendingFactor"],
  @"blendingMode":[(NSObject*)a111Main valueForKey:@"blendingMode"],
  @"blendingClutMode":[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] ?: @"",
  @"applicationActive":@([(NSApplication*)NSApp isActive]),
  @"keyWindow":[(NSApplication*)NSApp keyWindow].title ?: @""
 }];
 NSMutableArray *a111Layers=[NSMutableArray array];
 for (NSUInteger a111Index=0;a111Index<a111Views.count;a111Index++) {
  id a111View=a111Views[a111Index]; id a111Pix=(id)[a111View curDCM];
  id a111Vc=(id)[a111View windowController];
  NSUInteger a111W=(NSUInteger)[[(NSObject*)a111Pix valueForKey:@"pwidth"] unsignedIntegerValue];
  NSUInteger a111H=(NSUInteger)[[(NSObject*)a111Pix valueForKey:@"pheight"] unsignedIntegerValue];
  NSString *a111File=[NSString stringWithFormat:@"%@-layer-%lu",PREFIX,(unsigned long)a111Index];
  NSMutableDictionary *a111Layer=[NSMutableDictionary dictionaryWithDictionary:@{
   @"width":@(a111W),@"height":@(a111H),@"modality":[(NSObject*)a111Pix valueForKey:@"modalityString"],
   @"patient":[(NSObject*)a111Vc valueForKeyPath:@"currentStudy.patientID"],
   @"series":[(NSObject*)a111Vc valueForKeyPath:@"currentSeries.seriesInstanceUID"],
   @"level":[(NSObject*)a111View valueForKey:@"curWL"],@"widthWindow":[(NSObject*)a111View valueForKey:@"curWW"],
   @"hasTransferFunction":@((void*)[a111Pix transferFunctionPtr]!=NULL),
   @"hasSubtraction":@((void*)[a111Pix subtractedfImage]!=NULL),
   @"hasFilter":@((BOOL)[a111Pix horosPlanarHasPresentationFilter]),
   @"softwareInterpolation":@((BOOL)[a111View softwareInterpolation]),
   @"prefix":a111File.lastPathComponent
  }];
  for(NSString *a111Key in @[@"scaleValue",@"rotation",@"xFlipped",@"yFlipped",@"curImage"])
   a111Layer[a111Key]=[(NSObject*)a111View valueForKey:a111Key];
  for(NSString *a111Key in @[@"stackMode",@"stack",@"stackDirection",@"shutterEnabled",@"thickSlabVRActivated",@"isRGB"])
   a111Layer[a111Key]=[(NSObject*)a111Pix valueForKey:a111Key];
  NSRect a111Local=[(NSView*)a111View bounds];
  NSMutableArray *a111Transform=[NSMutableArray array];
  for (int corner=0;corner<3;corner++) {
   NSPoint point={a111Local.size.width/2+(corner==1 ? .5 : -.5)*a111Bounds.size.width,
                  a111Local.size.height/2+(corner==2 ? -.5 : .5)*a111Bounds.size.height};
   NSPoint mapped=(NSPoint)[a111View ConvertFromNSView2GL:point];
   [a111Transform addObject:@(mapped.x)];[a111Transform addObject:@(mapped.y)];
  }
  a111Layer[@"screenToPixel"]=a111Transform;
  NSRect a111Shutter=(NSRect)[a111Pix shutterRect];
  a111Layer[@"shutterRect"]=@[@(a111Shutter.origin.x),@(a111Shutter.origin.y),@(a111Shutter.size.width),@(a111Shutter.size.height)];
  if ((BOOL)[a111Pix horosPlanarHasPresentationFilter]) {
   NSUInteger n=(unsigned short)[a111Pix kernelsize];
   if(n<1 || n>5) { a111Synthetic=NO; break; }
   float *kernel=(float*)[a111Pix kernel];NSMutableArray *values=[NSMutableArray array];
   for(NSUInteger i=0;i<n*n;i++) [values addObject:@(kernel[i])];
   a111Layer[@"kernel"]=values;a111Layer[@"kernelSize"]=@(n);
   a111Layer[@"kernelNormalization"]=@((float)[a111Pix normalization]);
  }
  NSMutableArray *a111Rois=[NSMutableArray array];
  for(NSObject *roi in (NSArray*)(id)[(NSObject*)a111View valueForKey:@"curRoiList"])
   [a111Rois addObject:@{@"type":[roi valueForKey:@"type"],@"mean":[roi valueForKey:@"mean"],@"min":[roi valueForKey:@"min"],@"max":[roi valueForKey:@"max"]}];
  a111Layer[@"rois"]=a111Rois;
  if (!a111W || !a111H || a111W>1024 || a111H>1024) { a111Synthetic=NO; break; }
  [[NSData dataWithBytes:(void*)[a111Pix fImage] length:a111W*a111H*4]writeToFile:[a111File stringByAppendingString:@".f32"] atomically:YES];
  if (!(BOOL)[a111Pix isRGB] && !(BOOL)[a111Pix thickSlabVRActivated])
   [[NSData dataWithBytes:(void*)[a111Pix baseAddr] length:a111W*a111H]writeToFile:[a111File stringByAppendingString:@".u8"] atomically:YES];
  NSMutableData *a111Volume=[NSMutableData data];
  NSArray *a111Slices=(NSArray*)(id)[a111Vc pixList];
  if(a111Slices.count>32) { a111Synthetic=NO; break; }
  for (id slice in a111Slices) {
   NSUInteger sw=(NSUInteger)[[(NSObject*)slice valueForKey:@"pwidth"] unsignedIntegerValue],sh=(NSUInteger)[[(NSObject*)slice valueForKey:@"pheight"] unsignedIntegerValue];
   if(sw!=a111W || sh!=a111H) { a111Synthetic=NO; break; }
   [a111Volume appendBytes:(void*)[slice fImage] length:sw*sh*4];
  }
  [a111Volume writeToFile:[a111File stringByAppendingString:@".volume.f32"] atomically:YES];
  unsigned char *a111A,*a111R,*a111G,*a111B;
  if(a111Index) {
   (void)[a111Main blendingColorTables:&a111A :&a111R :&a111G :&a111B];
   /* PET colours can come from the primary's shared PET table, but
      loadTextureIn:blending:YES consumes the secondary view's alphaTable. */
   unsigned char *unusedR,*unusedG,*unusedB;
   (void)[a111View colorTables:&a111A :&unusedR :&unusedG :&unusedB];
  }
  else (void)[a111View colorTables:&a111A :&a111R :&a111G :&a111B];
  NSMutableData *a111Palette=[NSMutableData dataWithLength:1024]; unsigned char *a111RGBA=(unsigned char*)a111Palette.mutableBytes;
  for(NSUInteger i=0;i<256;i++){a111RGBA[4*i]=a111R[i];a111RGBA[4*i+1]=a111G[i];a111RGBA[4*i+2]=a111B[i];a111RGBA[4*i+3]=a111Index ? a111A[i] : 255;}
  [a111Palette writeToFile:[a111File stringByAppendingString:@".rgba"] atomically:YES];
  id a111Texture=(id)[(id)[(id)[a111Main horosPlanarRenderer] uploadedTextureForLayer:(NSInteger)a111Index] retain];
  NSUInteger a111TextureWidth=(NSUInteger)[[(NSObject*)a111Texture valueForKey:@"width"] unsignedIntegerValue],a111TextureHeight=(NSUInteger)[[(NSObject*)a111Texture valueForKey:@"height"] unsignedIntegerValue];
  MTLPixelFormat format=(MTLPixelFormat)(NSUInteger)[[(NSObject*)a111Texture valueForKey:@"pixelFormat"] unsignedIntegerValue];
  if(!a111Texture || (NSUInteger)[[(NSObject*)a111Texture valueForKey:@"storageMode"] unsignedIntegerValue]!=MTLStorageModeShared || a111TextureWidth<1 || a111TextureHeight<1 || a111TextureWidth>4096 || a111TextureHeight>4096 ||
     (format!=MTLPixelFormatR32Float && format!=MTLPixelFormatR8Unorm)) {
   (void)[a111Texture release];a111Synthetic=NO;break;
  }
  a111Layer[@"scalarDraw"]=@(format==MTLPixelFormatR32Float);
  a111Layer[@"textureCount"]=@1;a111Layer[@"textureRows"]=@1;
  a111Layer[@"textureSize"]=@[@(a111TextureWidth),@(a111TextureHeight)];a111Layer[@"texturePixelFormat"]=@(format);
  NSUInteger bpp=format==MTLPixelFormatR32Float ? 4 : 1;
  NSMutableData *raw=[NSMutableData dataWithLength:a111TextureWidth*a111TextureHeight*bpp];
  (void)[a111Texture getBytes:raw.mutableBytes bytesPerRow:a111TextureWidth*bpp fromRegion:MTLRegionMake2D(0,0,a111TextureWidth,a111TextureHeight) mipmapLevel:0];
  (void)[a111Texture release];
  [raw writeToFile:[a111File stringByAppendingString:@".texture.raw"] atomically:YES];
  NSMutableData *tex=[NSMutableData dataWithLength:a111TextureWidth*a111TextureHeight*4];
  if(bpp==4) memcpy(tex.mutableBytes,raw.bytes,tex.length);
  else for(NSUInteger i=0;i<a111TextureWidth*a111TextureHeight;i++) ((float*)tex.mutableBytes)[i]=((const unsigned char*)raw.bytes)[i]/255.0f;
  [tex writeToFile:[a111File stringByAppendingString:@".texture.f32"] atomically:YES];
  [a111Layers addObject:a111Layer];
 }
 a111State[@"layers"]=a111Layers;
 NSInteger a111W=(NSInteger)a111Backing.size.width,a111H=(NSInteger)a111Backing.size.height;
 NSData *a111Top=a111Synthetic ? (id)[a111Main horosPlanarPixelsWidth:a111W height:a111H inverted:NO] : nil;
 if(a111Top.length!=(NSUInteger)a111W*a111H*4) a111Synthetic=NO;
 NSMutableData *a111Output=[NSMutableData dataWithLength:a111Top.length];
 for(NSInteger y=0;a111Synthetic && y<a111H;y++)
  memcpy((char*)a111Output.mutableBytes+y*a111W*4,(const char*)a111Top.bytes+(a111H-1-y)*a111W*4,a111W*4);
 a111State[@"captureAPI"]=@"horosPlanarPixelsWidth:height:inverted:+uploaded-texture";
 a111State[@"captureError"]=@0;a111State[@"rowOrder"]=@"bottom-up";
 if(a111Synthetic) {
  [a111Output writeToFile:[PREFIX stringByAppendingString:@".bgra"] atomically:YES];
  [[NSJSONSerialization dataWithJSONObject:a111State options:3 error:nil]writeToFile:OUTPUT atomically:YES];
 }
}
'''
expression = expression.replace('BUNDLE','@'+json.dumps(args.bundle_id)).replace('TITLE','@'+json.dumps(args.title_prefix)).replace('PREFIX','@'+json.dumps(str(prefix))).replace('OUTPUT','@'+json.dumps(str(staged)))
commands = prefix.with_suffix('.lldb')
commands.write_text('expression -l objc++ -- @import AppKit\nexpression -l objc++ -- @import Metal\nexpression -l objc++ -- @import ObjectiveC\n'
                    'expression -l objc++ -- { '+' '.join(expression.splitlines())+' }\nprocess detach --keep-stopped false\n')
if args.prepare_only:
    print('Prepared commands only (no capture):',commands)
    raise SystemExit(0)
result = subprocess.run(['xcrun','lldb','--batch','-p',str(args.pid),'-s',str(commands)],capture_output=True,text=True)
prefix.with_suffix('.lldb.log').write_text(result.stdout+result.stderr)
if result.returncode or not staged.exists():
    raise SystemExit('Capture failed or synthetic guard refused it; inspect the local LLDB log')
state = json.loads(staged.read_text())
paths = [prefix.with_suffix('.bgra')]
for layer in state['layers']:
    paths += list(args.output.glob(layer['prefix']+'.*'))
state['captureHashes'] = {path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
staged.write_text(json.dumps(state,indent=2)+'\n');staged.replace(prefix.with_suffix('.json'))
print(args.label, 'layers',len(state['layers']),'Metal',state['metalEnabled'],'fallback',bool(state['fallback']),'capture',state['captureAPI'])
for layer in state['layers']:
    print({k:layer.get(k) for k in ('modality','curImage','hasTransferFunction','hasFilter','stackMode','stack','hasSubtraction','shutterEnabled','scalarDraw','textureSize','texturePixelFormat')})
