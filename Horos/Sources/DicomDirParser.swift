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

// DicomDirParser and the NSString (NumberStuff) category are implemented in
// Swift: the Objective-C names, the selectors and
// <Horos/DicomDirParser.h> are those of the former DicomDirParser.m. The
// strings are handled as NSString, with the same NSString methods the
// Objective-C called, so case mapping, path components and comparisons are
// those of before.

public extension NSString {

    /// YES when the receiver, trimmed of spaces and tabs, holds only decimal
    /// digits (an empty string after trimming counts); NO for an empty string.
    @objc(holdsIntegerValue)
    func holdsIntegerValue() -> Bool {
        if length == 0 {
            return false
        }

        let compare = trimmingCharacters(in: .whitespaces) as NSString
        let validCharacters = NSCharacterSet.decimalDigits as NSCharacterSet
        for i in 0..<compare.length {
            if !validCharacters.characterIsMember(compare.character(at: i)) {
                return false
            }
        }
        return true
    }
}

/// Reads and parses DICOMDIRs: `-init:` runs dcmdump on the DICOMDIR for its
/// Referenced File IDs (0004,1500), and `-parseArray:` adds to the array the
/// files under the DICOMDIR's folder that those IDs name.
@objc(DicomDirParser)
public final class DicomDirParser: NSObject {

    /// The former @synchronized (singeDcmDump): one dcmdump at a time, whichever
    /// the parser.
    private static let singeDcmDump = NSRecursiveLock()

    /// How deep -parseArray: is in the DICOMDIR's folders. It was a file-scope
    /// static shared by every parser and thread, without a lock.
    private var validFilePathDepth = 0

    private static let timeout: TimeInterval = 20 // the former TIMEOUT

    /// The former ivars: the dcmdump output and the DICOMDIR's folder, with a
    /// trailing slash.
    private let data: NSString
    private let dirpath: NSString

    @objc(init:)
    public init(_ srcFile: String!) {
        // The former -init: raised NSInvalidArgumentException for a nil file,
        // when it added it to the dcmdump arguments.
        guard let srcFile = srcFile as NSString? else {
            NSException(name: .invalidArgumentException,
                        reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
            fatalError("unreachable")
        }

        var output: NSString = ""
        var raised: NSException?

        // @synchronized released the lock when an exception left it and let
        // the exception reach the caller; so does this.
        DicomDirParser.singeDcmDump.lock()
        do {
            try HorosObjCException.perform {
                output = DicomDirParser.dcmdumpOutput(srcFile)
            }
        } catch {
            raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        DicomDirParser.singeDcmDump.unlock()

        if let raised = raised {
            raised.raise()
        }

        dirpath = NSString(format: "%@/", srcFile.deletingLastPathComponent)
        data = NSString(string: output as String)
        super.init()
    }

    /// The former class inherited -init, which left both ivars nil: such a
    /// parser runs no dcmdump and -parseArray: adds nothing. Kept so that a
    /// plain -init still answers that way instead of trapping.
    public override init() {
        dirpath = ""
        data = ""
        super.init()
    }

    /// dcmdump +L +P 0004,1500 of the DICOMDIR, read for at most 20 seconds;
    /// empty when dcmdump does not start.
    private static func dcmdumpOutput(_ srcFile: NSString) -> NSString {
        let theArguments = NSMutableArray()
        let newPipe = Pipe()

        // create the subprocess
        let aTask = Process()

        aTask.standardOutput = newPipe

        let resourcePath = (Bundle.main.resourcePath ?? "") as NSString
        aTask.environment = ["DCMDICTPATH": resourcePath.appendingPathComponent("/dicom.dic")]
        aTask.executableURL = URL(fileURLWithPath: resourcePath.appendingPathComponent("/dcmdump"))
        theArguments.add(srcFile)

        theArguments.add("+L")
        theArguments.add("+P")
        theArguments.add("0004,1500")

        aTask.arguments = theArguments as? [String]

        // A dcmdump that did not start has no output. The former read loop
        // waited for it forever, holding the lock every DICOMDIR read takes.
        if let taskError = launch(aTask) {
            NSLog("****** dcmdump failed for %@: %@", srcFile, taskError.localizedDescription)
            return ""
        }
        try? newPipe.fileHandleForWriting.close()

        // The whole output, read on another thread so that the deadline holds
        // even while dcmdump writes nothing, then decoded once. The former loop
        // decoded each read as UTF-8 and dropped the reads that did not decode:
        // a name in Latin-1, or a character cut between two reads, lost files.
        let output = DicomDirParserOutput()
        let reader = newPipe.fileHandleForReading
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.set(reader.readDataToEndOfFile())
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("****** dcmdump timed out for %@", srcFile)
            aTask.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(aTask.processIdentifier, SIGKILL)
                finished.wait()
            }
        }

        // Avoid waitUntilExit here: it allows the main run loop to continue.

        let bytes = output.get()
        return (NSString(data: bytes, encoding: String.Encoding.utf8.rawValue)
                ?? NSString(data: bytes, encoding: String.Encoding.isoLatin1.rawValue)) ?? ""
    }

