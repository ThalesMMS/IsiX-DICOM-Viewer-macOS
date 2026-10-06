#!/usr/bin/env python3
"""-setMenus goes only to the filters that implement it.

`+[PluginManager setMenus::::]` ends by sending `-setMenus` to every registered
filter. The method is `PluginFilter`'s, and the app's own Swift filters, ROI
Enhancement and T2 Fit Map, are plain NSObjects: at every launch the loop raised
two NSInvalidArgumentExceptions, caught and logged ("***** exception in
+[PluginManager setMenus::::]: -[ROIEnhancementFilter setMenus]: unrecognized
selector").

The shipped loop is compiled here over a filter that implements `-setMenus`, one
that does not, and a plugin whose `-setMenus` raises: the first is called once,
the second is passed over without an exception, and the third's exception is
still caught, each inside the crash guard. PluginManager is Swift:
the loop is compiled with HorosObjCException, which catches what a plugin
raises, and the plugins stay Objective-C.

    python3 tests/test-plugin-set-menus.py [<git revision>]
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
path = str(source_path('PluginManager').relative_to(root))
source = (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path])
          if len(sys.argv) > 1 else (root / path).read_bytes()).decode('utf-8')


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it,
    outside comments and string literals."""
    index, depth, opened = at, 0, False
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
            if index < 0:
                break
            continue
        if text.startswith('/*', index):
            index = text.index('*/', index) + 2
            continue
        if text[index] == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == '\\' else 1
        elif text[index] == '{':
            depth, opened = depth + 1, True
        elif text[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return text[at:index + 1]
        index += 1
    return ''


method = source.index('public class func setMenus(_ filtersMenu: NSMenu!, _ roisMenu: NSMenu!, _ othersMenu: NSMenu!, _ dbMenu: NSMenu!)')
start = source.index('let pluginEnum = Registry.plugins?.objectEnumerator()', method)
loop = source.index('while let pluginFilter = pluginEnum?.nextObject() {', start)
body = source[start:start + len(swift_block(source, start))]
if not body.rstrip().endswith('}') or loop > start + len(body):
    print('FAIL: the -setMenus loop is not where it was')
    raise SystemExit(1)

plugins = r'''
#import <Foundation/Foundation.h>
@interface PluginFilter : NSObject
- (void)setMenus;
@end
@implementation PluginFilter
- (void)setMenus {}
@end
// A plugin that makes its menu changes.
@interface MenuPlugin : PluginFilter
@property int calls;
@end
@implementation MenuPlugin
- (void)setMenus { self.calls++; }
@end
// A plugin whose menu changes fail: still caught, never stops the loop.
@interface FailingPlugin : PluginFilter
@end
@implementation FailingPlugin
- (void)setMenus { [NSException raise:@"PluginFailure" format:@"a plugin's own failure"]; }
@end
// What ROIEnhancementFilter and T2FitMapFilter are: registered filters that are not PluginFilters.
@interface NativeFilter : NSObject
@end
@implementation NativeFilter
@end
'''

code = r'''
import Foundation

// The loop logs what it catches: counted here.
var guards = 0, openGuards = 0, logged = 0
func NSLog(_ format: String, _ args: CVarArg...) {
    logged += 1
    FileHandle.standardError.write((String(format: format, arguments: args) + "\n").data(using: .utf8)!)
}
enum ObjC {
    static func arg(_ value: Any?) -> CVarArg { return (value as AnyObject?) as? NSObject ?? ("(null)" as NSString) }
    static func exception(_ error: Error) -> NSException? { return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException }
}
enum Registry {
    static var plugins: NSMutableDictionary? = nil
}
@objc(PluginManager) final class PluginManager: NSObject {
    @objc(startProtectForCrashWithFilter:) class func startProtectForCrash(withFilter filter: Any!) { guards += 1; openGuards += 1 }
    @objc class func endProtectForCrash() { openGuards -= 1 }
    @objc class func runLoop() {
BODY
    }
}

let menu = MenuPlugin()
Registry.plugins = NSMutableDictionary(dictionary: ["Menu plugin": menu, "ROI Enhancement": NativeFilter(), "T2 Fit Map": NativeFilter(),
                                                    "Failing plugin": FailingPlugin()])
PluginManager.runLoop()
var failed = 0
if menu.calls != 1 { print("FAIL: the plugin that implements -setMenus was called \(menu.calls) times"); failed += 1 }
if logged != 1 { print("FAIL: \(logged) exceptions logged, only the failing plugin's expected"); failed += 1 }
if guards != 4 || openGuards != 0 { print("FAIL: \(guards) crash guards opened, \(openGuards) left open"); failed += 1 }
if failed > 0 { exit(1) }
print("ok")
'''.replace('BODY', body)

with tempfile.TemporaryDirectory(prefix='horos-set-menus-') as temporary:
    work = Path(temporary)
    (work / 'plugins.m').write_text(plugins)
    (work / 'plugins.h').write_text('#import "HorosObjCException.h"\n' + plugins[:plugins.index('@implementation PluginFilter')]
                                    + '@interface MenuPlugin : PluginFilter\n@property int calls;\n@end\n'
                                    + '@interface FailingPlugin : PluginFilter\n@end\n@interface NativeFilter : NSObject\n@end\n')
    (work / 'main.swift').write_text(code)
    built = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', str(work / 'plugins.m'), '-o', str(work / 'plugins.o')],
                           capture_output=True, text=True)
    if built.returncode == 0:
        built = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                                str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(work / 'exception.o')],
                               capture_output=True, text=True)
    if built.returncode == 0:
        built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'SetMenus', '-import-objc-header', str(work / 'plugins.h'),
                                '-Xcc', '-I' + str(root / 'Horos/Sources'), str(work / 'main.swift'),
                                str(work / 'plugins.o'), str(work / 'exception.o'), '-o', str(work / 'probe')],
                               capture_output=True, text=True)
    if built.returncode != 0:
        print('FAIL: the loop does not build: ' + built.stderr[-2000:])
        raise SystemExit(1)
    run = subprocess.run([str(work / 'probe')], capture_output=True, text=True, timeout=30)
    if run.returncode != 0:
        print((run.stdout + run.stderr).strip())
        raise SystemExit(1)
print('-setMenus: sent to the plugin that implements it, not to the native filters; a plugin failure still caught')
