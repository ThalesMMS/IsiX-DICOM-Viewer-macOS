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
import Testing
@testable import IsiXDICOMNetwork

// MARK: Rules as the preference pane writes them

/// The three shapes a rule has in `AUTOROUTINGDICTIONARY`: the new route the
/// pane adds (numbers as text), the route its sheet saves (numbers, Booleans,
/// the date picker's strings), and a rule of an earlier version without the
/// keys the pane adds when it opens.
private func paneRules() -> [[String: Any]] {
    let added: [String: Any] = [
        "name": "new route", "description": "", "filter": "(series.study.modality contains[c] \"CT\")",
        "server": "PACS", "failureRetry": "20", "filterType": "0", "imagesOnly": false, "scheduleType": "0",
        "delayTime": "2", "fromTime": "21:00", "toTime": "06:00",
    ]
    let saved: [String: Any] = [
        "name": "nightly", "activated": true, "description": "CT at night", "filter": "", "server": "ARCHIVE",
        "previousStudies": NSNumber(value: Int32(2)), "previousModality": true, "previousDescription": false,
        "failureRetry": NSNumber(value: Int32(5)), "cfindTest": true, "filterType": NSNumber(value: Int32(1)),
        "scheduleType": NSNumber(value: Int32(2)), "delayTime": 3,
        "fromTime": "Thursday, January 1, 1970 at 9:00:00 PM Coordinated Universal Time",
        "toTime": "Thursday, January 1, 1970 at 6:00:00 AM Coordinated Universal Time",
        "imagesOnly": NSNumber(value: Int32(1)), "version": NSNumber(value: Int32(1)),
    ]
    let earlier: [String: Any] = [
        "name": "old", "filter": "modality == \"MR\"", "server": "PACS", "filterType": 2,
        "fromTime": Date(timeIntervalSince1970: 75600),
    ]
    return [added, saved, earlier]
}

/// Equal as the preferences store them: the same keys, values and kinds
/// (a Boolean is not the number 1).
private func sameStored(_ left: Any, _ right: Any) -> Bool {
    switch (left, right) {
    case let (l as [String: Any], r as [String: Any]):
        return Set(l.keys) == Set(r.keys) && l.allSatisfy { key, value in sameStored(value, r[key]!) }
    case let (l as [Any], r as [Any]):
        return l.count == r.count && zip(l, r).allSatisfy(sameStored)
    case let (l as NSNumber, r as NSNumber):
        let lb = CFGetTypeID(l) == CFBooleanGetTypeID(), rb = CFGetTypeID(r) == CFBooleanGetTypeID()
        return lb == rb && CFNumberIsFloatType(l) == CFNumberIsFloatType(r) && l == r
    case let (l as String, r as String):
        return l == r
    case let (l as Date, r as Date):
        return l == r
    default:
        return false
    }
}

@Suite struct RoutingRuleTests {
    @Test func everyRuleOfThePaneComesBackAsItWasStored() throws {
        let stored = paneRules()
        let rules = RoutingRule.rules(fromPropertyList: stored)
        #expect(rules.count == 3)
        #expect(sameStored(rules.map(\.propertyList), stored))

        // Encoded, the rules are the property list the preference holds.
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = format
            let data = try encoder.encode(rules)
            let read = try PropertyListSerialization.propertyList(from: data, format: nil)
            #expect(sameStored(read, stored))
            let fromStored = try PropertyListSerialization.data(fromPropertyList: stored, format: format, options: 0)
            #expect(try PropertyListDecoder().decode([RoutingRule].self, from: fromStored) == rules)
        }
    }

    @Test func anEntryThatIsNotARuleIsLeftOut() {
        #expect(RoutingRule.rules(fromPropertyList: ["text", ["name": "kept"], 3]).map(\.name) == ["kept"])
        #expect(RoutingRule.rules(fromPropertyList: nil).isEmpty)
    }

    @Test func theSettingsReadAsTheRoutingReadThem() throws {
        let rules = RoutingRule.rules(fromPropertyList: paneRules())
        let added = rules[0], saved = rules[1], earlier = rules[2]
        #expect(added.failureRetry == 20 && added.filterType == 0 && added.delayTime == 2 && added.scheduleType == 0)
        #expect(added.isActivated && !added.imagesOnly && added.version == 0)
        #expect(added.effectiveFilter == "(series.study.modality contains[c] \"CT\")")
        #expect(saved.imagesOnly && saved.cfindTest && saved.previousModality && !saved.previousDescription)
        #expect(saved.previousStudies == 2 && saved.scheduleType == 2 && saved.destinationName == "ARCHIVE")
        // A rule of an earlier version with a filter type had its filter hidden.
        #expect(earlier.effectiveFilter == "")
        #expect(earlier.filterType == 2)

        func activated(_ value: Any?) -> Bool {
            var entry: [String: Any] = ["name": "r"]
            entry["activated"] = value
            return RoutingRule(propertyList: entry)!.isActivated
        }
        #expect(activated(nil) && activated(true) && activated("1") && activated("yes") && activated(2))
        #expect(!activated(false) && !activated("0") && !activated("") && !activated("no") && !activated(0))
        #expect(RoutingRule(propertyList: ["scheduleType": " 1"])!.scheduleType == 0)
        #expect(RoutingRule(propertyList: ["failureRetry": " 7x"])!.failureRetry == 7)
    }
}

