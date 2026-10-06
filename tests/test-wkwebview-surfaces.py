#!/usr/bin/env python3
"""The About window and the plugin catalogs are WKWebViews.

SplashScreen kept three WebKit1 WebViews and PluginManagerController two, with
a WebPolicyDelegate method that took WebFrame and WebPolicyDecisionListener.
Both now use WKWebView, and iChatHelper.xib, a nib no source loaded that held
the last other WebView, is gone. This checks:

1. No xib of the checkout declares a WebKit1 WebView or needs WebKit1's
   Interface Builder plugin, and iChatHelper.xib is gone from disk and from
   the project.
2. Splash.xib and PluginManager.xib, in every localization, connect each web
   view outlet to a WKWebView.
3. The two controllers name no WebKit1 type.
4. The About pages' navigation delegate, compiled over WebKit and NSWorkspace
   doubles, lets the bundled pages and the files beside them load, opens a
   web or mail link once in the user's application without navigating, and
   cancels everything else: remote loads that are not clicks, files outside
   the pages' folder (including by ".."), other schemes.
5. Compiled against the real WebKit, both navigation delegates answer
   WebKit's selector, so WebKit asks them.

The catalogs' navigation decision is checked by test-plugin-roles-and-catalog.py.

    python3 tests/test-wkwebview-surfaces.py
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = 0


def fail(message):
    global failures
    print('FAIL: ' + message)
    failures += 1


tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '*.xib'], text=True).split()
xibs = [root / name for name in tracked if (root / name).exists()]

# ---------------------------------------------------------------- 1

legacy = []
for xib in xibs:
    text = xib.read_text(encoding='utf-8', errors='replace')
    if re.search(r'<webView\b|customClass="WebView"|com\.apple\.WebKitIBPlugin"', text):
        legacy.append(str(xib.relative_to(root)))
if legacy:
    fail('xibs still use the WebKit1 WebView: ' + ', '.join(legacy))
else:
    print(f'PASS: none of the {len(xibs)} xibs declares a WebKit1 WebView')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
leftovers = [str(path.relative_to(root)) for path in root.glob('Horos/Resources/*.lproj/iChatHelper.xib')]
if leftovers or 'iChatHelper' in project:
    fail('iChatHelper.xib is still ' + ('on disk: ' + ', '.join(leftovers) if leftovers else 'in the project'))
else:
    print('PASS: iChatHelper.xib is gone from disk and from the project')

# ---------------------------------------------------------------- 2

outlets = {'Splash.xib': ['aboutWebView', 'partnersWebView', 'releaseNotesWebView'],
           'PluginManager.xib': ['osirixPluginWebView', 'horosPluginWebView']}
for name, properties in outlets.items():
    copies = sorted(root.glob('Horos/Resources/*.lproj/' + name))
    if len(copies) < 2:
        fail(f'{name} has {len(copies)} localizations, not the en and ja-JP copies')
    for xib in copies:
        text = xib.read_text(encoding='utf-8')
        for prop in properties:
            outlet = re.search(r'<outlet property="%s" destination="([^"]+)"' % prop, text)
            if not outlet:
                fail(f'{xib.relative_to(root)} does not connect {prop}')
            elif not re.search(r'<wkWebView\b[^>]*\bid="%s"' % re.escape(outlet.group(1)), text):
                fail(f'{xib.relative_to(root)} connects {prop} to something that is not a WKWebView')
if failures == 0:
    print('PASS: every localization of Splash.xib and PluginManager.xib connects its web views to WKWebViews')

# ---------------------------------------------------------------- 3

splash = (root / 'Horos/Sources/SplashScreen.swift').read_text(encoding='utf-8')
controller = (root / 'Horos/Sources/PluginManagerController.swift').read_text(encoding='utf-8')
code_only = lambda text: '\n'.join(line.split('//')[0] for line in text.splitlines())
named = [(file, word) for file, text in (('SplashScreen.swift', splash), ('PluginManagerController.swift', controller))
         for word in ('WebView', 'WebFrame', 'WebPolicyDecisionListener', 'WebPolicyDelegate', 'mainFrame',
                      'WebViewProgressStarted', 'WebViewProgressFinished')
         if re.search(r'(?<![A-Za-z])%s\b' % word, code_only(text))]
if named:
    fail('WebKit1 is still named: ' + ', '.join(f'{word} in {file}' for file, word in named))
else:
    print('PASS: SplashScreen and PluginManagerController name no WebKit1 type')

# ---------------------------------------------------------------- 4


def swift_block(text, marker):
    at = text.find(marker)
    if at < 0:
        fail(f'{marker!r} is not where it was')
        raise SystemExit(1)
    index, depth, opened = at, 0, False
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
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


navigation = swift_block(splash, '@MainActor\nprivate final class SplashPageNavigation')
navigation_swift = r'''
import Foundation

// WebKit and NSWorkspace doubles: nothing loads and nothing opens.
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

NAVIGATION

var failed = 0
let pages = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// The delegate is main-actor isolated, as WebKit calls it; so is this driver.
private let delegate = MainActor.assumeIsolated { SplashPageNavigation(pagesDirectory: pages) }
func expect(_ label: String, _ url: URL, _ type: WKNavigationType, _ wanted: String, opens: Int) {
    var decisions: [String] = []
    MainActor.assumeIsolated {
        delegate.webView(WKWebView(), decidePolicyFor: WKNavigationAction(type, URLRequest(url: url))) { policy in
            decisions.append(policy == .allow ? "allow" : "cancel")
        }
    }
    if decisions != [wanted] || opened.count != opens || (opens == 1 && opened.first != url) {
        print("FAIL: \(label): decisions \(decisions), wanted [\(wanted)]; opened \(opened)")
        failed += 1
    }
    opened = []
}
let about = pages.appendingPathComponent("about.html")
expect("the About page", about, .other, "allow", opens: 0)
expect("the licenses page linked from it", pages.appendingPathComponent("licenses.html"), .linkActivated, "allow", opens: 0)
expect("a license text", pages.appendingPathComponent("OpenSSL-LICENSE.txt"), .linkActivated, "allow", opens: 0)
expect("an image below the folder", pages.appendingPathComponent("images/isis-logo.png"), .other, "allow", opens: 0)
expect("going back to the About page", about, .backForward, "allow", opens: 0)
expect("about:blank", URL(string: "about:blank")!, .other, "allow", opens: 0)
expect("the LGPL link", URL(string: "http://www.gnu.org/licenses/lgpl-3.0.en.html")!, .linkActivated, "cancel", opens: 1)
expect("an https link", URL(string: "https://example.invalid/partner")!, .linkActivated, "cancel", opens: 1)
expect("a mail link", URL(string: "mailto:nobody@example.invalid")!, .linkActivated, "cancel", opens: 1)
expect("a remote load that is not a click", URL(string: "https://example.invalid/tracker")!, .other, "cancel", opens: 0)
expect("a remote form", URL(string: "https://example.invalid/form")!, .formSubmitted, "cancel", opens: 0)
expect("a file outside the folder", URL(fileURLWithPath: "/etc/hosts"), .linkActivated, "cancel", opens: 0)
expect("a file reached by ..", URL(fileURLWithPath: pages.path + "/../outside.html"), .linkActivated, "cancel", opens: 0)
expect("a sibling folder with the same prefix", URL(fileURLWithPath: pages.path + "-other/about.html"), .linkActivated, "cancel", opens: 0)
expect("another scheme", URL(string: "ftp://example.invalid/file")!, .linkActivated, "cancel", opens: 0)
if failed > 0 { exit(1) }
'''

with tempfile.TemporaryDirectory(prefix='horos-wkwebview-') as temporary:
    work = Path(temporary)
    pages = work / 'Splash'
    (pages / 'images').mkdir(parents=True)
    (work / 'navigation.swift').write_text(navigation_swift.replace('NAVIGATION', navigation))
    built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'navigation', str(work / 'navigation.swift'),
                            '-o', str(work / 'navigation')], capture_output=True, text=True)
    if built.returncode != 0:
        fail('the About pages\' navigation delegate does not build: ' + built.stderr[-3000:])
    else:
        # The temporary folder is under /var, a symbolic link to /private/var:
        # the delegate must compare resolved paths.
        result = subprocess.run([str(work / 'navigation'), str(pages)], capture_output=True, text=True, timeout=60)
        output = (result.stdout + result.stderr).strip()
        if output:
            print(output)
        if result.returncode != 0:
            failures += 1
        else:
            print('PASS: the About pages load the bundled files, open web and mail links once elsewhere, and load nothing else')

# ---------------------------------------------------------------- 5
# Against the real WebKit, both delegates must answer WebKit's selector. A
# closure type that only nearly matched WebKit's (without @MainActor) once
# exported them under another selector: the build only warned, the doubles
# above still passed, and WebKit never asked, so every navigation was allowed.

catalog = swift_block(controller, '@MainActor\nprivate final class CatalogNavigation')
real_swift = r"""
import AppKit
import WebKit

