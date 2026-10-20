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

import AppKit
import CryptoKit

/// The series a DICOMweb node's rules left out of a study retrieve, shown as
/// placeholders beside the study's series: greyed, crossed, with their name,
/// date and number of images, and retrieved when clicked.
///
/// They are kept in a file per study under the database's RetrieveManifests
/// folder, not in Core Data: a series without images is deleted from the
/// database, and the viewer and the browser look a study up by its UID, not by
/// the node it came from, as the retrieve manifests are keyed. Each record names
/// its node, so that a click retrieves the series from it, and a placeholder
/// shows only while that node exists and one of its rules still leaves the
/// series out, and while the series is not in the database.
@objc(HorosExcludedSeries)
public final class ExcludedSeries: NSObject {
    public struct Record: Codable, Equatable {
        public var series: String
        /// The DICOMweb node's identifier.
        public var node: String
        public var description: String
        public var rule: String
        public var number: Int? = nil
        public var instances: Int? = nil
        /// Series Date and Time as DICOM writes them (DA, TM).
        public var date: String? = nil
        public var time: String? = nil
        public var modality: String? = nil
        /// An instance of the middle of the series, for /rendered.
        public var middleInstance: String? = nil
        /// The picture's file name, beside the study's file.
        public var thumbnail: String? = nil
    }

    struct File: Codable {
        var version = 1
        var study: String
        var series: [Record]
    }

    /// Posted on the main thread when a study's placeholders or their pictures change; the object is the Study Instance UID.
    @objc public static let didChangeNotification = Notification.Name("HorosExcludedSeriesDidChange")

    @objc public let study: String
    @objc public let database: String
    public let record: Record

    init(study: String, database: String, record: Record) {
        self.study = study
        self.database = database
        self.record = record
    }

    @objc public var seriesInstanceUID: String { record.series }
    @objc public var nodeIdentifier: String { record.node }
    @objc public var seriesDescription: String { record.description }
    @objc public var numberOfImages: Int { record.instances ?? 0 }
    @objc public var middleInstance: String? { record.middleInstance }

    // MARK: Files

    private static let lock = NSLock()