@Suite struct RoutingScheduleTests {
    @Test func eachActivatedRuleIsInExactlyOneList() {
        let rules = RoutingRule.rules(fromPropertyList: [
            ["name": "plain"],
            ["name": "off", "activated": false],
            ["name": "on", "activated": true, "scheduleType": 0],
            ["name": "delayed", "activated": true, "scheduleType": 1, "delayTime": 2],
            ["name": "window", "activated": true, "scheduleType": 2, "fromTime": "08:00", "toTime": "18:00"],
            ["name": "windowless", "activated": true, "scheduleType": 2],
            ["name": "unknown", "activated": true, "scheduleType": 9],
            ["name": "offString", "activated": "0"],
        ] as [Any])
        #expect(RoutingSchedule.immediateRules(in: rules).map(\.name) == ["plain", "on", "windowless", "unknown"])
        #expect(RoutingSchedule.scheduledRules(in: rules).map(\.name) == ["delayed", "window"])
    }

    @Test func theDelaysOfTheSchedules() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: hour, minute: minute))!
        }
        func window(_ from: String, _ to: String, _ now: Date) -> RoutingSchedule.Delay {
            RoutingSchedule.delay(for: RoutingRule(propertyList: ["scheduleType": 2, "fromTime": from, "toTime": to])!,
                                  at: now, calendar: calendar)
        }
        #expect(RoutingSchedule.delay(for: RoutingRule(propertyList: ["scheduleType": "1", "delayTime": "2"])!,
                                      at: at(12), calendar: calendar).seconds == 7200)
        #expect(window("08:00", "10:00", at(7)).seconds == 3600)
        #expect(window("08:00", "10:00", at(9)).seconds == 0)
        #expect(window("08:00", "10:00", at(12)).seconds == 72000)
        #expect(window("21:00", "06:00", at(23)).seconds == 0)
        #expect(window("21:00", "06:00", at(1)).seconds == 0)
        #expect(window("21:00", "06:00", at(12)).seconds == 32400)
        let unreadable = window("soon", "later", at(12))
        #expect(unreadable.seconds == 0 && unreadable.windowIsUnreadable)
        let dated = RoutingRule(entry: ["scheduleType": .integer(2), "fromTime": .date(at(21)), "toTime": .date(at(6))])
        #expect(RoutingSchedule.windowDelay(for: dated, at: at(12), calendar: calendar) == 32400)
    }
}

// MARK: Destinations

private func node(_ name: String, _ port: Any, activated: Any? = nil, aet: String? = nil) -> DICOMNode {
    var entry: [String: Any] = ["Description": name, "AETitle": aet ?? "AE\(port)", "Address": "127.0.0.1", "Port": port]
    entry["Activated"] = activated
    return DICOMNode(propertyList: entry)!
}

