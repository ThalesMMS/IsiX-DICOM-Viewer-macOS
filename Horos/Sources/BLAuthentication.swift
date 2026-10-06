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
//  ====================================================================== 	//
//  BLAuthentication.h														//
//  																		//
//  Last Modified on Tuesday April 24 2001									//
//  Copyright 2001 Ben Lachman												//
//																			//
//	Thanks to Brian R. Hill <http://personalpages.tds.net/~brian_hill/>		//
//  ====================================================================== 	//

import AppKit
import Security

/// Authorization rights, and commands run as root with them. PluginManager
/// moves plugins and makes plugin folders through -executeCommand:withArgs:.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/BLAuthentication.h> are those of the former class. The exported C
/// function AuthorizationExecuteWithPrivilegesStdErrAndPid() stays Objective-C,
/// in BLAuthentication+CAPI.m.
@objc(BLAuthentication)
public final class BLAuthentication: NSObject {
    private var authorizationRef: AuthorizationRef? = nil

    /// The instance +sharedInstance creates the first time, as the former
    /// `static id sharedTask`. A global `let` is made once even when two
    /// threads ask first; the lazy `var` could make two.
    // nonisolated(unsafe): the constant never changes. Its authorization is
    // used by the plugin installation, on the main thread (PluginManager).
    nonisolated(unsafe) private static let sharedTask = BLAuthentication()

    /// kAuthorizationRightExecute as a C string that lives as long as the app,
    /// kept as its address: it is never written, so any thread may read it.
    private static let rightExecuteAddress = UInt(bitPattern: strdup(kAuthorizationRightExecute)!)
    private static var rightExecute: UnsafePointer<CChar> { UnsafePointer(bitPattern: rightExecuteAddress)! }

    /// The former code read at most 20 commands, of at most 127 bytes each.
    private static let maxCommands = 20
    private static let maxPathLength = 128

    // returns an instace of itself, creating one if needed
    @objc(sharedInstance)
    public class func sharedInstance() -> BLAuthentication! {
        return sharedTask
    }

    // initializes the super class and sets authorizationRef to NULL
    public override init() {
        super.init()
        authorizationRef = nil
    }

    // deauthenticates the user and deallocates memory
    deinit {
        deauthenticate()
    }

    /// The rights the former code asked for: kAuthorizationRightExecute for
    /// each of the first 20 commands, as a C string of at most 127 bytes.
    /// `items` has one entry per command, as before; the entries past the 20th
    /// name the right with an empty value here, where the former code left them
    /// uninitialized. A path that does not fit, or is not a string, is an empty
    /// C string here, where the former buffer kept whatever it held.
    private func withRightItems<T>(_ forCommands: [Any], _ body: (UnsafeMutablePointer<AuthorizationItem>, Int) -> T) -> T {
        let numItems = forCommands.count
        let items = UnsafeMutablePointer<AuthorizationItem>.allocate(capacity: max(numItems, 1))
        items.initialize(repeating: AuthorizationItem(name: BLAuthentication.rightExecute, valueLength: 0, value: nil, flags: 0), count: max(numItems, 1))
        let paths = UnsafeMutablePointer<CChar>.allocate(capacity: BLAuthentication.maxCommands * BLAuthentication.maxPathLength)
        paths.initialize(repeating: 0, count: BLAuthentication.maxCommands * BLAuthentication.maxPathLength)
        defer {
            items.deallocate()
            paths.deallocate()
        }
        var i = 0
        while i < numItems && i < BLAuthentication.maxCommands {
            let path = paths + i * BLAuthentication.maxPathLength
            _ = (forCommands[i] as? NSString)?.getCString(path, maxLength: BLAuthentication.maxPathLength, encoding: String.Encoding.utf8.rawValue)

            items[i].name = BLAuthentication.rightExecute
            items[i].value = UnsafeMutableRawPointer(path)
            items[i].valueLength = strlen(path)
            items[i].flags = 0

            i += 1
        }

        return body(items, numItems)
    }

    /// AuthorizationCopyRights, which the former code called with a NULL
    /// reference when AuthorizationCreate had failed.
    private func copyRights(_ rights: inout AuthorizationRights, _ flags: AuthorizationFlags, _ authorizedRights: inout UnsafeMutablePointer<AuthorizationRights>?) -> OSStatus {
        guard let authorizationRef = authorizationRef else { return errAuthorizationInvalidRef }
        return AuthorizationCopyRights(authorizationRef, &rights, nil /*kAuthorizationEmptyEnvironment*/, flags, &authorizedRights)
    }

