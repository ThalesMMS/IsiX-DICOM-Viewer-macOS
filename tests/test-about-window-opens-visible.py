#!/usr/bin/env python3
"""The About window opens visible, in front, in every language.

Choosing About made a new controller each time, whose window opened fully
transparent and was faded in by a timer of the run loop's default mode: with
the run loop in another mode the window stayed on screen at no opacity, and
the menu item seemed to do nothing. The window also floated above the other
windows and hid when the application was left, as a palette does, and did not
follow the desktop in use. Spanish and Italian had no nib of it, and the
Japanese one was mostly in English.

SplashScreen.swift is compiled here into a small application with the About
nibs of two languages, compiled from the sources, and run in Spanish:

- the window loads from the nib of the language, with its title and tabs;
- right after -affiche, with no turn of the run loop, it is opaque, visible,
  at the level of ordinary windows, does not hide when the application
  is left, moves to the desktop in use and may sit over a full-screen window;
- closed, it closes at once, and -affiche shows the same window again;
- a controller whose nib is missing shows nothing and raises nothing.

In the sources: no timer is left in the controller, the application keeps one
controller, each of the twelve languages has the nib, with one structure and
its own texts, and the project lists them.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from sources import source_text

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


driver = r'''
import AppKit
import WebKit

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}

// What the controller asks of the application, beside its nib.
enum LicenseAttribution { static func missingNotices(in bundle: Bundle) -> [String] { [] } }
enum ReleaseNotes {
    struct Notes { let html: String }
    static func fetchLatest(_ completion: @escaping (Notes?) -> Void) {}
}

@MainActor func tabs(of window: NSWindow) -> [String] {
    var found: [String] = [], stack: [NSView] = window.contentView.map { [$0] } ?? []
    while let view = stack.popLast() {
        if let tabView = view as? NSTabView { found += tabView.tabViewItems.map(\.label) }
        stack += view.subviews
    }
    return found
}

@MainActor func run() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let controller = SplashScreen()
    controller.showWindow(nil)
    controller.affiche()
    guard let window = controller.window else { check(false, "the About window did not load from its nib"); return }
    // No turn of the run loop since -affiche.
    check(window.alphaValue == 1, "the window opens at opacity \(window.alphaValue)")
    check(window.isVisible, "the window is not on screen")
    check(window.level == .normal, "the window is at level \(window.level.rawValue)")
    check(!window.hidesOnDeactivate, "the window hides when the application is left")
    check(window.collectionBehavior.contains(.moveToActiveSpace) && window.collectionBehavior.contains(.fullScreenAuxiliary),
          "the window does not follow the desktop in use: \(window.collectionBehavior.rawValue)")
    check(window.title == "Acerca de IsiX DICOM Viewer", "the window is not the Spanish one: \(window.title)")
    check(tabs(of: window) == ["Acerca de", "Notas de la versión", "Licencias"], "the tabs are not the Spanish ones: \(tabs(of: window))")
    check(!controller.version.title.isEmpty && controller.version.title != "Número de versión", "the version is not shown: \(controller.version.title)")

    window.performClose(nil)
    check(!window.isVisible, "the window does not close at once")
    controller.showWindow(nil)
    controller.affiche()
    check(controller.window === window && window.isVisible && window.alphaValue == 1, "the same window does not come back")
    // The steps of the former fades, for whoever still sends them.
    window.alphaValue = 0.3
    controller.fadeIn(nil)
    check(window.alphaValue == 1, "-fadeIn: leaves the window at \(window.alphaValue)")
    controller.fade(nil)
    check(!window.isVisible, "-fade: leaves the window open")

    let missing = SplashScreen(windowNibName: "NoSuchNib")
    missing.affiche()
    missing.affiche()
    check(!missing.isWindowLoaded || missing.window == nil, "a window came from a nib that is not there")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("PASS: the About window loads in the language, opens opaque and visible at once, as an ordinary window that follows the desktop in use, closes at once and comes back the same; a missing nib shows nothing")
'''

with tempfile.TemporaryDirectory(prefix='horos-about-') as directory:
    work = Path(directory)
    contents = work / 'About.app/Contents'
    (contents / 'MacOS').mkdir(parents=True)
    for language in ('en', 'es'):
        folder = contents / 'Resources' / f'{language}.lproj'
        folder.mkdir(parents=True)
        subprocess.run(['xcrun', 'ibtool', '--compile', str(folder / 'Splash.nib'), str(RESOURCES / f'{language}.lproj/Splash.xib')],
                       check=True, capture_output=True, timeout=300)
    info = plistlib.loads((ROOT / 'Horos/Info.plist').read_bytes())
    plist = {'CFBundleExecutable': 'about', 'CFBundleIdentifier': 'org.horos.qa.about-window', 'CFBundlePackageType': 'APPL',
             'CFBundleDevelopmentRegion': info.get('CFBundleDevelopmentRegion', 'en'), 'CFBundleGetInfoString': 'IsiX DICOM Viewer test',
             'CFBundleVersion': '1', 'LSUIElement': True}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(plist))
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                            str(ROOT / 'Horos/Sources/SplashScreen.swift'), str(work / 'main.swift'), '-o', str(contents / 'MacOS/about')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(contents / 'MacOS/about'), '-AppleLanguages', '(es)'], capture_output=True, text=True, timeout=120)
    print('\n'.join(line for line in (run.stdout + run.stderr).strip().splitlines() if line.startswith(('PASS', 'FAIL')) or run.returncode not in (0, 1)))
    check(run.returncode == 0, f'the window failed (exit {run.returncode})')
    check(run.stderr.count('the About window could not be loaded') == 1, 'a missing nib is not said once in the log')

splash = source_text('SplashScreen')
check('Timer.scheduledTimer' not in splash and 'timerIn' not in splash and 'timerOut' not in splash, 'a timer still shows or closes the window')
check('alphaValue = 0' not in splash, 'the window is still made transparent')
check('.level = .floating' not in splash, 'the window still floats above the others')
application = source_text('AppController')
check('if splashController == nil { splashController = SplashScreen() }\n        splashController?.showWindow(self)\n        splashController?.affiche()' in application,
      'the application makes a new About controller at each choice')

languages = sorted(path.parent.name for path in RESOURCES.glob('*.lproj/MainMenu.xib'))
check(len(languages) == 12, f'{len(languages)} languages have a main menu')
project = (ROOT / 'Horos.xcodeproj/project.pbxproj').read_text()
english = None
shapes = {}
for language in languages:
    path = RESOURCES / language / 'Splash.xib'
    check(path.is_file(), f'{language}: no About nib')
    if not path.is_file():
        continue
    code = language[:-len('.lproj')]
    check(re.search(r'path = "?(Horos/Resources/)?%s\.lproj/Splash\.xib"?;' % re.escape(code), project) is not None, f'{language}: the project does not list its About nib')
    text = path.read_text()
    check('hidesOnDeactivate' not in text, f'{language}: the nib hides the window when the application is left')
    tree = ET.parse(path)
    window = tree.find('.//window')
    texts = (window.get('title'), *(item.get('label') for item in tree.iter('tabViewItem')), tree.find('.//buttonCell[@id="32"]').get('title'))
    check(len(texts) == 5 and all(texts), f'{language}: a text of the nib is missing: {texts}')
    shapes[language] = sorted((node.tag, node.get('id')) for node in tree.iter() if node.get('id'))
    if language == 'en.lproj':
        english = texts
for language in languages:
    path = RESOURCES / language / 'Splash.xib'
    if language == 'en.lproj' or not path.is_file() or english is None:
        continue
    tree = ET.parse(path)
    texts = (tree.find('.//window').get('title'), *(item.get('label') for item in tree.iter('tabViewItem')), tree.find('.//buttonCell[@id="32"]').get('title'))
    same = [text for text, source in zip(texts, english) if text == source]
    check(not same, f'{language}: left in English: {same}')
check(len({tuple(shape) for shape in shapes.values()}) == 1, 'the About nibs do not share one structure')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print(f'PASS: one About controller with no timer; {len(shapes)} languages have the nib, with one structure and their own texts')