@Suite struct RoutingDestinationTests {
    @Test func aRuleResolvesToExactlyOneActivatedNodeOrSaysWhy() {
        let good = RoutingDestination.resolve(named: "PACS", in: [node("PACS", "104"), node("ARCHIVE", "105")], ruleName: "nightly")
        #expect(good.isResolved && good.node?.aeTitle == "AE104" && good.problem == nil)

        let two = RoutingDestination.resolve(named: "PACS", in: [node("PACS", "104"), node("PACS", 11112)], ruleName: "nightly")
        #expect(!two.isResolved && two.isPermanent)
        #expect(two.problem?.contains("2 DICOM nodes are called that: AE104@127.0.0.1:104, AE11112@127.0.0.1:11112") == true)

        let missing = RoutingDestination.resolve(named: "PACS", in: [node("ARCHIVE", "105")], ruleName: "nightly")
        #expect(missing.problem?.contains("there is no DICOM node of that name") == true)
        #expect(missing.problem?.contains("\"nightly\"") == true)

        let off = RoutingDestination.resolve(named: "PACS", in: [node("PACS", "104", activated: false)], ruleName: nil)
        #expect(off.problem?.contains("exists but is not activated") == true)
        #expect(RoutingDestination.resolve(named: "", in: [], ruleName: nil).problem == "A routing rule names no destination.")
        #expect(RoutingDestination.resolve(named: "PACS", in: [node("PACS", "104", activated: "1")], ruleName: nil).isResolved)
    }

    @Test func theCFindNodeIsTheFirstActivatedOneOfThatName() {
        let nodes = [node("PACS", "1"), node("PACS", "2", activated: false), node("PACS", "3", activated: true),
                     node("PACS", "4", activated: true)]
        // A node without the key is not one for the C-FIND, as before.
        #expect(RoutingDestination.firstActivatedNode(named: "PACS", in: nodes)?.aeTitle == "AE3")
        #expect(RoutingDestination.firstActivatedNode(named: nil, in: nodes) == nil)
    }

    @Test func aProblemIsReportedOnceUntilItIsFixed() {
        var gate = RoutingProblemGate()
        var answers: [Bool] = []
        answers.append(gate.suspend(rule: "nightly", because: "gone"))
        answers.append(gate.suspend(rule: "nightly", because: "gone"))
        answers.append(gate.suspend(rule: "nightly", because: "ambiguous"))
        #expect(answers == [true, false, true])
        #expect(gate.problem(forRule: "nightly") == "ambiguous")
        gate.resume(rule: "nightly")
        #expect(gate.problem(forRule: "nightly") == nil)

        let down = "PACSB@127.0.0.1:11182"
        answers = []
        answers.append(gate.shouldReport(problem: "refused", forDestination: down))
        answers.append(gate.shouldReport(problem: "refused", forDestination: down))
        answers.append(gate.shouldReport(problem: "timed out", forDestination: down))
        answers.append(gate.shouldReport(problem: "refused", forDestination: "PACSA@127.0.0.1:11181"))
        gate.clearProblems(forDestination: down)
        answers.append(gate.shouldReport(problem: "refused", forDestination: down))
        #expect(answers == [true, false, true, true, true])
        // A rule's name cannot silence a destination that shares it.
        gate.resumeAll()
        gate.suspend(rule: down, because: "refused")
        let reported = gate.shouldReport(problem: "refused", forDestination: down)
        #expect(reported)
    }
}

// MARK: Earlier studies

@Suite struct PreviousRoutingStudiesTests {
    let now = Date(timeIntervalSince1970: 200_000)

    func study(_ modality: String = "CT", _ name: String = "CURRENT", _ seconds: Double = -1) -> RoutedStudy {
        RoutedStudy(id: "s", studyName: name, modality: modality, date: now.addingTimeInterval(seconds))
    }

    @Test func anEarlierStudyMatchesAsTheRuleAsks() {
        let current = RoutedStudy(id: "c", studyName: "CURRENT", modality: "CT\\MR", date: now)
        func check(_ prior: RoutedStudy, _ modality: Bool, _ description: Bool) -> Bool {
            PreviousRoutingStudies.matches(prior, currentStudy: current, modality: modality, description: description)
        }
        #expect(check(study(), true, true))
        #expect(check(study("US", "OTHER"), false, false))
        #expect(!check(study("US"), true, false))
        #expect(!check(study("CT", "OTHER"), false, true))
        #expect(!check(study("CT", "CURRENT", 0), false, false))
        #expect(!check(RoutedStudy(id: "x"), false, false))
        #expect(!check(study("", ""), true, true))
    }

