#!/usr/bin/env python3
"""Validate Swift median and its production DCMPix statistics integration.

The statistics are IsiXROI's since they left DCMPix.m; before, DCMPix summed
the samples itself and asked the app's HorosROIStatistics for the median. The
same checks run on either, so a revision before the move can still be given.

Since -computeROI: left DCMPix.m for a Swift extension (DCMPix+ROIMeasure.swift),
the same samples go through what it calls, IsiXROI's statistics, in a Swift
driver, and the extension is checked for handing its pixels to them.

The ROI's side - the median in its label, its data export and its tab-separated
description, and N/A when there is none - is checked on this checkout's ROI,
linked as the application's build compiled it (tests/roi_harness.py); without
a build that part is skipped.
"""
from pathlib import Path
import subprocess, sys, tempfile
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests'))
import isix_modules  # noqa: E402
import roi_harness  # noqa: E402
# Empty once DCMPix is Swift: -computeROI: is then DCMPix+ROIMeasure.swift's.
s=(subprocess.check_output(['git','show',sys.argv[1]+':Horos/Sources/DCMPix.m']) if len(sys.argv)>1
   else (root/'Horos/Sources/DCMPix.m').read_bytes() if (root/'Horos/Sources/DCMPix.m').is_file() else b'').decode('latin1')
SIGNATURE='- (void) computeROI:(ROI*) roi :(float*) mean :(float *)total :(float *)dev :(float *)min :(float *)max :(float *)skewness'

SWIFT_DRIVER = r'''
import Foundation
import IsiXROI

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
func statistics(_ values: [Float]) -> (ROIPixelStatistics, Double) {
    values.withUnsafeBufferPointer { buffer in
        let samples = ROIPixelSamples(values: values.isEmpty ? nil : buffer.baseAddress, count: values.count)
        return (ROIPixelStatistics(samples: samples, deviation: true, higherMoments: false), ROIPixelStatistics.median(of: samples))
    }
}
let samples: [[Float]] = [[9, 1, 5], [9, 1, 5, 3], [], [42], [-9, -1, -5], [.nan, 1, 3, .infinity], [.nan, -.infinity],
                          [.greatestFiniteMagnitude, .greatestFiniteMagnitude]]
let expected: [Double] = [5, 4, .nan, 42, -5, 2, .nan, Double(Float.greatestFiniteMagnitude)]
for (i, values) in samples.enumerated() {
    let (s, median) = statistics(values)
    check(expected[i].isNaN ? median.isNaN : median == expected[i], "median of set \\(i)")
    if i == 0 { check(s.mean == 5 && s.total == 15 && s.deviation == 4 && s.minimum == 1 && s.maximum == 9, "set 0") }
    if i == 1 { check(s.mean == 4.5 && s.total == 18 && abs(Double(s.deviation) - (35.0 / 3).squareRoot()) < 1e-6 && s.minimum == 1 && s.maximum == 9, "set 1") }
    if i == 2 || i == 3 { check(s.deviation == 0 && s.deviation.sign == .plus, "set \\(i) dispersion") }
}
for scale in [Float(2e38), Float(1e-30)] {
    let (s, _) = statistics([-scale, scale])
    check(s.deviation.isFinite && abs(Double(s.deviation) / (2.0.squareRoot() * Double(scale)) - 1) < 1e-6, "wide range \\(scale)")
}
for invalid in [Float.nan, .infinity] {
    check(statistics([invalid]).0.deviation.isNaN, "invalid \\(invalid)")
}
var input: [Float] = [9, 1, 5, 3]
check(statistics(input).1 == 4 && input == [9, 1, 5, 3], "median keeps the order")
check(ROIPixelStatistics.median(of: ROIPixelSamples(values: nil, count: 0)).isNaN, "empty median")
check(input.withUnsafeMutableBufferPointer { ROIPixelStatistics.median(of: ROIPixelSamples(values: $0.baseAddress, count: -1)) }.isNaN, "negative count")
if failures > 0 { exit(1) }
print("PASS: median, zero/singleton dispersion, wide-range deviation and unchanged ordinary statistics")
'''

