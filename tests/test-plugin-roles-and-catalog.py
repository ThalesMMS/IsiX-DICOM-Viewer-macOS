#!/usr/bin/env python3
"""Plugin roles, the "No plugins" items and the catalog window's decisions.

Six defects found while PluginManager and PluginManagerController moved to
Swift, which kept them:

1. The "No plugins available for this menu" items target the PluginManager
   class, but -noPlugins: was an instance method. The class did not answer
   it, so the menus disabled the items and choosing one did nothing. It is a
   class method now.
2. A plugin whose Info.plist has no pluginType was loaded as a Pre-Process
   filter, also registered as a Report, and, had it reached the menus, taken
   for a fusion filter: the helper that stands for [pluginType rangeOfString:]
   answered "found" for a nil pluginType, as the zero range of a message to nil
   did. A plugin without pluginType has no role now: it registers by its menu
   titles and lands in the others menu, run by -executeFilter:.
3. The availability lookups checked `count >= 1` before reading index 1 and
   `>= 2` before index 2. There are always three, so nothing failed, but the
   guards now say `> 1` and `> 2`.
4. +releaseInstanciedObjectsOfClass: had no caller, and +unloadPluginBundle:
   was empty, called only by a loop over the loaded bundles at discovery and
   by +unloadPluginWithName:. Both are gone; +unloadPluginWithName:, which
   plugins may call, stays and still does nothing.
5. The catalog's installed check read `alreadyInstalled || sameName ||
   (sameName && sameVersion)`. The last term never counts: an installed plugin
   of the catalog entry's name is that entry, and the version only decides
   between "Plugin already installed" and "Download the new version!". The
   expression is written as that; the behaviour is checked unchanged here.
6. The catalog web views' policy delegate decided twice for a web view that is
   not one of the window's catalogs (use, then use again, or use and also open
   the link in the browser), and never decided for a catalog link or form it
   handled itself. Each navigation now gets exactly one decision. Now
   the catalogs are WKWebViews: the decision is the WKNavigationDelegate's,
   back/forward is cancelled as the former empty back/forward list did, and a
   navigation that arrives after the controller is gone is cancelled.

The shipped Swift is compiled over doubles: the registration branch of
+loadPluginBundle:, +setMenus:::: with +sortMenu:, and the -noPlugins: declaration
over synthetic Info.plist-only bundles in a temporary folder; the controller's
installed check over the real HorosPluginCatalog.h; and the navigation delegate over
WebKit and NSWorkspace doubles, so no page loads and no browser opens. Nothing
touches a real plugins folder or the network.

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
registration_at = manager.find('if ObjC.contains(info?.object(forKey: "pluginType"), "Pre-Process") {')
report_at = manager.find('if ObjC.contains(info?.object(forKey: "pluginType"), "Report") {', registration_at)
if min(no_plugins_at, registration_at, report_at) < 0:
    print('FAIL: the registration branch or -noPlugins: is not where it was')
    raise SystemExit(1)
registration = manager[registration_at:report_at + len(swift_block(manager, report_at))]

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

    SORTMENU

    SETMENUS

    NOPLUGINS

    class func register(info: NSDictionary?, filterClass: AnyClass, plugin: Bundle) {
        REGISTRATION
    }
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

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : BUNDLES
func bundle(_ name: String) -> Bundle {
    let plugin = Bundle(path: (folder as NSString).appendingPathComponent(name + ".horosplugin"))!
    PluginManager.register(info: plugin.infoDictionary as NSDictionary?, filterClass: SyntheticFilter.self, plugin: plugin)
    return plugin
}
let untyped = bundle("Untyped")
_ = bundle("Imaging")
_ = bundle("Fusing")
_ = bundle("Reporting")
_ = bundle("Preprocessing")

// Loading: only the Pre-Process plugin is one, only the Report plugin is one.
check(Registry.preProcessPlugins!.count == 1,
      "\(Registry.preProcessPlugins!.count) Pre-Process filters registered; only the plugin that says Pre-Process is one")
check((Registry.reportPlugins!.allKeys as! [String]).sorted() == ["Reporting"],
      "Report plugins \((Registry.reportPlugins!.allKeys as! [String]).sorted()); only the plugin that says Report is one")
check(Registry.pluginsDict!["Untyped Tool"] as? Bundle == untyped,
      "the plugin without pluginType is not registered by its menu title")

let filters = NSMenu(title: "Filters"), rois = NSMenu(title: "ROIs"), others = NSMenu(title: "Others"), database = NSMenu(title: "Database")
PluginManager.setMenus(filters, rois, others, database)

func item(_ title: String, in menu: NSMenu) -> NSMenuItem? { return menu.items.first { $0.title == title } }

// Menus: the untyped plugin is an "other" plugin, sent to the first responder.
let untypedItem = item("Untyped Tool", in: others)
check(untypedItem != nil, "the plugin without pluginType is not in the others menu")
check(untypedItem?.action == NSSelectorFromString("executeFilter:") && untypedItem?.target == nil,
      "the plugin without pluginType runs by \(untypedItem?.action.map(NSStringFromSelector) ?? "nothing"), not -executeFilter: to the first responder")
check(!(Registry.fusionPlugins as! [String]).contains("Untyped Tool") && Registry.fusionPluginsMenu!.items.allSatisfy { $0.title != "Untyped Tool" },
      "the plugin without pluginType is taken for a fusion filter")
// The typed plugins keep their menus.
check(item("Imaging Tool", in: filters)?.action == NSSelectorFromString("executeFilter:"), "the imageFilter plugin left the filters menu")
check((Registry.fusionPlugins as! [String]) == ["Fusing Tool"] && Registry.fusionPluginsMenu!.items.contains { $0.title == "Fusing Tool" },
      "the fusionFilter plugin is not the only fusion filter: \(Registry.fusionPlugins!)")
check(item("Reporting Tool", in: others)?.action == NSSelectorFromString("executeFilterDB:"), "the Report plugin is not run by -executeFilterDB:")

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

# ---------------------------------------------------------------- 5

installed = block(controller, 'private func installedState(of plugin: NSDictionary)')
equal = block(controller, 'private static func isEqualToString(_ value: Any?, _ other: Any?) -> Bool')
catalog_swift = r'''
import Foundation

final class Controller: NSObject {
    var pluginsArray: NSMutableArray = []
    EQUAL
    INSTALLED
    func state(_ plugin: NSDictionary) -> (Bool, Bool, Bool) { return installedState(of: plugin) }
}

var failed = 0
func entry(_ name: String, _ version: String) -> NSDictionary {
    return ["name": name, "version": version, "download_url": "https://example.invalid/\(name).horosplugin.zip"]
}
let controller = Controller()
controller.pluginsArray = [["name": "Other", "version": "9.0"], ["name": "Viewer", "version": "1.2"], ["name": "Older", "version": "0.9"]]
// (catalog entry, installed, installed in the same or a later version)
let cases: [(NSDictionary, Bool, Bool, String)] = [
    (entry("Viewer", "1.2"), true, true, "same name, same version"),
    (entry("Viewer", "1.1"), true, true, "same name, the installed one is newer"),
    (entry("Viewer", "1.3"), true, false, "same name, the catalog is newer"),
    (entry("Older", "1.0"), true, false, "same name after another plugin, the catalog is newer"),
    (entry("Absent", "1.0"), false, false, "a name nothing installed has"),
]
for (plugin, installed, current, label) in cases {
    let (alreadyInstalled, sameName, sameVersion) = controller.state(plugin)
    if alreadyInstalled != installed || (installed && (sameName != true || sameVersion != current)) {
        print("FAIL: \(label): installed \(alreadyInstalled), same name \(sameName), same version \(sameVersion)"); failed += 1
    }
}
if failed > 0 { exit(1) }
'''

# ---------------------------------------------------------------- 6

policy = block(controller, 'fileprivate func catalogPolicy(for navigationAction: WKNavigationAction, in webView: WKWebView)')
navigation = block(controller, '@MainActor\nprivate final class CatalogNavigation: NSObject, WKNavigationDelegate')
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
    @objc func fakeThread(_ object: Any?) {}
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
    package_helper = controller[controller.index('private final class PluginPackageDownload:'):]
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
    @objc func fakeThread(_ object: Any?) {}
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

policy_swift = r'''
import Foundation

// WebKit and NSWorkspace doubles: nothing loads and no browser opens.
class WKWebView: NSObject {}
@objc protocol WKNavigationDelegate: NSObjectProtocol {}
enum WKNavigationType: Int { case linkActivated = 0, formSubmitted, backForward, reload, formResubmitted, other = -1 }
@objc enum WKNavigationActionPolicy: Int { case cancel = 0, allow }
final class WKNavigationAction: NSObject {
    let navigationType: WKNavigationType
    let request: URLRequest
    init(_ type: WKNavigationType, _ request: URLRequest) { navigationType = type; self.request = request }
}
var opened: [URL] = []
final class NSWorkspace { static let shared = NSWorkspace(); func open(_ url: URL) { opened.append(url) } }

final class PluginManagerController: NSObject {
    var osirixPluginWebView: WKWebView? = WKWebView()
    var horosPluginWebView: WKWebView? = WKWebView()
    var submissions: [String?] = []
    func sendPluginSubmission(_ request: String!) { submissions.append(request) }
    POLICY
}

NAVIGATION

var failed = 0
var controller: PluginManagerController? = PluginManagerController()
// The delegate is main-actor isolated, as WebKit calls it; so is this driver.
private let delegate = MainActor.assumeIsolated { CatalogNavigation(controller: controller!) }
let url = URL(string: "https://example.invalid/plugin.html?name=Viewer&version=1.0")!
func decide(_ view: WKWebView?, _ type: WKNavigationType) -> [String] {
    var decisions: [String] = []
    MainActor.assumeIsolated {
        delegate.webView(view ?? WKWebView(), decidePolicyFor: WKNavigationAction(type, URLRequest(url: url))) { policy in
            decisions.append(policy == .allow ? "allow" : "cancel")
        }
    }
    return decisions
}
func expect(_ label: String, _ decisions: [String], _ wanted: [String], opens: Int, submits: Int) {
    let submissions = controller?.submissions.count ?? 0
    if decisions != wanted || opened.count != opens || submissions != submits {
        print("FAIL: \(label): decisions \(decisions), wanted \(wanted); \(opened.count) links opened in the browser, \(submissions) forms mailed")
        failed += 1
    }
    opened = []
    controller?.submissions = []
}
let foreign = WKWebView()
expect("another web view's page", decide(foreign, .other), ["allow"], opens: 0, submits: 0)
expect("another web view's link", decide(foreign, .linkActivated), ["allow"], opens: 0, submits: 0)
expect("another web view's form", decide(foreign, .formSubmitted), ["allow"], opens: 0, submits: 0)
for (name, view) in [("OsiriX", controller!.osirixPluginWebView), ("Horos", controller!.horosPluginWebView)] {
    expect("the \(name) catalog's page", decide(view, .other), ["allow"], opens: 0, submits: 0)
    expect("the \(name) catalog's reload", decide(view, .reload), ["allow"], opens: 0, submits: 0)
    expect("the \(name) catalog's link", decide(view, .linkActivated), ["cancel"], opens: 1, submits: 0)
    expect("the \(name) catalog's form", decide(view, .formSubmitted), ["cancel"], opens: 0, submits: 1)
    expect("the \(name) catalog's back/forward", decide(view, .backForward), ["cancel"], opens: 0, submits: 0)
}
let catalog = controller!.horosPluginWebView
controller = nil
expect("a link after the controller is gone", decide(catalog, .linkActivated), ["cancel"], opens: 0, submits: 0)
expect("a page after the controller is gone", decide(catalog, .other), ["cancel"], opens: 0, submits: 0)
if failed > 0 { exit(1) }
'''

with tempfile.TemporaryDirectory(prefix='horos-plugin-roles-') as temporary:
    work = Path(temporary)

    # Info.plist-only bundles: nothing is loaded or executed from them.
    bundles = work / 'Plugins'
    for name, plugin_type in [('Untyped', None), ('Imaging', 'imageFilter'), ('Fusing', 'fusionFilter'),
                              ('Reporting', 'Report'), ('Preprocessing', 'Pre-Process')]:
        contents = bundles / (name + '.horosplugin') / 'Contents'
        contents.mkdir(parents=True)
        info = {'CFBundleExecutable': name, 'CFBundleIdentifier': 'invalid.synthetic.' + name,
                'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1.0', 'MenuTitles': [name + ' Tool']}
        if plugin_type:
            info['pluginType'] = plugin_type
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))

    exception = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                                str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(work / 'exception.o')],
                               capture_output=True, text=True)
    if exception.returncode != 0:
        print('FAIL: HorosObjCException does not build: ' + exception.stderr[-2000:])
        raise SystemExit(1)

    code = (roles_swift.replace('REGISTRY', registry).replace('OBJC', objc_helpers, 1)
            .replace('SORTMENU', sort_menu).replace('SETMENUS', set_menus).replace('NOPLUGINS', no_plugins)
            .replace('REGISTRATION', registration).replace('BUNDLES', '"' + str(bundles) + '"'))
    status = run(build(work, 'roles', code, filters_objc, filters_impl, [str(work / 'exception.o')]))
    if status == 0:
        print('PASS: an untyped plugin has no role, typed plugins keep theirs, and "No plugins" reaches +noPlugins:')
    failures += status

    status = run(build(work, 'catalog', catalog_swift.replace('EQUAL', equal).replace('INSTALLED', installed),
                       '#import "HorosPluginCatalog.h"\n'))
    if status == 0:
        print('PASS: the catalog counts an installed plugin by name and tells a current one from an older one')
    failures += status

    status = run(build(work, 'policy', policy_swift.replace('POLICY', policy).replace('NAVIGATION', navigation),
                       '#import <Foundation/Foundation.h>\n'))
    if status == 0:
        print('PASS: every catalog navigation gets exactly one decision, only the catalogs open links elsewhere, and none reaches a controller that is gone')
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
