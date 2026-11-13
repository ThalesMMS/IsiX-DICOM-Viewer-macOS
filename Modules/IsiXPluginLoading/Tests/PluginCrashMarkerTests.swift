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
@testable import IsiXPluginLoading

@Suite struct PluginCrashMarkerTests {
    private let path = "/Users/somebody/Library/Application Support/IsiX/Plugins/Thing.horosplugin"

    @Test func aLoadingPluginIsWrittenAsThePathAlone() {
        let marker = PluginCrashMarker(pluginPath: path, phase: .loading)
        #expect(marker.contents == path)
        #expect(PluginCrashMarker(contents: marker.contents) == marker)
    }

    @Test func aRunningPluginSaysSoOnASecondLine() {
        let marker = PluginCrashMarker(pluginPath: path, phase: .running)
        #expect(marker.contents == path + "\nrunning")
        #expect(PluginCrashMarker(contents: marker.contents) == marker)
        #expect(PluginCrashMarker(contents: path + "\nrunning\n") == marker)
    }

    @Test func whatEarlierVersionsWroteReadsAsLoading() {
        #expect(PluginCrashMarker(contents: path) == PluginCrashMarker(pluginPath: path, phase: .loading))
        #expect(PluginCrashMarker(contents: path + "\n") == PluginCrashMarker(pluginPath: path, phase: .loading))
        #expect(PluginCrashMarker(contents: path + "\nsomething else") == PluginCrashMarker(pluginPath: path, phase: .loading))
        #expect(PluginCrashMarker(contents: "") == PluginCrashMarker(pluginPath: "", phase: .loading))
    }

    @Test func aPluginThatStoppedWhileLoadingIsSwitchedOffByDefault() {
        let marker = PluginCrashMarker(pluginPath: path, phase: .loading)
        #expect(marker.recovery(canRestore: true, canDisable: true)
                == .init(choices: [.restorePrevious, .disablePlugin, .keepPlugin], opensWithoutPlugins: true))
        #expect(marker.recovery(canRestore: false, canDisable: true)
                == .init(choices: [.disablePlugin, .keepPlugin], opensWithoutPlugins: true))
        #expect(marker.recovery(canRestore: true, canDisable: false)
                == .init(choices: [.restorePrevious, .keepPlugin], opensWithoutPlugins: true))
        #expect(marker.recovery(canRestore: false, canDisable: false)
                == .init(choices: [.keepPlugin], opensWithoutPlugins: true))
    }

    @Test func aPluginThatWasRunningStaysByDefault() {
        let marker = PluginCrashMarker(pluginPath: path, phase: .running)
        for canRestore in [true, false] {
            for canDisable in [true, false] {
                let recovery = marker.recovery(canRestore: canRestore, canDisable: canDisable)
                #expect(recovery.choices.first == .keepPlugin)
                #expect(!recovery.opensWithoutPlugins)
                #expect(recovery.choices.contains(.disablePlugin) == canDisable)
                #expect(recovery.choices.contains(.restorePrevious) == canRestore)
                #expect(recovery.choices.count <= 3)
            }
        }
        #expect(marker.recovery(canRestore: true, canDisable: true).choices == [.keepPlugin, .disablePlugin, .restorePrevious])
    }

    @Test func anAlertDismissedWithoutAButtonLeavesThePluginAlone() {
        let recovery = PluginCrashMarker(pluginPath: path, phase: .loading).recovery(canRestore: false, canDisable: true)
        #expect(recovery.choice(at: 0) == .disablePlugin)
        #expect(recovery.choice(at: 1) == .keepPlugin)
        #expect(recovery.choice(at: 2) == .keepPlugin)
        #expect(recovery.choice(at: -1) == .keepPlugin)
    }
}