if SIGNATURE not in s:
    measure = (root / 'Horos/Sources/DCMPix+ROIMeasure.swift').read_text(encoding='utf-8')
    compute = measure[measure.find('@objc(computeROI::::::::)'):measure.find('@objc(moment:length:mean:order:)')]
    for needle in ('ROIPixelStatistics(samples: samples, deviation: dev != nil', '.median = ROIPixelStatistics.median(of: samples)',
                   'getROIValue(&count, roi, nil)'):
        if needle not in compute:
            print('FAIL: the Swift -computeROI: no longer has %r' % needle)
            sys.exit(1)
    with tempfile.TemporaryDirectory(prefix='horos-roi-median-') as d:
        p = Path(d)
        (p / 'driver.swift').write_text(SWIFT_DRIVER)
        subprocess.run(['xcrun', 'swiftc', str(p / 'driver.swift'), *isix_modules.module_flags('IsiXROI', p / 'modules'),
                        '-o', str(p / 'driver')], check=True)
        subprocess.run([str(p / 'driver')], check=True)
    a = b = 0
else:
    a=s.index(SIGNATURE)
    b=s.index('- (void) setRGB:',a)
code=r'''
#import <Cocoa/Cocoa.h>
#import "STATISTICS_HEADER"
MEDIAN_DEFINITION
@interface ROI:NSObject
@property double median;
@property(copy) NSArray<NSNumber*> *samples;
@end
@implementation ROI
@end
@interface DCMPix:NSObject
-(float*)getROIValue:(long*)count :(ROI*)roi :(void*)unused;
+(float)kurtosis:(float*)v length:(long)n mean:(double)m;
+(float)skewness:(float*)v length:(long)n mean:(double)m;
@end
@implementation DCMPix
-(float*)getROIValue:(long*)count :(ROI*)roi :(void*)unused {
 *count=roi.samples.count;if(!*count)return NULL;
 float*v=malloc(*count*sizeof(float));for(long i=0;i<*count;i++)v[i]=roi.samples[i].floatValue;return v;
}
+(float)kurtosis:(float*)v length:(long)n mean:(double)m{return 0;}
+(float)skewness:(float*)v length:(long)n mean:(double)m{return 0;}
METHOD
@end
static int failures;
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);failures++;}}while(0)
int main(){@autoreleasepool{
 NSArray *samples=@[@[@9,@1,@5],@[@9,@1,@5,@3],@[],@[@42],@[@(-9),@(-1),@(-5)],@[@(NAN),@1,@3,@(INFINITY)],@[@(NAN),@(-INFINITY)],@[@(FLT_MAX),@(FLT_MAX)]];
 double expected[]={5,4,NAN,42,-5,2,NAN,FLT_MAX};
 for(NSUInteger i=0;i<samples.count;i++){
  ROI*r=[ROI new];r.samples=samples[i];DCMPix*p=[DCMPix new];
  float mean,total,dev,min,max;
  [p computeROI:r :&mean :&total :&dev :&min :&max :NULL :NULL];
  check(isnan(expected[i])?isnan(r.median):r.median==expected[i]);
  if(i==0)check(mean==5 && total==15 && dev==4 && min==1 && max==9);
  if(i==1)check(mean==4.5 && total==18 && fabs(dev-sqrt(35.0/3))<1e-6 && min==1 && max==9);
  if(i==2 || i==3)check(dev==0 && !signbit(dev));
 }
 for(NSNumber*scale in @[@(2e38f),@(1e-30f)]){
  ROI*r=[ROI new];r.samples=@[@(-scale.floatValue),scale];
  DCMPix*p=[DCMPix new];float dev;
  [p computeROI:r :NULL :NULL :&dev :NULL :NULL :NULL :NULL];
  double expectedDev=sqrt(2.0)*scale.doubleValue;
  check(isfinite(dev) && fabs(dev/expectedDev-1)<1e-6);
 }
 for(NSNumber*invalid in @[@(NAN),@(INFINITY)]){
  ROI*r=[ROI new];r.samples=@[invalid];DCMPix*p=[DCMPix new];float dev;
  [p computeROI:r :NULL :NULL :&dev :NULL :NULL :NULL :NULL];
  check(isnan(dev));
 }
 float input[]={9,1,5,3};
 check(MEDIAN(input,4)==4);
 check(input[0]==9 && input[1]==1 && input[2]==5 && input[3]==3);
 check(isnan(MEDIAN(NULL,0)));
 check(isnan(MEDIAN(input,-1)));
 if(failures)return 1;
 NSLog(@"PASS: median, zero/singleton dispersion, wide-range deviation and unchanged ordinary statistics");
}}
'''.replace('METHOD',s[a:b])
if SIGNATURE in s:
    modular='IsiXROI-Swift.h' in s
    if modular:
        code=code.replace('STATISTICS_HEADER','IsiXROI-Swift.h').replace('MEDIAN_DEFINITION',
            '#define MEDIAN(v,n) [IsiXROIPixelStatistics medianOfSamples:[[[IsiXROIPixelSamples alloc] initWithValues:(v) count:(n)] autorelease]]')
    else:
        code=code.replace('STATISTICS_HEADER','Statistics-Swift.h').replace('MEDIAN_DEFINITION',
            '#define MEDIAN(v,n) [HorosROIStatistics medianOfValues:(v) count:(n)]')
    with tempfile.TemporaryDirectory(prefix='horos-roi-median-') as d:
        p=Path(d);(p/'test.m').write_text(code)
        if modular:
            isix_modules.build_module('IsiXROI',p)
            (p/'empty.swift').write_text('')
            subprocess.run(['xcrun','swiftc',str(p/'empty.swift'),'-emit-library','-module-name','Statistics',
                            '-Xlinker','-force_load','-Xlinker',str(p/'libIsiXROI.a'),'-o',str(p/'libStatistics.dylib')],check=True)
        else:
            statistics=subprocess.check_output(['git','show',sys.argv[1]+':Horos/Sources/ROIStatistics.swift']) if len(sys.argv)>1 else (root/'Horos/Sources/ROIStatistics.swift').read_bytes()
            (p/'ROIStatistics.swift').write_bytes(statistics)
            subprocess.run(['xcrun','swiftc',str(p/'ROIStatistics.swift'),'-emit-library','-module-name','Statistics','-emit-objc-header-path',str(p/'Statistics-Swift.h'),'-o',str(p/'libStatistics.dylib')],check=True)
        subprocess.run(['xcrun','clang','-fno-objc-arc','-fsanitize=undefined','-framework','Cocoa','-I',d,str(p/'test.m'),'-L',d,'-lStatistics','-o',str(p/'test')],check=True)
        subprocess.run([str(p/'test')],check=True)

