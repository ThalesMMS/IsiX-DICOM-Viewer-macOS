#!/usr/bin/env python3
"""Measure two passes of native Metal VR at the current camera in development Horos.

Attaches LLDB, warms each engine, measures NSView.display through the native VR
renderer, captures the native RGB readback, and restores the selected engine/LOD.
Visible VR views normalize CPU engine requests to Metal, so this tool does not
label such requests as CPU measurements. No input events are sent.
These are synchronous rendering times, not input latency or displayed FPS.
Run without Instruments or other GPU workloads; raw captures stay local.
"""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('label')
p.add_argument('--pid', required=True, type=int)
p.add_argument('--iterations', type=int, default=20)
p.add_argument('--metal-only', action='store_true', help='Compatibility flag: visible native VR always uses Metal')
p.add_argument('--trace', action='store_true', help='Include existing MetalPerformanceTrace samples; enable the preference before launch')
p.add_argument('--cold-upload', action='store_true', help='Measure one released-volume redraw before each warm pass')
p.add_argument('--prepare-rgb-tables', action='store_true', help='Initialize the native mapper component tables before RGB timing')
p.add_argument('--lod', type=float, default=2, help='Image sample distance for both passes (default: 2)')
p.add_argument('--warmup-seconds', type=float, default=0, help='Minimum continuous warmup time per pass, in addition to three frames')
p.add_argument('--output', type=Path, default=Path('local-validation/vr-metal'))
a = p.parse_args()
if a.pid <= 0 or not re.fullmatch('[a-z0-9-]+', a.label) or not 1 <= a.iterations <= 100 or not math.isfinite(a.lod) or not 1 <= a.lod <= 8 or not math.isfinite(a.warmup_seconds) or not 0 <= a.warmup_seconds <= 30:
    p.error('Use a positive PID, lowercase label, 1-100 iterations, LOD 1-8 and warmup 0-30 seconds')
a.output.mkdir(parents=True, exist_ok=True)
base = (a.output / a.label).resolve()
if any(base.parent.glob(base.name + '.*')) or any(base.parent.glob(base.name + '-*')):
    p.error('Output label already exists; use a fresh label to preserve evidence')
