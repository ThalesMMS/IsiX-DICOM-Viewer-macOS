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
import Testing
import IsiXHTTPServer

@Suite struct LinkSchemeHandlersTests {
    private typealias Application = LinkSchemeHandlers.Application
    private typealias Action = LinkSchemeHandlers.Action

    private let direct = Application(identifier: "thalesmms.isis.workstation", path: "/Applications/IsiX DICOM Viewer.app")
    private let store = Application(identifier: "thalesmms.isis.Isis-DICOM-Viewer", path: "/Applications/IsiX DICOM Viewer.app")
    private let development = Application(identifier: "thalesmms.isis.workstation.local-development",
                                          path: "/Users/someone/build/Development/IsiX DICOM Viewer.app")
    private let other = Application(identifier: "com.example.other-viewer", path: "/Applications/Other Viewer.app")

    private func actions(_ handlers: [Application?], running: Application, on: Bool = true,
                         policy: LinkSchemeHandlers.StartupPolicy = .ask) -> [Action] {
        let entries = zip(LinkSchemeHandlers.declared, handlers).map { (scheme: $0, handler: $1) }
        return LinkSchemeHandlers.decisions(handlers: entries, running: running, urlSupportOn: on, policy: policy).map(\.action)
    }

    @Test func theDeclaredSchemes() {
        #expect(LinkSchemeHandlers.declared == ["isix", "horos", "osirix"])
        #expect(LinkSchemeHandlers.isDeclared("ISIX"))
        #expect(LinkSchemeHandlers.isDeclared("horos"))
        #expect(!LinkSchemeHandlers.isDeclared("http"))
        #expect(!LinkSchemeHandlers.isDeclared("dicom"))
    }

    /// Every scheme is opened by the application that runs: nothing to do,
    /// whatever the policy.
    @Test func ownHandlerNeedsNothing() {
        for policy in LinkSchemeHandlers.StartupPolicy.allCases {
            #expect(actions([direct, direct, direct], running: direct, policy: policy) == [.nothing, .nothing, .nothing])
        }
    }

    /// Another application on one, two and three schemes, asked about by default.
    @Test func anotherHandlerIsToldByDefault() {
        #expect(actions([direct, direct, other], running: direct) == [.nothing, .nothing, .notify])
        #expect(actions([direct, other, other], running: direct) == [.nothing, .notify, .notify])
        #expect(actions([other, other, other], running: direct) == [.notify, .notify, .notify])
    }

    @Test func eachPolicy() {
        #expect(actions([direct, other, other], running: direct, policy: .ask) == [.nothing, .notify, .notify])
        #expect(actions([direct, other, other], running: direct, policy: .takeBack) == [.nothing, .takeBack, .takeBack])
        #expect(actions([direct, other, other], running: direct, policy: .never) == [.nothing, .nothing, .nothing])
    }

    /// A scheme no application opens is told about, and taken back, as one
    /// another application opens.
    @Test func noHandler() {
        #expect(actions([direct, nil, direct], running: direct) == [.nothing, .notify, .nothing])
        #expect(actions([direct, nil, direct], running: direct, policy: .takeBack) == [.nothing, .takeBack, .nothing])
        #expect(actions([nil, nil, nil], running: direct, policy: .never) == [.nothing, .nothing, .nothing])
    }

    /// With the URL support off a link is not carried out: nothing is told or changed.
    @Test func urlSupportOff() {
        for policy in LinkSchemeHandlers.StartupPolicy.allCases {
            #expect(actions([other, other, nil], running: direct, on: false, policy: policy) == [.nothing, .nothing, .nothing])
        }
    }

    /// The build for the store and the development build are themselves when
    /// they run, each with its own identifier.
    @Test func eachBuildIsItself() {
        #expect(actions([store, store, store], running: store) == [.nothing, .nothing, .nothing])
        #expect(actions([development, development, development], running: development) == [.nothing, .nothing, .nothing])
        #expect(LinkSchemeHandlers.isRunningApplication(Application(identifier: "THALESMMS.ISIS.Isis-DICOM-Viewer", path: nil), running: store))
    }

