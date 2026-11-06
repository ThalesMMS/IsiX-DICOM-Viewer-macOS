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

/// A run of the Decompress helper as CompressionHelperRun drives it: Process
/// in the application, a stand-in in the tests.
public protocol CompressionHelperProcess: AnyObject {
    /// Starts it; throws when it cannot be started.
    func launch() throws
    var isRunning: Bool { get }
    func terminate()
    /// Read only once it is no longer running.
    var terminationStatus: Int32 { get }
    /// It ended on a signal it did not catch: it crashed.
    var endedOnUncaughtSignal: Bool { get }
}

/// Compressing or decompressing files in the Decompress helper, a chunk of
/// files per helper, one helper at a time: no more than 10 min each. A chunk
/// fails when its helper cannot be started, outlives its time (20 s a file,
/// at least 600 s), is killed by a signal (when compressing) or exits with a
/// failure; the others still run.
public enum CompressionHelperRun {

    /// The files given to one helper.
    public static let chunkSize = 200
    /// Seconds allowed for each file of a chunk.
    public static let secondsPerFile = 20.0
    /// The least time a chunk is allowed.
    public static let minimumChunkSeconds = 600.0

    /// How a run waits and reports, which the application gives as the
    /// calling thread's progress, the clock and sleep, and its logs.
    public struct Environment {
        public var progress: (Double) -> Void
        public var now: () -> TimeInterval
        public var sleep: (TimeInterval) -> Void
        /// A message with the stack, for a helper that timed out or crashed.
        public var logStackTrace: (String) -> Void
        /// A helper that could not be started, and why.
        public var logLaunchFailure: (Error) -> Void
        /// A compressing helper crashed: what to do with all the files given.
        public var crashed: ([String]) -> Void

        public init(progress: @escaping (Double) -> Void, now: @escaping () -> TimeInterval,
                    sleep: @escaping (TimeInterval) -> Void, logStackTrace: @escaping (String) -> Void,
                    logLaunchFailure: @escaping (Error) -> Void, crashed: @escaping ([String]) -> Void) {
            self.progress = progress
            self.now = now
            self.sleep = sleep
            self.logStackTrace = logStackTrace
            self.logLaunchFailure = logLaunchFailure
            self.crashed = crashed
        }
    }

    /// Runs `makeProcess(arguments)` over `files` in chunks, the arguments
    /// being the destination ("sameAsDestination" for none), the mode
    /// ("compress" or "decompressList") and the chunk's files. NO when a chunk
    /// failed.
    public static func run(_ files: [String], mode: String, destination: String?,
                           chunkSize: Int = chunkSize, secondsPerFile: Double = secondsPerFile,
                           environment: Environment,
                           makeProcess: ([String]) -> CompressionHelperProcess) -> Bool {
        let dest = destination ?? "sameAsDestination"
        let compressing = mode == "compress"
        var succeeded = true
        let total = files.count

        var i = 0
        while i < total {
            let no = i + chunkSize >= total ? total - i : chunkSize
            if i != 0 || i + no < total {
                environment.progress(1.0 * Double(i) / Double(total))
            }
            let subArray = Array(files[i..<(i + no)])

            let task = makeProcess([dest, mode] + subArray)
            do {
                try task.launch()

                var timeout = secondsPerFile * Double(subArray.count)
                if timeout < minimumChunkSeconds { timeout = minimumChunkSeconds }
                let taskStart = environment.now()
                while task.isRunning {
                    environment.sleep(0.1)
                    if environment.now() - taskStart > timeout { break }
                }

                if task.isRunning {
                    environment.logStackTrace("***** task timeout reached -> terminate the NSTask : \((files as NSArray).description)")
                    succeeded = false
                    task.terminate()
                } else if compressing && task.endedOnUncaughtSignal {
                    succeeded = false
                    environment.logStackTrace("***** Decompress process crashed.")
                    environment.crashed(files)
                }
                if !task.isRunning && task.terminationStatus != 0 {
                    succeeded = false
                }
            } catch {
                succeeded = false
                environment.logLaunchFailure(error)
            }
            i += no
        }
        return succeeded
    }
}