    /// HorosLaunchTask() of HorosBoundedTask.h, which the former code called and
    /// which Swift cannot import (the header is manual retain/release): nil when
    /// the task started, else the error launchAndReturnError: gave, or one made
    /// of the exception -launch raised.
    private static func launch(_ task: Process) -> NSError? {
        var failure: NSError?
        var launched = false
        do {
            try HorosObjCException.perform {
                do {
                    try task.run() // -launchAndReturnError:
                    launched = true
                } catch {
                    failure = error as NSError
                }
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            failure = NSError(domain: "HorosTaskLaunch", code: 2, userInfo: [
                NSLocalizedDescriptionKey: exception?.reason ?? "The helper tool could not be started."])
        }
        if launched {
            return nil
        }
        return failure ?? NSError(domain: "HorosTaskLaunch", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The helper tool could not be started."])
    }

    //————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    private func testForValidFilePath(_ dicomdirFileList: NSMutableArray, path startDirectory: NSString?, files: NSMutableArray?) {
        guard let startDirectory = startDirectory, let files = files else { return }
        if startDirectory.isEqual(to: "") || startDirectory.isEqual(to: "/") { return }
        validFilePathDepth += 1

        do {
            try HorosObjCException.perform {
                for filePathComponent in (try? FileManager.default.contentsOfDirectory(atPath: startDirectory as String)) ?? [] {
                    autoreleasepool {
                        do {
                            try HorosObjCException.perform {
                                self.testItem(filePathComponent as NSString, in: startDirectory,
                                              dicomdirFileList: dicomdirFileList, files: files)
                            }
                        } catch {
                            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                                NSLog("%@", e)
                            }
                        }
                    }
                }
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[DicomDirParser _testForValidFilePath:path:files:]")
            }
        }

        validFilePathDepth -= 1
    }

    /// One entry of `startDirectory`: a file named by the DICOMDIR is added to
    /// `files`, a folder is searched in turn, down to 8 levels.
    private func testItem(_ name: NSString, in startDirectory: NSString, dicomdirFileList: NSMutableArray, files: NSMutableArray) {
        let filePath = startDirectory.appendingPathComponent(name as String) as NSString

        let uppercaseFilePath = filePath.uppercased as NSString

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath as String, isDirectory: &isDirectory) else { return }

        if !isDirectory.boolValue {
            do {
                try HorosObjCException.perform {
                    let ext = uppercaseFilePath.pathExtension as NSString

                    // only files with DCM or no extension, or a number like 82873.9982.9928.22
                    guard ext.isEqual(to: "DCM") || ext.isEqual(to: "") || ext.length > 4 || ext.length < 3 || ext.holdsIntegerValue() else {
                        return
                    }

                    let cutFilePath: NSString
                    if ext.length <= 4 && ext.length >= 3 && !ext.holdsIntegerValue() {
                        cutFilePath = uppercaseFilePath.deletingPathExtension as NSString
                    } else {
                        cutFilePath = uppercaseFilePath
                    }

                    guard cutFilePath.length < 2000 else { return }

                    autoreleasepool {
                        // The former @catch (...) {} : whatever is raised here
                        // is dropped silently.
                        try? HorosObjCException.perform {
                            if dicomdirFileList.contains(cutFilePath) || dicomdirFileList.contains(filePath) {
                                files.add(filePath)
                            } else {
                                let cutFilePathWithoutPathExtension = cutFilePath.deletingPathExtension as NSString

                                for case let s as NSString in dicomdirFileList {
                                    if cutFilePathWithoutPathExtension.isEqual(to: s as String) {
                                        files.add(filePath)
                                        break
                                    }

                                    if (s.pathExtension as NSString).isEqual(to: "") { /// for this case: 738495.		// GE Scanner
                                        if (cutFilePath.deletingPathExtension as NSString).isEqual(to: s.deletingPathExtension) {
                                            files.add(filePath)
                                            break
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    NSLog("**** _testForValidFilePath exception: %@", e)
                }
            }
        } else if validFilePathDepth < 8 {
            autoreleasepool {
                testForValidFilePath(dicomdirFileList, path: filePath, files: files)
            }
        }
    }

    //————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    @objc(parseArray:)
    public func parseArray(_ files: NSMutableArray!) {
        let result = NSMutableArray()

        // Each [...] value of the output, with '\' turned into '/'. The former
        // code walked the bytes of -UTF8String but stopped at -length, which
        // counts UTF-16 units, so the end of a UTF-8 output was not read;
        // this walks the characters.
        let text = data
        let length = text.length
        let open = unichar(UInt8(ascii: "[")), close = unichar(UInt8(ascii: "]"))

        var i = 0
        while i < length {
            if text.character(at: i) == open {
                var end = i + 1
                while end < length && text.character(at: end) != close {
                    end += 1
                }

                if end - i - 1 > 0 {
                    let piece = text.substring(with: NSMakeRange(i + 1, end - i - 1)).replacingOccurrences(of: "\\", with: "/")
                    let file = dirpath.appending(piece) as NSString

                    let ext = file.pathExtension as NSString

                    if ext.length <= 4 && ext.length >= 3 && !ext.holdsIntegerValue() {
                        result.add((file.uppercased as NSString).deletingPathExtension)
                    } else {
                        result.add(file.uppercased)
                    }
                }
                i = end
            }

            i += 1
        }

        validFilePathDepth = 0
        testForValidFilePath(result, path: dirpath, files: files)
    }
}

/// dcmdump's output, handed from the reading thread under a lock.
/// dcmdump's output, written by the reading thread and read by the caller
/// after it: the Mutex is the lock it always had.
private final class DicomDirParserOutput: Sendable {
    private let data = Mutex(Data())

    func set(_ value: Data) { data.withLock { $0 = value } }
    func get() -> Data { data.withLock { $0 } }
}
