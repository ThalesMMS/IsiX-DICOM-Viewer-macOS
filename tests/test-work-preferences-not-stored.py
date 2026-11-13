#!/usr/bin/env python3
"""Work that overrides a preference while it lasts never writes it.

Several pieces of work of the application stored their own value under a
preference of the user and put back afterwards the value they had read: the
zoom drag of a curved MPR's transverse view (MouseClickZoomCentered, at every
event), the layout of the planes of an MPR and of a curved MPR
(syncZoomLevelMPR), the selection of "Database" in the albums
(clearSearchAndTimeIntervalWhenSelectingAlbum), the migration of the former
application's studies (COPYDATABASE, COPYDATABASEMODE). A value that was only
the registered one was then stored as the user's, a value given at the launch
was written over the user's, and an exception or an application that ended in
the middle left the work's value as the user's choice.

The work now holds a state of the process (ForcedPreference) that the code
which decides by the key asks, or is told the value as a parameter. Compiled
here, as they stand, with the real IsiXPreferences, IsiXImaging, IsiXDatabase
and HorosObjCException, around controlled preferences (a suite of the test's
own) that start, for each key, stored on, stored off, only registered, absent
and given at the launch:

  * the guards of PreferenceWorkGuards.swift: the readers that ask are
    answered the work's value while it runs, the stored preferences and the
    launch's are as before during and after, and work that raises an
    NSException releases what it held before the exception reaches the caller;
  * -selectNoAlbums: of the browser with the expression its
    -tableViewSelectionDidChange: reads: the search is kept while "Database"
    is selected, also when the selection raises;
  * the declaration of the state the MPR and the curved MPR share with the
    condition their cross-reference lines read, and by their text: the layout
    of the planes runs inside the guard, and neither writes the setting;
  * -mouseDraggedZoom: of the transverse view beside the image view's: the
    same scale and the origin of a zoom that is not centred on the click,
    whatever the setting says, with nothing read or written;
  * the options the migration hands its import with the lines of the import
    that read them: the files are copied whatever the settings say.
"""
from pathlib import Path
import re
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults
import isix_modules
import objc_exception_guards
from sources import source_path, source_text

ROOT = Path(__file__).resolve().parents[1]


def block(text, signature, where):
    """From the line of `signature` to the brace that closes the block it opens."""
    assert text.count(signature) == 1, f'{where}: {text.count(signature)} of {signature!r}'
    start = text.rindex('\n', 0, text.index(signature)) + 1
    depth, index = 0, text.index('{', text.index(signature))
    while True:
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[start:index + 1]
        index += 1


def one(pattern, text, where):
    found = re.findall(pattern, text)
    assert len(found) == 1, f'{where}: {len(found)} of {pattern!r}'
    return found[0]


# The browser: the state, the selection of "Database" and what the change of selection reads.
albums = source_text('BrowserController+Albums')
albums_state = one(r'\n(    nonisolated static let searchKeptForDatabase = [^\n]+)\n', albums, 'BrowserController+Albums')
select_no_albums = block(albums, '    @objc(selectNoAlbums:)', 'BrowserController+Albums')
clears_search = one(r'albumSelectionChanged\(clearsSearch: (.+)\)\n', source_text('BrowserController+AlbumsTableView'), 'BrowserController+AlbumsTableView')
assert 'searchKeptForDatabase.value(in:' in clears_search, clears_search
assert not re.search(r'\.set\([^\n]*clearsSearchWhenSelectingAlbum', albums), 'the browser stores the setting'

# The MPR and the curved MPR: one state, asked by the cross-reference lines of both.
mpr, cpr = source_text('MPRController'), source_text('CPRController')
planes_state = one(r'\n(    nonisolated static let planesLayoutZoomSync = [^\n]+)\n', mpr, 'MPRController')
conditions = {}
for name, text, layout in (('MPRController', mpr, 'private dynamic func resetMPRPlanes('), ('CPRController', cpr, 'public override dynamic func showWindow(')):
    assert 'syncsZoomLevelMPR' not in text.replace(planes_state, ''), f'{name} reads or writes the setting outside the state'
    lines = block(text, '    @objc(computeCrossReferenceLines:)', name)
    conditions[name] = one(r'\n            if (.+planesLayoutZoomSync\.value\(in: self\.preferenceStore\)) \{\n', lines, name)
    # The planes are laid out inside the guard, from their default thickness to the tool of the window.
    method = block(text, layout, name)
    guarded = block(method, 'planesLayoutZoomSync.whileWorking {', name)
    for statement in ('self.clippingRangeMode = 1', 'mprView1?.vrView?.resetImage(self)', 'mprView1?.updateViewMPR(onLoading: isInitializing)',
                      'mprView3?.updateViewMPR(onLoading: isInitializing)', 'super.showWindow(sender)', 'self.setTool(toolsMatrix)'):
        assert statement in guarded, f'{name}: {statement} is outside the guard'
    assert guarded.rstrip().endswith('}') and 'dontUseAutoLOD = false' not in guarded and 'dontUseAutoLOD = false' in method