if len(sys.argv) > 1:
    sys.exit(0)

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    ROI *r = newROI( tROI);
    showAlone( r);
    r.rect = NSMakeRect( 10, 10, 4, 4);
    NSDictionary *summary = [r dataString];
    double m = r.median;
    check( isfinite( m));
    check( [summary[@"MedianUnit"] isEqual: @"HU"] && [summary[@"Median"] doubleValue] == m && [summary[@"MedianAvailable"] boolValue]);
    NSArray *fields = [[r description] componentsSeparatedByString: @"\t"];
    check( fields.count == 8 && [fields[ 6] isEqual: [NSString stringWithFormat: @"%.3f", m]] && [fields[ 7] isEqual: @"HU"]);
    [r setStatisticsLines: 3 mean: 1 sdev: 1 sum: 1 median: m min: 0 max: 2 skewness: 0 kurtosis: 0 unit: @" HU " fused: NO];
    check( [r.textualBoxLine3 containsString: [NSString stringWithFormat: @"Median: %.3f HU", m]]);
    view.curDCM.SUVConverted = YES;
    check( [[r dataString][@"MedianUnit"] isEqual: @"SUV"]);
    // No pixel inside: no median.
    ROI *empty = newROI( tROI);
    showAlone( empty);
    empty.rect = NSMakeRect( 10, 10, 0, 0);
    NSDictionary *none = [empty dataString];
    check( isnan( empty.median));
    check( ![none[@"MedianAvailable"] boolValue] && !none[@"Median"]);
    check( [[empty description] hasSuffix: @"\tN/A\tSUV"]);
    [empty setStatisticsLines: 3 mean: 1 sdev: 1 sum: 1 median: empty.median min: 0 max: 2 skewness: 0 kurtosis: 0 unit: @" HU " fused: NO];
    check( [empty.textualBoxLine3 containsString: @"Median: N/A HU"]);
    [window release];
    printf( "PASS: the ROI's label, export and description carry the median, N/A without one, in the image's unit\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
