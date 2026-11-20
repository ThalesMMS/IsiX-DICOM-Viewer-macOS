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
@testable import IsiXStorage

/// "Add local path" of Settings > Locations: what the open panel is asked in
/// each channel, and the folder a choice stands for.
@Suite struct LocalDatabasePathChoiceTests {
    private func isData(_ name: String) -> Bool { name == "IsiX Data" || name == "Horos Data" }

    /// The sandbox's panel takes folders, and is told of no type of file.
    @Test func theSandboxChoosesFoldersAndNamesNoFileType() {
        let choice = LocalDatabasePathChoice(sandboxed: true)
        #expect(choice.canChooseDirectories)
        #expect(!choice.canChooseFiles)
        #expect(choice.fileExtensions.isEmpty)
    }

    @Test func outOfTheSandboxAFolderOrAnIndexFile() {
        let choice = LocalDatabasePathChoice(sandboxed: false)
        #expect(choice.canChooseDirectories)
        #expect(choice.canChooseFiles)
        #expect(choice.fileExtensions == ["sql"])
    }

    /// The folder chosen is the only one the grant covers: it stands for
    /// itself, a data directory included, and a file for nothing.
    @Test func inTheSandboxTheFolderChosenStandsForItself() {
        let choice = LocalDatabasePathChoice(sandboxed: true)
        #expect(choice.folder(forChosenPath: "/Volumes/Disk/Studies", isDirectory: true, isDataDirectoryName: isData) == "/Volumes/Disk/Studies")
        #expect(choice.folder(forChosenPath: "/Volumes/Disk/Studies/IsiX Data", isDirectory: true, isDataDirectoryName: isData) == "/Volumes/Disk/Studies/IsiX Data")
        #expect(choice.folder(forChosenPath: "/Volumes/Disk/Studies/IsiX Data/Database.sql", isDirectory: false, isDataDirectoryName: isData) == nil)
    }

    @Test func outOfTheSandboxAChoiceStandsForTheDatabaseFolder() {
        let choice = LocalDatabasePathChoice(sandboxed: false)
        func folder(_ path: String, directory: Bool = true) -> String? {
            choice.folder(forChosenPath: path, isDirectory: directory, isDataDirectoryName: isData)
        }
        #expect(folder("/Volumes/Disk/Studies") == "/Volumes/Disk/Studies")
        #expect(folder("/Volumes/Disk/Studies/IsiX Data") == "/Volumes/Disk/Studies")
        #expect(folder("/Volumes/Disk/Studies/Horos Data") == "/Volumes/Disk/Studies")
        #expect(folder("/Volumes/Disk/Studies/IsiX Data/DATABASE.noindex") == "/Volumes/Disk/Studies")
        #expect(folder("/Volumes/Disk/Studies/IsiX Data/DATABASE") == "/Volumes/Disk/Studies")
        // A folder of that name elsewhere is a folder like any other.
        #expect(folder("/Volumes/Disk/DATABASE") == "/Volumes/Disk/DATABASE")
        // The index file, in the data directory or loose in a folder.
        #expect(folder("/Volumes/Disk/Studies/IsiX Data/Database.sql", directory: false) == "/Volumes/Disk/Studies")
        #expect(folder("/Volumes/Disk/Loose/Database.SQL", directory: false) == "/Volumes/Disk/Loose")
        #expect(folder("/Volumes/Disk/Studies/report.pdf", directory: false) == nil)
    }
}
