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

/// The options of a burn as the preferences hold them when they are read: what
/// the checkboxes, the destination and the compression of the burn window
/// choose. The window binds its checkboxes to these keys, so it reads the
/// options again when it opens, when it estimates the size and when a burn
/// starts; the burn thread then works from the options the burn started with.
public struct BurnOptions: Sendable, Equatable {
    /// The files are anonymized before they are written.
    public var anonymized: Bool
    /// Where the burn writes: the tag of the destination (CD/DVD, USB key, disc image).
    public var destination: Int
    /// The medium holds a ZIP file protected by a password.
    public var encrypted: Bool
    /// The compression the window selects when it opens: the tag of its choice.
    public var compressionMode: Int
    /// Compressing writes JPEG instead of JPEG 2000.
    public var jpegInsteadOfJPEG2000: Bool
    /// The Weasis viewer goes on the medium.
    public var includesWeasis: Bool
    /// HTML pages of the images go on the medium, unless it is anonymized.
    public var includesHTML: Bool
    /// The studies' reports go on the medium, unless it is anonymized.
    public var copiesReports: Bool
    /// The supplementary folder goes on the medium.
    public var includesSupplementaryFolder: Bool
    /// The supplementary folder, as written in the preferences (it may start with a tilde).
    public var supplementaryFolderPath: String?

    public init(anonymized: Bool, destination: Int, encrypted: Bool, compressionMode: Int, jpegInsteadOfJPEG2000: Bool,
                includesWeasis: Bool, includesHTML: Bool, copiesReports: Bool, includesSupplementaryFolder: Bool,
                supplementaryFolderPath: String?) {
        self.anonymized = anonymized
        self.destination = destination
        self.encrypted = encrypted
        self.compressionMode = compressionMode
        self.jpegInsteadOfJPEG2000 = jpegInsteadOfJPEG2000
        self.includesWeasis = includesWeasis
        self.includesHTML = includesHTML
        self.copiesReports = copiesReports
        self.includesSupplementaryFolder = includesSupplementaryFolder
        self.supplementaryFolderPath = supplementaryFolderPath
    }

    /// The options in `store` now.
    public init(_ store: any PreferenceStore) {
        typealias Keys = ApplicationPreferences
        self.init(anonymized: store[Keys.anonymizedBeforeBurning], destination: store[Keys.burnDestination],
                  encrypted: store[Keys.encryptsBurnedMedia], compressionMode: store[Keys.burnCompressionMode],
                  jpegInsteadOfJPEG2000: store[Keys.burnsJPEGInsteadOfJPEG2000], includesWeasis: store[Keys.burnWeasis],
                  includesHTML: store[Keys.burnHtml], copiesReports: store[Keys.copyReportsToMedia],
                  includesSupplementaryFolder: store[Keys.burnSupplementaryFolder],
                  supplementaryFolderPath: store[Keys.supplementaryBurnPath])
    }

    /// HTML pages go on the medium: asked for, and the medium not anonymized.
    public var addsHTML: Bool { includesHTML && !anonymized }

    /// The reports go on the medium: asked for, and the medium not anonymized.
    public var addsReports: Bool { copiesReports && !anonymized }

    /// The supplementary folder with its tilde expanded, when its path is
    /// longer than one character (UTF-16) and `exists` finds it; nil
    /// otherwise, and the window then turns the option off in the preferences.
    public func usableSupplementaryFolder(exists: (String) -> Bool) -> String? {
        guard let path = supplementaryFolderPath, (path as NSString).length > 1 else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return exists(expanded) ? expanded : nil
    }
}
