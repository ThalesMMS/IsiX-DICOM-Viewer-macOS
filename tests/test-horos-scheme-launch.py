#!/usr/bin/env python3
"""LaunchServices, the browser prompt, and the parser are three different layers.

Chrome 94 started requiring a user gesture and an allow prompt before it will
hand a custom scheme to LaunchServices. A link that never becomes an Apple
Event is not a parse error. This compiles the same HorosSchemeURL type and
feeds it controlled snapshots so the diagnosis names the layer: parser,
launchServices, or browser.

A live LaunchServices read is taken too. It does not change handlers.
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
import isix_modules  # noqa: E402
failures = []

source = root / 'Horos/Sources/HorosSchemeURL.swift'
# AppController is Swift.
application = source_text('AppController')
info = (root / 'Horos/Info.plist').read_text()


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

DRIVER = r'''
import Foundation

func emit(_ key: String, _ value: String?) {
    print(key + "\t" + (value ?? "nil").replacingOccurrences(of: "\n", with: " "))
}

func dump(_ key: String, _ diagnosis: HorosSchemeDiagnosis) {
    emit(key + ".layer", diagnosis.layer)
    emit(key + ".code", diagnosis.code)
    emit(key + ".message", diagnosis.message)
}

let studyURL = "horos://?methodName=DisplayStudy&StudyInstanceUID=2.25.1"
let badURL = "horos://?methodName=DisplayStudy"

let horosHandler = HorosSchemeLaunchSnapshot()
horosHandler.scheme = "horos"
horosHandler.candidateBundleIDs = ["thalesmms.isis.workstation.local-development"]
horosHandler.chosenBundleID = "thalesmms.isis.workstation.local-development"
horosHandler.runningBundleID = "thalesmms.isis.workstation.local-development"
horosHandler.chromeMajorVersion = 152
horosHandler.navigationHadUserGesture = true
horosHandler.appleEventDelivered = true

dump("delivered", HorosSchemeURL.diagnose(studyURL, snapshot: horosHandler))

let noHandler = HorosSchemeLaunchSnapshot()
noHandler.scheme = "horos"
noHandler.candidateBundleIDs = []
noHandler.chosenBundleID = nil
noHandler.chromeMajorVersion = 152
noHandler.navigationHadUserGesture = true
noHandler.appleEventDelivered = false
dump("noLS", HorosSchemeURL.diagnose(studyURL, snapshot: noHandler))

let otherApp = HorosSchemeLaunchSnapshot()
otherApp.scheme = "horos"
otherApp.candidateBundleIDs = ["com.example.other-viewer"]
otherApp.chosenBundleID = "com.example.other-viewer"
otherApp.runningBundleID = "thalesmms.isis.workstation"
otherApp.chromeMajorVersion = 152
otherApp.navigationHadUserGesture = true
otherApp.appleEventDelivered = false
dump("otherLS", HorosSchemeURL.diagnose(studyURL, snapshot: otherApp))

let chromeBlock = HorosSchemeLaunchSnapshot()
chromeBlock.scheme = "horos"
chromeBlock.candidateBundleIDs = ["thalesmms.isis.workstation"]
chromeBlock.chosenBundleID = "thalesmms.isis.workstation"
chromeBlock.runningBundleID = "thalesmms.isis.workstation"
chromeBlock.chromeExcludedSchemes = ["horos": true]
chromeBlock.chromeMajorVersion = 152
chromeBlock.navigationHadUserGesture = true
chromeBlock.appleEventDelivered = false
dump("excluded", HorosSchemeURL.diagnose(studyURL, snapshot: chromeBlock))

let noGesture = HorosSchemeLaunchSnapshot()
noGesture.scheme = "horos"
noGesture.candidateBundleIDs = ["thalesmms.isis.workstation"]
noGesture.chosenBundleID = "thalesmms.isis.workstation"
noGesture.runningBundleID = "thalesmms.isis.workstation"
noGesture.chromeMajorVersion = 94
noGesture.navigationHadUserGesture = false
noGesture.appleEventDelivered = false
dump("gesture", HorosSchemeURL.diagnose(studyURL, snapshot: noGesture))

let prompt = HorosSchemeLaunchSnapshot()
prompt.scheme = "horos"
prompt.candidateBundleIDs = ["thalesmms.isis.workstation"]
prompt.chosenBundleID = "thalesmms.isis.workstation"
prompt.runningBundleID = "thalesmms.isis.workstation"
prompt.chromeMajorVersion = 152
prompt.navigationHadUserGesture = true
prompt.appleEventDelivered = false
dump("clickUnconfirmed", HorosSchemeURL.diagnose(studyURL, snapshot: prompt))
prompt.externalProtocolPromptObserved = true
dump("prompt", HorosSchemeURL.diagnose(studyURL, snapshot: prompt))
prompt.navigationHadUserGesture = false
dump("automaticPrompt", HorosSchemeURL.diagnose(studyURL, snapshot: prompt))
prompt.appleEventDelivered = true
dump("deliveredAfterPrompt", HorosSchemeURL.diagnose(studyURL, snapshot: prompt))

// A bad URL is a parser error even when Chrome would also have blocked it.
dump("parserWins", HorosSchemeURL.diagnose(badURL, snapshot: chromeBlock))

let prefs = """
{"protocol_handler":{"excluded_schemes":{"horos":true,"osirix":false}}}
"""
let fromPrefs = HorosSchemeLaunchSnapshot.chromeSnapshot(fromPreferencesJSON: prefs, majorVersion: 152)
fromPrefs.scheme = "horos"
fromPrefs.candidateBundleIDs = ["thalesmms.isis.workstation"]
fromPrefs.chosenBundleID = "thalesmms.isis.workstation"
fromPrefs.runningBundleID = "thalesmms.isis.workstation"
fromPrefs.navigationHadUserGesture = true
fromPrefs.appleEventDelivered = false
dump("fromPrefs", HorosSchemeURL.diagnose(studyURL, snapshot: fromPrefs))

// The application LaunchServices picks is compared with the one that is
// running, whatever its identifier: no identifier is the application's own.
func handled(_ chosenID: String?, _ chosenPath: String?, by runningID: String?, _ runningPath: String?,
             scheme: String = "horos") -> HorosSchemeDiagnosis {
    let snapshot = HorosSchemeLaunchSnapshot()
    snapshot.scheme = scheme
    snapshot.candidateBundleIDs = [chosenID ?? "unknown"]
    snapshot.chosenBundleID = chosenID
    snapshot.chosenPath = chosenPath
    snapshot.runningBundleID = runningID
    snapshot.runningPath = runningPath
    return HorosSchemeURL.diagnose(scheme + "://?methodName=DisplayStudy&StudyInstanceUID=2.25.1", snapshot: snapshot)
}
let installed = "/Applications/IsiX DICOM Viewer.app"
dump("storeBuild", handled("thalesmms.isis.Isis-DICOM-Viewer", installed, by: "thalesmms.isis.Isis-DICOM-Viewer", installed))
dump("developmentBuild", handled("thalesmms.isis.workstation.local-development", "/b/Development/IsiX DICOM Viewer.app",
                                 by: "thalesmms.isis.workstation.local-development", "/b/Development/IsiX DICOM Viewer.app"))
dump("earlierCopy", handled("thalesmms.isis.workstation", installed,
                            by: "thalesmms.isis.workstation.local-development", "/b/Development/IsiX DICOM Viewer.app"))
dump("otherChannel", handled("thalesmms.isis.workstation", installed, by: "thalesmms.isis.Isis-DICOM-Viewer", "/Users/u/IsiX DICOM Viewer.app"))
dump("secondCopy", handled("thalesmms.isis.workstation", "/Users/u/Downloads/IsiX DICOM Viewer.app", by: "thalesmms.isis.workstation", installed))
dump("isixOther", handled("com.example.other-viewer", "/Applications/Other.app", by: "thalesmms.isis.workstation", installed, scheme: "isix"))
dump("isixOwn", handled("thalesmms.isis.workstation", installed, by: "thalesmms.isis.workstation", installed, scheme: "isix"))
dump("unknownRunning", handled("thalesmms.isis.workstation", installed, by: nil, nil))

let live = HorosSchemeURL.liveSnapshot(forScheme: "horos")
emit("live.chosenPath", live.chosenPath)
emit("live.running", (live.runningBundleID ?? "nil") + " at " + (live.runningPath ?? "nil"))
emit("live.candidates", live.candidateBundleIDs.joined(separator: ","))
emit("live.chosen", live.chosenBundleID)
emit("live.chromeVersion", live.chromeMajorVersion == 0 ? "unknown" : String(live.chromeMajorVersion))
emit("live.excludedHoros", live.chromeExcludedSchemes["horos"].map { $0 ? "true" : "false" } ?? "absent")
dump("live", HorosSchemeURL.diagnose(studyURL, snapshot: live))
'''

swiftc = subprocess.run(['xcrun', '--sdk', 'macosx', '-f', 'swiftc'], capture_output=True, text=True)
results = {}
if swiftc.returncode != 0:
    failures.append('no swiftc here: %s' % (swiftc.stderr or '').strip())
elif not source.is_file():
    failures.append('HorosSchemeURL.swift is missing')
else:
    with tempfile.TemporaryDirectory(prefix='horos-scheme-launch-') as directory:
        driver = Path(directory) / 'main.swift'
        driver.write_text(DRIVER)
        binary = Path(directory) / 'scheme-launch'
        # The comparison with the running application is a rule of the module
        # of the server's rules.
        modules = isix_modules.module_flags('IsiXHTTPServer', Path(directory) / 'modules')
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-framework', 'AppKit', *modules,
                                '-o', str(binary), str(source), str(driver)],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('HorosSchemeURL.swift does not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the launch driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value


def expect(key, value, detail):
    got = results.get(key)
    if got != value:
        failures.append('%s: expected %r, got %r (%s)' % (key, value, got, detail))


if results:
    expect('delivered.layer', 'accepted', 'an Apple Event that Horos received is accepted')
    expect('delivered.code', 'ok', 'accepted system delivery')

    expect('noLS.layer', 'launchServices', 'no handler is LaunchServices, not the parser')
    expect('noLS.code', 'no-handler', 'name the missing registration')

    expect('otherLS.layer', 'launchServices', 'another app owning the scheme is LaunchServices')
    if 'com.example.other-viewer' not in (results.get('otherLS.message') or ''):
        failures.append('other-app diagnosis does not name the chosen bundle: %r'
                        % results.get('otherLS.message'))

    expect('excluded.layer', 'browser', 'Chrome excluded_schemes is a browser policy')
    expect('excluded.code', 'chrome-excluded-scheme', 'name the Chrome key')
    if 'excluded_schemes' not in (results.get('excluded.message') or ''):
        failures.append('Chrome block does not name excluded_schemes: %r'
                        % results.get('excluded.message'))

    expect('gesture.layer', 'browser', 'browser delivery still needs verification')
    expect('gesture.code', 'chrome-navigation-unconfirmed', 'no gesture alone proves no block')
    expect('clickUnconfirmed.code', 'chrome-navigation-unconfirmed', 'a click alone proves no prompt')

    expect('prompt.layer', 'browser', 'an observed prompt has a specific diagnosis')
    expect('prompt.code', 'chrome-external-protocol-prompt', 'name the prompt')
    expect('automaticPrompt.code', 'chrome-external-protocol-prompt', 'observed prompt without page activation')
    expect('deliveredAfterPrompt.layer', 'accepted', 'actual delivery takes precedence over prior prompt')

    expect('parserWins.layer', 'parser',
           'an invalid DisplayStudy stays a parser error when Chrome would also block')
    expect('parserWins.code', 'invalid-parameters', 'parser wins over browser')

    expect('fromPrefs.layer', 'browser', 'Chrome Preferences JSON is read, not rewritten')
    expect('fromPrefs.code', 'chrome-excluded-scheme', 'excluded_schemes.horos == true')

    # The running application is itself under any identifier; a copy with
    # another identifier, or elsewhere, is another application.
    expect('storeBuild.code', 'ok', 'the build for the store is not another application to itself')
    expect('developmentBuild.code', 'ok', 'nor is the development build')
    expect('earlierCopy.code', 'other-handler', 'an earlier copy with another identifier is another application')
    if '/Applications/IsiX DICOM Viewer.app' not in (results.get('earlierCopy.message') or ''):
        failures.append('the diagnosis of an earlier copy does not say where it is: %r' % results.get('earlierCopy.message'))
    expect('otherChannel.code', 'other-handler', 'a build of another channel is another application')
    expect('secondCopy.code', 'other-handler', 'the same identifier somewhere else is the copy the links open')
    expect('isixOther.code', 'other-handler', 'isix:// opened by another application is diagnosed as horos:// is')
    expect('isixOwn.code', 'ok', 'isix:// opened by the running application passes LaunchServices')
    expect('unknownRunning.code', 'other-handler', 'with nothing known of the running application, no handler is taken for it')

    # Live read is evidence, not a gate: this machine may have several copies.
    # The driver is not the application, so the handler it reads is another one.
    if results.get('live.chosen') not in (None, 'nil'):
        expect('live.code', 'other-handler', 'the handler read live is compared with the process that reads it')
    live_layer = results.get('live.layer')
    if live_layer not in ('accepted', 'launchServices', 'browser'):
        failures.append('live diagnosis is not one of the three layers: %r' % live_layer)
    print('live candidates: %s' % results.get('live.candidates'))
    print('live chosen: %s at %s' % (results.get('live.chosen'), results.get('live.chosenPath')))
    print('live running: %s' % results.get('live.running'))
    print('live chrome: %s excluded=%s → %s/%s'
          % (results.get('live.chromeVersion'), results.get('live.excludedHoros'),
             results.get('live.layer'), results.get('live.code')))

# getUrl must not rewrite LaunchServices.plist or Chrome preferences.
get_url_at = application.find('@objc(getUrl:withReplyEvent:) func getUrl(')
get_url = swift_block(application, get_url_at) if get_url_at >= 0 else ''
if not get_url:
    failures.append('getUrl: is gone')
elif 'com.apple.LaunchServices.plist' in get_url:
    failures.append('getUrl: writes LaunchServices.plist again')
if 'LSSetDefaultHandlerForURLScheme' in application:
    failures.append('AppController still calls LSSetDefaultHandlerForURLScheme')

# The handler of a scheme changes in one place, through the workspace, for a
# declared scheme, and the system is asked again afterwards.
sources = sorted((root / 'Horos/Sources').glob('*.swift')) + sorted((root / 'Preference Panes').rglob('*.swift'))
writers = [path.name for path in sources
           if re.search(r'setDefaultApplication\(|LSSetDefaultHandlerForURLScheme|LSSetDefaultRoleHandlerForContentType',
                        path.read_text(encoding='utf-8'))]
if writers != ['LinkSchemeRegistry.swift']:
    failures.append('the handler of a scheme is set outside LinkSchemeRegistry.swift: %r' % writers)
registry = (root / 'Horos/Sources/LinkSchemeRegistry.swift').read_text(encoding='utf-8')
for name in ('take', 'giveBack'):
    at = registry.find('    func %s(_ scheme: String) async' % name)
    body = swift_block(registry, at) if at >= 0 else ''
    if not body:
        failures.append('LinkSchemeRegistry.%s is gone' % name)
        continue
    declared_at, set_at, read_at = (body.find(text) for text in ('guard LinkSchemeHandlers.isDeclared(scheme)', 'await Self.setHandler(',
                                                                 'let after = Self.handler(of: scheme)'))
    if not 0 <= declared_at < set_at:
        failures.append('LinkSchemeRegistry.%s changes a scheme before checking that it is declared' % name)
    if not 0 <= set_at < read_at:
        failures.append('LinkSchemeRegistry.%s does not ask the system again after the change' % name)
if re.search(r'\bProcess\(|NSTask', registry):
    failures.append('LinkSchemeRegistry runs a tool')

# At launch: once the launch has finished, through the rule, with no modal.
lifecycle = (root / 'Horos/Sources/ApplicationLifecycle.swift').read_text(encoding='utf-8')
finished = swift_block(lifecycle, lifecycle.find('    func didFinishLaunching() {'))
if not 0 <= finished.find('LaunchEnd.reach()') < finished.find('LinkSchemeStartupCheck(preferences: preferences).run()'):
    failures.append('the link schemes are not looked at once the launch has finished')
check = (root / 'Horos/Sources/LinkSchemeStartupCheck.swift').read_text(encoding='utf-8')
if 'LinkSchemeHandlers.decisions(' not in check:
    failures.append('the launch check does not take its answer from LinkSchemeHandlers.decisions')
for modal in ('runModal', 'beginSheet', 'HorosAlertPanel', 'NSAlert('):
    if modal in check:
        failures.append('the launch check of the link schemes uses %s: a link may have launched the app' % modal)

if 'LSIsAppleDefaultForType' not in info:
    failures.append('Info.plist no longer claims the default role for the schemes')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: diagnosis names LaunchServices, Chrome protocol policy, and the '
      'parser as separate layers, and never writes a browser or LS preference')
