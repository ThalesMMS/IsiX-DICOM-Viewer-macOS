//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
import IsiXStorage

@Suite struct DatabaseVolumeTests {

    @Test func aVolumeIsThePathsFirstThreeComponents() {
        #expect(DatabaseVolume.volume(of: "/Volumes/Archive/IsiX Data") == "/Volumes/Archive")
        #expect(DatabaseVolume.volume(of: "/Volumes/Archive") == "/Volumes/Archive")
        #expect(DatabaseVolume.volume(of: "/Users") == nil)
        #expect(DatabaseVolume.volume(of: "") == nil)
    }

    @Test func aFolderOnTheStartupDiskIsNotWaitedFor() {
        #expect(DatabaseVolume.documentsVolume(resolved: "/Users/someone/Documents/IsiX Data", locationMode: 1,
                                               chosenFolder: "/Volumes/Archive/IsiX Data") == nil)
    }

    @Test func aResolvedFolderOnAVolumeNamesItsVolume() {
        #expect(DatabaseVolume.documentsVolume(resolved: "/Volumes/Archive/IsiX Data", locationMode: 0, chosenFolder: nil)
                == "/Volumes/Archive")
    }

    @Test func anUnresolvedFolderWaitsForTheVolumeTheUserChose() {
        // A folder on a volume that is not mounted resolves to nil.
        #expect(DatabaseVolume.documentsVolume(resolved: nil, locationMode: 1, chosenFolder: "/Volumes/Archive/IsiX Data")
                == "/Volumes/Archive")
        // An empty folder is neither on a volume nor unresolved: nothing is waited for.
        #expect(DatabaseVolume.documentsVolume(resolved: "", locationMode: 1, chosenFolder: "/Volumes/Archive/IsiX Data") == nil)
        // The chosen folder only counts in the "chosen folder" mode.
        #expect(DatabaseVolume.documentsVolume(resolved: nil, locationMode: 0, chosenFolder: "/Volumes/Archive/IsiX Data") == nil)
        #expect(DatabaseVolume.documentsVolume(resolved: nil, locationMode: 1, chosenFolder: nil) == nil)
        #expect(DatabaseVolume.documentsVolume(resolved: nil, locationMode: 1, chosenFolder: "/") == nil)
    }

    @Test func aMovedDataFolderOnAVolumeNamesItsVolume() {
        #expect(DatabaseVolume.dataVolume(dataFolderLocation: "/Volumes/Big/Data") == "/Volumes/Big")
        #expect(DatabaseVolume.dataVolume(dataFolderLocation: "/Users/someone/Data") == nil)
        #expect(DatabaseVolume.dataVolume(dataFolderLocation: nil) == nil)
    }

    @Test func theWaitEndsOnQuitContinueTheVolumeOrTheTimeLimit() {
        func step(_ response: Int, exists: Bool = false, now: Double = 0) -> DatabaseVolume.WaitStep {
            DatabaseVolume.step(response: response, quitResponse: 1, continueResponse: 0, volumeExists: exists,
                                now: now, deadline: DatabaseVolume.waitLimit)
        }
        #expect(step(1) == .quit)
        #expect(step(1, exists: true) == .quit)
        #expect(step(0) == .proceed(timedOut: false))
        #expect(step(-1002, exists: true) == .proceed(timedOut: false))
        #expect(step(-1002, now: 601) == .proceed(timedOut: true))
        #expect(step(-1002, now: 600) == .wait)
        #expect(DatabaseVolume.waitLimit == 600)
    }
}