# The transverse view of the curved MPR and the image view: their zoom drags.
transverse = source_text('CPRTransverseView')
assert 'preferenceStore' not in transverse and 'ouseClickZoomCentered' not in transverse, 'the transverse view reads or writes the setting'
transverse_drag = block(transverse, '    public override func mouseDraggedZoom(', 'CPRTransverseView')
assert 'super.mouseDraggedZoom' not in transverse_drag and 'zoomDragOrigin(click: nil,' in transverse_drag
image_drag = block(source_text('DCMView+MouseDragging'), '    @objc(mouseDraggedZoom:)', 'DCMView+MouseDragging')

# The migration: what it tells its import, and how the import reads what it is told.
migration = source_text('O2HMigrationAssistant')
assert 'copyToDatabase' not in migration, 'the migration touches the copy settings'
overrides = one(r'droppedFiles\.add\(\[osirixPath\], overriding: (\[\n(?:[^\n]*\n)+?\s*\])\)', migration, 'O2HMigrationAssistant')
dropped = source_text('DroppedFilesImport')
assert 'func add(_ paths: [String], overriding overrides: [AnyHashable: Any] = [:]) {' in dropped
import_options = one(r'\n        importFiles\(files, options: (.+)\)\n', block(dropped, '    func add(_ paths: [String], overriding', 'DroppedFilesImport'), 'DroppedFilesImport')
import_files = block(dropped, '    func importFiles(_ paths: [String], options: [AnyHashable: Any]) -> Bool {', 'DroppedFilesImport')
copy_choice = one(r'\n(        var copyEnabled = [^\n]+\n        var mode = [^\n]+\n        if let value = options\["COPYDATABASE"\][^\n]+\n        if let value = options\["COPYDATABASEMODE"\][^\n]+\n)',
                  import_files, 'DroppedFilesImport')

