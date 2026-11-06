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

/// The listener's AE title: how it is checked before the listener starts, and
/// how the title an association calls is compared with it.
public enum ListenerAETitleRules {

    /// The title the listener uses: the stored one without its leading and
    /// trailing spaces, "" when there is none.
    public static func trimmed(_ title: String?) -> String {
        guard let title else { return "" }
        return (title as NSString).trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    /// Why the trimmed title `title` cannot name the listener, nil when it can:
    /// it is empty, or longer than the 16 characters an AE title holds.
    public static func problem(with title: String) -> String? {
        let length = (title as NSString).length
        if length == 0 {
            return "The DICOM listener has no AE title: set one in Preferences > Listener."
        }
        if length > 16 {
            return "The DICOM listener's AE title, \(title), is longer than 16 characters: shorten it in Preferences > Listener."
        }
        return nil
    }

    /// What the listener says after a configuration it cannot start with.
    public static let turnOffAdvice = " If you do not use the DICOM listener, turn it off in Preferences > Listener."

    /// Whether a called AE title names the listener whose AE title is
    /// `configured`. Leading and trailing spaces are not significant in an AE
    /// title, while case and the spaces inside it are; the bytes are compared
    /// as they are. An empty configured title matches nothing.
    public static func matches(called: [UInt8], configured: [UInt8]) -> Bool {
        let ours = trimmedBytes(configured)
        return !ours.isEmpty && trimmedBytes(called) == ours
    }

    private static func trimmedBytes(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        let space = UInt8(ascii: " ")
        guard let first = bytes.firstIndex(where: { $0 != space }),
              let last = bytes.lastIndex(where: { $0 != space }) else { return [] }
        return bytes[first...last]
    }
}

/// How long the listener waits, and how many associations it serves at once.
public enum ListenerLimits {

    /// The ACSE and DIMSE timeout: the DICOMTimeout preference, at least 2 s.
    public static func timeout(configured: Int) -> Int {
        max(configured, 2)
    }

    /// The time a peer has to connect: DICOMConnectionTimeout when positive,
    /// the timeout otherwise.
    public static func connectionTimeout(configured: Int, timeout: Int) -> Int {
        configured > 0 ? configured : timeout
    }

    /// The associations served at once: the
    /// maximumNumberOfConcurrentDICOMAssociations preference when positive, 8
    /// otherwise. Past it an association is rejected as a transient local limit.
    public static func maximumAssociations(configured: Int) -> Int {
        configured > 0 ? configured : 8
    }

    /// Whether another association may start while `active` are served.
    public static func admits(active: Int, maximum: Int, stopping: Bool) -> Bool {
        !stopping && active < maximum
    }

    /// The connections that may wait for their association request at once,
    /// each on a thread of its own; past it a new connection is closed.
    public static let maximumUnreadConnections = 64

    /// The associations DCMTK's configuration allows.
    public static let configuredMaximumAssociations = 800
}

/// The DIMSE commands the listener receives.
public enum ListenerCommand: Int, Sendable {
    case echo, store, find, move, get

    /// The name its activity and its log give it.
    public var name: String {
        switch self {
        case .echo: return "C-ECHO"
        case .store: return "C-STORE"
        case .find: return "C-FIND"
        case .move: return "C-MOVE"
        case .get: return "C-GET"
        }
    }
}

/// What the listener accepts: the services it negotiates and the commands it
/// answers.
public enum ListenerAcceptance {

    /// The query/retrieve services offered, in this order: Verification, then
    /// the Study Root model's C-FIND, C-MOVE and C-GET. The Patient Root and
    /// Patient/Study Only models are not offered.
    public static let services: [String] = [
        QueryRetrieveService.verification.rawValue,
        QueryRetrieveService.findStudyRoot.rawValue,
        QueryRetrieveService.moveStudyRoot.rawValue,
        QueryRetrieveService.getStudyRoot.rawValue,
    ]

    /// Whether a command is answered: C-GET only when the "activateCGETSCP"
    /// preference is on and C-FIND only when "activateCFINDSCP" is; the
    /// others always. One that is not answered ends the association.
    public static func answers(_ command: ListenerCommand, findEnabled: Bool, getEnabled: Bool) -> Bool {
        switch command {
        case .get: return getEnabled
        case .find: return findEnabled
        case .echo, .store, .move: return true
        }
    }
}

/// Where the listener sends what a C-MOVE asks for.
public enum MoveDestinationRule {

    /// The index of the node the move destination `title` names: the first
    /// whose AE title is `title`, or, when none is, the first whose name is.
    /// Titles and names are compared as Foundation strings compare them
    /// (code unit by code unit).
    public static func index(of title: String, aeTitles: [Any?], names: [Any?]) -> Int? {
        func equal(_ value: Any?) -> Bool { (value as? NSObject)?.isEqual(title as NSString) == true }
        if let found = aeTitles.firstIndex(where: equal) { return found }
        return names.firstIndex(where: equal)
    }
}

/// What the network log says of an association the listener served.
public enum ListenerLogRules {

    /// Who a retrieve is for: the caller, followed by the move destination when
    /// one is named and is not the caller ("CALLER / DESTINATION").
    public static func retrieveParties(callingAETitle: String?, moveDestination: [UInt8]) -> String {
        let caller = callingAETitle ?? "(null)"
        let callerBytes = Array((callingAETitle ?? "").utf8)
        if moveDestination.isEmpty || moveDestination == callerBytes { return caller }
        let destination = String(decoding: moveDestination, as: UTF8.self)
        return "\(caller) / \(destination)"
    }

    /// The character set a received instance's log entry reads its names in:
    /// its Specific Character Set, or ISO_IR 100 when it has none. Each value
    /// separated by a backslash is one character set; past nine, none is used.
    public static func receivedCharacterSets(_ specificCharacterSet: String?) -> [String] {
        let declared = specificCharacterSet ?? "ISO_IR 100"
        let parts = declared.components(separatedBy: "\\")
        return parts.count < 10 ? parts : []
    }

    /// The bytes of a sender's value the log keeps: at most 1023.
    public static func bounded(_ value: [UInt8]?) -> [UInt8] {
        Array((value ?? []).prefix(1023))
    }

    /// The study description of a received instance's log entry: the study's,
    /// followed by the series' after a space when it has one, at most 1023
    /// bytes in all.
    public static func receivedDescription(study: [UInt8]?, series: [UInt8]?) -> [UInt8] {
        var text = study ?? []
        if let series {
            text.append(UInt8(ascii: " "))
            text.append(contentsOf: series)
        }
        return bounded(text)
    }
}
