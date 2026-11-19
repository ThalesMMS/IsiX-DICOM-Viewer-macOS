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

/// The wait of a request for a study whose files are still coming in: one
/// loop for the order to open a study that has not arrived yet and for the
/// `then` of a Retrieve, so both look at the same pace and end the same way.
///
/// The wait holds nothing of its own between two looks: each caller waits on
/// its own thread, and one that is waiting does not delay another.
public enum StudyArrivalWait {

    /// The seconds between two looks.
    public static let interval: TimeInterval = 0.5

    /// Looks now and then every `interval`, until `look` answers something,
    /// `seconds` have passed or `isCancelled` says to stop. A look is always
    /// made after the last pause, so what arrived during it is not missed.
    ///
    /// A failed look is looked at again: the wait throws only the failure of
    /// its last look, and answers nil when nothing came in time.
    public static func first<Found>(within seconds: TimeInterval,
                                    interval: TimeInterval = StudyArrivalWait.interval,
                                    isCancelled: () -> Bool = { false },
                                    now: () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
                                    pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                    look: () throws -> Found?) throws -> Found? {
        let start = now()
        var failure: Error?
        while true {
            do {
                if let found = try look() { return found }
                failure = nil
            } catch {
                failure = error
            }
            if isCancelled() || now() - start >= seconds { break }
            pause(interval)
        }
        if let failure { throw failure }
        return nil
    }
}
