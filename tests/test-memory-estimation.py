#!/usr/bin/env python3
"""Run the real estimator with bounded allocation probes and controlled failures.

The estimator (-computeEnoughMemory::) is Swift: ViewerSeriesLoader.enoughMemory
(ViewerSeriesLoader.swift) over IsiXImaging's ViewerMemory.enoughMemory. It is
compiled here as it is, with its malloc and free counted by the probe
allocator (the probes are never written), its @try through the real
HorosObjCException, and the thread operation counted.
"""
from pathlib import Path
import subprocess, tempfile, sys, os
root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
loader = (sources / 'ViewerSeriesLoader.swift').read_text()
a = loader.index('    nonisolated static func enoughMemory(for lists:')
estimator = loader[a:loader.index('\n    }\n', a) + len('\n    }\n')]
estimator = estimator.replace('malloc(', 'probeMalloc(').replace('free($0)', 'probeFree($0)')
a = loader.index('nonisolated func memoryImage(')
reader = loader[a:loader.index('\n}\n', a) + 3]
support = (sources / 'BrowserController+DatabaseSupport.swift').read_text()
a = support.index('    static func attempt(')
attempt = support[a:support.index('\n    }\n', a) + len('\n    }\n')]
bridge = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
@interface NSThread (Test)
@property (copy, nullable) NSString *status;
@property double progress;
- (void)enterOperation;
- (void)exitOperation;
@end
extern int operations;
'''
native = r'''
#import "Bridge.h"
int operations;
@implementation NSThread (Test)
- (void)setStatus:(NSString *)s {} - (NSString *)status { return nil; }
- (void)setProgress:(double)p {} - (double)progress { return 0; }
- (void)enterOperation { operations++; } - (void)exitOperation { operations--; }
@end
'''
code = r'''
import Foundation
nonisolated(unsafe) var live = 0, calls = 0, failAt = 0
nonisolated(unsafe) var largest = 0
func probeMalloc(_ n: Int) -> UnsafeMutableRawPointer? {
    calls += 1; largest = max(largest, n)
    if calls == failAt { return nil }
    live += 1
    return malloc(1)
}
func probeFree(_ p: UnsafeMutableRawPointer?) { if let p { live -= 1; free(p) } }
enum BrowserObjC {
ATTEMPT
}
READER
enum ViewerSeriesLoader {
ESTIMATOR
}
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: " + message); exit(1) } }
func image(_ w: Int64, _ h: Int64, _ f: Int64) -> NSDictionary { ["width": w, "height": h, "numberOfFrames": f, "numberOfSeries": 1] }
func enough(_ lists: [[Any]], _ m: inout UInt) -> Bool { ViewerSeriesLoader.enoughMemory(for: lists, requiredMegabytes: &m) }
var m: UInt = 99
let many = [[Any]](repeating: [], count: 1001)
if CommandLine.arguments.count > 1 { check(enough(many, &m), "many"); exit(0) }
check(enough([], &m) && m == 0 && live == 0, "empty")
check(enough([[image(1024, 1024, 16)]], &m) && m == 64 && live == 0, "multi-frame estimate \(m)")
check(enough(many, &m) && live == 0, "1001 series")
largest = 0
check(enough([[image(65536, 65536, 1)]], &m), "wide")
check(largest > 16 * 1024 * 1024 * 1024 && m >= 16384, "wide probe \(largest) \(m)")
check(!enough([[image(Int64.max, Int64.max, 2)]], &m) && live == 0, "overflow")
check(!enough([[image(0, 512, 1)]], &m) && live == 0, "zero width")
check(!enough([[image(-1, 512, 1)]], &m) && live == 0, "negative width")
calls = 0; failAt = 1
check(!enough([[image(512, 512, 1)]], &m) && live == 0, "first probe fails")
calls = 0; failAt = 3
check(!enough([[image(512, 512, 1)], [image(512, 512, 1)], [image(512, 512, 1)]], &m) && live == 0, "third probe fails")
failAt = 0
let raised = BrowserObjC.attempt { _ = enough([[image(512, 512, 1)], [NSObject()]], &m) }
check(raised != nil, "an unreadable image did not raise")
check(live == 0 && operations == 0, "exception cleanup: live \(live) operations \(operations)")
print("PASS: 1001 series, float-byte estimates, wide dimensions, overflow/invalid metadata, failed probes and exception cleanup")
'''.replace('ATTEMPT', attempt).replace('READER', reader).replace('ESTIMATOR', estimator)
with tempfile.TemporaryDirectory(prefix='horos-memory-estimate-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    (p / 'Bridge.h').write_text(bridge)
    (p / 'native.m').write_text(native)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(p), '-I', str(sources), str(p / 'native.m'), '-o', str(p / 'native.o')],
                   check=True, timeout=300)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(sources), str(sources / 'HorosObjCException.m'), '-o', str(p / 'exception.o')],
                   check=True, timeout=300)
    subprocess.run(['xcrun', 'swiftc', '-import-objc-header', str(p / 'Bridge.h'), '-Xcc', '-I' + str(sources),
                    str(root / 'Modules/IsiXImaging/Sources/ViewerOpening/ViewerOpeningRules.swift'), str(p / 'main.swift'),
                    str(p / 'native.o'), str(p / 'exception.o'), '-o', str(p / 'test')], check=True, timeout=300)
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
    subprocess.run([str(p / 'test')] + sys.argv[2:], check=True, env=env, timeout=60)
