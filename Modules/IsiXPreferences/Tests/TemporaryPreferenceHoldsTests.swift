//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Synchronization
import Testing
@testable import IsiXPreferences

/// The values the opening and the arrangement of the viewers' windows give
/// preferences while they work: read by every reader, never stored, whatever
/// the order the pieces of work end in.
///
/// Inside the suite of the value one piece of work gives, which runs one test
/// at a time: the argument domain is the process's, each test of either puts
/// back the whole of it when it ends, and a test of one running beside a test
/// of the other took the other's value away with it.
extension TemporaryPreferenceTests {
    @MainActor @Suite struct TemporaryPreferenceHoldsTests {
        private typealias Domain = [String: AnyHashable]

        /// The keys the viewers' windows hold, as the catalog registers them, and
        /// the value the work gives each.
        private static let held: [(name: String, registered: Bool, given: Bool)] = [
            (ViewerPreferences.copySettings.name, true, false), (ViewerPreferences.autoTiling.name, true, false),
            (ViewerPreferences.autoTiling.name, true, true), (ViewerPreferences.automaticWorkspaceLoad.name, true, false),
            (ViewerPreferences.automaticWorkspaceLoad.name, true, true), (ViewerPreferences.autoHidesMatrix.name, false, false),
            (DatabasePreferences.syncPreviewList.name, true, false), (ViewerPreferences.nextSeriesToAllViewers.name, true, false),
            (ViewerPreferences.onlyDisplayImagesOfSamePatient.name, false, false),
        ]

        private struct Stopped: Error {}

        /// Counts what the key-value observers of a key are told.
        private final class Observer: NSObject {
            private let count = Mutex(0)
            var told: Int { count.withLock { $0 } }
            override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
                count.withLock { $0 += 1 }
            }
        }