    /// An earlier copy with another identifier is another application, and so
    /// is a build of one channel while a build of another runs.
    @Test func anEarlierCopyIsAnotherApplication() {
        let earlier = Application(identifier: "thalesmms.isis.workstation", path: "/Applications/IsiX DICOM Viewer.app")
        #expect(actions([development, earlier, earlier], running: development) == [.nothing, .notify, .notify])
        #expect(actions([direct, direct, direct], running: store) == [.notify, .notify, .notify])
        #expect(!LinkSchemeHandlers.isRunningApplication(Application(identifier: "thalesmms.isis.workstation.old", path: nil), running: direct))
    }

    /// The same identifier somewhere else is the copy the links would open.
    @Test func aSecondCopyWithTheSameIdentifier() {
        let copy = Application(identifier: direct.identifier, path: "/Users/someone/Downloads/IsiX DICOM Viewer.app")
        #expect(!LinkSchemeHandlers.isRunningApplication(copy, running: direct))
        #expect(actions([copy, direct, direct], running: direct) == [.notify, .nothing, .nothing])
    }

    @Test func whatIsKnownDecides() {
        // One of the two known and the same: it is the application.
        #expect(LinkSchemeHandlers.isRunningApplication(Application(identifier: direct.identifier, path: nil), running: direct))
        #expect(LinkSchemeHandlers.isRunningApplication(Application(identifier: nil, path: direct.path), running: direct))
        #expect(LinkSchemeHandlers.isRunningApplication(Application(identifier: nil, path: "/Applications/IsiX DICOM Viewer.app/"), running: direct))
        // The running application's path unknown: the identifier alone.
        #expect(LinkSchemeHandlers.isRunningApplication(other, running: Application(identifier: other.identifier, path: nil)))
        // Nothing to compare: not it.
        #expect(!LinkSchemeHandlers.isRunningApplication(Application(identifier: nil, path: nil), running: direct))
        #expect(!LinkSchemeHandlers.isRunningApplication(direct, running: Application(identifier: nil, path: nil)))
        #expect(!LinkSchemeHandlers.isRunningApplication(nil, running: direct))
    }

    /// A scheme the application does not declare is never answered for.
    @Test func onlyDeclaredSchemes() {
        let decisions = LinkSchemeHandlers.decisions(handlers: [(scheme: "http", handler: other), (scheme: "HOROS", handler: other),
                                                                (scheme: "mailto", handler: nil)],
                                                     running: direct, urlSupportOn: true, policy: .takeBack)
        #expect(decisions == [LinkSchemeHandlers.Decision(scheme: "horos", handler: other, action: .takeBack)])
    }

    @Test func theStoredPolicy() {
        #expect(LinkSchemeHandlers.StartupPolicy(stored: 0) == .ask)
        #expect(LinkSchemeHandlers.StartupPolicy(stored: 1) == .takeBack)
        #expect(LinkSchemeHandlers.StartupPolicy(stored: 2) == .never)
        #expect(LinkSchemeHandlers.StartupPolicy(stored: 7) == .ask)
        #expect(LinkSchemeHandlers.StartupPolicy(stored: -1) == .ask)
    }

    /// Unticking gives the scheme back only to a known application that still
    /// exists and is not the one that runs.
    @Test func release() {
        #expect(LinkSchemeHandlers.release(previous: other, previousExists: true, running: direct) == .giveBack(to: other))
        #expect(LinkSchemeHandlers.release(previous: other, previousExists: false, running: direct) == .keep)
        #expect(LinkSchemeHandlers.release(previous: nil, previousExists: false, running: direct) == .keep)
        #expect(LinkSchemeHandlers.release(previous: direct, previousExists: true, running: direct) == .keep)
        #expect(LinkSchemeHandlers.release(previous: Application(identifier: other.identifier, path: nil), previousExists: true, running: direct) == .keep)
    }
}
