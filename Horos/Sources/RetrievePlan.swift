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

/// The order a node's series are asked for in.
@objc(HorosRetrieveOrder)
public enum RetrieveOrder: Int, CaseIterable {
    /// As the node lists them; a study is asked for in one request.
    case asListed = 0
    /// By series number, then series UID.
    case seriesNumber = 1
    /// Fewest instances first, from the count the node gives for each series:
    /// an estimate of size, since an instance may hold one frame or many and
    /// its bytes are not known before its pixels.
    case fewestInstances = 2
}

/// The order of one retrieve's series: a series the operator chose goes
/// first, then the others in the node's order. Only the order in which
/// requests start is planned; they may end in another.
///
/// Every series stays in the plan, so none waits forever. A series with no
/// number or count goes after those that have one; equal keys keep the
/// series number, then the series UID, so the order is the same on every run.
/// A new priority applies to what has not started yet: nothing received is
/// asked for again.
///
/// @unchecked Sendable: `series`, `order` and `priority` are read and written
/// only under `lock`; the retrieve's request threads read the ranks while the
/// operator's choice may change the priority.
@objc(HorosRetrievePlan)
public final class RetrievePlan: NSObject, @unchecked Sendable {
    public struct Series: Equatable {
        public let uid: String
        public let number: Int?
        public let instances: Int?
        public var description: String? = nil
    }

    private let lock = NSLock()
    private var series: [Series] = []
    private let order: RetrieveOrder
    private var priority: String?
    /// The node's exclusion rules, empty when it has none or the operation ignores them.
    private var rules: [String] = []
    /// The series a rule excludes: their description and that rule.
    private var excluded: [String: (description: String, rule: String)] = [:]
    /// Changes each time the priority does, so a request pool knows to look again.
    @objc public private(set) var revision = 0

    @objc public init(order: RetrieveOrder) {
        self.order = order
        super.init()
    }

    @objc public var retrieveOrder: RetrieveOrder { order }

    /// Excludes, from now on, each series whose description contains one of
    /// `rules` (`exclusionRule(for:rules:)`).
    @objc(excludeSeriesMatching:)
    public func exclude(matching rules: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.rules = Self.validRules(rules)
    }

    @objc public var hasExclusionRules: Bool { lock.lock(); defer { lock.unlock() }; return !rules.isEmpty }

    /// Adds a series with what the node said of it: its number and instance
    /// count, nil when not given.
    @objc(addSeries:number:instances:)
    public func add(series uid: String, number: NSNumber?, instances: NSNumber?) {
        add(series: uid, number: number, instances: instances, description: nil)
    }

    /// Adds a series with its description too: a series a rule matches is
    /// left out of the plan, and one without a description is kept.
    @objc(addSeries:number:instances:description:)
    public func add(series uid: String, number: NSNumber?, instances: NSNumber?, description: String?) {
        guard !uid.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !series.contains(where: { $0.uid == uid }) else { return }
        series.append(Series(uid: uid, number: number?.intValue, instances: instances?.intValue, description: description))
        if let description, let rule = Self.exclusionRule(for: description, rules: rules) {
            excluded[uid] = (description, rule)
        }
    }

    /// Whether a rule leaves this series out.
    @objc(isExcludedSeries:)
    public func isExcluded(series uid: String) -> Bool { lock.lock(); defer { lock.unlock() }; return excluded[uid] != nil }

    /// The series left out, by UID: their description and the rule, as
    /// `[description, rule]`.
    @objc public var excludedSeries: [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        return excluded.mapValues { [$0.description, $0.rule] }
    }

    /// Whether every series listed is left out: nothing is to be asked for.
    @objc public var excludesEverything: Bool {
        lock.lock(); defer { lock.unlock() }
        return !series.isEmpty && series.allSatisfy { excluded[$0.uid] != nil }
    }