DRIVER = harness_defaults.DOMAINS + r'''
import AppKit
import IsiXDatabase
import IsiXImaging
import IsiXPreferences

// The application's preferences are a suite of this test only.
let suite = harnessDomainName("work-preferences-\(getpid())")
let controlled = UserDefaults(suiteName: suite)!
enum PreferencesSource {
    enum process { static var preferences: UserDefaults { controlled } }
}

typealias Domain = [String: AnyHashable]
func stored() -> Domain { (controlled.persistentDomain(forName: suite) ?? [:]).compactMapValues { $0 as? AnyHashable } }
func volatile(_ name: String) -> Domain { controlled.volatileDomain(forName: name).compactMapValues { $0 as? AnyHashable } }

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0
func check(_ condition: Bool, _ what: @autoclosure () -> String) { checks += 1; if !condition { failures.append(what()) } }

/// How a key stands before the work: what the user stored, what the
/// application registered, what the launch gave.
enum Had: String, CaseIterable { case storedOn, storedOff, registeredOn, absent, launchOn, launchOffOverStoredOn }

/// Arranges `key` as `had`, with `on` and `off` its two values, runs `body`
/// with the value a reader of the preferences finds, and checks that the stored
/// preferences, the launch's and the registered ones are afterwards as before.
func with<Value: Hashable>(_ key: String, _ had: Had, on: Value, off: Value, _ what: String, _ body: (_ users: Value, _ unchanged: @escaping () -> Bool) -> Void) {
    let launch = controlled.volatileDomain(forName: UserDefaults.argumentDomain)
    let registered = controlled.volatileDomain(forName: UserDefaults.registrationDomain)
    defer {
        controlled.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)
        controlled.setVolatileDomain(registered, forName: UserDefaults.registrationDomain)
        controlled.removeObject(forKey: key)
    }
    controlled.removeObject(forKey: key)
    controlled.set("kept", forKey: "sentinel")
    var users = off
    switch had {
    case .storedOn: controlled.set(on, forKey: key); users = on
    case .storedOff: controlled.set(off, forKey: key)
    case .registeredOn: controlled.register(defaults: [key: on]); users = on
    case .absent: break
    case .launchOn, .launchOffOverStoredOn:
        if had == .launchOffOverStoredOn { controlled.set(on, forKey: key) }
        var given = launch
        given[key] = had == .launchOn ? on : off
        controlled.setVolatileDomain(given, forName: UserDefaults.argumentDomain)
        users = had == .launchOn ? on : off
    }
    let before = (stored(), volatile(UserDefaults.argumentDomain), volatile(UserDefaults.registrationDomain))
    let unchanged = { stored() == before.0 && volatile(UserDefaults.argumentDomain) == before.1 && volatile(UserDefaults.registrationDomain) == before.2 }
    body(users, unchanged)
    check(unchanged(), "\(what), \(had.rawValue): the stored preferences are \(stored()) and the launch's \(volatile(UserDefaults.argumentDomain)), not as before (\(before.0), \(before.1))")
}

func raise(_ reason: String) { NSException(name: .genericException, reason: reason, userInfo: nil).raise() }

// MARK: The guards

MainActor.assumeIsolated {
    let sync = PreferenceKey<Bool>("syncZoomLevelMPR")
    for had in Had.allCases {
        with(sync.name, had, on: true, off: false, "a state held by work") { users, unchanged in
            let work = ForcedPreference(sync, to: true)
            check(work.value(in: controlled) == users, "\(had.rawValue): before the work the reader is answered the user's value")
            var ran = false
            work.whileWorking {
                ran = true
                check(work.value(in: controlled), "\(had.rawValue): the reader that asks is answered the work's value")
                check(controlled[sync] == users, "\(had.rawValue): a reader that does not ask reads the user's value")
                check(unchanged(), "\(had.rawValue): nothing is stored while the work runs")
            }
            check(ran && !work.isHeld && work.value(in: controlled) == users, "\(had.rawValue): the work ended, the reader is answered the user's value again")

            // Work that raises: released before the exception reaches the caller.
            var heldAtCatch: Bool?
            let raised = HorosObjCException.caught {
                HorosObjCException.caught({
                    work.whileWorking {
                        check(work.value(in: controlled), "\(had.rawValue): held before it raises")
                        raise("in the middle")
                    }
                }, catch: { exception in
                    heldAtCatch = work.isHeld
                    exception.raise()
                })
            }
            check(raised?.reason == "in the middle" && heldAtCatch == false, "\(had.rawValue): work that raises releases the state, and the exception goes on (\(String(describing: raised?.reason)), \(String(describing: heldAtCatch)))")
            check(work.value(in: controlled) == users && unchanged(), "\(had.rawValue): after the exception the reader is answered the user's value and nothing was stored")
        }
    }

    // A value for the process: hideListenerError, read on every thread through the preferences themselves.
    let hides = PreferenceKey<Bool>("hideListenerError")
    for had in Had.allCases {
        with(hides.name, had, on: true, off: false, "a value for the process") { users, unchanged in
            let launchBefore = volatile(UserDefaults.argumentDomain)
            let storedBefore = stored()
            var ran = false
            TemporaryPreference(hides, in: controlled).whileWorking(with: true) {
                ran = true
                check(controlled[hides] && UserDefaults.standard.bool(forKey: hides.name), "\(had.rawValue): every reader of the process reads the work's value")
                var elsewhere = false
                let thread = Thread { elsewhere = UserDefaults.standard.bool(forKey: hides.name) }
                thread.start()
                while !thread.isFinished { usleep(200) }
                check(elsewhere, "\(had.rawValue): on another thread too")
                check(stored() == storedBefore, "\(had.rawValue): nothing is stored while the work runs")
            }
            check(ran && controlled[hides] == users && volatile(UserDefaults.argumentDomain) == launchBefore, "\(had.rawValue): the value is taken back, the launch's as it was")

            var readAtCatch: Bool?
            let raised = HorosObjCException.caught {
                HorosObjCException.caught({
                    TemporaryPreference(hides, in: controlled).whileWorking(with: true) { raise("in the middle") }
                }, catch: { exception in
                    readAtCatch = controlled[hides]
                    exception.raise()
                })
            }
            check(raised?.reason == "in the middle" && readAtCatch == users, "\(had.rawValue): work that raises takes the value back before the exception goes on")
            check(unchanged(), "\(had.rawValue): after the exception everything is as before")
        }
    }
}

// MARK: The albums of the browser

final class AlbumTable {
    var selected: () -> Void = {}
    func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection: Bool) { selected() }
}

final class BrowserController: NSObject {
    var horos_albumTable: AlbumTable? = AlbumTable()
<THE STATE OF THE ALBUMS>

<SELECT NO ALBUMS>

    /// What -tableViewSelectionDidChange: hands the study list.
    func clearsSearch() -> Bool { <CLEARS SEARCH> }
}

do {
    let key = "clearSearchAndTimeIntervalWhenSelectingAlbum"
    for had in Had.allCases {
        with(key, had, on: true, off: false, "the selection of Database") { users, unchanged in
            let browser = BrowserController()
            check(browser.clearsSearch() == users, "\(had.rawValue): an album selected clears the search as the settings say")
            var during: Bool?
            browser.horos_albumTable?.selected = {
                during = browser.clearsSearch()
                check(unchanged(), "\(had.rawValue): nothing is stored while Database is selected")
            }
            browser.selectNoAlbums(nil)
            check(during == false, "\(had.rawValue): Database selected keeps the search (\(String(describing: during)))")
            check(browser.clearsSearch() == users, "\(had.rawValue): and the next album clears it as the settings say")

            browser.horos_albumTable?.selected = { raise("the table") }
            let raised = HorosObjCException.caught { browser.selectNoAlbums(nil) }
            check(raised?.reason == "the table" && browser.clearsSearch() == users && !BrowserController.searchKeptForDatabase.isHeld,
                  "\(had.rawValue): a selection that raises leaves nothing held")
        }
    }
}

// MARK: The planes of the MPR and of the curved MPR

final class MPRController {
    let preferenceStore: any PreferenceStore = controlled
<THE STATE OF THE PLANES>
    func syncsZoom() -> Bool { <THE MPR CONDITION> }
}

final class CPRController {
    let preferenceStore: any PreferenceStore = controlled
    func syncsZoom() -> Bool { <THE CPR CONDITION> }
}

do {
    let mpr = MPRController(), cpr = CPRController()
    for had in Had.allCases {
        with("syncZoomLevelMPR", had, on: true, off: false, "the layout of the planes") { users, unchanged in
            check(mpr.syncsZoom() == users && cpr.syncsZoom() == users, "\(had.rawValue): the zooms go together as the window's setting says")
            MPRController.planesLayoutZoomSync.whileWorking {
                check(mpr.syncsZoom() && cpr.syncsZoom(), "\(had.rawValue): they go together while the planes are laid out")
                check(unchanged(), "\(had.rawValue): nothing is stored while the planes are laid out")
            }
            check(mpr.syncsZoom() == users && cpr.syncsZoom() == users, "\(had.rawValue): and as the setting says afterwards")
        }
    }
}

// MARK: The zoom drags

final class Pix { var pwidth = 256 }
enum PreciseMouse { static func appliedDelta(_ delta: Double) -> Double { delta * 0.5 } }
let kMouseClickZoomCentered: NSString = "MouseClickZoomCentered"
struct DraggingDefaults { func draggingBoolForKey(_ key: NSString) -> Bool { controlled.bool(forKey: key as String) } }
func standardDefaults() -> DraggingDefaults? { DraggingDefaults() }

class DCMView: NSView {
    var viewport = ViewportState(scale: 2, origin: CGPoint(x: 12, y: -7), rotation: 30, xFlipped: true)
    var horos_start = NSPoint(x: 310, y: 95)
    var horos_drawingFrameRect = NSRect(x: 0, y: 0, width: 800, height: 600)
    var curDCM: Pix? = Pix()
    var current = NSPoint(x: 330, y: 155)
    var originSet: [Float] = []
    static var horos_static_deg2rad: Double { Double.pi / 180.0 }
    var scaleValue: Float {
        get { viewport.scale }
        set { viewport.scale = newValue }
    }
    func currentPoint(inView event: NSEvent!) -> NSPoint { current }
    func setOriginX(_ x: Float, y: Float) { originSet = [x, y] }

<THE DRAG OF THE IMAGE VIEW>
}

final class TransverseController {
    var propagated = 0
    func propagateOriginRotationAndZoom(toTransverseViews view: CPRTransverseView) { propagated += 1 }
}

final class CPRTransverseView: DCMView {
    var cprController: TransverseController? = TransverseController()

<THE DRAG OF THE TRANSVERSE VIEW>
}

MainActor.assumeIsolated {
    func dragged(_ view: DCMView) -> [Float] {
        view.viewport.beginDrag()
        view.mouseDraggedZoom(nil)
        return [view.scaleValue] + view.originSet
    }
    // The image view, with the setting off and on: the drag this test tells apart.
    controlled.set(false, forKey: "MouseClickZoomCentered")
    let aboutTheMiddle = dragged(DCMView())
    controlled.set(true, forKey: "MouseClickZoomCentered")
    let aboutTheClick = dragged(DCMView())
    controlled.removeObject(forKey: "MouseClickZoomCentered")
    check(aboutTheMiddle.count == 3 && aboutTheMiddle != aboutTheClick && aboutTheMiddle[0] == aboutTheClick[0] && aboutTheMiddle[0] != 2,
          "the image view zooms about the click or about the middle, by the same scale: \(aboutTheMiddle), \(aboutTheClick)")

    for had in Had.allCases {
        with("MouseClickZoomCentered", had, on: true, off: false, "the zoom drag of the transverse view") { _, unchanged in
            let view = CPRTransverseView()
            for event in 1...3 {
                check(dragged(view) == aboutTheMiddle, "\(had.rawValue): the transverse view zooms about the middle, as the image view with the setting off")
                check(view.cprController?.propagated == event, "\(had.rawValue): and tells the other sections once an event")
                check(unchanged(), "\(had.rawValue): nothing is stored at an event of the drag")
                view.viewport = DCMView().viewport
            }
        }
    }
}

// MARK: The migration's import

func copyChoice(overrides: [AnyHashable: Any]) -> (copies: Bool, mode: Int) {
    let preferences = controlled
    let options: [AnyHashable: Any] = <THE OPTIONS OF THE IMPORT>
<THE COPY CHOICE>
    return (copyEnabled, mode)
}

do {
    let always = 0
    let migration: [AnyHashable: Any] = <THE OVERRIDES OF THE MIGRATION>
    for dicomOnly in [false, true] {
        if dicomOnly { controlled.set(true, forKey: "onlyDICOM") }
        for (copies, mode) in [(false, 3), (true, 3), (false, 0), (true, 2)] {
            for had in [Had.storedOn, .registeredOn, .launchOn] {
                with("COPYDATABASE", had, on: copies, off: !copies, "the migration's import") { _, _ in
                    with("COPYDATABASEMODE", had, on: mode, off: 0, "the migration's import") { _, unchanged in
                        let plain = copyChoice(overrides: [:])
                        check(plain.copies == copies && plain.mode == mode, "\(had.rawValue): an import copies as the settings say (\(plain))")
                        let migrated = copyChoice(overrides: migration)
                        check(migrated.copies && migrated.mode == always, "\(had.rawValue): the migration's files are always copied (\(migrated))")
                        check(unchanged(), "\(had.rawValue): the settings are not written")
                    }
                }
            }
        }
        controlled.removeObject(forKey: "onlyDICOM")
    }
}

controlled.removePersistentDomain(forName: suite)
if !failures.isEmpty {
    for failure in failures.prefix(40) { print("FAIL: " + failure) }
    print("\(failures.count) of \(checks) checks failed")
    exit(1)
}
print("PASS: \(checks) checks: the work's value is what its readers are answered while it runs, also when it raises, and the preferences "
      + "(stored on or off, only registered, absent or given at the launch) are afterwards as they were")
'''

