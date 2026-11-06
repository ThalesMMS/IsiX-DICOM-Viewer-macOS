//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// XML-RPC methods of a plugin. The application's XML-RPC interface, with its
// access settings (this computer only, the local network, a password), calls
// the plugin that registered a method's name; the application's own methods
// keep their names, and two plugins cannot register the same one.

import Foundation

/// An XML-RPC value.
public enum IsiXXMLRPCValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([IsiXXMLRPCValue])
    case structure([String: IsiXXMLRPCValue])

    /// The text of a string, or nil.
    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The member of a structure, or nil.
    public subscript(member: String) -> IsiXXMLRPCValue? {
        if case .structure(let members) = self { return members[member] }
        return nil
    }
}

/// A method's handler: the call's parameters in order, and the answer.
/// Throwing answers the caller with a fault that carries the error's text.
public typealias IsiXXMLRPCHandler = @MainActor ([IsiXXMLRPCValue]) throws -> IsiXXMLRPCValue

/// The XML-RPC side of the host: which names are free.
@_spi(IsiXHost)
@MainActor
public protocol IsiXXMLRPCBackend: AnyObject {
    /// False for a method of the application and for a name another plugin registered.
    func xmlRPCMethodNameIsAvailable(_ name: String) -> Bool
}

/// The methods of one plugin.
@MainActor
final class IsiXXMLRPCRegistry {
    private var handlers: [String: IsiXXMLRPCHandler] = [:]
    private var closed = false

    var names: [String] { handlers.keys.sorted() }

    func add(_ name: String, _ handler: @escaping IsiXXMLRPCHandler) -> Bool {
        guard !closed, handlers[name] == nil else { return false }
        handlers[name] = handler
        return true
    }

    func remove(_ name: String) { handlers[name] = nil }

    func handler(named name: String) -> IsiXXMLRPCHandler? { handlers[name] }

    func close() {
        closed = true
        handlers.removeAll()
    }
}

public extension IsiXPluginContext {
    /// Whether `name` can name a method: letters, digits, `_`, `.` and `-`,
    /// starting with a letter, at most 128 characters.
    nonisolated static func isValidXMLRPCMethodName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 128, CharacterSet.letters.contains(first), first.isASCII else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }
    }

    /// Answers the XML-RPC method `name` with `handler`, on the main actor,
    /// until the plugin unregisters it or is deactivated. Needs `xmlrpc`. A
    /// name of the application's own methods, or one another plugin answers,
    /// throws `invalidValue`.
    func registerXMLRPCMethod(named name: String, handler: @escaping IsiXXMLRPCHandler) throws {
        try requireActive()
        try requireCapability(.xmlRPC)
        guard Self.isValidXMLRPCMethodName(name) else {
            throw IsiXPluginError.invalidValue("\"\(name)\" cannot name an XML-RPC method: use letters, digits, _, . and -, starting with a letter.")
        }
        guard let backend = host as? any IsiXXMLRPCBackend else {
            throw IsiXPluginError.hostFailure("This application does not give plugins XML-RPC methods.")
        }
        guard backend.xmlRPCMethodNameIsAvailable(name), xmlRPCMethods.add(name, handler) else {
            throw IsiXPluginError.invalidValue("The XML-RPC method \(name) is already answered by the application or by a plugin.")
        }
    }

    func unregisterXMLRPCMethod(named name: String) {
        xmlRPCMethods.remove(name)
    }
}

@_spi(IsiXHost)
public extension IsiXPluginRuntime {
    /// The XML-RPC methods the plugin answers, by name.
    var xmlRPCMethodNames: [String] {
        guard state == .active else { return [] }
        return context.xmlRPCMethods.names
    }

    /// Calls the plugin's method; nil when the plugin does not answer `name`.
    func callXMLRPCMethod(named name: String, parameters: [IsiXXMLRPCValue]) throws -> IsiXXMLRPCValue? {
        guard state == .active, let handler = context.xmlRPCMethods.handler(named: name) else { return nil }
        return try handler(parameters)
    }
}