    /// Whether the node's series have been listed: until then a plan that
    /// controls the order has nothing to order.
    @objc public private(set) var seriesListed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return listed }
        set { lock.lock(); listed = newValue; lock.unlock() }
    }
    private var listed = false

    @objc public func markSeriesListed() { seriesListed = true }

    /// Whether this plan asks for each series on its own instead of the study
    /// in one request: when the order is not the node's own, or a rule may
    /// leave a series out.
    @objc public var controlsSeries: Bool { order != .asListed || hasExclusionRules }

    /// Whether the study can still be asked for in one request once its series
    /// are known: the node's own order, and no series left out.
    @objc public var wholeStudySuffices: Bool {
        lock.lock(); defer { lock.unlock() }
        return order == .asListed && excluded.isEmpty
    }

    /// Puts `uid` first among what has not started.
    @objc(prioritizeSeries:)
    public func prioritize(series uid: String) {
        lock.lock(); defer { lock.unlock() }
        guard priority != uid else { return }
        priority = uid
        revision += 1
    }

    @objc public var prioritySeries: String? { lock.lock(); defer { lock.unlock() }; return priority }

    /// The series asked for, in the order their requests start: those a rule
    /// excludes are not.
    @objc public var orderedSeries: [String] {
        lock.lock(); defer { lock.unlock() }
        return Self.ordered(series.filter { excluded[$0.uid] == nil }, order: order, priority: priority).map(\.uid)
    }

    /// The place of a series in that order; a series not in the plan goes last.
    @objc(rankOfSeries:)
    public func rank(of uid: String) -> Int {
        let ordered = orderedSeries
        return ordered.firstIndex(of: uid) ?? ordered.count
    }

    /// Whether the order is an estimate of size from instance counts.
    @objc public var isEstimate: Bool { order == .fewestInstances }

    static func ordered(_ series: [Series], order: RetrieveOrder, priority: String?) -> [Series] {
        let listed = Array(series.enumerated())
        func tie(_ a: (offset: Int, element: Series), _ b: (offset: Int, element: Series)) -> Bool {
            switch (a.element.number, b.element.number) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.element.uid != b.element.uid ? a.element.uid < b.element.uid : a.offset < b.offset
            }
        }
        var sorted: [(offset: Int, element: Series)]
        switch order {
        case .asListed:
            sorted = listed
        case .seriesNumber:
            sorted = listed.sorted(by: tie)
        case .fewestInstances:
            sorted = listed.sorted { a, b in
                switch (a.element.instances, b.element.instances) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return tie(a, b)
                }
            }
        }
        if let priority, let index = sorted.firstIndex(where: { $0.element.uid == priority }) {
            sorted.insert(sorted.remove(at: index), at: 0)
        }
        return sorted.map(\.element)
    }

    // MARK: Running operations

    nonisolated(unsafe) private static var active: [String: RetrievePlan] = [:]
    private static let activeLock = NSLock()

    private static func key(endpoint: String, study: String) -> String { endpoint + "\n" + study }

    /// Makes the plan the one an operation on `study` from `endpoint` follows,
    /// until `end`.
    @objc(beginForEndpoint:study:)
    public func begin(endpoint: String, study: String) {
        Self.activeLock.lock(); Self.active[Self.key(endpoint: endpoint, study: study)] = self; Self.activeLock.unlock()
    }

    @objc(endForEndpoint:study:)
    public func end(endpoint: String, study: String) {
        Self.activeLock.lock()
        if Self.active[Self.key(endpoint: endpoint, study: study)] === self { Self.active[Self.key(endpoint: endpoint, study: study)] = nil }
        Self.activeLock.unlock()
    }

    /// Asks a retrieve of `study` from `endpoint` that is running to take
    /// `series` next. Returns whether one was: the series then comes with it,
    /// instead of in a second retrieve of the same instances.
    @objc(prioritizeSeries:ofStudy:endpoint:)
    public static func prioritize(series: String, study: String, endpoint: String) -> Bool {
        activeLock.lock()
        let plan = active[key(endpoint: endpoint, study: study)]
        activeLock.unlock()
        // A series the running retrieve leaves out is retrieved on its own: asked
        // for explicitly, past the node's rules.
        guard let plan, !plan.isExcluded(series: series) else { return false }
        plan.prioritize(series: series)
        return true
    }

    /// The URLs, stably in the order of their series (a WADO-URI `seriesUID`
    /// parameter); a URL without one keeps its place before the others.
    @objc(orderURLs:)
    public func order(urls: [URL]) -> [URL] {
        let ordered = orderedSeries
        var rank: [String: Int] = [:]
        for (index, uid) in ordered.enumerated() { rank[uid] = index }
        return urls.enumerated().sorted { a, b in
            let x = Self.seriesUID(of: a.element).map { rank[$0] ?? ordered.count } ?? -1
            let y = Self.seriesUID(of: b.element).map { rank[$0] ?? ordered.count } ?? -1
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    static func seriesUID(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "seriesUID" }?.value
    }

    /// The URLs not of a series a rule excludes.
    @objc(eligibleURLs:)
    public func eligible(urls: [URL]) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls.filter { url in Self.seriesUID(of: url).map { excluded[$0] == nil } ?? true }
    }

    /// Keeps the first of each URL, in order: a request list deduplicated
    /// without losing the plan's order.
    @objc(uniqueURLs:)
    public static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    // MARK: Node setting

    /// The keys of a node's order: a DICOMweb node's in `DICOMWEB_SERVERS`, a
    /// WADO-URI node's in `SERVERS`.
    @objc public static let dicomwebKey = "SeriesOrder"
    @objc public static let wadoKey = "WADOSeriesOrder"

    /// A stored order, or "as listed" for anything else.
    @objc(orderForStoredValue:)
    public static func order(forStoredValue value: Any?) -> RetrieveOrder {
        let raw = (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) } ?? 0
        return RetrieveOrder(rawValue: raw) ?? .asListed
    }

    /// The titles of the orders, as the Locations pane offers them.
    @objc public static var orderTitles: [String] {
        [NSLocalizedString("As Listed", comment: "series retrieve order"),
         NSLocalizedString("Series Number", comment: "series retrieve order"),
         NSLocalizedString("Fewest Instances First (estimate)", comment: "series retrieve order")]
    }

    // MARK: Exclusion rules

    /// The keys of a node's rules: a DICOMweb node's in `DICOMWEB_SERVERS`, a
    /// WADO-URI node's in `SERVERS`.
    @objc public static let dicomwebExclusionKey = "ExcludeSeries"
    @objc public static let wadoExclusionKey = "WADOExcludeSeries"

    /// The rule that leaves out a series with this description, if any: the
    /// first rule found in it as a literal substring, whatever the case and
    /// accents of either. Nothing is read into it: "sagittal" does not find
    /// "sagital", nor "scout" a series called "localizer".
    @objc(exclusionRuleForDescription:rules:)
    public static func exclusionRule(for description: String, rules: [String]) -> String? {
        guard !description.isEmpty else { return nil }
        return validRules(rules).first { description.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Rules trimmed, without empty ones or repeats, in order.
    static func validRules(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        return rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted }
    }

    /// Stored rules: a list, or text with one rule per comma or line.
    @objc(exclusionRulesForStoredValue:)
    public static func exclusionRules(forStoredValue value: Any?) -> [String] {
        if let list = value as? [Any] { return validRules(list.compactMap { $0 as? String }) }
        if let text = value as? String { return validRules(text.components(separatedBy: CharacterSet(charactersIn: ",\n"))) }
        return []
    }

    /// Rules as the editors show them.
    @objc(textForExclusionRules:)
    public static func text(forExclusionRules rules: [String]) -> String { validRules(rules).joined(separator: ", ") }

    @objc public static var exclusionHelp: String {
        NSLocalizedString("Series whose description contains one of these words or phrases, separated by commas, are not retrieved from this node, for example: scout, localizer, coronal. Case and accents are ignored; a series without a description is retrieved. Applies to WADO-RS and WADO-URI, not to C-MOVE or C-GET. Retrieve a series by itself, or hold Option while retrieving, to include it.", comment: "series exclusion rules")
    }

    @objc public static var orderHelp: String {
        NSLocalizedString("The order this node's series are asked for in. As Listed asks for a study in one request. Fewest Instances First estimates size from the number of instances, not bytes or frames. A series chosen during a retrieve goes first.", comment: "series retrieve order")
    }
}
