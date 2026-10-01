#!/usr/bin/env python3
"""The crash reporter finds the reports the system writes today.

The original finder looks for `<executable>_*.crash`. The system now writes
`<executable>-<date>.ips`, so after a crash nothing was found and the crash
window never opened. The host selects its own finder: the former files and the
`.ips` reports of this application's crashes - by the process name, the bundle
identifier and the bug type in the report's first line - and, for the crash
tab, the readable lines of a report ahead of its JSON.

The finder selected by the real build is compiled and run on synthetic reports
in a disposable folder.
"""
from pathlib import Path
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('feedback_prepare', root / 'Horos/Scripts/FeedbackReporter/prepare.py')
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


MAIN = r'''
#import <Foundation/Foundation.h>
#import "FRCrashLogFinder.h"
@interface FRCrashLogFinder (Host)
+ (NSArray *)crashLogsInDirectories:(NSArray<NSURL *> *)directories since:(nullable NSDate *)date baseName:(NSString *)baseName bundleIdentifier:(nullable NSString *)identifier;
+ (nullable NSString *)textOfReportAtURL:(NSURL *)url;
@end
int main(int argc, const char **argv) {
    (void)argc;
    @autoreleasepool {
        NSURL *folder = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSDate *since = [NSDate dateWithTimeIntervalSince1970:atof(argv[2])];
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSArray *found = [FRCrashLogFinder crashLogsInDirectories:@[folder] since:since baseName:@"Horos" bundleIdentifier:@"org.example.horos"];
        out[@"since"] = [found valueForKey:@"lastPathComponent"];
        found = [FRCrashLogFinder crashLogsInDirectories:@[folder] since:nil baseName:@"Horos" bundleIdentifier:@"org.example.horos"];
        out[@"all"] = [found valueForKey:@"lastPathComponent"];
        found = [FRCrashLogFinder crashLogsInDirectories:@[folder] since:nil baseName:@"Horos" bundleIdentifier:nil];
        out[@"anyBundle"] = [found valueForKey:@"lastPathComponent"];
        out[@"missingFolder"] = [FRCrashLogFinder crashLogsInDirectories:@[[folder URLByAppendingPathComponent:@"none"]] since:nil baseName:@"Horos" bundleIdentifier:nil];
        for (NSString *name in @[@"Horos-2026-10-01-120000.ips", @"Horos_2026-09-30-080000_host.crash", @"Horos-2026-10-01-150000.ips", @"Horos-2026-10-01-160000.ips"]) {
            NSString *text = [FRCrashLogFinder textOfReportAtURL:[folder URLByAppendingPathComponent:name]];
            out[[@"text:" stringByAppendingString:name]] = text ?: [NSNull null];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
        fwrite(data.bytes, 1, data.length, stdout);
    }
    return 0;
}
'''


def report(name='Horos', bundle='org.example.horos', bug_type='309', body=True):
    header = {'app_name': name, 'timestamp': '2026-10-01 12:00:00.00 -0300', 'app_version': '4.0.1', 'build_version': '1234',
              'bundleID': bundle, 'bug_type': bug_type, 'os_version': 'macOS 27.0.1 (26A434)', 'name': name}
    if bundle is None:
        del header['bundleID']
    text = json.dumps(header) + '\n'
    if body:
        text += json.dumps({
            'procName': name, 'pid': 4321, 'captureTime': '2026-10-01 12:00:00.1234 -0300',
            'exception': {'type': 'EXC_BAD_ACCESS', 'signal': 'SIGSEGV', 'codes': '0x0000000000000001, 0x0000000000000000'},
            'termination': {'indicator': 'Segmentation fault: 11'}, 'faultingThread': 1,
            'threads': [{'frames': [{'imageIndex': 1, 'symbol': 'mach_msg', 'symbolLocation': 8, 'imageOffset': 100}]},
                        {'triggered': True, 'frames': [{'imageIndex': 0, 'symbol': '-[Viewer draw]', 'symbolLocation': 24, 'imageOffset': 4096},
                                                       {'imageIndex': 1, 'imageOffset': 8192},
                                                       {'imageIndex': 9, 'symbol': 'start', 'symbolLocation': 0, 'imageOffset': 1}]}],
            'usedImages': [{'name': 'Horos', 'base': 4294967296}, {'name': 'libsystem_kernel.dylib', 'base': 6442450944}],
        }, indent=2) + '\n'
    return text


