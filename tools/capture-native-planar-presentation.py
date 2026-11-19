#!/usr/bin/env python3
"""Read synthetic A111 presentation inputs, uploaded textures and native output.

All interaction happens through the UI. LLDB reads the uploaded shared Metal
textures and production capture output without driving UI. Captures remain local.

The verifier only accepts a capture of an active application. A first LLDB
attach therefore asks the application to activate, when the capture's own
synthetic guard holds, and detaches, so that its event loop handles the
activation; the capturer waits a bounded time for it to come to the front and
settle. The capture's snapshot then reads [NSApp isActive], and a snapshot of
an inactive application is refused with nothing saved.
"""
import argparse
import json
import hashlib
from pathlib import Path
import re
import subprocess
import time
import uuid

ACTIVATION_WAIT_SECONDS = 3
# Becoming active redraws the windows and synchronizes the other viewers on the
# application's run loop: the capture stops the process only after that.
ACTIVATION_SETTLE_SECONDS = 1
ACTIVATION_ATTACH_SECONDS = 60


def inactive_refusal(state, pid):
    """Why a capture snapshot must not be saved for inactivity, or None."""
    if state.get('applicationActive'):
        return None
    return (f'Refused: the application (pid {pid}) was not active in the capture snapshot, although it was asked '
            'to activate. Another application may keep the front; bring the viewer to the front and capture again. '
            'No capture was saved.')


def wait_until_front(pid, seconds):
    """Whether LaunchServices reports the process in front within `seconds`; the snapshot still decides."""
    asn = re.compile(r'ASN:0x[0-9a-f]+-0x[0-9a-f]+')
    deadline = time.monotonic() + seconds

    def lsappinfo(*arguments):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            output = subprocess.run(['lsappinfo', *arguments], capture_output=True, text=True,
                                    stdin=subprocess.DEVNULL, timeout=remaining).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        match = asn.search(output)
        return match.group() if match else None

    mine = None
    while time.monotonic() < deadline:
        mine = mine or lsappinfo('find', f'pid={pid}')
        if mine and lsappinfo('front') == mine:
            return True
        time.sleep(0.1)
    return False


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
# The one synthetic viewer of the series, on the main thread of the isolated host;
# the activation and the capture both act only when it holds.
guard = r'''
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
'''
expression = r'''
BOOL a111Active=(BOOL)[(NSApplication*)NSApp isActive];
''' + guard + r'''
/* Inactive: only the state goes out, for the refusal; no capture file is written. */
if (a111Synthetic && !a111Active)
 [[NSJSONSerialization dataWithJSONObject:@{@"applicationActive":@NO} options:0 error:nil]writeToFile:OUTPUT atomically:YES];
if (a111Synthetic && a111Active) {
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
  @"applicationActive":@(a111Active),
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
def fill(text):
    return text.replace('BUNDLE','@'+json.dumps(args.bundle_id)).replace('TITLE','@'+json.dumps(args.title_prefix)).replace('PREFIX','@'+json.dumps(str(prefix))).replace('OUTPUT','@'+json.dumps(str(staged)))


def one_line(text):
    return 'expression -l objc++ -- { '+' '.join(fill(text).splitlines())+' }'


def discard():
    """Remove what a refused or failed capture of this label wrote; its LLDB commands and log stay."""
    layer = re.compile(re.escape(args.label)+r'-layer-\d+\.(f32|u8|volume\.f32|rgba|texture\.raw|texture\.f32)')
    for path in [staged, prefix.with_suffix('.bgra'), *(path for path in args.output.iterdir() if layer.fullmatch(path.name))]:
        path.unlink(missing_ok=True)


def attach(*arguments, timeout=None):
    return subprocess.run(['xcrun','lldb','--batch','-p',str(args.pid),*arguments],capture_output=True,text=True,
                          stdin=subprocess.DEVNULL,timeout=timeout)


commands = prefix.with_suffix('.lldb')
commands.write_text('expression -l objc++ -- @import AppKit\nexpression -l objc++ -- @import Metal\nexpression -l objc++ -- @import ObjectiveC\n'
                    +one_line(expression)+'\nprocess detach --keep-stopped false\n')
if args.prepare_only:
    print('Prepared commands only (no capture):',commands)
    raise SystemExit(0)
# Activation is handled by the application's own event loop, so it is asked for
# in an attach of its own; the capture's attach then finds it settled.
activation = guard+'''
if (a111Synthetic && !(BOOL)[(NSApplication*)NSApp isActive]) (void)[(NSApplication*)NSApp activateIgnoringOtherApps:YES];
'''
try:
    activated = attach('-o','expression -l objc++ -- @import AppKit','-o','expression -l objc++ -- @import ObjectiveC',
                       '-o',one_line(activation),'-o','process detach --keep-stopped false',timeout=ACTIVATION_ATTACH_SECONDS)
    log, failure = activated.stdout+activated.stderr, activated.returncode and f'LLDB exited with {activated.returncode}'
except subprocess.TimeoutExpired as expired:
    log = ''.join(part.decode(errors='replace') if isinstance(part,bytes) else part for part in (expired.stdout or '',expired.stderr or ''))
    failure = f'LLDB did not finish within {ACTIVATION_ATTACH_SECONDS} s'
if failure:
    prefix.with_suffix('.lldb.log').write_text(log)
    raise SystemExit(f'Could not ask the application to activate ({failure}); no capture was saved; inspect the local LLDB log')
if wait_until_front(args.pid, ACTIVATION_WAIT_SECONDS):
    time.sleep(ACTIVATION_SETTLE_SECONDS)
result = attach('-s',str(commands))
prefix.with_suffix('.lldb.log').write_text(log+result.stdout+result.stderr)
if result.returncode or not staged.exists():
    discard()
    raise SystemExit('Capture failed or synthetic guard refused it; no capture was saved; inspect the local LLDB log')
state = json.loads(staged.read_text())
refusal = inactive_refusal(state, args.pid)
if refusal:
    discard()
    raise SystemExit(refusal)
paths = [prefix.with_suffix('.bgra')]
for layer in state['layers']:
    paths += list(args.output.glob(layer['prefix']+'.*'))
state['captureHashes'] = {path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
staged.write_text(json.dumps(state,indent=2)+'\n');staged.replace(prefix.with_suffix('.json'))
print(args.label, 'layers',len(state['layers']),'Metal',state['metalEnabled'],'fallback',bool(state['fallback']),'capture',state['captureAPI'])
for layer in state['layers']:
    print({k:layer.get(k) for k in ('modality','curImage','hasTransferFunction','hasFilter','stackMode','stack','hasSubtraction','shutterEnabled','scalarDraw','textureSize','texturePixelFormat')})