    @Test func aStudyIsQueuedForANodeOnceInThreeHours() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = DICOMNode(propertyList: ["Address": "localhost", "Port": 11330, "AETitle": "ONE"])!
        func reserve(_ uid: String, _ time: Date, _ node: DICOMNode) -> Bool {
            PreviousRoutingStudies.reserve(study: uid, node: node, databasePath: folder.path, now: time)
        }
        #expect(reserve("study", now, one))
        #expect(!reserve("study", now, one))
        #expect(!reserve("study", now.addingTimeInterval(10_799), one))
        #expect(reserve("study", now.addingTimeInterval(10_800), one))
        #expect(reserve("study", now, DICOMNode(propertyList: ["Address": "localhost", "Port": "11331", "AETitle": "ONE"])!))
        #expect(!reserve("study", now, DICOMNode(propertyList: ["Address": "LOCALHOST", "Port": 11331, "AETitle": "ONE"])!))
        #expect(!reserve("x", now, DICOMNode(propertyList: ["Address": "localhost", "Port": "0", "AETitle": "ONE"])!))
        #expect(!PreviousRoutingStudies.reserve(study: "x", node: one, databasePath: folder.path + "/absent", now: now))
    }
}

// MARK: Selection, with a stand-in of the database

private func file(_ id: String, study: RoutedStudy, image: Bool = true, generated: Bool = false,
                  imported: Bool = false, path: String? = nil) -> RoutedFile {
    RoutedFile(id: id, path: path ?? "/db/\(id).dcm", study: study, isImageStorage: image,
               isGeneratedByApp: generated, isImported: imported)
}

/// The database: filters are "ALL", "NONE", "BAD" (cannot be read) or a
/// modality that the file's study must have.
final class StandInCatalog: RoutingCatalog {
    var studies: [RoutedStudy] = []
    var filesOfStudy: [String: [RoutedFile]] = [:]
    var counts: [String: Int32] = [:]
    var remote: [String: [Int32]] = [:]
    var asked: [String] = []

    func files(_ files: [RoutedFile], matchingFilter filter: String) throws -> [RoutedFile] {
        switch filter {
        case "", "ALL": return files
        case "NONE": return []
        case "BAD": throw RoutingSelectionError("syntax")
        default: return files.filter { $0.study.modality == filter }
        }
    }

    func studies(ofPatientUID patientUID: String) throws -> [RoutedStudy] {
        studies.filter { $0.patientUID == patientUID }
    }

    func files(of study: RoutedStudy) throws -> [RoutedFile] {
        filesOfStudy[study.id] ?? []
    }

    func fileCount(ofStudyOf file: RoutedFile) throws -> Int32 {
        counts[file.study.id] ?? 0
    }

    func remoteImageCounts(ofStudyInstanceUID studyInstanceUID: String, on node: DICOMNode) throws -> [Int32] {
        asked.append("\(studyInstanceUID)@\(node.aeTitle ?? "")")
        return remote[studyInstanceUID] ?? []
    }
}

@Suite struct RoutingSelectionTests {
    let ct = RoutedStudy(id: "ct", studyInstanceUID: "1.1", patientID: "P1", patientUID: "U1", patientName: "Alpha",
                         studyName: "CHEST", modality: "CT", date: Date(timeIntervalSince1970: 1_000_000))
    let mr = RoutedStudy(id: "mr", studyInstanceUID: "1.2", patientID: "P2", patientUID: "U2", patientName: "Beta",
                         studyName: "HEAD", modality: "MR", date: Date(timeIntervalSince1970: 1_000_000))
    let nodes = [node("PACS", "11112"), node("ARCHIVE", 104, activated: true)]

    func rule(_ entry: [String: Any]) -> RoutingRule {
        var base: [String: Any] = ["name": "r", "server": "PACS", "version": 1]
        base.merge(entry) { $1 }
        return RoutingRule(propertyList: base)!
    }