    //============================================================================
    //	- (BOOL)isAuthenticated:(NSArray *)forCommands
    //============================================================================
    // Find outs if the user has the appropriate authorization rights for the
    // commands listed in (NSArray *)forCommands.
    // This should be called each time you need to know whether the user
    // is authorized, since the AuthorizationRef can be invalidated elsewhere, or
    // may expire after a short period of time.
    //
    @objc(isAuthenticated:)
    public func isAuthenticated(_ forCommands: [Any]!) -> Bool {
        var rights = AuthorizationRights(count: 0, items: nil)
        var authorizedRights: UnsafeMutablePointer<AuthorizationRights>? = nil
        var flags: AuthorizationFlags = []

        let forCommands = forCommands ?? []
        let numItems = forCommands.count

        var err: OSStatus = 0
        var authorized = false

        if authorizationRef == nil {
            rights.count = 0
            rights.items = nil

            flags = []

            err = AuthorizationCreate(&rights, nil /*kAuthorizationEmptyEnvironment*/, flags, &authorizationRef)
        }

        if numItems < 1 {
            return authorized
        }

        return withRightItems(forCommands) { items, numItems in
            rights.count = UInt32(numItems)
            rights.items = items

            flags = .extendRights

            err = copyRights(&rights, flags, &authorizedRights)

            authorized = (errAuthorizationSuccess == err)

            if authorized, let authorizedRights = authorizedRights {
                AuthorizationFreeItemSet(authorizedRights)
            }

            return authorized
        }
    }

    //============================================================================
    //	- (void)deauthenticate
    //============================================================================
    // Deauthenticates the user by freeing their authorization.
    //
    @objc(deauthenticate)
    public func deauthenticate() {
        if let ref = authorizationRef {
            AuthorizationFree(ref, [.destroyRights])
            authorizationRef = nil
            NotificationCenter.default.post(name: .BLDeauthenticated, object: self)
        }
    }

