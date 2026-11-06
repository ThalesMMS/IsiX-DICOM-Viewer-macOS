#!/usr/bin/env python3
"""A plugin's Objective-C subclass of PluginFilter works in the application.

Almost every plugin built for Horos or OsiriX has as its principal class an
Objective-C subclass of the application's PluginFilter, linked with -undefined
dynamic_lookup. Such a subclass has none of the metadata of a Swift class: when
PluginFilter was a Swift class, +filter (self.init()) reached its initializer
through the Swift class's table, which the subclass does not have, and the
process died at the plugin's loading. PluginFilter is now declared by
PluginFilter.h and implemented by PluginFilter.swift (@objc @implementation),
an Objective-C class for the runtime.

The shipped PluginFilter.swift and the class's interface in PluginFilter.h are
compiled here into a host executable, with a stand-in ViewerController; a
bundle whose principal class subclasses PluginFilter, declared as the former SDK
declared it, is built as the former plugins were and loaded by the host, which
checks that:

- +filter, sent as the loader sends it, answers an instance of the subclass,
  and -init ran the subclass's -initPlugin once; so does +filter called from
  Swift;
- -prepareFilter: (the host's) and -filterImage: (the subclass's), sent as the
  menus send them, and -filterImage: and -reportDateForStudy: called from Swift
  through the class's interface, reach the right implementations;
- the methods the subclass inherits answer as PluginFilter's.

    python3 tests/test-plugin-filter-objc-subclass.py [<git revision>]

With a revision, its PluginFilter.swift and PluginFilter.h are compiled instead
(a revision whose header does not declare the class compiles the Swift class as
it was): a revision before the class became Objective-C fails.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SWIFT = 'Horos/Sources/PluginFilter.swift'
HEADER = 'Horos/Sources/PluginFilter.h'


def read(path):
    if len(sys.argv) > 1:
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', sys.argv[1] + ':' + path])
    return (ROOT / path).read_bytes()


swift = read(SWIFT).decode('utf-8')
header = read(HEADER).decode('latin1')
interface = re.search(r'^@interface PluginFilter : NSObject\b.*?^@end\b', header, re.S | re.M)
if interface is None and len(sys.argv) == 1:
    print('FAIL: PluginFilter.h does not declare @interface PluginFilter : NSObject')
    raise SystemExit(1)

host_header = ('#import <Cocoa/Cocoa.h>\n#import <CoreData/CoreData.h>\n@class ViewerController;\n'
               + (interface.group(0) + '\n' if interface else ''))

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
/// [target selector: argument] of a method returning long, as Objective-C sends it.
func sendLong(_ target: AnyObject, _ name: String, _ argument: AnyObject?) -> Int {
    let selector = NSSelectorFromString(name)
    typealias Method = @convention(c) (AnyObject, Selector, AnyObject?) -> Int
    return unsafeBitCast(target.method(for: selector), to: Method.self)(target, selector, argument)
}
func count(_ filter: AnyObject?) -> Int { (filter?.value(forKey: "initPluginCount") as? NSNumber)?.intValue ?? -1 }
func lastMenu(_ filter: AnyObject?) -> String? { filter?.value(forKey: "lastMenu") as? String }

let bundle = Bundle(path: CommandLine.arguments[1])!
do { try bundle.loadAndReturnError() } catch { print("FAIL: the bundle does not load: \(error)"); exit(1) }
guard let principal: AnyClass = bundle.principalClass else { print("FAIL: no principal class"); exit(1) }
check(NSStringFromClass(principal) == "LegacyFilter" && class_getSuperclass(principal) == PluginFilter.self,
      "the principal class is the bundle's subclass of the host's PluginFilter")

// As the loader makes the filter: [principalClass filter], by message.
let made = (principal as AnyObject).perform(NSSelectorFromString("filter"))?.takeUnretainedValue()
check(made.map { NSStringFromClass(type(of: $0)) } == "LegacyFilter", "+filter answers an instance of the subclass")
check(count(made) == 1, "-init ran the subclass's -initPlugin once: \(count(made))")
guard let filter = made as? PluginFilter else { print("FAIL: +filter did not answer a PluginFilter"); exit(1) }

// As the menus run it: -prepareFilter: (the host's), then -filterImage: (the subclass's).
let viewer = ViewerController()
check(sendLong(filter, "prepareFilter:", viewer) == 0 && filter.viewerController === viewer,
      "-prepareFilter: is PluginFilter's and keeps the viewer")
check(sendLong(filter, "filterImage:", "Menu A" as NSString) == 7 && lastMenu(filter) == "Menu A",
      "-filterImage: sent as the menus send it reaches the subclass's")

// From Swift, through the class's interface.
check(filter.filterImage("Menu B") == 7 && lastMenu(filter) == "Menu B", "a Swift call of -filterImage: reaches the subclass's")
check(filter.reportDate(forStudy: nil) as? String == "subclass date", "a Swift call of -reportDateForStudy: reaches the subclass's")
let second = (principal as? PluginFilter.Type)?.filter()
check(second.map { NSStringFromClass(type(of: $0)) } == "LegacyFilter" && count(second) == 1,
      "+filter called from Swift answers an instance of the subclass, initialized once")

// What the subclass inherits answers as PluginFilter's.
check(filter.processFiles(nil) == 0 && filter.report(nil, action: "dateReport") == nil
      && !filter.isCertifiedForMedicalImaging() && filter.viewerControllersList()?.count == 0
      && filter.duplicateCurrent2DViewerWindow() == nil && !filter.deleteReport(forStudy: nil) && !filter.createReport(forStudy: nil),
      "the inherited methods answer as PluginFilter's")
filter.setMenus()
filter.willUnload()
if failed > 0 { exit(1) }
print("ok")
'''

plugin = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
// What the former SDK declared of PluginFilter; the class itself is the host's.
@interface PluginFilter : NSObject
+ (PluginFilter *)filter;
- (long)filterImage:(NSString *)menuName;
- (void)initPlugin;
- (id)reportDateForStudy:(NSManagedObject *)study;
- (long)prepareFilter:(id)vC;
@end
@interface LegacyFilter : PluginFilter
{
    int initPlugins;
    NSString *menu;
}
@end
@implementation LegacyFilter
- (void)initPlugin { initPlugins++; }
- (long)filterImage:(NSString *)menuName
{
    [menu release];
    menu = [menuName copy];
    return 7;
}
- (id)reportDateForStudy:(NSManagedObject *)study { return @"subclass date"; }
- (int)initPluginCount { return initPlugins; }
- (NSString *)lastMenu { return menu; }
- (void)dealloc
{
    [menu release];
    [super dealloc];
}
@end
'''


def run(command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


with tempfile.TemporaryDirectory(prefix='horos-plugin-filter-') as temporary:
    work = Path(temporary)
    (work / 'Host.h').write_text(host_header, encoding='latin1')
    (work / 'PluginFilter.swift').write_text(swift)
    (work / 'StandIns.swift').write_text(stand_ins)
    (work / 'main.swift').write_text(host)
    (work / 'Legacy.m').write_text(plugin)
    legacy = work / 'Legacy.bundle'
    (legacy / 'Contents/MacOS').mkdir(parents=True)
    (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Legacy', 'CFBundleIdentifier': 'org.example.legacy', 'CFBundlePackageType': 'BNDL',
        'NSPrincipalClass': 'LegacyFilter'}))
    built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Host', '-import-objc-header', str(work / 'Host.h'),
                 str(work / 'PluginFilter.swift'), str(work / 'StandIns.swift'), str(work / 'main.swift'), '-o', str(work / 'host')])
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
print('PluginFilter: an Objective-C subclass from a former plugin is made by +filter, runs its -initPlugin and its -filterImage:')
