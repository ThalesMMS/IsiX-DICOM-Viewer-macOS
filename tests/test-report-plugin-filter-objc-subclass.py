#!/usr/bin/env python3
"""A report plugin's Objective-C subclass of ReportPluginFilter loads and works.

The Horos and OsiriX SDK gave report plugins (pluginType "Report") a base class
of their own, ReportPluginFilter, a PluginFilter with the three report messages.
A plugin built with it, linked with -undefined dynamic_lookup, looks the class
up by name when it loads: without _OBJC_CLASS_$_ReportPluginFilter in the
application the bundle does not load at all ("symbol not found in flat
namespace"). The class is declared by ReportPluginFilter.h and implemented by
ReportPluginFilter.swift (@objc @implementation), an Objective-C class for the
runtime, as PluginFilter is.

The shipped PluginFilter.swift and ReportPluginFilter.swift and the interfaces
of their headers are compiled here into a host executable, with a stand-in
ViewerController; a bundle whose principal class subclasses ReportPluginFilter,
declared as the former SDK declared it, is built as the former plugins were and
loaded by the host, which checks that:

- the bundle loads, and its principal class descends from the host's
  ReportPluginFilter, itself a PluginFilter;
- +filter, sent as the loader sends it, answers an instance of the subclass,
  whose -initPlugin ran once;
- -createReportForStudy: and -reportDateForStudy:, sent by selector as the
  application sends them to the chosen report plugin and called from Swift
  through PluginFilter's interface, reach the subclass's;
- -deleteReportForStudy:, which the subclass does not override, and the three
  messages on a ReportPluginFilter itself answer NO, NO and nil.

    python3 tests/test-report-plugin-filter-objc-subclass.py [<git revision>]

With a revision, its sources are compiled instead: a revision without the class
fails.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    if len(sys.argv) > 1:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', sys.argv[1] + ':' + path], capture_output=True)
        if shown.returncode != 0:
            print(f'FAIL: {path} is not in {sys.argv[1]}')
            raise SystemExit(1)
        return shown.stdout
    return (ROOT / path).read_bytes()


def interface(path, pattern):
    found = re.search(pattern, read(path).decode('latin1'), re.S | re.M)
    if found is None:
        print(f'FAIL: {path} does not declare the class as the test reads it')
        raise SystemExit(1)
    return found.group(0)


host_header = ('#import <Cocoa/Cocoa.h>\n#import <CoreData/CoreData.h>\n@class ViewerController;\n'
               + interface('Horos/Sources/PluginFilter.h', r'^@interface PluginFilter : NSObject\b.*?^@end\b') + '\n'
               + interface('Horos/Sources/ReportPluginFilter.h', r'^@interface ReportPluginFilter : PluginFilter\b.*?^@end\b') + '\n')

# What the application gives PluginFilter.swift: the open viewers and a viewer's copy.
stand_ins = r'''
import Foundation

@objc(ViewerController) public final class ViewerController: NSObject {
    @objc(getDisplayed2DViewers) public class func getDisplayed2DViewers() -> NSMutableArray! { NSMutableArray() }
    @MainActor @objc(horosDuplicatedViewerWindow) public func horosDuplicatedViewerWindow() -> ViewerController? { nil }
}
'''

host = r'''
import CoreData
import Foundation

var failed = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: " + what); failed += 1 }
}
/// [target selector: argument] of a method returning BOOL, as Objective-C sends it.
func sendBool(_ target: AnyObject, _ name: String, _ argument: AnyObject?) -> Bool {
    let selector = NSSelectorFromString(name)
    typealias Method = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
    return unsafeBitCast(target.method(for: selector), to: Method.self)(target, selector, argument).boolValue
}

let bundle = Bundle(path: CommandLine.arguments[1])!
do { try bundle.loadAndReturnError() } catch { print("FAIL: the bundle does not load: \(error)"); exit(1) }
guard let principal: AnyClass = bundle.principalClass else { print("FAIL: no principal class"); exit(1) }
check(NSStringFromClass(principal) == "LegacyReport" && class_getSuperclass(principal) == ReportPluginFilter.self
      && class_getSuperclass(ReportPluginFilter.self) == PluginFilter.self,
      "the principal class is the bundle's subclass of the host's ReportPluginFilter, a PluginFilter")

// As the loader makes the filter: [principalClass filter], by message.
let made = (principal as AnyObject).perform(NSSelectorFromString("filter"))?.takeUnretainedValue()
check(made.map { NSStringFromClass(type(of: $0)) } == "LegacyReport", "+filter answers an instance of the subclass")
check((made?.value(forKey: "initPluginCount") as? NSNumber)?.intValue == 1, "-init ran the subclass's -initPlugin once")
guard let filter = made as? PluginFilter else { print("FAIL: +filter did not answer a PluginFilter"); exit(1) }

// As the application sends them to the chosen report plugin: by selector.
let study = NSObject()
check(sendBool(filter, "createReportForStudy:", study) && (filter.value(forKey: "created") as AnyObject?) === study,
      "-createReportForStudy: sent by selector reaches the subclass's, with the study")
check(!sendBool(filter, "deleteReportForStudy:", study), "-deleteReportForStudy:, not overridden, answers NO")
check(filter.perform(NSSelectorFromString("reportDateForStudy:"), with: study)?.takeUnretainedValue() as? Date == Date(timeIntervalSinceReferenceDate: 86400),
      "-reportDateForStudy: sent by selector answers the subclass's date")
// From Swift, through PluginFilter's interface.
check(filter.createReport(forStudy: nil) && filter.reportDate(forStudy: nil) as? Date == Date(timeIntervalSinceReferenceDate: 86400)
      && !filter.deleteReport(forStudy: nil), "Swift calls through PluginFilter's interface reach the subclass's")

// The base class itself: no report made, deleted or dated.
let base = ReportPluginFilter()
check(!sendBool(base, "createReportForStudy:", study) && !sendBool(base, "deleteReportForStudy:", study)
      && base.perform(NSSelectorFromString("reportDateForStudy:"), with: study) == nil && base.reportDate(forStudy: nil) == nil,
      "ReportPluginFilter itself answers NO, NO and nil")
if failed > 0 { exit(1) }
print("ok")
'''

plugin = r'''
#import <Foundation/Foundation.h>
// What the former SDK declared of the two classes; the classes themselves are the host's.
@interface PluginFilter : NSObject
+ (PluginFilter *)filter;
- (void)initPlugin;
@end
@interface ReportPluginFilter : PluginFilter {
}
- (BOOL)createReportForStudy:(id)study;
- (BOOL)deleteReportForStudy:(id)study;
- (NSDate *)reportDateForStudy:(id)study;
@end
@interface LegacyReport : ReportPluginFilter
{
    int initPlugins;
    id created;
}
@end
@implementation LegacyReport
- (void)initPlugin { initPlugins++; }
- (BOOL)createReportForStudy:(id)study
{
    created = study;
    return YES;
}
- (NSDate *)reportDateForStudy:(id)study { return [NSDate dateWithTimeIntervalSinceReferenceDate:86400]; }
- (int)initPluginCount { return initPlugins; }
- (id)created { return created; }
@end
'''


def run(command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


with tempfile.TemporaryDirectory(prefix='horos-plugin-filter-') as temporary:
    work = Path(temporary)
    (work / 'Host.h').write_text(host_header, encoding='latin1')
    (work / 'PluginFilter.swift').write_bytes(read('Horos/Sources/PluginFilter.swift'))
    (work / 'ReportPluginFilter.swift').write_bytes(read('Horos/Sources/ReportPluginFilter.swift'))
    (work / 'StandIns.swift').write_text(stand_ins)
    (work / 'main.swift').write_text(host)
    (work / 'Legacy.m').write_text(plugin)
    legacy = work / 'Legacy.bundle'
    (legacy / 'Contents/MacOS').mkdir(parents=True)
    (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Legacy', 'CFBundleIdentifier': 'org.example.legacy', 'CFBundlePackageType': 'BNDL',
        'NSPrincipalClass': 'LegacyReport'}))
    built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Host', '-import-objc-header', str(work / 'Host.h'),
                 str(work / 'PluginFilter.swift'), str(work / 'ReportPluginFilter.swift'), str(work / 'StandIns.swift'), str(work / 'main.swift'), '-o', str(work / 'host')])
    if built.returncode == 0:
        # As the former plugins were built: Objective-C without ARC, the host's classes found at run time.
        built = run(['xcrun', 'clang', '-bundle', '-fno-objc-arc', '-framework', 'Foundation', '-framework', 'CoreData',
                     '-undefined', 'dynamic_lookup', '-mmacosx-version-min=15.0', str(work / 'Legacy.m'),
                     '-o', str(legacy / 'Contents/MacOS/Legacy')])
    if built.returncode != 0:
        print('FAIL: the host or the plugin does not build: ' + built.stderr[-3000:])
        raise SystemExit(1)
    probe = run([str(work / 'host'), str(legacy)], timeout=60)
    if probe.returncode != 0:
        died = f' (signal {-probe.returncode})' if probe.returncode < 0 else ''
        print((probe.stdout + probe.stderr).strip())
        print(f'FAIL: the host ended with status {probe.returncode}{died}')
        raise SystemExit(1)
print('PASS: a former report plugin\'s Objective-C subclass of ReportPluginFilter loads, is made by +filter and answers the report messages; the base class answers NO, NO and nil')