        /// Defaults of the test's own, the holds on them, what they store, and
        /// keys no other test reads.
        private func withHolds(_ body: (UserDefaults, TemporaryPreferenceHolds, _ stored: () -> Domain, _ key: (String, Bool) -> PreferenceKey<Bool>) throws -> Void) throws {
            let stamp = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let domain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IsiXPreferencesTests.holds.\(stamp)").path
            let defaults = try #require(UserDefaults(suiteName: domain))
            let launch = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defer {
                defaults.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)
                defaults.removePersistentDomain(forName: domain)
                try? FileManager.default.removeItem(atPath: domain + ".plist")
            }
            try body(defaults, TemporaryPreferenceHolds(defaults: defaults, storedDomain: domain),
                     { (defaults.persistentDomain(forName: domain) ?? [:]).compactMapValues { $0 as? AnyHashable } },
                     { name, registered in
                         let key = PreferenceKey<Bool>("\(name)_\(stamp)", registered: registered ? "1" : "0")
                         defaults.register(defaults: [key.name: registered ? "1" : "0"])
                         return key
                     })
        }

        // MARK: - Each key

        @Test func eachKeyReadsTheValueGivenAndStoresNothing() throws {
            for held in Self.held {
                // What the person chose (either way), and nothing chosen: the registered value.
                for chosen in [true, false, nil] as [Bool?] {
                    try withHolds { defaults, holds, stored, key in
                        let preference = key(held.name, held.registered)
                        if let chosen { defaults.set(chosen, forKey: preference.name) }
                        let before = stored(), read = defaults[preference]
                        #expect(read == (chosen ?? held.registered))

                        let hold = holds.hold(preference, at: held.given)
                        #expect(defaults[preference] == held.given, "\(held.name) at \(held.given), chosen \(String(describing: chosen))")
                        #expect(UserDefaults.standard.bool(forKey: preference.name) == held.given, "another instance reads it too")
                        #expect(stored() == before, "nothing is stored while it lasts")

                        holds.release(hold)
                        #expect(defaults[preference] == read)
                        #expect(stored() == before, "\(held.name): a value that was only registered is not stored as the person's, nor a chosen one rewritten")
                        #expect(!holds.isHeld(preference))
                    }
                }
            }
        }

        @Test func eachKeyComesBackWhenTheWorkStopsEarly() throws {
            for held in Self.held {
                try withHolds { defaults, holds, stored, key in
                    let preference = key(held.name, held.registered)
                    defaults.set(!held.given, forKey: preference.name)
                    let before = stored()

                    var stopped = false
                    do {
                        try holds.during(preference, at: held.given) {
                            #expect(defaults[preference] == held.given)
                            throw Stopped()
                        }
                    } catch {
                        stopped = error is Stopped
                    }
                    #expect(stopped)
                    #expect(defaults[preference] == !held.given, "\(held.name): work that throws leaves its value behind")
                    #expect(stored() == before)

                    // Work that leaves early, by a return in the middle.
                    @MainActor func leavingEarly() -> Int {
                        holds.during(preference, at: held.given) {
                            if defaults[preference] == held.given { return 1 }
                            return 2
                        }
                    }
                    #expect(leavingEarly() == 1)
                    #expect(defaults[preference] == !held.given)
                    #expect(stored() == before && !holds.isHeld(preference))
                }
            }
        }

        @Test func aValueTheLaunchGaveComesBack() throws {
            try withHolds { defaults, holds, stored, key in
                let tiling = key(ViewerPreferences.autoTiling.name, true)
                defaults.set(true, forKey: tiling.name)
                var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments[tiling.name] = "NO"
                defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                let before = stored()
                #expect(!defaults[tiling])

                let hold = holds.hold(tiling, at: true)
                #expect(defaults[tiling])
                holds.release(hold)
                #expect(!defaults[tiling], "the launch's value is there again, not the stored one")
                #expect(defaults.volatileDomain(forName: UserDefaults.argumentDomain)[tiling.name] as? String == "NO")
                #expect(stored() == before, "and it was not stored over the person's")
            }
        }

        // MARK: - Several pieces of work at once

        @Test func workInsideWorkLeavesTheOuterValueUntilTheOuterEnds() throws {
            try withHolds { defaults, holds, stored, key in
                // The opening of a study: the opener, the loader of each series, the arranger.
                let propagation = key(ViewerPreferences.copySettings.name, true)
                let tiling = key(ViewerPreferences.autoTiling.name, true)
                defaults.set(true, forKey: propagation.name)
                let before = stored()

                holds.during(tiling, at: true) {
                    holds.during(propagation, at: false) {
                        for _ in 0..<3 {
                            holds.during(propagation, at: false) {
                                #expect(!defaults[propagation])
                                holds.during(tiling, at: false) { #expect(!defaults[tiling]) }
                                #expect(defaults[tiling], "the inner work gave back its own value, not the outer one's")
                            }
                            #expect(!defaults[propagation], "a series loaded: the opening still has the propagation off")
                        }
                        holds.during(propagation, at: false) { #expect(!defaults[propagation]) }
                    }
                    #expect(defaults[propagation])
                }
                #expect(defaults[propagation] && defaults[tiling])
                #expect(stored() == before && !holds.isHeld(propagation) && !holds.isHeld(tiling))
            }
        }

        @Test func workThatOverlapsEndsInAnyOrder() throws {
            try withHolds { defaults, holds, stored, key in
                let propagation = key(ViewerPreferences.copySettings.name, true)
                let before = stored()
                #expect(defaults[propagation])

                // Two viewers enter full screen, and leave it in the order they entered.
                let first = holds.hold(propagation, at: false)
                let second = holds.hold(propagation, at: false)
                holds.release(first)
                #expect(!defaults[propagation], "the second viewer is still full screen")
                holds.release(second)
                #expect(defaults[propagation], "the value of the first is not left as the value of the process")

                // Different values: the one taken last shows, then the one still there.
                let off = holds.hold(propagation, at: false)
                let on = holds.hold(propagation, at: true)
                #expect(defaults[propagation])
                holds.release(off)
                #expect(defaults[propagation])
                let offAgain = holds.hold(propagation, at: false)
                holds.release(on)
                #expect(!defaults[propagation])
                holds.release(offAgain)
                #expect(defaults[propagation])
                #expect(stored() == before && !holds.isHeld(propagation))
            }
        }

        @Test func aHoldGivenBackTwiceChangesNothing() throws {
            try withHolds { defaults, holds, _, key in
                let propagation = key(ViewerPreferences.copySettings.name, true)
                let first = holds.hold(propagation, at: false)
                let second = holds.hold(propagation, at: false)
                holds.release(first)
                holds.release(first)
                #expect(!defaults[propagation], "the second hold is not taken for the first")
                holds.release(second)
                holds.release(second)
                holds.release(nil)
                #expect(defaults[propagation])
            }
        }

        // MARK: - Observers

        @Test func theObserversAreToldWhenWhatTheKeyReadsChangesAndOnlyThen() throws {
            try withHolds { defaults, holds, _, key in
                let propagation = key(ViewerPreferences.copySettings.name, true)
                defaults.set(true, forKey: propagation.name)
                let observer = Observer()
                defaults.addObserver(observer, forKeyPath: propagation.name, options: [], context: nil)
                defer { defaults.removeObserver(observer, forKeyPath: propagation.name) }

                let outer = holds.hold(propagation, at: false)
                #expect(observer.told == 1, "told by the call that takes the hold")
                let inner = holds.hold(propagation, at: false)
                holds.release(inner)
                #expect(observer.told == 1, "work inside work at the same value tells no one")
                holds.release(outer)
                #expect(observer.told == 2, "told by the call that gives the last hold back")

                // A hold at the value the key already reads tells no one at all.
                let same = holds.hold(propagation, at: true)
                holds.release(same)
                #expect(observer.told == 2)
            }
        }

        // MARK: - A choice made meanwhile

        @Test func aChoiceEndsTheHoldsAndShowsAtOnce() throws {
            try withHolds { defaults, holds, stored, key in
                let propagation = key(ViewerPreferences.copySettings.name, true)
                defaults.set(true, forKey: propagation.name)

                // The same value as the one stored: only the choice itself says it was made.
                let opening = holds.hold(propagation, at: false)
                let loading = holds.hold(propagation, at: false)
                holds.choose(true, for: propagation)
                #expect(defaults[propagation], "the fusion turned the propagation on while a series loaded")
                #expect(!holds.isHeld(propagation))
                holds.release(loading)
                holds.release(opening)
                #expect(defaults[propagation], "and it stays on")
                #expect(stored()[propagation.name] == AnyHashable(true))

                let fullScreen = holds.hold(propagation, at: false)
                holds.choose(false, for: propagation)
                holds.release(fullScreen)
                #expect(!defaults[propagation])
                #expect(stored()[propagation.name] == AnyHashable(false))
            }
        }

        @Test func aValueStoredByAnythingElseEndsTheHoldsToo() throws {
            try withHolds { defaults, holds, stored, key in
                // A menu item bound to the key writes through its own controller.
                let propagation = key(ViewerPreferences.copySettings.name, true)
                defaults.set(false, forKey: propagation.name)
                let fullScreen = holds.hold(propagation, at: false)
                let tiling = key(ViewerPreferences.autoTiling.name, true)
                let other = holds.hold(tiling, at: false)

                defaults.set(true, forKey: propagation.name)
                #expect(defaults[propagation], "the item the person chose shows at once")
                #expect(!holds.isHeld(propagation))
                #expect(!defaults[tiling] && holds.isHeld(tiling), "the holds of the other keys stay")

                holds.release(fullScreen)
                #expect(defaults[propagation], "leaving full screen does not take the choice back")
                #expect(stored()[propagation.name] == AnyHashable(true))
                holds.release(other)
                #expect(defaults[tiling])

                // A key the person never chose: a first value stored for it is a choice.
                let matrix = key(ViewerPreferences.autoHidesMatrix.name, false)
                let loading = holds.hold(matrix, at: false)
                defaults.set(true, forKey: matrix.name)
                #expect(defaults[matrix] && !holds.isHeld(matrix))
                holds.release(loading)
                #expect(defaults[matrix])
            }
        }

        @Test func whatIsStoredForOtherKeysEndsNoHold() throws {
            try withHolds { defaults, holds, _, key in
                let propagation = key(ViewerPreferences.copySettings.name, true)
                let hold = holds.hold(propagation, at: false)
                let frame = key("frame", true), rows = key("rows", true)
                defaults.set("a window frame", forKey: frame.name)
                defaults.set(3, forKey: rows.name)
                #expect(!defaults[propagation] && holds.isHeld(propagation))
                holds.release(hold)
                #expect(defaults[propagation])
            }
        }

        // MARK: - A hold an object keeps

        @Test func aHoldAnObjectKeepsIsGivenBackWhenAskedAndWhenTheObjectGoes() throws {
            try withHolds { defaults, holds, stored, key in
                let propagation = key(ViewerPreferences.copySettings.name, true)
                let before = stored()

                // A viewer enters full screen and leaves it.
                var viewer: NSObject? = NSObject()
                holds.hold(propagation, at: false, keptBy: viewer!)
                #expect(!defaults[propagation])
                holds.release(propagation, keptBy: viewer!)
                #expect(defaults[propagation])
                holds.release(propagation, keptBy: viewer!)
                #expect(defaults[propagation], "asked twice, it gives back once")

                // Entering twice keeps one hold.
                holds.hold(propagation, at: false, keptBy: viewer!)
                holds.hold(propagation, at: false, keptBy: viewer!)
                holds.release(propagation, keptBy: viewer!)
                #expect(defaults[propagation])

                // A viewer that goes while full screen: its hold goes with it.
                let other = NSObject()
                holds.hold(propagation, at: false, keptBy: viewer!)
                holds.hold(propagation, at: false, keptBy: other)
                viewer = nil
                #expect(!defaults[propagation], "the other viewer is still full screen")
                holds.release(propagation, keptBy: other)
                #expect(defaults[propagation], "no hold outlives the object that kept it")
                #expect(stored() == before && !holds.isHeld(propagation))

                // An object that kept none.
                holds.release(propagation, keptBy: NSObject())
                #expect(defaults[propagation])
            }
        }
    }
}
