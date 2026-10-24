#!/usr/bin/env python3
"""Measure real CPR views and operations in an isolated development application.

Requires a visible CPRController with a valid imported centerline. Changes the
angle/section position through the real view setters, waits for the real
generator and draws the view. Restores the path afterwards. Times are synchronous
update/draw latency, not input-to-display latency or monitor FPS. The window case
propagates the edit through the controller and explicitly draws all seven panes.
Run in an isolated development database; captures and logs stay local.
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
p.add_argument('--pid', type=int, required=True)
p.add_argument('--case', choices=['straightened', 'transverse', 'window'], default='straightened')
p.add_argument('--iterations', type=int, default=20)
p.add_argument('--thickness', type=float, default=0)
p.add_argument('--capture', action='store_true', help='Save the last generated float plane of each pass outside timing')
p.add_argument('--output', type=Path, default=Path('local-validation/native-cpr'))
a = p.parse_args()
if a.pid <= 0 or not re.fullmatch('[a-z0-9-]+', a.label) or not 1 <= a.iterations <= 100 or not math.isfinite(a.thickness) or not 0 <= a.thickness <= 100:
    p.error('Use a positive PID, lowercase label, 1-100 iterations and thickness 0-100 mm')
a.output.mkdir(parents=True, exist_ok=True)
base = (a.output / a.label).resolve()
if any(base.parent.glob(base.name + '.*')) or any(base.parent.glob(base.name + '-pass*')):
    p.error('Output label already exists; use a fresh label to preserve evidence')
staged = Path(str(base) + '.' + uuid.uuid4().hex + '.partial')
expression = r'''
if (![NSThread isMainThread]) { (void)printf("CPR benchmark requires main thread\n"); }
else {
(void)[(NSApplication *)NSApp activateIgnoringOtherApps:YES];
id c = nil;
for (NSWindow *w in (NSArray *)[(NSApplication *)NSApp windows]) {
 id candidate = (id)[w windowController];
 if ([w isVisible] && (BOOL)[candidate isKindOfClass:(Class)objc_getClass("CPRController")]) { c=candidate; break; }
}
if (c) {
id reformation=(id)[c cprView];
id v=TRANSVERSE ? (id)[c middleTransverseView] : (id)[reformation reformationView];
id original=(id)[(id)[v curvedPath] copy];
if (original && (NSUInteger)[(NSArray *)[original nodes] count]>=3) {
mach_timebase_info_data_t tb; (void)mach_timebase_info(&tb);
NSMutableArray *runs=[NSMutableArray array];
NSError *runError=nil;
(void)[(id)objc_getClass("HorosObjCException") performBlock:^{
for (int pass=0;pass<2;++pass) {
 NSMutableArray *samples=[NSMutableArray array];
 for (int i=-3;i<ITERATIONS;++i) {
  @autoreleasepool {
   id path=(id)[(id)[original copy] autorelease];
   [(NSObject *)path setValue:@(THICKNESS) forKey:@"thickness"];
   [(NSObject *)path setValue:@(0.03*(i+4)+0.001*pass) forKey:@"angle"];
   [(NSObject *)path setValue:@(0.25+0.005*(i+4)) forKey:@"transverseSectionPosition"];
   if (i==0) (void)[(id)objc_getClass("HorosMetalPerformanceTrace") reset];
   struct rusage before,after; (void)getrusage(RUSAGE_SELF,&before);
   double startUnix=[[NSDate date] timeIntervalSince1970];
   uint64_t start=mach_absolute_time();
   if (WINDOW_CASE) (void)[c CPRViewWillEditCurvedPath:reformation];
   (void)[v setCurvedPath:path];
   if (WINDOW_CASE) (void)[c CPRViewDidEditCurvedPath:reformation];
   uint64_t assigned=mach_absolute_time();
   if (TRANSVERSE) { (void)[v _sendNewRequestIfNeeded]; }
   else { (void)[v waitUntilPixUpdate]; }
   uint64_t generated=mach_absolute_time();
   if (WINDOW_CASE) {
    /* A container display does not force the layer-backed child panes. */
    for (NSView *pane in @[(id)[c mprView1],(id)[c mprView2],(id)[c mprView3],v,
                          (id)[c topTransverseView],(id)[c middleTransverseView],(id)[c bottomTransverseView]]) [pane display];
   } else [(NSView *)v display];
   uint64_t end=mach_absolute_time(); (void)getrusage(RUSAGE_SELF,&after);
   double endUnix=[[NSDate date] timeIntervalSince1970];
   id volume=TRANSVERSE ? (id)[v generatedVolumeData] : (id)[v curvedVolumeData];
   if (i>=0) [samples addObject:@{
    @"start_unix":@(startUnix),@"end_unix":@(endUnix),
    @"total_ms":@((end-start)*(double)tb.numer/tb.denom/1e6),
    @"assign_ms":@((assigned-start)*(double)tb.numer/tb.denom/1e6),
    @"generate_ms":@((generated-assigned)*(double)tb.numer/tb.denom/1e6),
    @"draw_ms":@((end-generated)*(double)tb.numer/tb.denom/1e6),
    @"cpu_ms":@((after.ru_utime.tv_sec-before.ru_utime.tv_sec+after.ru_stime.tv_sec-before.ru_stime.tv_sec)*1000.0+(after.ru_utime.tv_usec-before.ru_utime.tv_usec+after.ru_stime.tv_usec-before.ru_stime.tv_usec)/1000.0),
    @"valid":@(volume!=nil),
    @"dimensions":@[@((NSUInteger)[volume pixelsWide]),@((NSUInteger)[volume pixelsHigh]),@((NSUInteger)[volume pixelsDeep])]
   }];
  }
 }
 NSDictionary *trace=(NSDictionary *)[(id)objc_getClass("HorosMetalPerformanceTrace") snapshot];
 BOOL captureValid=YES;
 if (CAPTURE) {
  id volume=TRANSVERSE ? (id)[v generatedVolumeData] : (id)[v curvedVolumeData];
  NSUInteger width=(NSUInteger)[volume pixelsWide], height=(NSUInteger)[volume pixelsHigh];
  NSMutableData *plane=[NSMutableData dataWithLength:width*height*sizeof(float)];
  captureValid=width>0 && height>0;
  for (NSUInteger y=0;y<height;++y) captureValid = (BOOL)[volume getFloatRun:(float *)plane.mutableBytes+y*width atPixelCoordinateX:0 y:y z:0 length:width] && captureValid;
  captureValid = (BOOL)[plane writeToFile:[NSString stringWithFormat:@"%@-pass%d.f32",CAPTURE_BASE,pass] atomically:YES] && captureValid;
 }
 [runs addObject:@{@"captureValid":@(captureValid),@"pass":@(pass),@"samples":samples,@"trace":trace,@"thermalState":@((long)[[NSProcessInfo processInfo] thermalState])}];
}
} error:&runError];
if (WINDOW_CASE) (void)[c CPRViewWillEditCurvedPath:reformation];
(void)[v setCurvedPath:original];
if (WINDOW_CASE) (void)[c CPRViewDidEditCurvedPath:reformation];
if (!TRANSVERSE) (void)[v waitUntilPixUpdate];
(void)[original release];
NSDictionary *result=runError ? @{@"error":runError.localizedDescription} : @{@"case":@"CASE_NAME",@"thickness_mm":@(THICKNESS),@"iterations":@(ITERATIONS),@"interpolationMode":[(NSObject *)c valueForKey:@"selectedInterpolationMode"],@"runs":runs};
(void)[[NSJSONSerialization dataWithJSONObject:result options:3 error:nil] writeToFile:OUTPUT atomically:YES];
}
}
}
'''
for key, value in {'CAPTURE_BASE': '@' + json.dumps(str(base)), 'CAPTURE': '1' if a.capture else '0', 'TRANSVERSE': '1' if a.case == 'transverse' else '0', 'WINDOW_CASE': '1' if a.case == 'window' else '0', 'CASE_NAME': a.case, 'THICKNESS': repr(a.thickness), 'ITERATIONS': str(a.iterations), 'OUTPUT': '@' + json.dumps(str(staged))}.items():
    expression = expression.replace(key, value)
commands = Path(str(base)+'.lldb')
expression = ('NSError *benchmarkError=nil; (void)[(id)objc_getClass("HorosObjCException") performBlock:^{ '
              + expression + ' } error:&benchmarkError]; '
              + 'if (benchmarkError) (void)[[NSJSONSerialization dataWithJSONObject:@{@"error":benchmarkError.localizedDescription} options:3 error:nil] writeToFile:'
              + '@' + json.dumps(str(staged)) + ' atomically:YES];')
expression_file = Path(str(base)+'.expression.txt')
expression_file.write_text('{ '+expression+' }\n')
# Let application handlers catch their own Objective-C exceptions, and let the
# actual operation queues run immediately. LLDB's expression defaults otherwise
# stop at even handled exceptions and initially suspend the worker threads.
evaluate = ('script options=lldb.SBExpressionOptions(); options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); '
            'options.SetTrapExceptions(False); options.SetStopOthers(False); options.SetTimeoutInMicroSeconds(120000000); '
            'value=lldb.frame.EvaluateExpression(open('+repr(str(expression_file))+').read(), options); print(value.GetError())\n')
commands.write_text('expression -l objc++ -- @import AppKit\nexpression -l objc++ -- @import Darwin\n'
                    + evaluate + 'process detach\n')
r = subprocess.run(['xcrun','lldb','--batch','-p',str(a.pid),'-s',str(commands)],capture_output=True,text=True)
Path(str(base)+'.log').write_text(r.stdout+r.stderr)
if r.returncode or not staged.exists():
    raise SystemExit('Measurement failed; inspect '+str(base)+'.log')
output=Path(str(base)+'.json')
result=json.loads(staged.read_text())
if 'error' in result:
    raise SystemExit('Native CPR measurement failed: '+result['error'])
if len(result.get('runs', [])) != 2:
    raise SystemExit('Incomplete CPR passes; reject '+str(staged))
for index, run in enumerate(result['runs']):
    if run['pass'] != index or len(run['samples']) != a.iterations:
        raise SystemExit('Incomplete CPR samples; reject '+str(staged))
    values=sorted(s['total_ms'] for s in run['samples'])
    if not all(s['valid'] and len(s['dimensions']) == 3 and all(d > 0 for d in s['dimensions']) and all(math.isfinite(s[k]) and s[k] >= 0 for k in ('total_ms', 'assign_ms', 'generate_ms', 'draw_ms', 'cpu_ms')) for s in run['samples']):
        raise SystemExit('Invalid CPR output; do not accept timings')
    if a.capture:
        capture = Path(str(base)+'-pass%d.f32' % index)
        width, height, _ = run['samples'][-1]['dimensions']
        if not run['captureValid'] or not capture.is_file() or capture.stat().st_size != width*height*4:
            raise SystemExit('Incomplete CPR float capture; reject '+str(staged))
    print('pass %d: p50 %.2f ms, p95 %.2f ms, dimensions %s' % (run['pass'],statistics.median(values),values[math.ceil(.95*len(values))-1],run['samples'][-1]['dimensions']))
staged.replace(output)
print(output)
