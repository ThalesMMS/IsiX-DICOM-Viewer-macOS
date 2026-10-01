//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Security
import LocalAuthentication
import Darwin

/// Re-exec preserves the signed application's legacy ACL identity. This child
/// runs before NSApplicationMain; neither credentials nor the parent process's
/// Keychain interaction setting are modified.
enum NonInteractiveKeychainRead {
    static let argument = "--horos-noninteractive-keychain-read"

    static func read(service: String, account: String, data: Bool, keychainPath: String? = nil) -> (OSStatus, [String: Any]?) {
        guard let executable = Bundle.main.executableURL else { return (errSecNotAvailable, nil) }
        let child = Process()
        child.executableURL = executable
        child.arguments = [argument]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do {
            var values: [String: Any] = ["service": service, "account": account, "data": data]
            if let keychainPath { values["keychainPath"] = keychainPath }
            let request = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try child.run()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 3)
            timer.setEventHandler { if child.isRunning { child.terminate() } }
            timer.resume()
            defer { timer.cancel() }
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, response.count <= 1_048_576,
                  let reply = try PropertyListSerialization.propertyList(from: response, format: nil) as? [String: Any],
                  let status = reply["status"] as? Int32 else { return (errSecInteractionNotAllowed, nil) }
            return (status, reply["item"] as? [String: Any])
        } catch {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            return (errSecNotAvailable, nil)
        }
    }

    static func runHelperIfRequested() -> Bool {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == argument else { return false }
        // Do not turn the application's ACL identity into a credential reader
        // callable by unrelated programs through this command-line mode.
        guard parentHasSameIdentity() else { writeReply(errSecAuthFailed, nil); return true }
        var status = errSecParam
        var item: [String: Any]?
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        if bytes.count <= 16_384,
           let request = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
           let service = request["service"] as? String, let account = request["account"] as? String,
           let wantData = request["data"] as? Bool, allowed(service, account) {
            // File-based SecItem ignores LAContext.interactionNotAllowed. This
            // public legacy compatibility entry point is confined to the child.
            // Lookup fails closed if it disappears; no modern equivalent or
            // absence of legacy API use is claimed.
            typealias DisableInteraction = @convention(c) (UInt8) -> OSStatus
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed") {
                status = unsafeBitCast(symbol, to: DisableInteraction.self)(0)
                if status == errSecSuccess {
                    let context = LAContext()
                    context.interactionNotAllowed = true
                    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service, kSecAttrAccount as String: account,
                        kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true,
                        kSecUseAuthenticationContext as String: context]
                    if wantData { query[kSecReturnData as String] = true }
                    // Explicit file selection also supports disposable-keychain
                    // tests without changing the default/search list in either process.
                    if let path = request["keychainPath"] as? String {
                        typealias OpenKeychain = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<SecKeychain?>) -> OSStatus
                        guard path.hasPrefix("/"),
                              let openSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainOpen") else {
                            writeReply(errSecParam, nil); return true
                        }
                        var keychain: SecKeychain?
                        status = path.withCString { unsafeBitCast(openSymbol, to: OpenKeychain.self)($0, &keychain) }
                        guard status == errSecSuccess, let keychain else { writeReply(status, nil); return true }
                        query[kSecMatchSearchList as String] = [keychain]
                    }
                    var result: CFTypeRef?
                    status = SecItemCopyMatching(query as CFDictionary, &result)
                    if status == errSecSuccess, let attributes = result as? [String: Any] {
                        var values: [String: Any] = [:]
                        for key in [kSecValueData, kSecAttrGeneric] {
                            if let value = attributes[key as String] as? Data { values[key as String] = value }
                        }
                        item = values
                    }
                }
            } else { status = errSecNotAvailable }
        }
        writeReply(status, item)
        return true
    }

    private static func writeReply(_ status: OSStatus, _ item: [String: Any]?) {
        var reply: [String: Any] = ["status": status]
        if let item { reply["item"] = item }
        if let response = try? PropertyListSerialization.data(fromPropertyList: reply, format: .binary, options: 0) {
            try? FileHandle.standardOutput.write(contentsOf: response)
        }
    }

    private static func allowed(_ service: String, _ account: String) -> Bool {
        (service == "org.horosproject.DICOMweb.credentials" && !account.isEmpty && account.utf8.count <= 1024)
            || (service == "org.horosproject.horos.xmlrpc" && account == "server")
    }

    private static func parentHasSameIdentity() -> Bool {
        var ownCode: SecCode?, parentCode: SecCode?, requirement: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: getppid()] as CFDictionary,
                                            [], &parentCode) == errSecSuccess,
              let parentCode else { return false }
        return SecCodeCheckValidity(parentCode, [], requirement) == errSecSuccess
    }
}

@_cdecl("HorosRunNonInteractiveKeychainHelper")
func HorosRunNonInteractiveKeychainHelper() -> Int32 {
    NonInteractiveKeychainRead.runHelperIfRequested() ? 1 : 0
}