    @Test func filtersFilterTypesAndImagesOnly() {
        let files = [file("a", study: ct), file("b", study: ct, image: false, generated: true),
                     file("c", study: mr, imported: true), file("d", study: mr, generated: true, imported: true)]
        let catalog = StandInCatalog()
        func ids(_ entry: [String: Any]) -> [String] {
            guard let picked = try? RoutingSelection.files(for: rule(entry), of: files, nodes: nodes, databasePath: "",
                                                           catalog: catalog) else { return ["failed"] }
            return picked.map(\.id)
        }
        #expect(ids(["filter": "ALL"]) == ["a", "b", "c", "d"])
        #expect(ids(["filter": "CT"]) == ["a", "b"])
        #expect(ids(["filter": "ALL", "imagesOnly": true]) == ["a", "c", "d"])
        #expect(ids(["filter": "ALL", "filterType": 1]) == ["b", "d"])
        #expect(ids(["filter": "MR", "filterType": "2"]) == ["c", "d"])
        // Before version 1, a filter type hid the filter.
        #expect(ids(["filter": "NONE", "filterType": 2, "version": 0]) == ["c", "d"])
        #expect(ids(["filter": "BAD"]) == ["failed"])
        #expect(ids(["filter": "NONE", "previousStudies": 2, "cfindTest": true]).isEmpty)
    }

    @Test func eachRuleAppliedOnceAndOnlyWhatMatchedIsPicked() {
        let files = [file("a", study: ct), file("c", study: mr)]
        let rules = [rule(["name": "ct", "filter": "CT"]), rule(["name": "off", "filter": "ALL", "activated": false]),
                     rule(["name": "none", "filter": "NONE"]), rule(["name": "bad", "filter": "BAD"]),
                     rule(["name": "all", "filter": "ALL", "server": "ARCHIVE"])]
        let picks = RoutingSelection.apply(rules, to: files, nodes: nodes, databasePath: "", catalog: StandInCatalog())
        #expect(picks.map(\.rule.name) == ["ct", "all"])
        #expect(picks.map { $0.files.map(\.id) } == [["a"], ["a", "c"]])
    }

    @Test func earlierStudiesOfThePatientGoWithTheirOwnBudget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func prior(_ id: String, days: Double, _ modality: String = "CT") -> RoutedStudy {
            RoutedStudy(id: id, studyInstanceUID: "9.\(id)", patientID: "P1", patientUID: "U1", studyName: "CHEST",
                        modality: modality, date: ct.date!.addingTimeInterval(-days * 86_400))
        }
        let catalog = StandInCatalog()
        let older = prior("older", days: 30), recent = prior("recent", days: 2), mri = prior("mri", days: 1, "MR"),
            sameDay = RoutedStudy(id: "same", studyInstanceUID: "9.same", patientUID: "U1", modality: "CT", date: ct.date)
        catalog.studies = [older, ct, recent, mri, sameDay]
        for study in catalog.studies {
            catalog.filesOfStudy[study.id] = [file("\(study.id)-1", study: study), file("\(study.id)-2", study: study, image: false)]
        }
        let current = [file("a", study: ct)]
        func ids(_ entry: [String: Any]) throws -> [String] {
            try RoutingSelection.files(for: rule(entry), of: current, nodes: nodes, databasePath: folder.path,
                                       catalog: catalog).map(\.id)
        }
        // The most recent earlier CT, with all its files; then not again within three hours.
        #expect(try ids(["filter": "ALL", "previousStudies": 1, "previousModality": true]) == ["a", "recent-1", "recent-2"])
        #expect(try ids(["filter": "ALL", "previousStudies": 1, "previousModality": true]) == ["a"])
        // Images only; two of any modality, the reserved one counting against the budget.
        #expect(try ids(["filter": "ALL", "previousStudies": 3, "imagesOnly": true]) == ["a", "mri-1", "older-1"])
        // An unresolved destination takes no earlier study.
        #expect(try ids(["filter": "ALL", "previousStudies": 3, "server": "NOWHERE"]) == ["a"])
    }

    @Test func aStudyTheDestinationHasIsNotSentAgain() throws {
        let catalog = StandInCatalog()
        catalog.counts = ["ct": 2, "mr": 3]
        catalog.remote = ["1.1": [5, 2], "1.2": [2]]
        let files = [file("a", study: ct), file("b", study: ct), file("c", study: mr)]
        let picked = try RoutingSelection.files(for: rule(["filter": "ALL", "cfindTest": true, "server": "ARCHIVE"]),
                                                of: files, nodes: nodes, databasePath: "", catalog: catalog)
        #expect(picked.map(\.id) == ["c"])
        #expect(Set(catalog.asked) == ["1.1@AE104", "1.2@AE104"])
        // The C-FIND node needs Activated set: none, nothing asked, nothing removed.
        let unasked = StandInCatalog()
        #expect(try RoutingSelection.files(for: rule(["filter": "ALL", "cfindTest": true]), of: files, nodes: nodes,
                                           databasePath: "", catalog: unasked).count == 3)
        #expect(unasked.asked.isEmpty)
        // A file without a Study Instance UID fails the rule.
        let anonymous = file("x", study: RoutedStudy(id: "x"))
        #expect(throws: RoutingSelectionError.self) {
            try RoutingSelection.files(for: rule(["filter": "ALL", "cfindTest": true]), of: [anonymous], nodes: nodes,
                                       databasePath: "", catalog: unasked)
        }
    }
}

