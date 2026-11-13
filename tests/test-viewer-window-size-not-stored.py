#!/usr/bin/env python3
"""A study opened by a hanging protocol leaves the stored size of the viewers' windows as it was.

ViewerOpener.openPrepared has the windows tiled while a study opens by a
protocol, for a person who does not have new windows tiled: "AUTOTILING" is on
for the process meanwhile. The Viewers pane, when it is open, stores
"WINDOWSIZEVIEWER" 0 (the full screen) as soon as it sees tiling on, so the
opening kept the size: it read the key before and wrote the value read
afterwards, always. A size that was only the registered one was then stored as
the person's, and a size given at the launch was written over the person's.

openPrepared is compiled as it stands, with the real IsiXPreferences
(TemporaryPreferenceHolds, StoredPreference), TemporaryPreferenceWork.swift,
PreferenceWorkGuards.swift and HorosObjCException, over preferences of the
test's own. The size starts stored at 2, stored at 0, only registered, given at
the launch over a stored one and given at the launch alone; the pane is closed
or open (it stores 0 when it reads tiling on); the opening returns or raises:

  * while the study opens, tiling reads on and the size reads what it did
    before this change: what the pane stored, or the launch's value, or the
    person's;
  * afterwards tiling reads as before, and the stored preferences and the
    launch's are as they were, also when the opening raised;
  * with tiling already on, the study opens with nothing held and nothing
    written.

`--source <git revision>` reads ViewerOpener.swift from that revision, the
negative control.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults
import isix_modules
import objc_exception_guards
from sources import source_path

ROOT = Path(__file__).resolve().parents[1]
OPENER = 'Horos/Sources/ViewerOpener.swift'
parser = argparse.ArgumentParser()
parser.add_argument('--source', help='read ViewerOpener.swift from this Git revision')
args = parser.parse_args()
opener = (subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{args.source}:{OPENER}']).decode('utf-8') if args.source
          else (ROOT / OPENER).read_text(encoding='utf-8'))


def block(text, signature):
    """From the line of `signature` to the brace that closes the block it opens."""
    assert text.count(signature) == 1, f'{text.count(signature)} of {signature!r}'
    start = text.rindex('\n', 0, text.index(signature)) + 1
    depth, index = 0, text.index('{', text.index(signature))
    while True:
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[start:index + 1]
        index += 1


open_prepared = block(opener, '    private func openPrepared(').replace('private func openPrepared(', 'func openPrepared(')
kept = 'StoredPreference(ViewerPreferences.viewerWindowSize)'
if not args.source:
    assert kept in open_prepared and '.set(' not in open_prepared, 'the opening no longer keeps the stored size without writing it'
# The preferences of the application are the test's suite here.
open_prepared = open_prepared.replace(kept, 'StoredPreference(ViewerPreferences.viewerWindowSize, in: controlled, storedDomain: suite)')
work = source_path('TemporaryPreferenceWork').read_text(encoding='utf-8')
assert work.count('TemporaryPreferenceHolds.standard') == 1
work = work.replace('TemporaryPreferenceHolds.standard', 'holds')

DRIVER = harness_defaults.DOMAINS + r'''
import AppKit
import IsiXPreferences

let suite = harnessDomainName("viewer-window-size-\(getpid())")
let controlled = UserDefaults(suiteName: suite)!
@MainActor let holds = MainActor.assumeIsolated { TemporaryPreferenceHolds(defaults: controlled, storedDomain: suite) }
enum AppController { static func checkForPreferencesUpdate(_ on: Bool) {} }

typealias Domain = [String: AnyHashable]
func stored() -> Domain { (controlled.persistentDomain(forName: suite) ?? [:]).compactMapValues { $0 as? AnyHashable } }
func launch() -> Domain { controlled.volatileDomain(forName: UserDefaults.argumentDomain).compactMapValues { $0 as? AnyHashable } }

final class DicomStudy {}

@MainActor final class ViewerOpener {
    let preferences: any PreferenceStore = controlled
    var tiled: () -> Void = {}
    func openTiled(_ currentStudy: DicomStudy?, withProtocol currentHangingProtocol: [AnyHashable: Any]?, comparatives studies: [DicomStudy]) { tiled() }

<OPEN PREPARED>
}

var failures: [String] = []
var checks = 0
func check(_ condition: Bool, _ what: @autoclosure () -> String) { checks += 1; if !condition { failures.append(what()) } }

/// How the size stands before the opening, and what a reader of it finds.
let sizes: [(name: String, stored: Int?, given: String?, read: Int)] = [
    ("stored at 2", 2, nil, 2), ("stored at 0", 0, nil, 0), ("only registered", nil, nil, 0),
    ("given at the launch over a stored 1", 1, "3", 3), ("given at the launch alone", nil, "3", 3),
]
let size = "WINDOWSIZEVIEWER", tiling = "AUTOTILING"
let launchBefore = controlled.volatileDomain(forName: UserDefaults.argumentDomain)
controlled.register(defaults: [size: "0", tiling: "0"])

MainActor.assumeIsolated {
    for had in sizes {
        for paneOpen in [false, true] {
            for raises in [false, true] {
                for tilingStored in [nil, false] as [Bool?] {
                    let what = "\(had.name), the pane \(paneOpen ? "open" : "closed"), \(raises ? "raising" : "returning"), tiling \(tilingStored == nil ? "only registered" : "stored off")"
                    controlled.removePersistentDomain(forName: suite)
                    controlled.set("kept", forKey: "sentinel")
                    if let value = had.stored { controlled.set(value, forKey: size) }
                    if let value = tilingStored { controlled.set(value, forKey: tiling) }
                    var given = launchBefore
                    given[size] = had.given
                    controlled.setVolatileDomain(given, forName: UserDefaults.argumentDomain)
                    let before = (stored(), launch())
                    check(controlled.integer(forKey: size) == had.read, "\(what): before, the size reads \(controlled.integer(forKey: size))")

                    let opener = ViewerOpener()
                    var during: (tiling: Bool, size: Int)?
                    opener.tiled = {
                        // The Viewers pane, told of tiling: full-screen windows.
                        if paneOpen && controlled.bool(forKey: tiling) { controlled.set(0, forKey: size) }
                        during = (controlled.bool(forKey: tiling), controlled.integer(forKey: size))
                        if raises { NSException(name: .genericException, reason: "the opening", userInfo: nil).raise() }
                    }
                    let raised = HorosObjCException.caught { opener.openPrepared(DicomStudy(), withProtocol: [:], comparatives: []) }

                    // The pane's 0 is what is stored during; a launch's value comes before whatever is stored.
                    let sizeDuring = had.given != nil ? had.read : (paneOpen ? 0 : had.read)
                    check(during?.tiling == true && during?.size == sizeDuring, "\(what): while the study opens, tiling and the size read \(String(describing: during)), not (true, \(sizeDuring))")
                    check((raised?.reason == "the opening") == raises, "\(what): the exception of the opening \(raises ? "did not reach" : "reached") the caller")
                    check(!controlled.bool(forKey: tiling) && !holds.isHeld(ViewerPreferences.autoTiling), "\(what): afterwards tiling still reads on")
                    check(stored() == before.0, "\(what): afterwards the stored preferences are \(stored()), not \(before.0)")
                    check(launch() == before.1, "\(what): afterwards the launch's values are not as they were")
                    check(controlled.integer(forKey: size) == had.read, "\(what): afterwards the size reads \(controlled.integer(forKey: size)), not \(had.read)")
                }
            }
        }
    }

    // Tiling already on: the study opens with nothing held and nothing written.
    for had in sizes {
        controlled.removePersistentDomain(forName: suite)
        controlled.set(true, forKey: tiling)
        if let value = had.stored { controlled.set(value, forKey: size) }
        var given = launchBefore
        given[size] = had.given
        controlled.setVolatileDomain(given, forName: UserDefaults.argumentDomain)
        let before = (stored(), launch())
        let opener = ViewerOpener()
        var held: Bool?
        opener.tiled = { held = holds.isHeld(ViewerPreferences.autoTiling) }
        opener.openPrepared(DicomStudy(), withProtocol: [:], comparatives: [])
        check(held == false && stored() == before.0 && launch() == before.1, "\(had.name), tiling on: something was held or written")
    }
}

controlled.setVolatileDomain(launchBefore, forName: UserDefaults.argumentDomain)
controlled.removePersistentDomain(forName: suite)
if !failures.isEmpty {
    for failure in failures.prefix(30) { print("FAIL: " + failure) }
    print("\(failures.count) of \(checks) checks failed")
    exit(1)
}
print("PASS: \(checks) checks: a study opened by a protocol reads tiling on and the size as before while it opens, and leaves the stored "
      + "size (stored, only registered or given at the launch; the Viewers pane open or closed; returning or raising) as it was")
'''.replace('<OPEN PREPARED>', open_prepared)

with tempfile.TemporaryDirectory(prefix='horos-viewer-window-size-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(DRIVER)
    (folder / 'guards.swift').write_text(objc_exception_guards.source(log=False))
    (folder / 'TemporaryPreferenceWork.swift').write_text(work)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=15.0', '-c', str(ROOT / 'Horos/Sources/HorosObjCException.m'),
                    '-o', str(folder / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(ROOT / 'Horos/Sources/HorosObjCException.h'),
                    str(folder / 'main.swift'), str(folder / 'guards.swift'), str(folder / 'TemporaryPreferenceWork.swift'),
                    str(source_path('PreferenceWorkGuards')), str(folder / 'HorosObjCException.o'),
                    *isix_modules.module_flags('IsiXPreferences', folder / 'modules'), '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test')], check=True)
