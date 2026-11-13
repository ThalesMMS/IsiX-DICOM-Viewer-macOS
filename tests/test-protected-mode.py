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
from sources import source_text, class_text  # noqa: E402
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

let services = ["plugins", "DICOM listener", "TLS", "auto-routing", "automatic cleaning", "Web Portal",
                "XML-RPC", "Bonjour", "update checks", "window restoration", "quit"]
let message = ProtectedMode.alertMessage
for word in services + ["Shift and Option"] {
    assert(message.contains(word), word)
}

// A launch that found the note of a plugin that stopped while loading turns the
// mode on by itself. Nobody held a key: the alert says why, and not which keys
// to let go of. A mode the keys asked for keeps its own sentence.
let asked = ProtectedMode.isActive
ProtectedMode.activateAfterPluginFailure()
assert(ProtectedMode.isActive, "the note of a plugin must turn the mode on")
let after = ProtectedMode.alertMessage
if asked {
    assert(after == message, "the keys asked for the mode first: its alert must not change")
} else {
    for word in services + ["stopped while loading a plugin"] {
        assert(after.contains(word), word)
    }
    assert(!after.contains("Shift") && !after.contains("Option"), after)
    assert(!defaults.bool(forKey: "ApplePersistenceIgnoreState") || mode == "requested")
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
body = (root / 'Horos/Sources/main.swift').read_text()
if 'ProtectedMode.activateIfRequested()' not in body:
    failures.append('main does not turn protected mode on')
elif not (body.index('PreferencesContinuity.importPreviousPreferences()') < body.index('ProtectedMode.activateIfRequested()')
          < body.index('NSApplicationMain')):
    failures.append('protected mode must be decided after the preference import and before NSApplicationMain')
if '@objc(HorosProtectedMode)' not in protected:
    failures.append('ProtectedMode.swift no longer exports HorosProtectedMode to the Objective-C callers')

# The browser is Swift: its init is BrowserController.swift.
browser = class_text('BrowserController')
init = browser[browser.index('public override init(window: NSWindow?) {'):]
init = init[:init.index('studyListState.searchType = 7')]
if '_currentModifierFlags' in init or 'setRunOsiriXInProtectedMode' in init:
    failures.append('the browser still reads Shift and Option, after the plugins are loaded')
if 'message: ProtectedMode.alertMessage' not in init:
    failures.append('the browser does not show the protected mode alert that lists what is off')

# --- every start point asks --------------------------------------------------
app = class_text('AppController')


def method(text, signature, end):
    start = text.index(signature)
    return text[start:text.index(end, start + len(signature))]


# Every start of the listeners goes through DICOMListenerController's restart.
lifecycle = source_text('DICOMListenerController')
restart = method(lifecycle, '    func restart() {', 'storeListenerTitles()')
if 'ProtectedMode.isActive' not in restart or 'return' not in restart:
    failures.append('the restart starts the listeners in protected mode')
if 'dicomListener.restart()' not in method(app, 'public func restartSTORESCP()', '\n    }\n'):
    failures.append('restartSTORESCP does not go through the listener controller')
at = app.index('xmlrpcServer = XMLRPCInterface()')
if 'ProtectedMode.isActive' not in app[app.rindex('NetworkPreferences.xmlrpcServer', 0, at):at]:
    failures.append('the XML-RPC server starts in protected mode')
launch = method(app, 'func didFinishLaunching() {', 'DistributionChannel.configureMenu')
updates = launch[launch.index('#if !MACAPPSTORE'):]
if not re.match(r'#if !MACAPPSTORE\s+if ProtectedMode\.isActive', updates):
    failures.append('automatic update checks start in protected mode')
if 'updateCheckScheduler.startAtLaunch(' not in updates:
    failures.append('the launch no longer starts the automatic update checks where protected mode is checked')
for marker in ('checkForUpdatesPlugins', 'updateCheckScheduler.startAtLaunch('):
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

clean = (root / 'Horos/Sources/DatabaseCleanupService.swift').read_text()
timer = method(clean, 'private static func timerPass', 'initiateCleanUnlessAlreadyCleaning')
if 'ProtectedMode.isActive' not in timer:
    failures.append('automatic cleaning runs in protected mode')

database = (root / 'Horos/Sources/DicomFileIndexer.swift').read_text()  # DicomDatabase is Swift
# The indexer reaches the database as `database` and reads the preferences it is given.
routing = re.search(r'if database\.isLocal\(\) && returnArray && '
                    r'preferences\[NetworkPreferences\.autoroutingActivated\][^\n]*', database)
if not routing or '!ProtectedMode.isActive' not in routing.group():
    failures.append('auto-routing runs in protected mode')

# Only version 1 plugins load, through one loader, which refuses every plugin
# in protected mode before its signature or code is looked at.
manager = source_text('PluginManager')
version1 = (root / 'Horos/Sources/PluginManager+IsiXPlugins.swift').read_text()
if 'guard DCMPix.isRunOsiriXInProtectedModeActivated() == false else' not in version1 \
        or version1.index('isRunOsiriXInProtectedModeActivated') > version1.index('isPluginBundleSignatureValid(path)') \
        or 'PluginManager.loadIsiXPlugin(atPath: path)' not in manager:
    failures.append('plugin loading no longer refuses every plugin in protected mode')

# --- the crash offer: before the plugins, whatever hideListenerError says ----
offer_at = app.index('NSLocalizedString("IsiX DICOM Viewer crashed during last startup"')
plugins_at = app.index('Once.pluginManager = PluginManager()')
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
# Two sentences: the mode asked for with the keys, and the one a plugin's note starts.
keys = [json.loads('"' + found + '"') for found in
        re.findall(r'NSLocalizedString\("((?:\\.|[^"\\])*)"', protected[protected.index('alertMessage'):])]
if len(keys) != 2 or 'Shift and Option' not in keys[0] or 'Shift' in keys[1] or 'Option' in keys[1]:
    failures.append('the protected mode alert is not the two sentences expected: with the keys, and after a plugin\'s note')
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    language = catalog.parent.name[:-len('.lproj')]
    entries = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(catalog)]))
    for key in keys:
        value = entries.get(key)
        if not value:
            failures.append('%s has no protected mode alert' % language)
        elif language != 'en' and value == key:
            failures.append('%s shows the protected mode alert in English' % language)
        elif value.count('\n') != key.count('\n') or 'IsiX DICOM Viewer' not in value or 'XML-RPC' not in value:
            failures.append('%s protected mode alert lost its layout or a name' % language)
    # The list of what is off is one text in both.
    if len({entries.get(key, '').split('\n\n')[1:2][0] if entries.get(key, '').count('\n\n') == 2 else key for key in keys}) != 1:
        failures.append('%s lists different services in the two protected mode alerts' % language)
    if any(word in entries.get(keys[-1], '') for word in ('Shift', 'Option', 'Opción', 'Opzione', 'Wahltaste', 'Maj')):
        failures.append('%s still names the keys in the alert a plugin\'s note starts' % language)
    if any(k.startswith('IsiX DICOM Viewer is now running in Protected Mode') for k in entries):
        failures.append('%s still carries the old protected mode sentence' % language)

if failures:
    for failure in failures:
        print('FAIL: %s' % failure)
    sys.exit(1)
print('ok: protected mode is decided in main, before the plugins, and every listed service asks before it starts')