// MARK: The queue, with a stand-in of the app

actor StandInDelivery: RoutingDelivery {
    var nodeList: [DICOMNode]
    var gone: Set<String> = []
    nonisolated let missing: Set<String>
    var failing: Set<String> = []
    var cancelling: Set<String> = []
    var sent: [DICOMSendRequest] = []
    var unresolved: [String] = []
    var failures: [String] = []

    init(nodes: [DICOMNode], missing: Set<String> = []) {
        nodeList = nodes
        self.missing = missing
    }

    func set(failing: Set<String> = [], cancelling: Set<String> = [], gone: Set<String> = []) {
        self.failing = failing
        self.cancelling = cancelling
        self.gone = gone
    }

    func nodes() async -> [DICOMNode] { nodeList }

    func currentFiles(of order: RoutingOrder) async -> [RoutedFile] {
        order.files.filter { !gone.contains($0.id) }
    }

    nonisolated func fileExists(atPath path: String) -> Bool { !missing.contains(path) }

    func sendOptions() async -> DICOMSendOptions { DICOMSendOptions(callingAETitle: "HERE", mostConcurrentSends: 3) }

    func send(_ request: DICOMSendRequest) async -> RoutingSendResult {
        sent.append(request)
        let files = request.allFiles
        if files.contains(where: cancelling.contains) { return .cancelled }
        if files.contains(where: failing.contains) { return .failed(RoutingSendFailure(name: "Network", reason: "refused")) }
        return .sent
    }

    func reportUnresolvedDestination(_ problem: String) async { unresolved.append(problem) }

    func reportFailedSend(_ failure: RoutingSendFailure, to node: DICOMNode) async {
        failures.append("\(failure.reason) \(node.aeTitle ?? "")")
    }
}

@Suite struct RoutingQueueTests {
    func study(_ patientID: String?, _ name: String) -> RoutedStudy {
        RoutedStudy(id: name, studyInstanceUID: "1.\(name)", patientID: patientID, patientName: name, studyName: name)
    }

    func rule(_ name: String, _ server: String?, retry: Any = 2) -> RoutingRule {
        var entry: [String: Any] = ["name": name, "failureRetry": retry]
        entry["server"] = server
        return RoutingRule(propertyList: entry)!
    }

    @Test func filesAlreadyQueuedForTheRuleAreNotQueuedAgain() async {
        let queue = RoutingQueue(retryPause: .zero)
        let s = study("P1", "a")
        await queue.add([file("1", study: s), file("2", study: s)], for: rule("r", "PACS"), database: "db")
        await queue.add([file("2", study: s), file("3", study: s), file("3", study: s)], for: rule("r", "PACS"), database: "db")
        await queue.add([file("1", study: s)], for: rule("other", "PACS"), database: "db")
        await queue.add([file("4", study: s)], for: rule("nameless", nil), database: "db")
        let queued = await queue.queued
        #expect(queued.map { $0.files.map(\.id) } == [["1", "2", "3", "3"], ["1"], ["4"]])
        #expect(queued.map(\.failureRetry) == [2, 2, 0])
        #expect(queued[2].rule == nil && queued[2].destinationName == nil)
    }

