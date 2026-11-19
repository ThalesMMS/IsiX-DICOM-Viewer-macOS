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
import IsiXPreferences

/// What DicomCompressor, the class of the Horos and OsiriX plugin SDK that
/// compresses and decompresses lists of files, asks of a conversion: where the
/// results go and with which settings.
///
/// The SDK's class wrote its options to a property list and started the
/// Decompress helper with it. The helper began from the factory settings,
/// laid the application's stored preferences over them, and the options over
/// those: an option replaced the preference of the same name for that run,
/// and every other preference stood. The conversion is run in the application
/// now, and reads the same settings.
///
/// Of the options a plugin gives, the conversion reads CompressionSettings,
/// CompressionSettingsLowRes, CompressionResolutionLimit, UseJPEGColorSpace
/// and DecompressMoveIfFail. JPEGinsteadJPEG2000 is accepted and changes
/// nothing, as it changed nothing in the helper, which never read it: a caller
/// that wants JPEG gives the CompressionSettings that choose it.
/// UseOpenJpegForJPEG2000 and UseKDUForJPEG2000 chose between JPEG 2000
/// libraries the application no longer has a choice of.
public struct DicomCompressorRequest: Sendable {

    /// What the helper was told in place of a folder when each file was to be
    /// converted where it is.
    public static let inPlace = "sameAsDestination"

    /// The folder the results go to, nil for each file where it is: no folder
    /// and the helper's word for none are the same request.
    public let destination: String?
    /// How far an archive among the files may expand, as the application's
    /// preferences have it.
    public let archiveBudget: ArchiveExpansionBudget
    /// What the conversion reads: the preferences it reads, each replaced by
    /// the option of the same name.
    let preferences: MemoryPreferences

    /// The request for `directory` with `options`, in an application whose
    /// preferences are `preferences`. An option a property list cannot hold
    /// is not an option: the helper was given its options as one.
    public init(directory: String?, options: [AnyHashable: Any]?, preferences: any PreferenceStore) {
        destination = directory == Self.inPlace ? nil : directory
        archiveBudget = .imported(from: preferences)
        var given: [String: Any] = [:], stored: [String: Any] = [:]
        for name in DecompressConversion.settingsKeys.map(\.name) + [DatabasePreferences.decompressMovesUnreadableFiles.name] {
            if let value = options?[name] { given[name] = value }
            if let value = preferences.object(forKey: name) { stored[name] = value }
        }
        self.preferences = MemoryPreferences(given, registered: stored)
    }

    /// DecompressMoveIfFail: when compressing, a file that cannot be read is
    /// moved to the destination as it is.
    public var moveIfUnreadable: Bool {
        preferences[DatabasePreferences.decompressMovesUnreadableFiles]
    }

    /// One batch of the request, as CompressionHelperRun runs them: the
    /// arguments are its own, the destination, the mode and the files.
    public func batch(arguments: [String], service: DecompressService?) -> DecompressConversionTask {
        DecompressConversionTask(arguments: arguments, settings: DecompressConversion.settings(from: preferences),
                                 moveIfUnreadable: moveIfUnreadable, archiveBudget: archiveBudget, service: service)
    }

    /// The options of the property list at `path`: nil for no path, and for a
    /// file that is not there or holds no dictionary, which the helper read
    /// as no options at all.
    public static func options(atPath path: String?) -> [AnyHashable: Any]? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [AnyHashable: Any]
    }
}