staged = Path(str(base) + '.' + uuid.uuid4().hex + '.partial')
expression = r'''
if (![NSThread isMainThread]) { (void)printf("VR benchmark requires main thread\n"); }
else {
(void)[(NSApplication *)NSApp activateIgnoringOtherApps:YES];
id vrBenchController = nil;
for (NSWindow *vrBenchWindow in (NSArray *)[(NSApplication *)NSApp windows]) {
 id vrBenchCandidate = (id)[vrBenchWindow windowController];
 if ((BOOL)[vrBenchWindow isVisible] && (BOOL)[vrBenchCandidate isKindOfClass:(Class)objc_getClass("VRController")] && ![(NSString *)[vrBenchCandidate style] isEqualToString:@"noNib"]) { vrBenchController = vrBenchCandidate; break; }
}
if (vrBenchController) {
 /* CPR's hidden projection leaves this VTK gate set; VR interaction clears it. */
 int *vrBenchRenderGate=(int *)RENDER_GATE_ADDRESS;
 int vrBenchInitialRenderGate=*vrBenchRenderGate;
 *vrBenchRenderGate=0;
 id vrBenchView = (id)[vrBenchController view];
 int vrBenchInitialEngine = [(NSNumber *)[(NSObject *)vrBenchView valueForKey:@"engine"] intValue];
 float vrBenchInitialLOD = [(NSNumber *)[(NSObject *)vrBenchView valueForKey:@"LOD"] floatValue];
 mach_timebase_info_data_t vrBenchTimebase; (void)mach_timebase_info(&vrBenchTimebase);
 NSMutableDictionary *vrBenchResult = [NSMutableDictionary dictionary];
 NSError *vrBenchError=nil;
 (void)[(id)objc_getClass("HorosObjCException") performBlock:^{
 if (PREPARE_RGB_TABLES) (void)[vrBenchView horosMPRColourTables];
 for (NSNumber *vrBenchEngine in ENGINES) {
  @autoreleasepool {
   (void)[vrBenchView setEngine:(long)[vrBenchEngine longValue] showWait:(BOOL)0];
   [(NSObject *)vrBenchView setValue:@(LOD_VALUE) forKey:@"LOD"];
   double vrBenchColdMilliseconds=0; NSDictionary *vrBenchColdTrace=@{};
   if (COLD_UPLOAD && [vrBenchEngine intValue]==2) {
    (void)[vrBenchController horosVolumeMetalRelease];
    (void)[(id)objc_getClass("HorosMetalPerformanceTrace") reset];
    uint64_t coldStart=mach_absolute_time();
    [(NSView *)vrBenchView setNeedsDisplay:YES]; [(NSView *)vrBenchView display];
    vrBenchColdMilliseconds=(mach_absolute_time()-coldStart)*(double)vrBenchTimebase.numer/vrBenchTimebase.denom/1e6;
    vrBenchColdTrace=(NSDictionary *)[(id)objc_getClass("HorosMetalPerformanceTrace") snapshot];
   }
   uint64_t vrBenchWarmStart=mach_absolute_time();
   for (int vrBenchWarm=0;vrBenchWarm<3 || (mach_absolute_time()-vrBenchWarmStart)*(double)vrBenchTimebase.numer/vrBenchTimebase.denom/1e9<WARMUP_SECONDS;++vrBenchWarm) {
    @autoreleasepool { [(NSView *)vrBenchView setNeedsDisplay:YES]; [(NSView *)vrBenchView display]; }
   }
   TRACE_RESET
   NSMutableArray *vrBenchTimes=[NSMutableArray array], *vrBenchGPU=[NSMutableArray array];
   for (int vrBenchIteration=0;vrBenchIteration<ITERATIONS;++vrBenchIteration) {
    uint64_t vrBenchStart=mach_absolute_time(); void *vrBenchPool=(void *)objc_autoreleasePoolPush(); [(NSView *)vrBenchView setNeedsDisplay:YES]; [(NSView *)vrBenchView display]; (void)objc_autoreleasePoolPop(vrBenchPool);
    [vrBenchTimes addObject:@((mach_absolute_time()-vrBenchStart)*(double)vrBenchTimebase.numer/vrBenchTimebase.denom/1e6)];
    [vrBenchGPU addObject:@((double)[vrBenchController horosVolumeMetalLastMilliseconds])];
   }
   TRACE_SNAPSHOT
   NSData *vrBenchNativePixels=(NSData *)[vrBenchView horosRayCastImagePixels];
   BOOL vrBenchNativeWritten=(BOOL)[vrBenchNativePixels writeToFile:[NSString stringWithFormat:@"%@-pass%lu.rgba16",BASE,(unsigned long)[vrBenchResult count]] atomically:YES];
   NSMutableDictionary *vrBenchSnapshot = [(NSDictionary *)[vrBenchController horosVolumeSnapshot] mutableCopy];
   [vrBenchSnapshot removeObjectForKey:@"volume"];
   /* Keep transfer tables in the evidence so native A/B inputs can be compared. */
   if (vrBenchSnapshot[@"componentTables"]) {
    NSMutableArray *vrBenchTables=[NSMutableArray array];
    for (NSDictionary *vrBenchEntry in vrBenchSnapshot[@"componentTables"]) {
     NSMutableDictionary *vrBenchTable=[vrBenchEntry mutableCopy];
     for (NSString *vrBenchKey in [vrBenchTable allKeys]) if ((BOOL)[vrBenchTable[vrBenchKey] isKindOfClass:(Class)objc_getClass("NSData")]) vrBenchTable[vrBenchKey]=[(NSData *)vrBenchTable[vrBenchKey] base64EncodedStringWithOptions:0];
     [vrBenchTables addObject:vrBenchTable];
    }
    vrBenchSnapshot[@"componentTables"]=vrBenchTables;
   }
   for (NSString *vrBenchField in [vrBenchSnapshot allKeys]) {
    id vrBenchValue=vrBenchSnapshot[vrBenchField];
    if ((BOOL)[vrBenchValue isKindOfClass:(Class)objc_getClass("NSData")]) vrBenchSnapshot[vrBenchField]=[(NSData *)vrBenchValue base64EncodedStringWithOptions:0];
   }
   long vrBenchWidth=0,vrBenchHeight=0,vrBenchSamples=0,vrBenchBits=0;
   unsigned char *vrBenchPixels=(unsigned char *)[vrBenchView getRawPixels:&vrBenchWidth :&vrBenchHeight :&vrBenchSamples :&vrBenchBits :(BOOL)0 :(BOOL)0];
   NSString *vrBenchKey=[NSString stringWithFormat:@"engine%@-pass%lu",vrBenchEngine,(unsigned long)[vrBenchResult count]];
   BOOL vrBenchRGBWritten=NO;
   if(vrBenchPixels) { vrBenchRGBWritten=(BOOL)[[NSData dataWithBytes:vrBenchPixels length:(NSUInteger)(vrBenchWidth*vrBenchHeight*vrBenchSamples*vrBenchBits/8)] writeToFile:[NSString stringWithFormat:@"%@-%@.rgb",BASE,vrBenchKey] atomically:YES]; free(vrBenchPixels); }
   NSRect vrBenchBounds=[(NSView *)vrBenchView bounds];
   NSRect vrBenchBacking=[(NSView *)vrBenchView convertRectToBacking:vrBenchBounds];
   vrBenchResult[vrBenchKey]=@{@"captureValid":@(vrBenchNativeWritten && vrBenchRGBWritten),@"nativePixelBytes":@([vrBenchNativePixels length]),@"milliseconds":vrBenchTimes,@"metalBridgeMilliseconds":vrBenchGPU,@"snapshot":vrBenchSnapshot,
    @"initialEngine":@(vrBenchInitialEngine),@"initialLOD":@(vrBenchInitialLOD),
    @"engine":[(NSObject *)vrBenchView valueForKey:@"engine"],@"LOD":[(NSObject *)vrBenchView valueForKey:@"LOD"],
    @"width":@(vrBenchWidth),@"height":@(vrBenchHeight),@"samples":@(vrBenchSamples),@"bits":@(vrBenchBits),
    @"bounds":@[@(vrBenchBounds.size.width),@(vrBenchBounds.size.height)],@"backing":@[@(vrBenchBacking.size.width),@(vrBenchBacking.size.height)],
    @"fallback":(NSString *)[vrBenchController horosVolumeMetalFallbackReason]?:@"",@"volumeBytes":@((long)[vrBenchController horosVolumeMetalBytes]),
    @"trace":vrBenchTrace,@"coldUploadMilliseconds":@(vrBenchColdMilliseconds),@"coldTrace":vrBenchColdTrace,
    @"warmupSeconds":@(WARMUP_SECONDS),@"thermalState":@((long)[[NSProcessInfo processInfo] thermalState])};
  }
 }
 } error:&vrBenchError];
 (void)[vrBenchView setEngine:(long)vrBenchInitialEngine showWait:(BOOL)0];
 [(NSObject *)vrBenchView setValue:@(vrBenchInitialLOD) forKey:@"LOD"];
 [(NSView *)vrBenchView setNeedsDisplay:YES];
 *vrBenchRenderGate=vrBenchInitialRenderGate;
 (void)[[NSJSONSerialization dataWithJSONObject:(vrBenchError ? @{@"error":vrBenchError.localizedDescription} : vrBenchResult) options:3 error:nil] writeToFile:OUTPUT atomically:YES];
}
}
'''.replace('ITERATIONS', str(a.iterations)).replace('BASE', '@'+json.dumps(str(base))).replace('OUTPUT', '@'+json.dumps(str(staged)))
expression = expression.replace('ENGINES', '@[@2, @2]')
expression = expression.replace('LOD_VALUE', repr(a.lod))
expression = expression.replace('WARMUP_SECONDS', repr(a.warmup_seconds))
expression = expression.replace('COLD_UPLOAD', '1' if a.cold_upload else '0')
expression = expression.replace('PREPARE_RGB_TABLES', '1' if a.prepare_rgb_tables else '0')
expression = expression.replace('TRACE_RESET', '(void)[(id)objc_getClass("HorosMetalPerformanceTrace") reset];' if a.trace else '')
expression = expression.replace('TRACE_SNAPSHOT', 'NSDictionary *vrBenchTrace=(NSDictionary *)[(id)objc_getClass("HorosMetalPerformanceTrace") snapshot];' if a.trace else 'NSDictionary *vrBenchTrace=@{};')
commands = Path(str(base)+'.lldb')
expression_file = Path(str(base)+'.expression.txt')
expression_file.write_text('{ '+expression+' }\n')
# Resolve the legacy gate by its functional prefix, without depending on a
# vendor suffix. Require one data symbol and a valid loaded address; abort before
# evaluating native code if the target is missing or ambiguous.
# Let the app handle its exceptions and allow rendering workers to run.
evaluate = ('script options=lldb.SBExpressionOptions(); options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); '
            'options.SetTrapExceptions(False); options.SetStopOthers(False); options.SetTimeoutInMicroSeconds(300000000); '
            'vrBenchSymbols=[symbol for module in lldb.target.modules for symbol in module.symbols '
            'if (symbol.GetName() or "").startswith("dontRenderVolumeRendering") and symbol.GetType()==lldb.eSymbolTypeData]; '
            'assert len(vrBenchSymbols)==1, "Expected one volume rendering gate data symbol"; '
            'vrBenchGateAddress=vrBenchSymbols[0].GetStartAddress().GetLoadAddress(lldb.target); '
            'assert vrBenchGateAddress not in (0,lldb.LLDB_INVALID_ADDRESS) and vrBenchGateAddress%4==0, "Invalid volume rendering gate address"; '
            'value=lldb.frame.EvaluateExpression(open('+repr(str(expression_file))+').read().replace("RENDER_GATE_ADDRESS",hex(vrBenchGateAddress)), options); print(value.GetError())\n')
