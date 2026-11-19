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

/// The helper processes this application started and may have left behind.
enum StrayChildProcesses {
    /// Ends the crash reporters launched from inside this application's
    /// bundle, at start and at quit.
    nonisolated static func endOurs() {
        let kPIDArrayLength: Int32 = 100

        var MyArray = [pid_t](repeating: 0, count: Int(kPIDArrayLength))
        var NumberOfMatches: UInt32 = 0
        let Error: Int32

        // Every candidate below is matched on its BSD process name, which is shared
        // by anything else of that name this user is running. Only a process
        // launched from inside our own bundle may be signalled.
        let bundlePath = (Bundle.main.bundlePath as NSString).fileSystemRepresentation

        // The listener no longer forks a process per association: there
        // are no children of ours to end here.

        Error = GetAllPIDsForProcessName("CrashReporter", &MyArray, UInt32(kPIDArrayLength), &NumberOfMatches, nil)

        if Error == 0 {
            for Counter in 0..<Int(NumberOfMatches) {
                if MyArray[Counter] != getpid() && AppControllerCAPIProcessIsOurs(MyArray[Counter], bundlePath) {
                    NSLog("Child Process to kill (CrashReporter): %d (PID)", MyArray[Counter])
                    kill(MyArray[Counter], 15)
                }
            }
        }
    
    }
}
