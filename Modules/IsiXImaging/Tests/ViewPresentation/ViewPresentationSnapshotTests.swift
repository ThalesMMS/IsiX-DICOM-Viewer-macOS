//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
import IsiXImaging

// The snapshot an image view publishes for readers on any thread: each part
// written is read back whole, the other part is left as it was, and readers
// on other threads never see a value that no write published.

@Suite struct ViewPresentationSnapshotTests {

    @Test func startsEmptyAndKeepsEachPart() {
        let snapshot = ViewPresentationSnapshot()
        #expect(snapshot.presentation == ViewPresentation())

        let viewport = ViewportState(scale: 1.5, origin: CGPoint(x: 3, y: -4), rotation: 90, xFlipped: true, yFlipped: false)
        snapshot.publish(viewport: viewport)
        #expect(snapshot.presentation.viewport == viewport)
        #expect(snapshot.presentation.windowLevel == WindowLevelState())

        let window = WindowLevelState(level: 40, width: 400, suvConverted: false, suvFactor: 1)
        snapshot.publish(windowLevel: window)
        #expect(snapshot.presentation.windowLevel == window)
        #expect(snapshot.presentation.viewport == viewport)
    }

    /// Writers publish viewports whose fields all derive from one number and
    /// windows whose width is twice the level; readers on other threads
    /// check that every value they read is whole.
    @Test func readersOnOtherThreadsReadWholeValues() async {
        let snapshot = ViewPresentationSnapshot()
        let rounds = 20_000

        func viewport(_ n: Int) -> ViewportState {
            let f = Float(n)
            return ViewportState(scale: f, origin: CGPoint(x: Double(n), y: -Double(n)), rotation: f, xFlipped: n % 2 == 0, yFlipped: n % 2 == 1)
        }

        let torn = await withTaskGroup(of: Int.self) { group in
            group.addTask {
                for n in 1...rounds {
                    snapshot.publish(viewport: viewport(n))
                    snapshot.publish(windowLevel: WindowLevelState(level: Float(n), width: Float(2 * n)))
                }
                return 0
            }
            for _ in 0..<4 {
                group.addTask {
                    var torn = 0
                    for _ in 0..<rounds {
                        let read = snapshot.presentation
                        let n = Int(read.viewport.scale)
                        if read.viewport != (n == 0 ? ViewportState() : viewport(n)) { torn += 1 }
                        if read.windowLevel.width != 2 * read.windowLevel.level { torn += 1 }
                    }
                    return torn
                }
            }
            return await group.reduce(0, +)
        }
        #expect(torn == 0)
        #expect(snapshot.presentation.viewport == viewport(rounds))
        #expect(snapshot.presentation.windowLevel == WindowLevelState(level: Float(rounds), width: Float(2 * rounds)))
    }
}
