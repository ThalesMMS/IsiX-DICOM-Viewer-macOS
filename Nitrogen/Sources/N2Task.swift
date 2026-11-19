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

/// The implementation of N2Task, declared in N2Task.h: the NSTask subclass of
/// the plugin SDK of Horos and OsiriX. The SDK's class forked and executed by
/// itself; this one keeps what it is given and hands it, at -launch, to a
/// Process of its own, whose state it answers.
///
/// What it keeps of the SDK's class: a task may be launched again (the process
/// of the launch before is told to terminate); a process is given the
/// environment set and nothing else, so none at all when none was set; a
/// standard stream may be a file handle, a pipe or the number of a file
/// descriptor; -waitUntilExit sleeps between looks and runs no run loop.
///
/// What it does not: the SDK's class installed, when first used, a SIGCHLD
/// handler for the whole process that reaped any child that had ended. The
/// application starts processes of its own through Process, and such a handler
/// would take their exit status before Process read it. No handler is
/// installed here; Process reaps the child it started.
///
/// A task told to run as another user (uid) cannot: the application is
/// sandboxed and may not change user. -launch then raises, as NSTask does for
/// a process it cannot start.
@objc @implementation extension N2Task {
    private final var path: String?
    private final var parameters: [String]?
    private final var variables: [String: String]?
    private final var directory: String?
    private final var input: Any?
    private final var output: Any?
    private final var errorOutput: Any?
    /// The process of the last launch; nil before the first.
    private final var process: Process?

    private final var launched: TimeInterval = 0
    var uid: uid_t = 0

    /// When the task was last launched, in seconds since the reference date.
    var launchTime: TimeInterval {
        launched
    }

    // MARK: What the process is given

    public override var launchPath: String? {
        get { path }
        set { path = newValue }
    }

    public override var arguments: [String]? {
        get { parameters }
        set { parameters = newValue }
    }

    public override var environment: [String: String]? {
        get { variables }
        set { variables = newValue }
    }

    public override var currentDirectoryPath: String {
        get { directory ?? FileManager.default.currentDirectoryPath }
        set { directory = newValue }
    }

    public override var standardInput: Any? {
        get { input }
        set { input = newValue }
    }

    public override var standardOutput: Any? {
        get { output }
        set { output = newValue }
    }

    public override var standardError: Any? {
        get { errorOutput }
        set { errorOutput = newValue }
    }

    /// A file handle or a pipe as it is, the file descriptor of a number as a
    /// file handle that leaves it open; anything else is refused, as it was.
    private static func stream(_ object: Any?) -> Any? {
        guard let object else { return nil }
        if object is FileHandle || object is Pipe {
            return object
        }
        if let number = object as? NSNumber {
            return FileHandle(fileDescriptor: number.int32Value, closeOnDealloc: false)
        }
        NSException(name: .invalidArgumentException, reason: "N2Task has invalid file descriptor \(object)", userInfo: nil).raise()
        return nil
    }

    // MARK: The process

    public override func launch() {
        if let process, process.isRunning {
            process.terminate()
        }

        if uid != 0 && uid != getuid() {
            NSException(name: .invalidArgumentException,
                        reason: "launch path not accessible: N2Task cannot run \(path ?? "(null)") as user \(uid), the application may not change user",
                        userInfo: nil).raise()
            return
        }

        let process = Process()
        process.launchPath = path
        process.arguments = parameters ?? []
        // The SDK's class gave the process the environment set, and none when
        // none was set; Process would hand down the application's.
        process.environment = variables ?? [:]
        if let directory {
            process.currentDirectoryPath = directory
        }
        if let stream = Self.stream(input) { process.standardInput = stream }
        if let stream = Self.stream(output) { process.standardOutput = stream }
        if let stream = Self.stream(errorOutput) { process.standardError = stream }

        launched = Date.timeIntervalSinceReferenceDate
        self.process = process
        // Raises NSInvalidArgumentException for a path that cannot be run.
        process.launch()
    }

    public override func terminate() {
        if let process, process.isRunning {
            process.terminate()
        }
    }

    public override func interrupt() {
        if let process, process.isRunning {
            process.interrupt()
        }
    }

    public override func suspend() -> Bool {
        process?.suspend() ?? false
    }

    public override func resume() -> Bool {
        process?.resume() ?? false
    }

    public override var isRunning: Bool {
        process?.isRunning ?? false
    }

    public override var processIdentifier: Int32 {
        process?.processIdentifier ?? 0
    }

    /// The process of the last launch, once it has ended; raises as NSTask does
    /// for a task that was not launched or is still running.
    private final func endedProcess() -> Process? {
        guard let process else {
            NSException(name: .invalidArgumentException, reason: "task not launched", userInfo: nil).raise()
            return nil
        }
        if process.isRunning {
            NSException(name: .invalidArgumentException, reason: "task still running", userInfo: nil).raise()
            return nil
        }
        return process
    }

    public override var terminationStatus: Int32 {
        endedProcess()?.terminationStatus ?? 0
    }

    public override var terminationReason: Process.TerminationReason {
        endedProcess()?.terminationReason ?? .exit
    }

    /// Looks every hundredth of a second, as the SDK's class did, and runs no
    /// run loop meanwhile.
    public override func waitUntilExit() {
        while isRunning {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
