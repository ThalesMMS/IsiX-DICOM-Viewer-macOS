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
import IsiXPreferences

/// The preferences of the Sources list that the catalog of IsiXPreferences
/// does not hold.
public enum SourceListPreferences {
    /// On: the shared databases Bonjour announces are not listed. Nothing
    /// registers it, so it is off until the user turns it on.
    public static let doNotSearchForBonjourServices = PreferenceKey<Bool>("DoNotSearchForBonjourServices")
}

/// What the Sources list of the database window decides without AppKit, Core
/// Data or the network: which local databases the preferences remember, what
/// becomes of a source the user entered or Bonjour found when that changes,
/// which mounted volumes are listed and selected, which address of a resolved
/// service is used, and how images are copied from one source to another.
public enum SourceListRules {

    // MARK: The local databases the preferences remember

    /// What becomes of the list of local databases (`localDatabasePaths`).
    public enum SourcesUpdate: Sendable {
        /// Nothing is written.
        case unchanged
        /// This list is written; nil removes the user's own.
        case write(LocalDatabaseSources?)
    }

    /// The list of local databases once a database not in it is shown: the
    /// folder holding its data folder is added at the end, named `name`. A
    /// folder somewhere the system empties on its own is not somewhere to come
    /// back to, and the list stays as it is. A list that is not stored, or is
    /// not a list, is written as not stored.
    public static func sources(_ stored: LocalDatabaseSources?, addingShownFolder folder: String, name: String,
                               isTemporary: Bool) -> SourcesUpdate {
        if isTemporary { return .unchanged }
        guard case .array(let entries)? = stored?.propertyList else { return .write(nil) }
        return .write(LocalDatabaseSources(propertyList: .array(entries + [LocalDatabaseSource(path: folder, name: name).propertyList])))
    }

    /// Whether `path` names the folder of a source of the list, compared code
    /// unit by code unit as the list has always been searched.
    public static func source(of stored: LocalDatabaseSources?, at folder: String?) -> LocalDatabaseSource? {
        guard let folder else { return nil }
        return stored?.sources.first { literallyEqual($0.path, folder) }
    }

    // MARK: Entered and detected sources

    /// What becomes of a listed source the user entered once the stored list
    /// no longer has it.
    public enum EnteredSourceFate: Sendable, Equatable {
        /// Still stored: it stays as it is.
        case kept
        /// No longer entered, but detected (by Bonjour or as a mounted
        /// volume): it stays listed, flagged as not entered.
        case notEntered
        /// Neither entered nor detected: it leaves the list.
        case removed
    }

    public static func fate(stillStored: Bool, detected: Bool) -> EnteredSourceFate {
        if stillStored { return .kept }
        return detected ? .notEntered : .removed
    }

    /// What Bonjour announces: a shared database of another IsiX or OsiriX
    /// (`_osirixdb._tcp.`), or a DICOM node (`_dicom._tcp.`).
    public enum BonjourSourceKind: Sendable, Equatable {
        case sharedDatabase
        case dicomNode
    }

    /// Whether the sources Bonjour finds of `kind` are listed: shared
    /// databases unless the user turned their search off, DICOM nodes only
    /// when the user turned their search on.
    public static func listsBonjourSources(_ kind: BonjourSourceKind, doNotSearchSharedDatabases: Bool,
                                           searchDICOMNodes: Bool) -> Bool {
        switch kind {
        case .sharedDatabase: return !doNotSearchSharedDatabases
        case .dicomNode: return searchDICOMNodes
        }
    }

    /// The key under which one stored DICOM node of the Sources list is kept:
    /// its address, its port when stored as a number, and its AE title, as
    /// they print. Two nodes with the same key are one entry, the last one.
    public static func enteredNodeKey(address: PropertyListValue?, port: PropertyListValue?, aeTitle: PropertyListValue?) -> String {
        let number = port.map { $0.isNumber ? UInt32(truncatingIfNeeded: $0.intValue) : 0 } ?? 0
        return "\(address?.text ?? "(null)")\(number)\(aeTitle?.text ?? "(null)")"
    }

    /// One address a resolved Bonjour service answers on.
    public struct ServiceAddress: Sendable, Equatable {
        public var host: String
        public var port: Int
        public var isIPv4: Bool

