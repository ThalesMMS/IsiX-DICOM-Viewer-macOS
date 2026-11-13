#!/usr/bin/env python3
"""The opening and the arrangement of the viewers' windows store no preference of their own.

While a study opens, a series loads, the windows are tiled or a viewer is full
screen, the application needs some preferences at values of its own: the
propagation of settings off, the tiling on or off, the saved layouts loaded or
not, the list of series kept, the lists not following one another, the next
series in one viewer, the viewers of another patient left alone. It used to
write the preference and write back the value it had read: a value that was
only the registered one became the person's, the value of a launch argument was
stored over the person's, and an application that ended in the middle (or an
exception) left the value of the work as the person's choice. COPYSETTINGS was
found stored as false that way.

The values are now for the process and for as long as the work lasts
(IsiXPreferences' TemporaryPreferenceHolds, whose tests are
Modules/IsiXPreferences/Tests/TemporaryPreferenceHoldsTests.swift), given
through TemporaryPreferenceWork, which takes them back also when the work
raises an Objective-C exception.

- scope: TemporaryPreferenceWork.swift, compiled as it is with IsiXPreferences
  and the application's exception guards, over defaults of the test's own. For
  each of the seven keys, with a value the person stored either way and with
  none stored: the work reads its value, nothing is stored meanwhile nor
  afterwards, also when the work raises in the middle, and the exception
  reaches the caller. Work inside work, as the opener calls the loader and
  the arranger, leaves the outer value until the outer work ends, whichever
  raises. The tiling tells the application nothing of its value. A choice
  made meanwhile, as the fusion makes, stays.
- text: the eleven files of the viewers' windows no longer store any of the
  seven keys, each point takes its value through the scope or a hold, and the
  two places that store the propagation on purpose (a hanging protocol, a
  saved layout) say so and go through `choose`, as the fusion does.

`<git revision>` as an optional argument reads the sources of the application
from that revision for the text, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # noqa: E402
import isix_modules  # noqa: E402
import objc_exception_guards  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
SCOPE = 'Horos/Sources/TemporaryPreferenceWork.swift'


def source(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode() if shown.returncode == 0 else ''
    file = root / path
    return file.read_text(encoding='utf-8') if file.exists() else ''


def code(path):
    """The source without its comment lines."""
    return '\n'.join(line for line in source(path).splitlines() if not line.strip().startswith('//'))


def check(condition, message):
    if not condition:
        failures.append(message)


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

# ---------------------------------------------------------------- scope

DRIVER = harness_defaults.DOMAINS + r'''
import Foundation
import IsiXPreferences
import ObjectiveC

var failures: [String] = []
@MainActor func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

// The application's defaults are a domain of this test only.
let suite = harnessDomainName("viewer-temporary-preferences-\(getpid())")
let controlled = UserDefaults(suiteName: suite)!
extension UserDefaults { @objc class func controlled_standardUserDefaults() -> UserDefaults { controlled } }
method_exchangeImplementations(class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!,
                               class_getClassMethod(UserDefaults.self, #selector(UserDefaults.controlled_standardUserDefaults))!)
@MainActor func stored() -> NSDictionary { (controlled.persistentDomain(forName: suite) ?? [:]) as NSDictionary }

/// The application is told, or not, that preferences changed.
@MainActor enum AppController {
    static var told: [Bool] = []
    static func checkForPreferencesUpdate(_ check: Bool) { told.append(check) }
}

/// The keys the viewers' windows hold, and the value the work gives each.
let held: [(key: PreferenceKey<Bool>, given: Bool)] = [
    (ViewerPreferences.copySettings, false), (ViewerPreferences.autoTiling, false), (ViewerPreferences.autoTiling, true),
    (ViewerPreferences.automaticWorkspaceLoad, false), (ViewerPreferences.automaticWorkspaceLoad, true),
    (ViewerPreferences.autoHidesMatrix, false), (DatabasePreferences.syncPreviewList, false),
    (ViewerPreferences.nextSeriesToAllViewers, false), (ViewerPreferences.onlyDisplayImagesOfSamePatient, false),
]
let registered: [String: Bool] = [
    ViewerPreferences.copySettings.name: true, ViewerPreferences.autoTiling.name: true, ViewerPreferences.automaticWorkspaceLoad.name: true,
    ViewerPreferences.autoHidesMatrix.name: false, DatabasePreferences.syncPreviewList.name: true,
    ViewerPreferences.nextSeriesToAllViewers.name: true, ViewerPreferences.onlyDisplayImagesOfSamePatient.name: false,
]
controlled.register(defaults: registered.mapValues { $0 ? "1" : "0" })

@MainActor func run() {
    for (key, given) in held {
        for chosen in [true, false, nil] as [Bool?] {
            let label = "\(key.name) at \(given), \(chosen.map { "stored \($0)" } ?? "only registered")"
            controlled.removeObject(forKey: key.name)
            if let chosen { controlled.set(chosen, forKey: key.name) }
            let before = stored(), read = controlled[key]
            check(read == (chosen ?? registered[key.name]!), "\(label): the test's own defaults read \(read)")

            // Work that ends.
            var inside: Bool?
            TemporaryPreferenceWork.during(key, at: given) {
                inside = controlled[key]
                check(stored().isEqual(before), "\(label): something is stored while the work lasts")
            }
            check(inside == given, "\(label): the work read \(String(describing: inside))")
            check(controlled[key] == read, "\(label): the key does not read as before once the work ended")
            check(stored().isEqual(before), "\(label): the stored preferences changed: \(stored()[key.name] ?? "nothing") stored")

            // Work that raises in the middle: the caller gets the exception, and the value is taken back.
            let raised = HorosObjCException.caught {
                TemporaryPreferenceWork.during(key, at: given) {
                    check(controlled[key] == given, "\(label): the work that raises did not read its value")
                    NSException(name: .rangeException, reason: "raised in the middle", userInfo: nil).raise()
                }
            }
            check(raised?.reason == "raised in the middle", "\(label): the exception did not reach the caller")
            check(controlled[key] == read, "\(label): work that raised left its value for the process")
            check(stored().isEqual(before), "\(label): work that raised changed the stored preferences")
            check(!TemporaryPreferenceHolds.standard.isHeld(key), "\(label): a hold outlived the work")
        }
        controlled.removeObject(forKey: key.name)
    }

    // The opener has the windows tiled, the loader of each series keeps its settings to itself, and
    // the arranger tiles them: work inside work, on the same keys.
    let propagation = ViewerPreferences.copySettings, tiling = ViewerPreferences.autoTiling
    controlled.set(false, forKey: tiling.name)
    let before = stored()
    AppController.told = []
    for raising in [false, true] {
        let raised = HorosObjCException.caught {
            TemporaryPreferenceWork.during(tiling, at: true) {
                for series in 0..<2 {
                    TemporaryPreferenceWork.during(propagation, at: false) {
                        check(!controlled[propagation] && controlled[tiling], "opening, series \(series): the loader does not read both values")
                    }
                    check(controlled[propagation] && controlled[tiling], "opening: a series loaded took the opener's tiling back with it, or kept the propagation off")
                }
                TemporaryPreferenceWork.during(propagation, at: false) {
                    TemporaryPreferenceWork.during(propagation, at: false, silently: true) {
                        check(!controlled[propagation], "opening: the arranger does not read the propagation off")
                        if raising { NSException(name: .genericException, reason: "the arranger raised", userInfo: nil).raise() }
                    }
                    check(!controlled[propagation], "opening: the arranger took the loader's value back")
                }
            }
        }
        check((raised != nil) == raising, "opening: \(raising ? "the exception of the arranger did not reach the opener's caller" : "an exception came from nowhere")")
        check(controlled[propagation] && !controlled[tiling], "opening (raising: \(raising)): the keys do not read as the person has them afterwards")
        check(stored().isEqual(before), "opening (raising: \(raising)): the stored preferences changed")
        check(!TemporaryPreferenceHolds.standard.isHeld(propagation) && !TemporaryPreferenceHolds.standard.isHeld(tiling), "opening (raising: \(raising)): a hold outlived the opening")
    }
    // Told nothing when the arranger's value is given, and nothing when it is taken back, also when it raised.
    check(AppController.told == [false, true, false, true, false, true, false, true], "the tiling told the application of its value: \(AppController.told)")

    // The fusion turns the propagation on while a series loads: it stays on, stored as a choice.
    controlled.set(false, forKey: propagation.name)
    TemporaryPreferenceWork.during(propagation, at: false) {
        TemporaryPreferenceHolds.standard.choose(true, for: propagation)
        check(controlled[propagation], "a choice made while the work lasts does not show at once")
    }
    check(controlled[propagation] && (stored()[propagation.name] as? Bool) == true, "a choice made while the work lasts did not stay")
}

MainActor.assumeIsolated { run() }
controlled.removePersistentDomain(forName: suite)
for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

scope = root / SCOPE
if not scope.is_file():
    failures.append(f'{SCOPE} is not there: the work of the viewers\' windows has no scope for the values it gives preferences')
else:
    with tempfile.TemporaryDirectory(prefix='horos-viewer-temporary-preferences-') as directory:
        work = Path(directory)
        (work / 'main.swift').write_text(DRIVER)
        (work / 'guards.swift').write_text(objc_exception_guards.source(log=False))
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=15.0', '-c', str(root / 'Horos/Sources/HorosObjCException.m'),
                        '-o', str(work / 'HorosObjCException.o')], check=True)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(root / 'Horos/Sources/HorosObjCException.h'),
                                str(work / 'main.swift'), str(work / 'guards.swift'), str(scope), str(work / 'HorosObjCException.o'),
                                *isix_modules.module_flags('IsiXPreferences', work / 'modules'), '-o', str(work / 'test')],
                               capture_output=True, text=True, timeout=600)
        if built.returncode != 0:
            failures.append('the scope does not build: ' + built.stderr[-3000:])
        else:
            ran = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=300)
            if ran.returncode != 0:
                found = [line[len('FAIL: '):] for line in ran.stdout.splitlines() if line.startswith('FAIL:')]
                failures.extend(found[:12] or [f'the scope ended with {ran.returncode}: {(ran.stdout + ran.stderr)[-1500:]}'])
            else:
                print('ok: scope - each of the seven keys reads the value of the work, stores nothing and comes back, also when the work raises, alone and nested')

# ---------------------------------------------------------------- text

KEYS = ['copySettings', 'autoTiling', 'automaticWorkspaceLoad', 'autoHidesMatrix', 'syncPreviewList', 'nextSeriesToAllViewers',
        'onlyDisplayImagesOfSamePatient']
STORES = re.compile(r'\.set\([^\n]*for: (?:ViewerPreferences|DatabasePreferences)\.(%s)\b' % '|'.join(KEYS))
# file: what each of its points takes its value through
POINTS = {
    'Horos/Sources/FullScreenSession.swift': [
        'TemporaryPreferenceHolds.standard.hold(ViewerPreferences.copySettings, at: false, keptBy: viewer)',
        'TemporaryPreferenceHolds.standard.release(ViewerPreferences.copySettings, keptBy: viewer)'],
    'Horos/Sources/ITKTransform+Viewer.swift': ['TemporaryPreferenceWork.during(ViewerPreferences.autoTiling, at: false) {'],
    'Horos/Sources/ViewerOpener.swift': [
        'TemporaryPreferenceWork.during(ViewerPreferences.automaticWorkspaceLoad, at: false, openEach)',
        'TemporaryPreferenceWork.during(ViewerPreferences.autoTiling, at: true) {',
        'TemporaryPreferenceHolds.standard.choose(plistBool(propagate), for: ViewerPreferences.copySettings)',
        'TemporaryPreferenceHolds.standard.choose(plistBool(propagateSettings), for: ViewerPreferences.copySettings)'],
    'Horos/Sources/ViewerOpener+Navigation.swift': ['TemporaryPreferenceWork.during(ViewerPreferences.onlyDisplayImagesOfSamePatient, at: false) {'],
    'Horos/Sources/ViewerSeriesLoader.swift': [
        'listStays = TemporaryPreferenceHolds.standard.hold(ViewerPreferences.autoHidesMatrix, at: false)',
        'TemporaryPreferenceHolds.standard.release(listStays)',
        'TemporaryPreferenceWork.during(ViewerPreferences.copySettings, at: false) {'],
    'Horos/Sources/ViewerWindowArranger.swift': ['TemporaryPreferenceWork.during(ViewerPreferences.copySettings, at: false, silently: true) {'],
    'Horos/Sources/ViewerController+SeriesPopup.swift': [
        'TemporaryPreferenceWork.during(DatabasePreferences.syncPreviewList, at: false) {',
        'TemporaryPreferenceWork.during(ViewerPreferences.autoHidesMatrix, at: false) {'],
    'Horos/Sources/ViewerController+StudyNavigation.swift': ['TemporaryPreferenceWork.during(ViewerPreferences.nextSeriesToAllViewers, at: false) {'],
    'Horos/Sources/ViewerController+WindowLayout.swift': ['TemporaryPreferenceWork.during(ViewerPreferences.autoTiling, at: false) {'],
    'Horos/Sources/ViewerWorkspaceArchiver.swift': ['TemporaryPreferenceWork.during(ViewerPreferences.automaticWorkspaceLoad, at: true) {'],
    'Horos/Sources/ApplicationMenus.swift': ['TemporaryPreferenceWork.during(ViewerPreferences.automaticWorkspaceLoad, at: true) {'],
}
for path, points in POINTS.items():
    text = code(path)
    check(text, f'{path} is not there')
    for stored in STORES.finditer(text):
        failures.append(f'{path} stores "{stored.group(1)}" again: {text[text.rfind(chr(10), 0, stored.start()) + 1:stored.end()].strip()[:110]}')
    for point in points:
        check(point in text, f'{path}: the point that took its value through «{point[:90]}» is gone')

# The loader gives its hold back where every way out of the loading passes: after the guard of the loading, never inside it.
loader = code('Horos/Sources/ViewerSeriesLoader.swift')
taken = loader.find('listStays = TemporaryPreferenceHolds.standard.hold(')
guarded, given_back = loader.find('if let exception {', taken), loader.find('TemporaryPreferenceHolds.standard.release(listStays)')
check(0 <= taken < guarded < given_back, 'the loader does not give the list of series back after the guard of the loading, where an exception and an early stop arrive too')

# The places that store the propagation of settings on purpose say why, and the fusion chooses it too.
opener = source('Horos/Sources/ViewerOpener.swift')
check(opener.count('Stored on purpose, and never put back') == 2, 'the hanging protocol and the saved layout no longer say why they store the propagation of settings')
fusion = code('Horos/Sources/ViewerFusion.swift')
check(fusion.count('TemporaryPreferenceHolds.standard.choose(true, for: ViewerPreferences.copySettings)') == 2 and not STORES.search(fusion),
      'the fusion stores the propagation of settings without ending what the work under way holds of it: it would stay off until that work ended')

# The full screen leaves by the same call when its viewer closes.
check('if viewer.horos_FullScreenOn { viewer.fullScreenMenu(viewer) }' in code('Horos/Sources/ViewerSessionGraph+WindowLife.swift'),
      'a viewer that closes while full screen no longer leaves it, and would keep its hold until it is released')

scope_text = code(SCOPE)
order = [scope_text.find(part) for part in ('let hold = holds.hold(key, at: value)', 'let raised = HorosObjCException.caught(work)', 'holds.release(hold)', 'raised?.raise()')]
check(all(place >= 0 for place in order) and order == sorted(order), 'the scope does not take the value back before the exception of the work goes on')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('ok: text - the eleven files of the viewers\' windows store none of the seven keys, each point takes its value for the process')
print('PASS: the opening and the arrangement of the viewers\' windows store no preference of their own')