commands.write_text('expression -l objc++ -- @import AppKit\nexpression -l objc++ -- @import Darwin\n'
                   + evaluate + 'process detach\n')
r = subprocess.run(['xcrun','lldb','--batch','-p',str(a.pid),'-s',str(commands)],capture_output=True,text=True)
Path(str(base)+'.log').write_text(r.stdout+r.stderr)
if r.returncode or not staged.exists():
    raise SystemExit('Measurement failed; inspect '+str(base)+'.log')
output=Path(str(base)+'.json')
result=json.loads(staged.read_text())
if 'error' in result:
    raise SystemExit('Native VR measurement failed: '+result['error'])
engines = [2, 2]
if set(result) != {f'engine{engine}-pass{i}' for i, engine in enumerate(engines)}:
    raise SystemExit('Incomplete VR passes; reject '+str(staged))
for index, engine in enumerate(engines):
    name=f'engine{engine}-pass{index}'
    run=result[name]
    if run['fallback'] or int(run['engine']) != engine or len(run['milliseconds']) != a.iterations or not all(math.isfinite(v) and v > 0 for v in run['milliseconds']):
        raise SystemExit('Invalid VR engine/samples; reject '+str(staged))
    rgb=Path(str(base)+'-'+name+'.rgb')
    native=Path(str(base)+f'-pass{index}.rgba16')
    dimensions=[run[k] for k in ('width', 'height', 'samples', 'bits')]
    if not run['captureValid'] or not all(v > 0 for v in dimensions) or not rgb.is_file() or rgb.stat().st_size != math.prod(dimensions)//8 or not native.is_file() or native.stat().st_size != run['nativePixelBytes'] or run['nativePixelBytes'] <= 0:
        raise SystemExit('Incomplete VR pixel capture; reject '+str(staged))
    if a.prepare_rgb_tables and (not run['snapshot'].get('colourVolume') or len(run['snapshot'].get('componentTables', [])) != 3):
        raise SystemExit('RGB mapper tables are not initialized; reject this capture: '+str(staged))
    if a.trace and int(run['engine']) == 2:
        draws = [s for s in run['trace']['samples'] if s['operation'] in ('vr.render', 'vr.render.metal4')]
        if len(draws) != a.iterations or run['trace']['dropped'] or run['fallback'] or not all(s.get('status') == 'completed' and isinstance(s.get('gpu_ms'), (int, float)) and math.isfinite(s['gpu_ms']) and s['gpu_ms'] >= 0 for s in draws):
            raise SystemExit('Invalid native render coverage/fallback; inspect '+str(staged))
    values=sorted(run['milliseconds']);run['p50']=statistics.median(values);run['p95']=values[math.ceil(len(values)*.95)-1]
    print('%s: p50 %.2f ms, p95 %.2f ms, %dx%d, fallback=%r' % (name,run['p50'],run['p95'],run['width'],run['height'],run['fallback']))
staged.replace(output)
print(output)
