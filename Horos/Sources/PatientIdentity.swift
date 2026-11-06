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

/// The key that decides whether two instances belong to the same patient.
///
/// Horos builds it from the patient's name, identifier and date of birth -
/// whichever of the three the preferences say to use - and matches a study on
/// that key together with the Study Instance UID. Two instances of one study
/// whose keys differ therefore become two studies, and that is by design: a
/// differing key can be a genuinely different person.
///
/// It was not always by design. A patient with **no** date of birth had one
/// invented: the missing date became 2001-01-01, and, being formatted in local
/// time, 2000-12-31 anywhere west of UTC. So a study split in two the moment one
/// instance carried the date and another did not, and two machines in different
/// time zones disagreed about which patient an instance belonged to.
@objc(HorosPatientIdentity)
public final class PatientIdentity: NSObject {

    /// Which part of two identifiers differs, for a line that can be acted on.
    ///
    /// "not same patientUID (A versus B)" is true and unhelpful: the reader has
    /// to spot the difference between two long strings and then work out which
    /// tag produced it.
    @objc(differenceBetweenUID:andUID:)
    public class func difference(betweenUID first: String, andUID second: String) -> String {
        if first.compare(second, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
            == .orderedSame {
            return "nothing: the identifiers are the same"
        }
        let left = components(of: first)
        let right = components(of: second)
        guard left.count == 3, right.count == 3 else {
            return "the identifiers are not comparable part by part (\(first) versus \(second))"
        }
        var differences: [String] = []
        for (label, pair) in zip(["name", "patient ID", "date of birth"], zip(left, right))
        where pair.0.caseInsensitiveCompare(pair.1) != .orderedSame {
            differences.append("\(label) \(shown(pair.0)) versus \(shown(pair.1))")
        }
        return differences.isEmpty
            ? "nothing that can be named (\(first) versus \(second))"
            : differences.joined(separator: ", ")
    }

    /// Whether an identifier carries a date of birth in its last part while the
    /// record it belongs to has none — which is the shape the invented date left
    /// behind, and the only thing worth repairing.
    @objc(uidCarriesABirthDate:)
    public class func uidCarriesABirthDate(_ uid: String) -> Bool {
        let parts = components(of: uid)
        guard parts.count == 3 else { return false }
        return !parts[2].isEmpty
    }

    /// The same identifier with the birth date removed - by cutting at the last
    /// separator, so that the joining rule stays in the one place that builds
    /// it. `+[DicomFile patientUID:]` cannot call into here: that file is
    /// compiled into the Decompress helper too, which has no Swift.
    @objc(uidWithoutBirthDate:)
    public class func uidWithoutBirthDate(_ uid: String) -> String {
        guard let separator = uid.range(of: "-", options: .backwards) else { return uid }
        return String(uid[uid.startIndex..<separator.upperBound])
    }

    /// Split into name, identifier and date of birth.
    ///
    /// The name has had its separators replaced before it gets here, so it holds
    /// no hyphen; the identifier can, so the split is anchored at the ends.
    private class func components(of uid: String) -> [String] {
        let pieces = uid.components(separatedBy: "-")
        guard pieces.count >= 3 else { return [] }
        return [pieces[0], pieces[1..<(pieces.count - 1)].joined(separator: "-"), pieces[pieces.count - 1]]
    }

    private class func shown(_ value: String) -> String {
        return value.isEmpty ? "(none)" : "\"\(value)\""
    }
}

/// Evidence for comparing study history without changing the database's patient key.
struct ComparativePatientIdentity: Sendable {
    private let patientID: String
    private let issuer: String?
    private let universalIssuer: String?
    private let name: String
    private let birthDate: Date?

    init?(patientID: String?, issuer: String?, universalIssuer: String?, name: String?, birthDate: Date?) {
        let issuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let patientID, !patientID.isEmpty, issuer?.isEmpty == false || universalIssuer != nil else { return nil }
        self.patientID = patientID
        self.issuer = issuer?.isEmpty == false ? issuer : nil
        self.universalIssuer = universalIssuer
        self.name = name ?? ""
        self.birthDate = birthDate
    }

    func hasDifferentIssuer(from other: ComparativePatientIdentity) -> Bool {
        if let universalIssuer, let otherIssuer = other.universalIssuer {
            return universalIssuer != otherIssuer
        }
        guard let issuer, let otherIssuer = other.issuer else { return false }
        return issuer != otherIssuer
    }

    func corroborates(_ other: ComparativePatientIdentity) -> Bool {
        guard patientID == other.patientID, !hasDifferentIssuer(from: other),
              universalIssuer == other.universalIssuer else { return false }
        let sameBirthDate: Bool
        if let birthDate, let otherDate = other.birthDate {
            sameBirthDate = Calendar(identifier: .gregorian).isDate(birthDate, inSameDayAs: otherDate)
            guard sameBirthDate else { return false }
        } else {
            sameBirthDate = false
        }

        let left = Self.nameComponents(name)
        let right = Self.nameComponents(other.name)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }

        // With a corroborating birth date, only the DICOM middle-name component may differ.
        guard sameBirthDate, left.count >= 2, right.count >= 2,
              !left[0].isEmpty, !left[1].isEmpty else { return false }
        return left[0] == right[0] && left[1] == right[1] &&
            Array(left.dropFirst(3)) == Array(right.dropFirst(3))
    }

    private static func nameComponents(_ name: String) -> [String] {
        guard let alphabetic = name.components(separatedBy: "=").first, !alphabetic.isEmpty else { return [] }
        var components = alphabetic.components(separatedBy: "^").map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ").folding(
                options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        while components.last == "" { components.removeLast() }
        return components
    }
}