REPLACEMENTS = {
    '<THE STATE OF THE ALBUMS>': albums_state,
    '<SELECT NO ALBUMS>': select_no_albums,
    '<CLEARS SEARCH>': clears_search,
    '<THE STATE OF THE PLANES>': planes_state,
    '<THE MPR CONDITION>': conditions['MPRController'],
    '<THE CPR CONDITION>': conditions['CPRController'],
    '<THE DRAG OF THE IMAGE VIEW>': image_drag.replace('public dynamic func', 'func'),
    '<THE DRAG OF THE TRANSVERSE VIEW>': transverse_drag.replace('public override func', 'override func'),
    '<THE OPTIONS OF THE IMPORT>': import_options,
    '<THE COPY CHOICE>': copy_choice,
    '<THE OVERRIDES OF THE MIGRATION>': overrides,
}
for placeholder, text in REPLACEMENTS.items():
    assert DRIVER.count(placeholder) == 1, placeholder
    DRIVER = DRIVER.replace(placeholder, text)

with tempfile.TemporaryDirectory(prefix='horos-work-preferences-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    (work / 'guards.swift').write_text(objc_exception_guards.source(log=False))
    flags = ['-I', str(work / 'modules'), '-L', str(work / 'modules')]
    for module in ('IsiXPreferences', 'IsiXImaging', 'IsiXDatabase'):
        flags += [flag for flag in isix_modules.module_flags(module, work / 'modules') if flag.startswith('-l') and flag not in flags]
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=15.0', '-c', str(ROOT / 'Horos/Sources/HorosObjCException.m'),
                    '-o', str(work / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(ROOT / 'Horos/Sources/HorosObjCException.h'),
                    str(work / 'main.swift'), str(work / 'guards.swift'), str(source_path('PreferenceWorkGuards')),
                    str(work / 'HorosObjCException.o'), *flags, '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)
