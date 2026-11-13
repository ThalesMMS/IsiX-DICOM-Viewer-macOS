/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import Synchronization

/// How a database numbers the files it keeps in its data folder: file `n` is
/// `<folder>/<n>.<extension>`, the folder being the next multiple of the
/// folder size above `n`, so that no folder holds more than that many files.
public enum DataFileNumbering {
    /// The extension a new data file takes: one of three or four characters,
    /// or `dcm`. `replaced` says that a non-empty extension was refused.
    public static func fileExtension(_ requested: String?) -> (value: String, replaced: Bool) {
        let length = (requested as NSString?)?.length ?? 0
        guard let requested, length >= 3 && length <= 4 else { return ("dcm", length != 0) }
        return (requested, false)
    }

    /// The folder, by its number, that holds file `index`. A folder size of 0
    /// counts as 1.
    public static func folder(forIndex index: UInt64, folderSize: UInt64) -> UInt64 {
        let size = max(folderSize, 1)
        return size &* (index / size &+ 1)
    }

    /// The path of file `index` in `dataFolder`.
    public static func path(forIndex index: UInt64, extension fileExtension: String, inDataFolder dataFolder: String,
                            folderSize: UInt64) -> (folder: String, file: String) {
        let folder = (dataFolder as NSString).appendingPathComponent(String(folder(forIndex: index, folderSize: folderSize)))
        return (folder, (folder as NSString).appendingPathComponent("\(index).\(fileExtension)"))
    }

    /// The number a name stands for, its extension left out, as
    /// `-[NSString integerValue]` reads it: leading digits, 0 for none.
    public static func number(inName name: String) -> Int {
        ((name as NSString).deletingPathExtension as NSString).integerValue
    }

    /// The number to go on from, given a listing of the data folder: in the
    /// folder with the highest number that holds a numbered file, the highest
    /// file, or the folder size below that folder when it has none of its own;
    /// `known`, a number already given, counts as a folder. Never 0, so that a
    /// data folder without files starts at 1.
    public static func resumingNumber(known: UInt64, numberedFolders: [UInt64], folderSize: UInt64,
                                      filesIn: (UInt64) -> [String]) -> UInt64 {
        let highest = numberedFolders.reduce(known) { max($0, $1) }
        guard highest > 0 else { return 1 }
        var found = highest > folderSize ? highest - folderSize : 0
        for name in filesIn(highest) {
            let number = Self.number(inName: name)
            if number > 0 && UInt64(number) > found { found = UInt64(number) }
        }
        return max(found, 1)
    }
}

/// The number of the next data file of a database, which a main database
/// shares with its independent databases: the threads of every context take
/// numbers from it, and no two of them get the same one.
///
/// The number only grows: what the folder holds raises it, and nothing lowers
/// it below a number already given, whose file may not be written yet. The
/// file system is read and written outside the lock, so a slow volume holds no
/// other thread that only wants a number.
///
/// The folder alone does not say which numbers are taken: a record of the
/// index names its file by its number, and still does when the file is gone
/// from the folder (deleted by another program, a volume restored from a
/// partial copy). A new file given that number would be read by that record,
/// as an image of its study. So the count also goes on from `highestRecorded`,
/// the highest number the index uses, asked each time the folder is read and
/// never for a single file.
public final class DataFileAllocator: Sendable {
    /// The number given last, 0 until the folder was read.
    private let given = Mutex<UInt64>(0)

    public init() {}

    /// The number given last; 0 before the data folder was read.
    public var lastNumber: UInt64 {
        given.withLock { $0 }
    }

    /// Raises the number given last to at least `number` and answers it.
    @discardableResult
    public func raise(toAtLeast number: UInt64) -> UInt64 {
        given.withLock { given in
            given = max(given, number)
            return given
        }
    }

    /// The next number, which no other caller gets.
    public func next() -> UInt64 {
        given.withLock { given in
            given &+= 1
            return given
        }
    }

    /// Reads the data folder and goes on from what it holds: removes the
    /// folders without a numbered file, which an interrupted import can leave,
    /// and raises the number to the one after the files of the last folder,
    /// and to `highestRecorded`, the highest number a record of the index
    /// uses, whose file may be gone. Answers the number given last.
    @discardableResult
    public func resume(fromDataFolder dataFolder: String, folderSize: UInt64,
                       fileManager: FileManager = .default, highestRecorded: () -> UInt64 = { 0 }) -> UInt64 {
        var numbered: [UInt64] = []
        for name in (try? fileManager.contentsOfDirectory(atPath: dataFolder)) ?? [] {
            let folder = (dataFolder as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let files = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
            if files.contains(where: { DataFileNumbering.number(inName: $0) > 0 }) {
                let number = (name as NSString).integerValue
                if number > 0 { numbered.append(UInt64(number)) }
            } else {
                try? fileManager.removeItem(atPath: folder)
            }
        }
        let resuming = DataFileNumbering.resumingNumber(known: lastNumber, numberedFolders: numbered, folderSize: folderSize) { folder in
            (try? fileManager.contentsOfDirectory(atPath: (dataFolder as NSString).appendingPathComponent(String(folder)))) ?? []
        }
        return raise(toAtLeast: max(resuming, highestRecorded()))
    }

    /// The path of a new file in `dataFolder`, which no other caller gets and
    /// which holds nothing yet; its folder exists. `prepareFolder` makes a
    /// folder ready, as the application makes its folders. A number whose file
    /// is already there, left by another program or by an earlier index, sends
    /// the count past what the folder holds once, then one number at a time.
    /// `highestRecorded` is asked only when the folder is read: the first
    /// time, and when a number's file is already there.
    public func uniquePath(inDataFolder dataFolder: String, extension fileExtension: String, folderSize: UInt64,
                           fileManager: FileManager = .default, highestRecorded: () -> UInt64 = { 0 },
                           prepareFolder: (String) -> Void) -> String {
        if lastNumber == 0 {
            resume(fromDataFolder: dataFolder, folderSize: folderSize, fileManager: fileManager, highestRecorded: highestRecorded)
        }
        var index = next()
        var resumed = false
        while true {
            let place = DataFileNumbering.path(forIndex: index, extension: fileExtension, inDataFolder: dataFolder, folderSize: folderSize)
            prepareFolder(place.folder)
            if !fileManager.fileExists(atPath: place.file) {
                return place.file
            }
            if !resumed {
                resumed = true
                resume(fromDataFolder: dataFolder, folderSize: folderSize, fileManager: fileManager, highestRecorded: highestRecorded)
            }
            index = next()
        }
    }
}
