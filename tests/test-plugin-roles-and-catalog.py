#!/usr/bin/env python3
"""Plugin roles, the "No plugins" items and the plugin window's update download.

Six defects found while PluginManager and PluginManagerController moved to
Swift, which kept them:

1. The "No plugins available for this menu" items target the PluginManager
   class, but -noPlugins: was an instance method. The class did not answer
   it, so the menus disabled the items and choosing one did nothing. It is a
   class method now.
2. A plugin whose Info.plist had no pluginType was loaded as a Pre-Process
   filter and a Report. The loader that read pluginType is gone with the
   former plugin API; nothing registers a plugin by it any more.
3. The availability lookups checked `count >= 1` before reading index 1 and
   `>= 2` before index 2. There are always three, so nothing failed, but the
   guards now say `> 1` and `> 2`.
4. +releaseInstanciedObjectsOfClass: had no caller, and +unloadPluginBundle:
   was empty, called only by a loop over the loaded bundles at discovery and
   by +unloadPluginWithName:. Both are gone; +unloadPluginWithName:, which
   plugins may call, stays and still does nothing.
5. and 6. The catalog's installed check and the catalog web views' navigation
   decision left the app with the Horos catalog tab of the Plugins Manager.

The plugin download the window keeps for updates is compiled with its
URLSession transfer and run against loopback addresses that refuse it.

The shipped Swift is compiled over doubles: +setMenus:::: with +sortMenu:, and
the -noPlugins: declaration, over empty registries. Nothing touches a real
plugins folder or the network.

    python3 tests/test-plugin-roles-and-catalog.py [<git revision>]
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(name):
    path = 'Horos/Sources/' + name
    return (subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path])
            if revision else (root / path).read_bytes()).decode('utf-8')


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


def block(text, marker):
    at = text.find(marker)
    if at < 0:
        print(f'FAIL: {marker!r} is not where it was')
        raise SystemExit(1)
    return swift_block(text, at)


def build(work, name, swift, header, objc=None, links=()):
    """Compile `swift` with `header` bridged; returns the executable or None."""
    (work / (name + '.h')).write_text(header)
    # main.swift, so that its top-level code stays the entry point beside the
    # second file.
    (work / (name + '-src')).mkdir(exist_ok=True)
    (work / (name + '-src') / 'main.swift').write_text(swift)
    objects = list(links)
    if objc:
        (work / (name + '.m')).write_text(objc)
        built = subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(root / 'Horos/Sources'),
                                str(work / (name + '.m')), '-o', str(work / (name + '.o'))],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print(f'FAIL: {name} doubles do not build: ' + built.stderr[-2000:])
            return None
        objects.append(str(work / (name + '.o')))
    built = subprocess.run(['xcrun', 'swiftc', '-module-name', name, '-import-objc-header', str(work / (name + '.h')),
                            '-Xcc', '-I' + str(root / 'Horos/Sources'), str(work / (name + '-src') / 'main.swift'),
                            # The main-actor callbacks the plugin code uses.
                            str(root / 'Horos/Sources/MainActorCallbacks.swift')] + objects
                           + ['-o', str(work / name)], capture_output=True, text=True)
    if built.returncode != 0:
        print(f'FAIL: {name} does not build: ' + built.stderr[-3000:])
        return None
    return work / name


def run(executable):
    if executable is None:
        return 1
    result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
    output = (result.stdout + result.stderr).strip()
    if output:
        print(output)
    return 0 if result.returncode == 0 else 1


manager = source('PluginManager.swift')
controller = source('PluginManagerController.swift')
failures = 0

# ---------------------------------------------------------------- 1 and 2

registry = block(manager, 'fileprivate enum Registry {')
objc_helpers = block(manager, 'fileprivate enum ObjC {')
set_menus = block(manager, '@objc(setMenus::::)')
sort_menu = block(manager, '@objc(sortMenu:)')
no_plugins_at = manager.find('@objc(noPlugins:)')
no_plugins = manager[no_plugins_at:manager.index('{', no_plugins_at)] + '{ noPluginsCalls += 1 }'
if no_plugins_at < 0:
    print('FAIL: -noPlugins: is not where it was')
    raise SystemExit(1)
if 'forKey: "pluginType"' in manager:
    print('FAIL: PluginManager.swift still registers plugins by their pluginType')
    raise SystemExit(1)

filters_objc = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
// What a plugin's principal class is to the loader: +filter and -filterImage:.
@interface SyntheticFilter : NSObject
+ (id)filter;
- (long)filterImage:(NSString *)menuName;
@end
'''
filters_impl = r'''
#import "roles.h"
@implementation SyntheticFilter
+ (id)filter { return [self new]; }
- (long)filterImage:(NSString *)menuName { return 0; }
@end
'''

roles_swift = r'''
import Cocoa

var noPluginsCalls = 0

REGISTRY
OBJC

// The browser that answers Database and Report items: none in this process.
enum BrowserController { static func currentBrowser() -> AnyObject? { return nil } }
enum NativeFilterMenus { static func addItems(for plugins: NSMutableDictionary, filtersMenu: NSMenu, roisMenu: NSMenu) {} }
enum MenuShortcutCatalog { static func applyStoredAssignments(to menus: [NSMenu]) {} }

@objc(PluginManager) final class PluginManager: NSObject {
    @objc(startProtectForCrashWithFilter:) class func startProtectForCrash(withFilter filter: Any!) {}
    @objc(startProtectForCrashWithPath:) class func startProtectForCrash(withPath path: String!) {}
    @objc class func endProtectForCrash() {}
    // The commands of plugins of the API version 1 are tested apart.
    class func addIsiXPluginMenuItems(_ filtersMenu: NSMenu?, _ roisMenu: NSMenu?, _ othersMenu: NSMenu?, _ dbMenu: NSMenu?) {}

    SORTMENU

    SETMENUS

    NOPLUGINS
}

Registry.pluginsBundleDictionnary = NSMutableDictionary()
Registry.plugins = NSMutableDictionary()
Registry.pluginsDict = NSMutableDictionary()
Registry.fileFormatPlugins = NSMutableDictionary()
Registry.preProcessPlugins = NSMutableArray(capacity: 0)
Registry.reportPlugins = NSMutableDictionary()
Registry.pluginsNames = NSMutableDictionary()
Registry.fusionPlugins = NSMutableArray(capacity: 0)
Registry.fusionPluginsMenu = NSMenu(title: "")
Registry.fusionPluginsMenu!.insertItem(withTitle: "Select a fusion plug-in", action: nil, keyEquivalent: "", at: 0)

var failed = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failed += 1 }
}

let filters = NSMenu(title: "Filters"), rois = NSMenu(title: "ROIs"), others = NSMenu(title: "Others"), database = NSMenu(title: "Database")
PluginManager.setMenus(filters, rois, others, database)

// "No plugins available for this menu": the ROI and database menus are empty.
for menu in [rois, database] {
    guard let placeholder = menu.items.first, menu.items.count == 1 else {
        check(false, "the \(menu.title) menu has \(menu.items.count) items, not the one placeholder"); continue
    }
    let target = placeholder.target as AnyObject?
    let action = placeholder.action ?? NSSelectorFromString("none")
    check(target?.responds(to: action) == true,
          "the \(menu.title) menu's \"\(placeholder.title)\" item targets \(String(describing: target)), which does not answer \(NSStringFromSelector(action)): the menu disables it")
    if target?.responds(to: action) == true {
        let before = noPluginsCalls
        _ = target?.perform(action, with: placeholder)
        check(noPluginsCalls == before + 1, "choosing the \(menu.title) menu's placeholder does not reach -noPlugins:")
    }
}
if failed > 0 { exit(1) }
'''

# ---------------------------------------------------------------- the update download

download_plugin = block(controller, 'private func downloadPlugin(from downloadURL: String?)')
download_swift = r'''
import Foundation
var destinations: [String] = []
final class NSURLDownload: NSObject {
    init(request: URLRequest, delegate: NSObject) { super.init() }
    func setDestination(_ path: String, allowOverwrite: Bool) { destinations.append(path) }
}
extension FileManager { func tmpDirPath() -> String { "/tmp/synthetic-plugins" } }
extension Thread { var status: String? { get { nil } set {} } }
final class ThreadsManager {
    static func `default`() -> ThreadsManager { ThreadsManager() }
    func addThreadAndStart(_ thread: Thread) {} // no app thread is started
}
final class DownloadController: NSObject {
    let downloadingPlugins = NSMutableDictionary()
    static func request(forURLString string: String?) -> URLRequest { URLRequest(url: URL(string: string!)!) }
    @objc nonisolated func fakeThread(_ object: Any?) {}
DOWNLOAD
    func exercise(_ string: String) { downloadPlugin(from: string) }
}
let downloader = DownloadController()
downloader.exercise("https://example.invalid/package%20%2B%2520.zip?ticket=%2F#fragment")
downloader.exercise("https://example.invalid/%E6%97%A5%E6%9C%AC.zip")
precondition(destinations == ["/tmp/synthetic-plugins/package +%20.zip", "/tmp/synthetic-plugins/日本.zip"])
downloader.exercise("https://example.invalid/%2e%2e")
downloader.exercise("https://example.invalid/a%2Fb.zip")
downloader.exercise("https://example.invalid/folder/")
precondition(destinations.count == 2)
print("PASS: actual plugin download uses one decoded path segment, excludes query/fragment and rejects directory escapes")
'''
# The transport is now URLSession. Compile its actual production helper;
# filename checks use loopback port 1 (no external server or real package),
# then cancel the disposable transfers. UI/activity recording stays a double.
if 'private final class PluginPackageDownload:' in controller:
    # The class alone: the file goes on past it, to an #endif.
    package_helper = '\n'.join(block(controller, marker) for marker in (
        'private final class PluginPackageDownload:', 'private final class PluginDownloadActivity:'))
    download_swift = r'''
import AppKit
import Synchronization
extension FileManager { func tmpDirPath() -> String { "/tmp/synthetic-plugins" } }
extension Thread {
    var status: String? { get { nil } set {} }
    var supportsCancel: Bool { get { false } set {} }
}
final class ThreadsManager {
    static func `default`() -> ThreadsManager { ThreadsManager() }
    func addThreadAndStart(_ thread: Thread) {} // no app activity thread
}
@MainActor final class DownloadController: NSObject {
    private nonisolated let downloadingPlugins = Mutex<[String: PluginPackageDownload]>([:])
    @objc nonisolated func fakeThread(_ object: Any?) {}
    func statusControls(forPath path: String) -> (NSTextField?, NSProgressIndicator?) { (nil, nil) }
    private func finishDownload(_ download: PluginPackageDownload, atPath path: String, error: Error?) {}
DOWNLOAD
    func exercise(_ string: String) { downloadPlugin(from: string) }
    var paths: [String] { downloadingPlugins.withLock { Array($0.keys).sorted() } }
    func cancelAll() {
        let downloads = downloadingPlugins.withLock { value in
            let pending = Array(value.values); value.removeAll(); return pending
        }
        for download in downloads { download.cancel() }
    }
}
HELPER
MainActor.assumeIsolated {
    let downloader = DownloadController()
    defer { downloader.cancelAll() }
    downloader.exercise("http://127.0.0.1:1/package%20%2B%2520.zip?ticket=%2F#fragment")
    downloader.exercise("http://127.0.0.1:1/%E6%97%A5%E6%9C%AC.zip")
    let expected = ["/tmp/synthetic-plugins/package +%20.zip", "/tmp/synthetic-plugins/日本.zip"].sorted()
    precondition(downloader.paths == expected)
    downloader.exercise("http://127.0.0.1:1/%2e%2e")
    downloader.exercise("http://127.0.0.1:1/a%2Fb.zip")
    downloader.exercise("http://127.0.0.1:1/folder/")
    precondition(downloader.paths == expected)
    print("PASS: actual plugin download uses one decoded path segment, excludes query/fragment and rejects directory escapes")
}
'''.replace('HELPER', package_helper)

with tempfile.TemporaryDirectory(prefix='horos-plugin-roles-') as temporary:
    work = Path(temporary)

    exception = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                                str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(work / 'exception.o')],
                               capture_output=True, text=True)
    if exception.returncode != 0:
        print('FAIL: HorosObjCException does not build: ' + exception.stderr[-2000:])
        raise SystemExit(1)

    code = (roles_swift.replace('REGISTRY', registry).replace('OBJC', objc_helpers, 1)
            .replace('SORTMENU', sort_menu).replace('SETMENUS', set_menus).replace('NOPLUGINS', no_plugins))
            
    status = run(build(work, 'roles', code, filters_objc, filters_impl, [str(work / 'exception.o')]))
    if status == 0:
        print('PASS: nothing registers by pluginType, and "No plugins" reaches +noPlugins:')
    failures += status

    status = run(build(work, 'download', download_swift.replace('DOWNLOAD', download_plugin),
                       '#import <Foundation/Foundation.h>\n'))
    failures += status

# ---------------------------------------------------------------- 3 and 4

guards = re.findall(r'availabilities\.count (>=|>) (\d+) && [^\n]*?availabilities\[(\d+)\]', manager)
unsafe = [g for g in guards if int(g[2]) >= (int(g[1]) if g[0] == '>=' else int(g[1]) + 1)]
if len(guards) < 4 or unsafe:
    print(f'FAIL: {len(guards)} availability guards found, {len(unsafe)} checking a count that does not cover the index read: '
          + ', '.join(f'count {op} {n} before [{i}]' for op, n, i in unsafe))
    failures += 1
else:
    print('PASS: every availability guard covers the index it reads')

dead = [code for code in ('@objc(releaseInstanciedObjectsOfClass:)', 'releaseInstanciedObjects(',
                          '@objc(unloadPluginBundle:)', 'unloadPluginBundle(')
        if code in manager]
if dead or '@objc(unloadPluginWithName:)' not in manager:
    print('FAIL: ' + (f'dead code remains: {", ".join(dead)}' if dead else '+unloadPluginWithName:, which plugins may call, is gone'))
    failures += 1
else:
    print('PASS: +releaseInstanciedObjectsOfClass: and +unloadPluginBundle: are gone; +unloadPluginWithName: stays')

raise SystemExit(1 if failures else 0)
