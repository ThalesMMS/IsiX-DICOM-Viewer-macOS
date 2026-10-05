#!/usr/bin/env python3
"""Protected mode starts before the plugins and leaves the services off.

Shift and Option held while the application opens, or `-ProtectedMode YES`,
used to be read when the browser window was created, after the plugins had
been loaded, and only hid images: the listener, auto-routing, cleaning, the
Web Portal, XML-RPC, Bonjour publishing and update checks still started. The
"crashed during last startup" offer only appeared when listener errors were
shown.

The decision and the activation are compiled and run with a stand-in for
DCMPix. The start points are read from their sources: each one must ask
ProtectedMode before starting. The keys themselves cannot be pressed here;
the decision is checked with the flags the keys produce.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []

swift = root / 'Horos/Sources/ProtectedMode.swift'
if not swift.exists():
    print('FAIL: ProtectedMode.swift is missing')
    sys.exit(1)
protected = swift.read_text()

# --- the decision and the activation, compiled -------------------------------
stub = r'''import Foundation
final class DCMPix {
    nonisolated(unsafe) static var flag = false
    static func setRunOsiriXInProtectedMode(_ value: Bool) { flag = value }
    static func isRunOsiriXInProtectedModeActivated() -> Bool { flag }
}
'''
driver = r'''import CoreGraphics
import Foundation

let both: CGEventFlags = [.maskShift, .maskAlternate]
assert(ProtectedMode.isRequested(flags: both, argument: nil))
assert(ProtectedMode.isRequested(flags: [.maskShift, .maskAlternate, .maskCommand], argument: nil))
assert(!ProtectedMode.isRequested(flags: .maskShift, argument: nil))
assert(!ProtectedMode.isRequested(flags: .maskAlternate, argument: nil))
assert(!ProtectedMode.isRequested(flags: [], argument: nil))
assert(ProtectedMode.isRequested(flags: [], argument: "YES"))
assert(ProtectedMode.isRequested(flags: [], argument: "1"))
assert(!ProtectedMode.isRequested(flags: [], argument: "NO"))
assert(ProtectedMode.isRequested(flags: [], argument: NSNumber(value: true)))
assert(!ProtectedMode.isRequested(flags: [], argument: NSNumber(value: false)))

let defaults = UserDefaults.standard
let domain = ProcessInfo.processInfo.processName
let saved = defaults.persistentDomain(forName: domain) ?? [:]
let mode = CommandLine.arguments[1]

ProtectedMode.activateIfRequested()
if mode == "requested" {
    assert(ProtectedMode.isActive, "-ProtectedMode YES must turn the mode on in main")
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    // Merged, never replaced: the isolation arguments stay.
    assert(arguments["IsolationProbe"] as? String == "kept", "\(arguments)")
    assert(arguments["ProtectedMode"] as? String == "YES", "\(arguments)")
    assert(defaults.bool(forKey: "ApplePersistenceIgnoreState"), "window restoration must be off")
    let persisted = defaults.persistentDomain(forName: domain) ?? [:]
    assert(NSDictionary(dictionary: persisted).isEqual(to: saved), "a saved preference changed: \(persisted)")
    assert(persisted["ApplePersistenceIgnoreState"] == nil && persisted["ProtectedMode"] == nil)
} else {
    assert(!ProtectedMode.isActive, "a normal start must not be protected")
    assert(!defaults.bool(forKey: "ApplePersistenceIgnoreState"))
}

let message = ProtectedMode.alertMessage
for word in ["plugins", "DICOM listener", "TLS", "auto-routing", "automatic cleaning", "Web Portal",
             "XML-RPC", "Bonjour", "update checks", "window restoration", "Shift and Option", "quit"] {
    assert(message.contains(word), word)
}
print("PASS: \(mode) start")
'''

with tempfile.TemporaryDirectory(prefix='horos-protected-mode-') as directory:
    p = Path(directory)
    (p / 'DCMPix.swift').write_text(stub)
    (p / 'main.swift').write_text(driver)
    binary = p / 'protected-mode-probe'
    compiled = subprocess.run(
        ['xcrun', 'swiftc', '-swift-version', '5', str(swift), str(p / 'DCMPix.swift'),
         str(p / 'main.swift'), '-o', str(binary)],
        capture_output=True, text=True, timeout=300)
    if compiled.returncode != 0:
        print(compiled.stderr)
        failures.append('ProtectedMode.swift did not compile')
    else:
        for mode, extra in (('requested', ['-ProtectedMode', 'YES']), ('normal', ['-ProtectedMode', 'NO'])):
            ran = subprocess.run([str(binary), mode, '-IsolationProbe', 'kept'] + extra,
                                 capture_output=True, text=True, timeout=60)
            sys.stdout.write(ran.stdout)
            sys.stderr.write(ran.stderr)
            if ran.returncode != 0:
                failures.append('the %s start failed its assertions' % mode)

# --- read in main, before NSApplicationMain ----------------------------------
main = (root / 'Horos/Sources/main.m').read_bytes().decode('latin1')
body = main[main.index('int main('):]
if 'HorosActivateProtectedModeIfRequested()' not in body:
    failures.append('main does not turn protected mode on')
elif not (body.index('HorosImportPreviousPreferences()') < body.index('HorosActivateProtectedModeIfRequested()')
          < body.index('NSApplicationMain')):
    failures.append('protected mode must be decided after the preference import and before NSApplicationMain')
if '@"HorosProtectedMode"' not in main or '@objc(HorosProtectedMode)' not in protected:
    failures.append('main looks up a class name that ProtectedMode.swift does not export')

browser = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('latin1')
init = browser[browser.index('- (id)initWithWindow:'):]
init = init[:init.index('_distantAlbumNoOfStudiesCache')]
if '_currentModifierFlags' in init or 'setRunOsiriXInProtectedMode' in init:
    failures.append('the browser still reads Shift and Option, after the plugins are loaded')
if '[HorosProtectedMode alertMessage]' not in init:
    failures.append('the browser does not show the protected mode alert that lists what is off')

# --- every start point asks --------------------------------------------------
app = source_text('AppController')


def method(text, signature, end):
    start = text.index(signature)
    return text[start:text.index(end, start + len(signature))]


restart = method(app, 'public func restartSTORESCP()', 'Is called restart')
if 'ProtectedMode.isActive' not in restart or 'return' not in restart:
    failures.append('restartSTORESCP starts the listeners in protected mode')
at = app.index('xmlrpcServer = XMLRPCInterface()')
if 'ProtectedMode.isActive' not in app[app.rindex('"httpXMLRPCServer"', 0, at):at]:
    failures.append('the XML-RPC server starts in protected mode')
launch = method(app, 'func applicationDidFinishLaunching(', 'DistributionChannel.configureMenu')
updates = launch[launch.index('#if !MACAPPSTORE'):]
if not re.match(r'#if !MACAPPSTORE\s+if ProtectedMode\.isActive', updates):
    failures.append('automatic update checks start in protected mode')
for marker in ('checkForUpdatesPlugins', 'AppController.checkForUpdates(_:)'):
    if marker in updates and updates.index(marker) < updates.index('} else {'):
        failures.append('%s runs before the protected mode check' % marker)

portal = source_text('WebPortal')
observer = portal[portal.index('if keyPath == valuesKeyPath(OsirixWebPortalEnabledDefaultsKey)'):]
if not observer.split('startAcceptingConnections', 1)[0].count('ProtectedMode.isActive'):
    failures.append('the Web Portal starts in protected mode')
wado = portal[portal.index('wadoOnlyServer'):]
if 'ProtectedMode.isActive' not in wado.split('startAcceptingConnections', 1)[0]:
    failures.append('the WADO-only server starts in protected mode')

publisher = source_text('BonjourPublisher')
toggle = method(publisher, 'public func toggleSharing(_ activate: Bool)', 'HorosDatabaseServer(')
if 'ProtectedMode.isActive' not in toggle:
    failures.append('Bonjour database sharing starts in protected mode')

clean = (root / 'Horos/Sources/DicomDatabase+Clean.swift').read_text()
timer = method(clean, 'private class func _cleanTimerCallback', 'initiateCleanUnlessAlreadyCleaning')
if 'ProtectedMode.isActive' not in timer:
    failures.append('automatic cleaning runs in protected mode')

database = (root / 'Horos/Sources/DicomDatabase.mm').read_bytes().decode('latin1')
routing = re.search(r'if \(self\.isLocal && returnArray && \[\[NSUserDefaults standardUserDefaults\] '
                    r'boolForKey: @"AUTOROUTINGACTIVATED"\][^\n]*', database)
if not routing or '![HorosProtectedMode isActive]' not in routing.group():
    failures.append('auto-routing runs in protected mode')

manager = source_text('PluginManager')
if 'if DCMPix.isRunOsiriXInProtectedModeActivated() == false && PluginManager.isPluginBundleSignatureValid(path)' not in manager:
    failures.append('plugin loading no longer refuses every plugin in protected mode')

# --- the crash offer: before the plugins, whatever hideListenerError says ----
offer_at = app.index('NSLocalizedString("IsiX DICOM Viewer crashed during last startup"')
plugins_at = app.index('State.pluginManager = PluginManager()')
if offer_at > plugins_at:
    failures.append('Protected Mode chosen after a failed start comes after the plugins are loaded')
offer = app[app.rindex('if !DatabaseFirstUse.hasPendingChoice', 0, offer_at):offer_at]
if 'hideListenerError' in offer:
    failures.append('the failed start offer still depends on hideListenerError')
if 'shouldOfferDatabaseRebuild' not in offer or 'crashMarkerPath()' not in offer:
    failures.append('the failed start offer lost its plugin marker check')
after = app[offer_at:offer_at + 2000]
if 'ProtectedMode.activate()' not in after:
    failures.append('Protected Mode chosen after a failed start does not go through ProtectedMode')

# --- the alert in every catalog ----------------------------------------------
key = json.loads('"' + re.search(r'NSLocalizedString\("((?:\\.|[^"\\])*)"', protected[protected.index('alertMessage'):]).group(1) + '"')
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    language = catalog.parent.name[:-len('.lproj')]
    entries = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(catalog)]))
    value = entries.get(key)
    if not value:
        failures.append('%s has no protected mode alert' % language)
    elif language != 'en' and value == key:
        failures.append('%s shows the protected mode alert in English' % language)
    elif value.count('\n') != key.count('\n') or 'IsiX DICOM Viewer' not in value or 'XML-RPC' not in value:
        failures.append('%s protected mode alert lost its layout or a name' % language)
    if any(k.startswith('IsiX DICOM Viewer is now running in Protected Mode') for k in entries):
        failures.append('%s still carries the old protected mode sentence' % language)

if failures:
    for failure in failures:
        print('FAIL: %s' % failure)
    sys.exit(1)
print('ok: protected mode is decided in main, before the plugins, and every listed service asks before it starts')
