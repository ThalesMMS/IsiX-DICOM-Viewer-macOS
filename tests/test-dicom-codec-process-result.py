#!/usr/bin/env python3
"""The codec launchers report each way a Decompress helper can fail, as before.

+[DicomDatabase compressDicomFilesAtPaths:intoDirAtPath:] and its decompressing
twin ran the helper chunk by chunk in DicomDatabase+DCMTK.mm; they are Swift
(DicomDatabase+DCMTK.swift) and the run is IsiXDatabase's CompressionHelperRun.
This runs the former Objective-C methods (history_reference; the tree or HEAD
while they still have them) and the module with the same stand-in helper, in
six scenarios each way - success, a failed exit, a helper that cannot start, a
timeout, a crash and a failure in an earlier chunk - and checks that both say
the same, and what they say.

    python3 tests/test-dicom-codec-process-result.py [REV]
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # noqa: E402  the harness's preferences stay in its own process
import history_reference  # noqa: E402

root = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/DicomDatabase+DCMTK.mm'
RULE = root / 'Modules/IsiXDatabase/Sources/CompressionHelperRun.swift'
if len(sys.argv) > 1:
    source = subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + PATH])
elif (root / PATH).exists():
    source = (root / PATH).read_bytes()
else:
    head = subprocess.run(['git', '-C', str(root), 'show', 'HEAD:' + PATH], capture_output=True)
    revision = None if head.returncode == 0 else history_reference.before_removal(PATH)
    if head.returncode != 0 and revision is None:
        print('skipped: needs the history that has ' + PATH)
        raise SystemExit(2)
    source = head.stdout if head.returncode == 0 else history_reference.show(revision, PATH)
source = source.decode('latin1')

methods = []
for name, arg in [('compress', 'paths'), ('decompress', 'files')]:
    start = source.index(f'+(BOOL){name}DicomFilesAtPaths:(NSArray*){arg} intoDirAtPath:')
    end = source.index('    //', source.index('[thread exitOperation];', start))
    methods.append(source[start:end] + '}\n')
program = r'''
#import <Foundation/Foundation.h>
static int scenario, launches, waits;
@interface NSThread (Test)
@property double progress;
- (void)enterOperation;
- (void)exitOperation;
@end
@implementation NSThread (Test)
- (double)progress{return 0;}
- (void)setProgress:(double)value{}
- (void)enterOperation{}
- (void)exitOperation{}
@end
@interface TestTask : NSObject
- (void)setLaunchPath:(id)p;
- (void)setArguments:(id)a;
- (void)launch;
- (BOOL)isRunning;
- (void)terminate;
- (void)waitUntilExit;
- (int)terminationStatus;
- (NSTaskTerminationReason)terminationReason;
@end
@implementation TestTask
- (void)setLaunchPath:(id)p{}
- (void)setArguments:(id)a{}
- (void)launch{launches++;if(scenario==2)[NSException raise:@"launch" format:@"missing executable"];}
- (BOOL)isRunning{return scenario==3;}
- (void)terminate{}
- (void)waitUntilExit{waits++;}
- (int)terminationStatus{return scenario==1 || scenario==4 || (scenario==5 && launches==1)?7:0;}
- (NSTaskTerminationReason)terminationReason{return scenario==4?NSTaskTerminationReasonUncaughtSignal:NSTaskTerminationReasonExit;}
@end
@interface TestDate:NSObject
+ (NSTimeInterval)timeIntervalSinceReferenceDate;
@end
@implementation TestDate
+ (NSTimeInterval)timeIntervalSinceReferenceDate{static double now=0;now+=1000;return now;}
@end
#define NSTask TestTask
#define NSDate TestDate
#define CHUNK_SUBPROCESS 1
#define TIMEOUT 1
#define N2LogStackTrace(...) do {} while(0)
#define N2LogExceptionWithStackTrace(...) do {} while(0)
@interface DicomDatabase:NSObject
+ (id)defaultDatabase;
- (NSString*)errorsDirPath;
@end
@implementation DicomDatabase
+ (id)defaultDatabase{return nil;}
- (NSString*)errorsDirPath{return nil;}
METHODS
@end
int main(){@autoreleasepool{
 [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"DELETEFILELISTENER"];
 for(int mode=0;mode<2;mode++)for(scenario=0;scenario<6;scenario++){
  launches=waits=0;
  BOOL ok=mode?[DicomDatabase decompressDicomFilesAtPaths:@[@"a",@"b"] intoDirAtPath:nil]:[DicomDatabase compressDicomFilesAtPaths:@[@"a",@"b"] intoDirAtPath:nil];
  printf("mode=%d scenario=%d result=%d launches=%d\n",mode,scenario,ok,launches);
 }
}}
'''.replace('METHODS', '\n'.join(methods))

SWIFT = r'''
import Foundation
nonisolated(unsafe) var scenario = 0, launches = 0, crashes = 0
struct Missing: Error {}
final class Stand: CompressionHelperProcess {
    func launch() throws { launches += 1; if scenario == 2 { throw Missing() } }
    var isRunning: Bool { scenario == 3 }
    func terminate() {}
    var terminationStatus: Int32 { scenario == 1 || scenario == 4 || (scenario == 5 && launches == 1) ? 7 : 0 }
    var endedOnUncaughtSignal: Bool { scenario == 4 }
}
nonisolated(unsafe) var now = 0.0
let environment = CompressionHelperRun.Environment(
    progress: { _ in }, now: { now += 1000; return now }, sleep: { _ in },
    logStackTrace: { _ in }, logLaunchFailure: { _ in }, crashed: { _ in crashes += 1 })
for mode in 0..<2 {
    for s in 0..<6 {
        scenario = s; launches = 0
        let ok = CompressionHelperRun.run(["a", "b"], mode: mode == 1 ? "decompressList" : "compress", destination: nil,
                                          chunkSize: 1, secondsPerFile: 1, environment: environment) { _ in Stand() }
        print("mode=\(mode) scenario=\(s) result=\(ok ? 1 : 0) launches=\(launches)")
    }
}
print("crashes=\(crashes)")
'''

with tempfile.TemporaryDirectory(prefix='horos-codec-result-') as folder:
    p = Path(folder)
    (p / 'test.m').write_text(program + harness_defaults.OBJC)
    subprocess.run(['xcrun', 'clang', '-Wno-incompatible-pointer-types', '-fsanitize=address', str(p / 'test.m'),
                    '-framework', 'Foundation', '-o', str(p / 'test')], check=True, timeout=300)
    former = subprocess.run([str(p / 'test')], capture_output=True, text=True, check=True, timeout=60).stdout.splitlines()
    (p / 'main.swift').write_text(SWIFT)
    subprocess.run(['xcrun', 'swiftc', str(RULE), str(p / 'main.swift'), '-o', str(p / 'swift')], check=True, timeout=300)
    current = subprocess.run([str(p / 'swift')], capture_output=True, text=True, check=True, timeout=60).stdout.splitlines()

failures = []
expected = ['mode=%d scenario=%d result=%d launches=2' % (mode, s, 1 if s == 0 else 0) for mode in range(2) for s in range(6)]
if former != expected:
    failures.append('the former launchers no longer say what this test expects: %r' % former)
if current[:-1] != former:
    for want, got in zip(former, current):
        if want != got:
            failures.append('former %s, now %s' % (want, got))
if current[-1:] != ['crashes=2']:
    failures.append('a crashed compressing helper is not handed its files once per crash (decompressing ones never): %r'
                    % current[-1:])
for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print('PASS: both codec launchers report exit errors, launch exceptions, timeouts, signals and earlier chunk failure, '
      'as the Objective-C did')