with tempfile.TemporaryDirectory(prefix='horos-crash-finder-') as scratch:
    work = Path(scratch)
    selected = selection.prepare(root / 'FeedbackReporter', work / 'selected')
    main = selected / 'Sources/Main'
    finder = (main / 'FRCrashLogFinder.m').resolve()
    require(finder == (root / 'Horos/FeedbackReporter/FRCrashLogFinder.m').resolve(), 'the build does not select the host\'s crash report finder')
    require('FRCrashLogFinder.m' in selection.HOST_SOURCES and len(selection.HOST_SOURCES) == 4, 'the host selection is not the four expected sources')
    record = json.loads((selected / 'BuildSource.json').read_text())
    require('FRCrashLogFinder.m' in record['hostSources'], 'the build record does not name the host\'s finder')

    reports = work / 'DiagnosticReports'
    reports.mkdir()
    base = 1790000000                      # the date of the last check; files are dated around it
    files = {                              # name: (text, seconds after the last check)
        'Horos_2026-09-30-080000_host.crash': ('Process: Horos [1]\nException Type: EXC_CRASH (SIGABRT)\n', 100),
        'Horos-2026-10-01-120000.ips': (report(), 200),
        'Horos-2026-10-01-130000.ips': (report(bundle='org.example.other'), 300),      # another application of the same name
        'HorosHelper-2026-10-01-131500.ips': (report(name='HorosHelper'), 310),      # another process
        'Horos-Helper-2026-10-01-133000.ips': (report(name='Horos-Helper'), 320),    # shares the prefix, not the name
        'Horos-2026-10-01-140000.ips': (report(bug_type='298'), 400),                # not a crash
        'Horos-2026-10-01-150000.ips': ('this is not a report\n', 500),
        'Horos-2026-10-01-160000.ips': (report(bundle=None, body=False), 600),       # a header alone, without a bundle
        'Horos-2026-09-01-090000.ips': (report(), -5000),                            # before the last check
        'Horos_2026-08-01-090000_host.crash': ('Process: Horos [2]\n', -9000),
        'Other_2026-10-01-000000_host.crash': ('Process: Other [3]\n', 700),
        'Horos-2026-10-01-170000.txt': (report(), 800),
    }
    for name, (text, offset) in files.items():
        path = reports / name
        path.write_text(text)
        os.utime(path, (base + offset, base + offset))
    (reports / 'Horos-2026-10-01-180000.ips').mkdir()                                # a folder is not a report
    source = work / 'main.m'
    source.write_text(MAIN)
    binary = work / 'finder'
    built = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Wexplicit-ownership-type', '-Wstrict-selector-match', '-Werror', '-I', str(main), str(source), str(finder),
                            '-framework', 'Cocoa', '-o', str(binary)], capture_output=True, text=True, timeout=300)
    require(built.returncode == 0, 'the host finder does not compile: ' + built.stderr[-800:])
    if built.returncode == 0:
        ran = subprocess.run([str(binary), str(reports), str(base)], capture_output=True, text=True, timeout=60)
        require(ran.returncode == 0, 'the finder failed: ' + ran.stderr[-400:])
        out = json.loads(ran.stdout) if ran.returncode == 0 else {}
        # Since the last check, oldest first: the former file, this application's crash, and the report without a bundle.
        require(out.get('since') == ['Horos_2026-09-30-080000_host.crash', 'Horos-2026-10-01-120000.ips', 'Horos-2026-10-01-160000.ips'],
                'since the last check: %s' % out.get('since'))
        require(out.get('all') == ['Horos_2026-08-01-090000_host.crash', 'Horos-2026-09-01-090000.ips', 'Horos_2026-09-30-080000_host.crash',
                                   'Horos-2026-10-01-120000.ips', 'Horos-2026-10-01-160000.ips'], 'without a date: %s' % out.get('all'))
        require('Horos-2026-10-01-130000.ips' in (out.get('anyBundle') or []) and 'Horos-Helper-2026-10-01-133000.ips' not in (out.get('anyBundle') or []),
                'without a bundle identifier to compare: %s' % out.get('anyBundle'))
        require(out.get('missingFolder') == [], 'a missing folder: %s' % out.get('missingFolder'))
        text = out.get('text:Horos-2026-10-01-120000.ips') or ''
        for line in ('Process: Horos [4321]', 'Identifier: org.example.horos', 'Version: 4.0.1 (1234)', 'OS Version: macOS 27.0.1 (26A434)',
                     'Exception Type: EXC_BAD_ACCESS (SIGSEGV)', 'Termination Reason: Segmentation fault: 11', 'Thread 1 Crashed:'):
            require(line in text, 'the readable lines of the report lack «%s»' % line)
        frames = [l.split() for l in text.split('Thread 1 Crashed:\n')[1].split('\n\n')[0].splitlines()] if 'Thread 1 Crashed:\n' in text else []
        require(frames[:3] == [['0', 'Horos', '-[Viewer', 'draw]', '+', '24'], ['1', 'libsystem_kernel.dylib', 'image', 'offset', '8192'],
                               ['2', '???', 'start', '+', '0']], 'the crashed thread reads %s' % frames)
        require('mach_msg' not in text.split('{"app_name"')[0], 'a thread that did not crash is listed as the crashed one')
        require(text.endswith(files['Horos-2026-10-01-120000.ips'][0]), 'the report as the system wrote it does not follow its readable lines')
        require(out.get('text:Horos_2026-09-30-080000_host.crash') == files['Horos_2026-09-30-080000_host.crash'][0], 'a .crash file is not shown as it is')
        require(out.get('text:Horos-2026-10-01-150000.ips') == 'this is not a report\n', 'a report that cannot be parsed is not shown as it is')
        alone = out.get('text:Horos-2026-10-01-160000.ips') or ''
        require(alone.startswith('Process: Horos\n') and 'Thread' not in alone.split('{"app_name"')[0], 'a header without a report reads %r' % alone[:120])