final class PluginManagerController: NSObject {
    fileprivate func catalogPolicy(for navigationAction: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy { .cancel }
}

SPLASH

CATALOG

let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
var failed = 0
for (name, cls) in [("SplashPageNavigation", SplashPageNavigation.self as AnyClass), ("CatalogNavigation", CatalogNavigation.self as AnyClass)] {
    if !class_respondsToSelector(cls, selector) {
        print("FAIL: \(name) does not answer \(NSStringFromSelector(selector)): WebKit would never ask it")
        failed += 1
    }
    if !class_conformsToProtocol(cls, WKNavigationDelegate.self) {
        print("FAIL: \(name) does not conform to WKNavigationDelegate"); failed += 1
    }
}
if failed > 0 { exit(1) }
"""

with tempfile.TemporaryDirectory(prefix='horos-wkwebview-real-') as temporary:
    work = Path(temporary)
    (work / 'real.swift').write_text(real_swift.replace('SPLASH', navigation).replace('CATALOG', catalog))
    # Swift 5 with strict concurrency, as the application target builds: it
    # is under strict concurrency that the closure type only nearly matched.
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-enable-upcoming-feature', 'StrictConcurrency',
                            '-module-name', 'real', str(work / 'real.swift'), '-o', str(work / 'real')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        fail('the delegates do not build against WebKit: ' + built.stderr[-3000:])
    elif 'nearly matches' in built.stderr:
        fail('a delegate method only nearly matches WebKit\'s: ' + built.stderr[-3000:])
    else:
        result = subprocess.run([str(work / 'real')], capture_output=True, text=True, timeout=60)
        output = (result.stdout + result.stderr).strip()
        if output:
            print(output)
        if result.returncode != 0:
            failures += 1
        else:
            print('PASS: against the real WebKit, both delegates answer webView:decidePolicyForNavigationAction:decisionHandler:')

sys.exit(1 if failures else 0)