    //============================================================================
    //	- (BOOL)fetchPassword:(NSArray *)forCommands
    //============================================================================
    // Adds rights for commands specified in (NSArray *)forCommands.
    // Commands should be passed as a NSString comtaining the path to the executable.
    // Returns YES if rights were gained
    //
    @objc(fetchPassword:)
    public func fetchPassword(_ forCommands: [Any]!) -> Bool {
        var rights = AuthorizationRights(count: 0, items: nil)
        var authorizedRights: UnsafeMutablePointer<AuthorizationRights>? = nil

        let forCommands = forCommands ?? []
        let numItems = forCommands.count

        var err: OSStatus = 0
        var authorized = false

        if numItems < 1 {
            return authorized
        }

        return withRightItems(forCommands) { items, numItems in
            rights.count = UInt32(numItems)
            rights.items = items

            let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]

            err = copyRights(&rights, flags, &authorizedRights)

            authorized = (errAuthorizationSuccess == err)

            if authorized {
                if let authorizedRights = authorizedRights {
                    AuthorizationFreeItemSet(authorizedRights)
                }
                NotificationCenter.default.post(name: .BLAuthenticated, object: self)
            }

            return authorized
        }
    }

    //============================================================================
    //	- (BOOL)authenticate:(NSArray *)forCommands
    //============================================================================
    // Authenticates the commands in the array (NSArray *)forCommands by calling
    // fetchPassword.
    //
    @objc(authenticate:)
    public func authenticate(_ forCommands: [Any]!) -> Bool {
        if !isAuthenticated(forCommands) {
            _ = fetchPassword(forCommands)
        }

        return isAuthenticated(forCommands)
    }

    //============================================================================
    //	- (int)getPID:(NSString *)forProcess
    //============================================================================
    // Retrieves the PID (process ID) for the process specified in
    // (NSString *)forProcess.
    // The more specific forProcess is the better your accuracy will be, esp. when
    // multiple versions of the process exist.
    //
    @objc(getPID:)
    public func getPID(_ forProcess: String!) -> Int32 {
        guard let forProcess, !forProcess.isEmpty else { return 0 }
        let processList = Process()
        let outpipe = Pipe()
        processList.executableURL = URL(fileURLWithPath: "/bin/ps")
        processList.arguments = ["-axwwopid,command"]
        processList.standardOutput = outpipe

        do {
            try processList.run()
        } catch {
            NSLog("Error opening pipe: %@", forProcess)
            NSSound.beep()
            return 0
        }
        let output = outpipe.fileHandleForReading.readDataToEndOfFile()
        processList.waitUntilExit()
        guard processList.terminationStatus == 0 else { return 0 }
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let entry = String(line)
            let scanner = Scanner(string: entry)
            guard let number = scanner.scanInt(), number > 0,
                  let pid = Int32(exactly: number) else { continue }
            let command = entry[scanner.currentIndex...]
            if command.contains(forProcess) { return pid }
        }
        return 0
    }

    //============================================================================
    //	-(void)executeCommand:(NSString *)pathToCommand withArgs:(NSArray *)arguments
    //============================================================================
    // Executes command in (NSString *)pathToCommand with the arguments listed in
    // (NSArray *)arguments as root.
    // pathToCommand should be a string contain the path to the command
    // (eg., /usr/bin/more), arguments should be an array of strings each containing
    // a single argument.
    //
    @objc(executeCommand:withArgs:)
    public func executeCommand(_ pathToCommand: String!, withArgs arguments: [Any]!) -> Bool {
        #if MACAPPSTORE
        let task = Process.launchedProcess(launchPath: pathToCommand, arguments: (arguments ?? []).compactMap { $0 as? String })
        task.waitUntilExit()
        return true
        #else
        var err: OSStatus = 0
        var processid: pid_t = 0

        if !authenticate([pathToCommand as Any]) {
            return false
        }

        let toolPath = strdup(pathToCommand ?? "")
        defer { free(toolPath) }

        if arguments == nil || arguments.count < 1 {
            err = AuthorizationExecuteWithPrivilegesStdErrAndPid(authorizationRef,
                                                                 toolPath,
                                                                 [],
                                                                 nil,
                                                                 nil,
                                                                 nil,
                                                                 &processid)
        } else {
            // can only handle 30 arguments to a given command; the former loop
            // stopped at 19
            var args = [UnsafeMutablePointer<CChar>?](repeating: nil, count: 30)
            var i = 0
            while i < arguments.count && i < 19 {
                if let argument = (arguments[i] as? NSString)?.utf8String {
                    args[i] = strdup(argument)
                }
                i += 1
            }
            args[i] = nil
            defer {
                for arg in args { free(arg) }
            }

            err = args.withUnsafeBufferPointer { argv in
                AuthorizationExecuteWithPrivilegesStdErrAndPid(authorizationRef,
                                                               toolPath,
                                                               [],
                                                               argv.baseAddress,
                                                               nil,
                                                               nil,
                                                               &processid)
            }
        }

        if err != 0 {
            NSSound.beep()
            NSLog("Error %d in AuthorizationExecuteWithPrivileges", Int32(err))
            return false
        } else {
            var waitResult: pid_t
            var junkStatus: Int32 = 0

            repeat {
                waitResult = waitpid(processid, &junkStatus, 0)
            } while (waitResult < 0) && (errno == EINTR)

            return true
        }
        #endif
    }

    //============================================================================
    //	- (void)killProcess:(NSString *)commandFromPS
    //============================================================================
    // Finds and kills the process specified in (NSString *)commandFromPS using ps
    // and kill. (by pid)
    // The more specific (ie., closer to matching the actual listing in ps)
    // commandFromPS is the better your accuracy will be, esp. when multiple
    // versions of the process exist.
    //
    @objc(killProcess:)
    public func killProcess(_ commandFromPS: String!) -> Bool {
        if !isAuthenticated([commandFromPS as Any]) {
            _ = authenticate([commandFromPS as Any])
        }

        let pid = String(format: "%d", getPID(commandFromPS))

        if (pid as NSString).intValue > 0 {
            _ = executeCommand("/bin/kill", withArgs: [pid])
            return true
        } else {
            NSSound.beep()
            NSLog("Error killing process %@, invalid PID.", pid)
            return false
        }
    }
}

// BLAuthentication sends these notifications are sent when the user
// becomes authenticated or deauthenticated.

// Sample notification observer:
/*
    [[NSNotificationCenter defaultCenter] addObserver:self
                                        selector:@selector(userAuthenticated:)
                                        name:BLAuthenticatedNotification
                                        object:[BLAuthentication sharedInstance]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                        selector:@selector(userDeauthenticated:)
                                        name:BLDeauthenticatedNotification
                                        object:[BLAuthentication sharedInstance]];
*/
