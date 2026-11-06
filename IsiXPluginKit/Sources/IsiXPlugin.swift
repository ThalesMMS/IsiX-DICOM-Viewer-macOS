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

/// The plugin API version this framework implements. A plugin declares the
/// version it was built for under `IsiXPluginAPIVersion` in its Info.plist; the
/// host refuses a bundle whose version it does not support before loading it.
public let IsiXPluginAPIVersion: Int = 1

/// A plugin's entry point.
///
/// The bundle names the class that adopts this protocol under
/// `NSPrincipalClass`, qualified by its Swift module (`MyPlugin.MyPlugin`, or
/// `$(PRODUCT_MODULE_NAME).MyPlugin` in a build setting). The host creates one
/// instance with `init()` after the bundle passed its checks, calls
/// `activate(with:)` once, and `deactivate()` once when the application quits.
///
/// Everything here runs on the main actor. Long work goes to
/// `IsiXPluginContext.startTask(named:_:)`, on value snapshots.
@MainActor
public protocol IsiXPlugin: AnyObject {
    init()

    /// Registers the plugin's commands and observations. Throwing refuses the
    /// plugin: whatever it registered is removed and it is not called again.
    func activate(with context: IsiXPluginContext) throws

    /// Called once before the application quits. The host has already
    /// cancelled the plugin's tasks and removed its observations and commands.
    func deactivate()
}

public extension IsiXPlugin {
    func deactivate() {}
}

/// Something the plugin uses and declares under `IsiXPluginCapabilities` in its
/// Info.plist. A call that needs an undeclared capability throws
/// `IsiXPluginError.capabilityNotDeclared`.
public struct IsiXCapability: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Viewers, their series, images, geometry and pixels, and their events.
    public static let viewerRead = IsiXCapability(rawValue: "viewer.read")
    /// Committing pixels, changing the window level of a viewer and opening
    /// a series the plugin computed in a new viewer.
    public static let viewerWrite = IsiXCapability(rawValue: "viewer.write")
    /// Reading, creating, measuring and removing ROIs, and ROI events.
    public static let roi = IsiXCapability(rawValue: "roi")
    /// Querying the studies, series, images and albums of the database, and
    /// opening a series of the database in a viewer.
    public static let databaseRead = IsiXCapability(rawValue: "database.read")
    /// Writing derived DICOM files of a study and importing files into the database.
    public static let databaseImport = IsiXCapability(rawValue: "database.import")
    /// Changing what the user edits in the database: comments, state and
    /// report of studies and series, key images, and the studies of albums.
    public static let databaseWrite = IsiXCapability(rawValue: "database.write")
    /// Sending images and files to the DICOM nodes the user configured with Send on.
    public static let networkSend = IsiXCapability(rawValue: "network.send")
    /// Querying the DICOM nodes the user configured with Query/Retrieve on:
    /// studies, series and the modality worklist.
    public static let networkQuery = IsiXCapability(rawValue: "network.query")
    /// Answering XML-RPC methods of the plugin's own through the application's
    /// XML-RPC interface.
    public static let xmlRPC = IsiXCapability(rawValue: "xmlrpc")
}

/// The plugin's identity, as its Info.plist declares it.
public struct IsiXPluginInfo: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let version: String
    public let bundleURL: URL
    public let capabilities: Set<IsiXCapability>

    @_spi(IsiXHost)
    public init(identifier: String, name: String, version: String, bundleURL: URL, capabilities: Set<IsiXCapability>) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.bundleURL = bundleURL
        self.capabilities = capabilities
    }
}

/// Why a call into the host failed.
public enum IsiXPluginError: Error, Sendable, Equatable {
    /// The viewer was closed; the handle stays safe to call, and every call throws this.
    case viewerClosed
    /// The plugin did not declare the capability in its Info.plist.
    case capabilityNotDeclared(IsiXCapability)
    /// The plugin was deactivated, or its activation failed.
    case pluginInactive
    case sliceOutOfRange(Int)
    case phaseOutOfRange(Int)
    /// The image changed, or is another image, since the snapshot being committed was taken.
    case staleImage
    /// The pixels to commit differ in size or format from the image they replace.
    case dimensionMismatch
    case roiNotFound
    case unsupportedROIKind(IsiXROIKind)
    case invalidROI(String)
    case invalidCommand(String)
    case commandAlreadyRegistered(String)
    case noDatabase
    case hostFailure(String)
    /// No study, series, image or album of the database has this identifier or name.
    case notFound(String)
    /// A value the database does not accept; nothing was changed.
    case invalidValue(String)
    /// No DICOM node the user configured has this identifier, or the node does
    /// not allow what was asked (Send, or Query/Retrieve, off).
    case nodeNotConfigured(String)
    /// The node could not be reached, refused the association or answered
    /// with a failure; the reason says which.
    case networkFailure(String)
}

/// A sentence for the user. The application shows it when a command or an
/// activation throws one of these errors; a plugin's own errors are shown by
/// their `LocalizedError.errorDescription` too, when they provide one.
extension IsiXPluginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .viewerClosed:
            return "The viewer was closed."
        case .capabilityNotDeclared(let capability):
            return "The plugin did not declare the capability \(capability) in its Info.plist."
        case .pluginInactive:
            return "The plugin is not active."
        case .sliceOutOfRange(let slice):
            return "The series has no slice \(slice)."
        case .phaseOutOfRange(let phase):
            return "The series has no phase \(phase)."
        case .staleImage:
            return "The image changed since the plugin read it. Run the command again."
        case .dimensionMismatch:
            return "The pixels differ in size or format from the image they belong to."
        case .roiNotFound:
            return "The ROI no longer exists."
        case .unsupportedROIKind(let kind):
            return "A plugin cannot create a ROI of kind \(kind)."
        case .invalidROI(let reason):
            return reason
        case .invalidCommand(let id):
            return "The command \"\(id)\" needs an identifier and a title."
        case .commandAlreadyRegistered(let id):
            return "The command \"\(id)\" is already registered."
        case .noDatabase:
            return "No local database is open."
        case .hostFailure(let reason):
            return reason
        case .notFound(let what):
            return "The database has no \(what)."
        case .invalidValue(let reason):
            return reason
        case .nodeNotConfigured(let node):
            return "\(node) is not a DICOM node configured in Locations for this. A plugin reaches only the nodes the user configured."
        case .networkFailure(let reason):
            return reason
        }
    }
}