    static func folder(database: String) -> URL {
        URL(fileURLWithPath: database, isDirectory: true)
            .appendingPathComponent("RetrieveManifests", isDirectory: true)
            .appendingPathComponent("ExcludedSeries", isDirectory: true)
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func file(study: String, database: String) -> URL {
        folder(database: database).appendingPathComponent(hash(study) + ".json")
    }

    static func load(study: String, database: String) -> File? {
        guard let data = try? Data(contentsOf: file(study: study, database: database)),
              let file = try? JSONDecoder().decode(File.self, from: data), file.study == study else { return nil }
        return file
    }

    static func save(_ file: File, database: String) {
        let url = self.file(study: file.study, database: database)
        if file.series.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The series one node's rules left out of the study's last retrieve from
    /// it, replacing what that node left out before. Each dictionary holds
    /// `series`, `description` and `rule`, and may hold `number`, `instances`,
    /// `date`, `time`, `modality` and `middleInstance`.
    @objc(recordStudy:node:database:series:)
    public static func record(study: String, node: String, database: String, series: [[String: Any]]) {
        guard !study.isEmpty, !node.isEmpty, !database.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var file = load(study: study, database: database) ?? File(study: study, series: [])
        let previous = file.series.filter { $0.node == node }
        file.series.removeAll { $0.node == node }
        for item in series {
            guard let uid = item["series"] as? String, !uid.isEmpty else { continue }
            var record = Record(series: uid, node: node, description: item["description"] as? String ?? "",
                                rule: item["rule"] as? String ?? "")
            record.number = (item["number"] as? NSNumber)?.intValue
            record.instances = (item["instances"] as? NSNumber)?.intValue
            record.date = (item["date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            record.time = (item["time"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            record.modality = (item["modality"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            record.middleInstance = (item["middleInstance"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            record.thumbnail = previous.first { $0.series == uid }?.thumbnail
            file.series.removeAll { $0.series == uid }
            file.series.append(record)
        }
        for old in previous where !file.series.contains(where: { $0.series == old.series && $0.thumbnail == old.thumbnail }) {
            if let name = old.thumbnail { try? FileManager.default.removeItem(at: folder(database: database).appendingPathComponent(name)) }
        }
        save(file, database: database)
    }

    /// The series of the study, left out by a node, still without a picture.
    @objc(seriesWithoutThumbnailOfStudy:node:database:)
    public static func seriesWithoutThumbnail(study: String, node: String, database: String) -> [ExcludedSeries] {
        lock.lock(); defer { lock.unlock() }
        return (load(study: study, database: database)?.series ?? [])
            .filter { $0.node == node && $0.thumbnail == nil }
            .map { ExcludedSeries(study: study, database: database, record: $0) }
    }

    /// Keeps a picture of a left-out series, as the node sent it.
    @objc(setThumbnail:series:study:database:)
    public static func setThumbnail(_ data: Data, series: String, study: String, database: String) {
        guard NSImage(data: data) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        guard var file = load(study: study, database: database),
              let index = file.series.firstIndex(where: { $0.series == series }) else { return }
        let name = hash(study) + "-" + hash(series).prefix(16) + ".thumbnail"
        let url = folder(database: database).appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) } catch { return }
        file.series[index].thumbnail = name
        save(file, database: database)
    }

    /// Forgets the study's placeholders and their pictures: the study was deleted.
    @objc(forgetStudy:database:)
    public static func forget(study: String, database: String) {
        lock.lock(); defer { lock.unlock() }
        guard let file = load(study: study, database: database) else { return }
        for name in file.series.compactMap(\.thumbnail) {
            try? FileManager.default.removeItem(at: folder(database: database).appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: self.file(study: study, database: database))
    }

    // MARK: Placeholders

    /// The placeholders to show for a study, in series number order: not in
    /// the database (`localSeries`), from a node that still exists, and left
    /// out by one of its rules as they read now.
    @objc(placeholdersOfStudy:database:localSeries:)
    public static func placeholders(study: String, database: String, localSeries: Set<String>) -> [ExcludedSeries] {
        placeholders(study: study, database: database, localSeries: localSeries) { identifier in
            DICOMwebNode.node(withIdentifier: identifier, in: .standard)?.excludedSeries
        }
    }

    /// `rules` gives a node's exclusion rules, nil when there is no such node.
    static func placeholders(study: String, database: String, localSeries: Set<String>,
                             rules: (String) -> [String]?) -> [ExcludedSeries] {
        guard !study.isEmpty, !database.isEmpty else { return [] }
        let records: [Record]
        lock.lock()
        records = load(study: study, database: database)?.series ?? []
        lock.unlock()
        var nodeRules: [String: [String]?] = [:]
        return records.filter { record in
            guard !localSeries.contains(record.series) else { return false }
            if nodeRules[record.node] == nil { nodeRules[record.node] = .some(rules(record.node)) }
            guard let current = nodeRules[record.node] ?? nil else { return false }
            return RetrievePlan.exclusionRule(for: record.description, rules: current) != nil
        }
        .sorted { ($0.number ?? Int.max, $0.description) < ($1.number ?? Int.max, $1.description) }
        .map { ExcludedSeries(study: study, database: database, record: $0) }
    }

    // MARK: Display

    /// "name / date / N images / Click to retrieve"; the study's date when
    /// the series has none.
    @objc(titleWithStudyDate:)
    public func title(studyDate: Date?) -> String {
        var lines = [record.description.isEmpty ? NSLocalizedString("Unnamed", comment: "") : record.description]
        if let date = Self.date(record.date, record.time) ?? studyDate {
            lines.append(UserDefaults.formatDateTime(date) ?? "")
        } else {
            lines.append("")
        }
        if let instances = record.instances, instances > 0 {
            let count = NumberFormatter.localizedString(from: NSNumber(value: instances), number: .decimal)
            lines.append(count + " " + (instances == 1 ? NSLocalizedString("Image", comment: "") : NSLocalizedString("Images", comment: "")))
        } else {
            lines.append("")
        }
        lines.append(NSLocalizedString("Click to retrieve", comment: "A series left out of a retrieve by a DICOMweb node's rule"))
        return lines.joined(separator: "\r")
    }

    static func date(_ date: String?, _ time: String?) -> Date? {
        guard let date, date.count >= 8 else { return nil }
        let digits = date.filter(\.isNumber)
        let clock = (time ?? "").filter(\.isNumber)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if clock.count >= 4 {
            formatter.dateFormat = clock.count >= 6 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
            if let value = formatter.date(from: String(digits.prefix(8)) + String(clock.prefix(clock.count >= 6 ? 6 : 4))) { return value }
        }
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: String(digits.prefix(8)))
    }

    /// The picture: the node's, or a grey frame, greyed and crossed.
    @objc(imageOfSize:)
    public func image(size: NSSize) -> NSImage {
        var picture: NSImage? = nil
        if let name = record.thumbnail,
           let data = try? Data(contentsOf: Self.folder(database: database).appendingPathComponent(name)) {
            picture = NSImage(data: data)
        }
        return NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
            rect.fill()
            if let picture, picture.size.width > 0, picture.size.height > 0 {
                let scale = min(rect.width / picture.size.width, rect.height / picture.size.height)
                let fitted = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
                let frame = NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
                picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 0.35)
            } else {
                NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
                let frame = NSBezierPath(rect: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2))
                frame.lineWidth = 1
                frame.stroke()
            }
            let cross = NSBezierPath()
            let inset = rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.32)
            cross.move(to: NSPoint(x: inset.minX, y: inset.minY)); cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            cross.move(to: NSPoint(x: inset.minX, y: inset.maxY)); cross.line(to: NSPoint(x: inset.maxX, y: inset.minY))
            cross.lineWidth = max(1.5, rect.width / 40)
            cross.lineCapStyle = .round
            NSColor(calibratedWhite: 0.85, alpha: 0.55).setStroke()
            cross.stroke()
            return true
        }
    }

    /// The server dictionary of its node, for a series retrieve; nil when
    /// the node is no longer in Locations.
    @objc public var server: [String: Any]? {
        DICOMwebNode.node(withIdentifier: record.node, in: .standard).map { DICOMwebSources.server(for: $0) }
    }
}