# The framework is made again when a selected source changes: its build phase
# had outputs and no inputs, so a changed host source never reached the product.
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
phase = project[project.index('F35B0D84289535B6008ABE3E /* Make */ = {'):]
phase = phase[:phase.index('shellScript')]
for name in selection.HOST_SOURCES:
    require('"$(SRCROOT)/Horos/FeedbackReporter/%s"' % name in phase, 'the framework is not rebuilt when %s changes' % name)
for name in ('Make.sh', 'prepare.py', 'Framework.project', 'upstream.json'):
    require('"$(SRCROOT)/Horos/Scripts/FeedbackReporter/%s"' % name in phase, 'the framework is not rebuilt when %s changes' % name)

# The crash tab asks the finder for the text.
controller = (root / 'Horos/FeedbackReporter/FRFeedbackController.m').read_text()
require('[FRCrashLogFinder textOfReportAtURL:latestCrashFileURL]' in controller, 'the crash tab does not show the finder\'s text of the report')
# The provider's tree is as pinned: -prepare refuses a changed one, and the original finder is still the .crash-only one.
original = (root / 'FeedbackReporter/Sources/Main/FRCrashLogFinder.m').read_text()
require('@"ips"' not in original and 'extension:@"crash"' in original, 'the provider\'s own finder was edited')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the host finder takes this application\'s .crash and .ips crash reports since the last check, and reads an .ips report for the crash tab')