        public init(host: String, port: Int, isIPv4: Bool) {
            self.host = host
            self.port = port
            self.isIPv4 = isIPv4
        }
    }

    /// The address a source found by Bonjour is listed with: the first IPv4
    /// address, else the first IPv6 one.
    public static func preferredAddress(_ addresses: [ServiceAddress]) -> ServiceAddress? {
        addresses.first(where: \.isIPv4) ?? addresses.first { !$0.isIPv4 }
    }

    // MARK: Mounted volumes

    /// The `MOUNT` setting that never lists a mounted volume.
    public static let ignoresMountedVolumes = 2
    /// The `MOUNT` setting that asks what to do with each volume.
    public static let asksForMountedVolumes = -1

    /// Whether mounted volumes are listed at all.
    public static func listsMountedVolumes(mountAction: Int) -> Bool {
        mountAction != ignoresMountedVolumes
    }

    /// How a mounted volume is read: scanned into a database of its own, or
    /// an iPod read in place.
    public enum MountKind: Int, Sendable, Equatable {
        case generic = 0
        case iPod = 1
    }

    /// The kind of a mounted volume from what `diskutil info` says of it and
    /// what it holds; nil for a volume that is not a source: no optical
    /// medium, no iPod, no DICOMDIR and no database folder.
    public static func mountKind(opticalMediaType: String?, mediaType: String?, holdsDICOMDIR: Bool,
                                 holdsDatabaseFolder: Bool) -> MountKind? {
        if let opticalMediaType, !opticalMediaType.isEmpty { return .generic }
        if literallyEqual(mediaType, "iPod") { return .iPod }
        if holdsDICOMDIR || holdsDatabaseFolder { return .generic }
        return nil
    }

    /// Whether a volume is listed already through a local database at its
    /// root or inside it.
    public static func isListedAsLocalDatabase(volume: String, localLocations: [String]) -> Bool {
        let inside = volume + "/"
        return localLocations.contains { literallyEqual($0, volume) || $0.hasPrefix(inside) }
    }

    /// Whether a scanned volume becomes the database shown. When the user
    /// is asked about each volume (or held Command), the scan's own answer
    /// decides; otherwise the preference to select a CD or DVD, if the device
    /// is still there.
    public static func selectsScannedVolume(mountAction: Int, commandDown: Bool, scanSelectsIt: Bool,
                                            autoSelectsMedia: Bool, deviceStillThere: Bool) -> Bool {
        if mountAction == asksForMountedVolumes || commandDown {
            return scanSelectsIt
        }
        return autoSelectsMedia && deviceStillThere
    }

    // MARK: Opening a database

    /// Whether the message about a local database that is not found adds
    /// that it may be on a drive that is not connected.
    public static func missingDatabaseMayBeOnDrive(_ path: String?) -> Bool {
        path?.hasPrefix("/Volumes/") ?? false
    }

    // MARK: Copying between sources

    /// What the destination of a copy is.
    public enum CopyDestination: Sendable, Equatable {
        case localDatabase
        case sharedDatabase
        case dicomNode
    }

    /// How images are copied from the database shown to a destination.
    public enum CopyRoute: Sendable, Equatable {
        /// Files copied into another local database and indexed there.
        case localToLocal
        /// Files uploaded to the server of a shared database.
        case localToShared
        /// Images sent to a DICOM node through the send window.
        case localToNode
        /// Files of a shared database fetched into a local database.
        case sharedToLocal
        /// The server of a shared database asked to send its images on.
        case sharedToRemote
    }

    /// The route of a copy; nil when there is none.
    public static func copyRoute(fromLocalDatabase local: Bool, to destination: CopyDestination?) -> CopyRoute? {
        guard let destination else { return nil }
        switch (local, destination) {
        case (true, .localDatabase): return .localToLocal
        case (true, .sharedDatabase): return .localToShared
        case (true, .dicomNode): return .localToNode
        case (false, .localDatabase): return .sharedToLocal
        case (false, .sharedDatabase), (false, .dicomNode): return .sharedToRemote
        }
    }

    /// Code unit by code unit, as `-isEqualToString:` compares; never for nil.
    private static func literallyEqual(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.utf16.elementsEqual(b.utf16)
    }
}