    @Test func aDrainSendsEachPatientInTurnAndSaysWhatItLeft() async {
        let delivery = StandInDelivery(nodes: [node("PACS", "4242", aet: "STORE")], missing: ["/db/m.dcm"])
        let queue = RoutingQueue(retryPause: .zero)
        let p2 = study("P2", "b"), p1 = study("P1", "a"), anonymous = study(nil, "n")
        await queue.add([file("b1", study: p2), file("a1", study: p1), file("n1", study: anonymous), file("m", study: p1),
                         file("n2", study: anonymous), file("b2", study: p2), file("a2", study: p1), file("g", study: p1)],
                        for: rule("r", "PACS"), database: "db")
        await delivery.set(gone: ["g"])
        #expect(await queue.drain(through: delivery))
        let sent = await delivery.sent
        #expect(sent.map { $0.batches.map(\.files) } == [[["/db/n1.dcm"]], [["/db/n2.dcm"]],
                                                          [["/db/a1.dcm", "/db/a2.dcm"]], [["/db/b1.dcm", "/db/b2.dcm"]]])
        #expect(sent.map { $0.batches[0].patientName } == ["n", "n", "a", "b"])
        #expect(sent.allSatisfy { $0.destination.aeTitle == "STORE" && $0.route == .cStore && $0.compression == 1 })
        #expect(sent.allSatisfy { $0.options.callingAETitle == "HERE" && $0.options.mostConcurrentSends == 3 })
        #expect(await queue.queued.isEmpty)
    }

    @Test func aFailedBatchIsTriedAgainWhileItsRuleAllows() async {
        let delivery = StandInDelivery(nodes: [node("PACS", "4242", activated: 1)])
        let queue = RoutingQueue(retryPause: .zero)
        let p1 = study("P1", "a"), p2 = study("P2", "b")
        await queue.add([file("a1", study: p1), file("b1", study: p2)], for: rule("r", "PACS", retry: "1"), database: "db")
        await delivery.set(failing: ["/db/a1.dcm", "/db/b1.dcm"])
        await queue.drain(through: delivery)
        // Reported once for the destination, both batches back with one try left.
        #expect(await delivery.failures == ["refused AE4242"])
        var queued = await queue.queued
        #expect(queued.map { $0.files.map(\.id) } == [["a1"], ["b1"]])
        #expect(queued.map(\.failureRetry) == [0, 0])
        #expect(queued.allSatisfy { $0.destinationName == "PACS" && $0.rule?.name == "r" })

        await queue.drain(through: delivery)
        #expect(await delivery.failures == ["refused AE4242"])
        #expect(await queue.queued.isEmpty)

        // Answered: the next failure is news again.
        await delivery.set()
        await queue.add([file("a1", study: p1)], for: rule("r", "PACS"), database: "db")
        await queue.drain(through: delivery)
        await delivery.set(failing: ["/db/a1.dcm"])
        await queue.add([file("a1", study: p1)], for: rule("r", "PACS", retry: 0), database: "db")
        await queue.drain(through: delivery)
        #expect(await delivery.failures == ["refused AE4242", "refused AE4242"])
        queued = await queue.queued
        #expect(queued.isEmpty)
    }

    @Test func anUnresolvedDestinationIsSaidOnceAndSendsNothing() async {
        let delivery = StandInDelivery(nodes: [node("PACS", "1"), node("PACS", "2")])
        let queue = RoutingQueue(retryPause: .zero)
        for _ in 0..<2 {
            await queue.add([file("a", study: study("P1", "a"))], for: rule("r", "PACS"), database: "db")
            await queue.drain(through: delivery)
        }
        #expect(await delivery.sent.isEmpty)
        #expect(await delivery.unresolved.count == 1)
        #expect(await queue.problems.problem(forRule: "r")?.contains("2 DICOM nodes") == true)
    }

    @Test func cancellingStopsTheDrain() async {
        let delivery = StandInDelivery(nodes: [node("PACS", "1")])
        let queue = RoutingQueue(retryPause: .zero)
        await queue.add([file("a", study: study("P1", "a")), file("b", study: study("P2", "b"))],
                        for: rule("r", "PACS"), database: "db")
        await queue.add([file("c", study: study("P3", "c"))], for: rule("s", "PACS"), database: "db")
        await delivery.set(cancelling: ["/db/a.dcm"])
        await queue.drain(through: delivery)
        #expect(await delivery.sent.count == 1)
        #expect(await queue.queued.isEmpty)
    }
}
