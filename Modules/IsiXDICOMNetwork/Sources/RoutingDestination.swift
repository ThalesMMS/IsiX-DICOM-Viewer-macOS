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

/// Which DICOM node an autorouting rule means.
///
/// A rule stores the destination as the node's `Description`, its display
/// name. Taking the first activated node of that name would send a study to
/// whichever of two same-named nodes the list holds first, and a renamed,
/// deleted or deactivated node would make the rule match nothing in silence.
/// This resolves the name and says which of those happened, so a rule that
/// cannot say where a study goes does not send it anywhere.
public struct RoutingDestination: Sendable, Hashable {
    /// The node, when exactly one activated node has that name.
    public let node: DICOMNode?
    /// What is wrong, in a sentence, when there is no such node.
    public let problem: String?
    /// Whether asking again could give a different answer.
    public let isPermanent: Bool

    public var isResolved: Bool { node != nil }

    /// Resolves the destination of a rule against the stored DICOM nodes.
    public static func resolve(named name: String?, in nodes: [DICOMNode], ruleName: String?) -> RoutingDestination {
        let rule = describe(rule: ruleName)
        guard let name, !name.isEmpty else {
            return RoutingDestination(node: nil, problem: "\(rule) names no destination.", isPermanent: true)
        }

        let matching = nodes.filter { $0[DICOMNode.Key.description]?.stringValue == name }
        let activated = matching.filter(isActivated)

        if activated.count == 1 {
            return RoutingDestination(node: activated[0], problem: nil, isPermanent: false)
        }
        if activated.count > 1 {
            // Sending to the first would be a guess, and reordering the list
            // would change the answer.
            let addresses = activated.map(address(of:)).joined(separator: ", ")
            return RoutingDestination(
                node: nil,
                problem: "\(rule) is addressed to \"\(name)\", and \(activated.count) DICOM "
                    + "nodes are called that: \(addresses). Nothing was sent, because which one "
                    + "is meant cannot be told from the name. Give them different names.",
                isPermanent: true)
        }
        if !matching.isEmpty {
            return RoutingDestination(
                node: nil,
                problem: "\(rule) is addressed to \"\(name)\", which exists but is not activated. Nothing was sent.",
                isPermanent: true)
        }
        return RoutingDestination(
            node: nil,
            problem: "\(rule) is addressed to \"\(name)\", and there is no DICOM node of that "
                + "name. Nothing was sent — a node that was renamed or removed leaves the rules "
                + "that named it pointing at nothing.",
            isPermanent: true)
    }

    /// The node the "already there?" C-FIND of a rule asks: the first, in
    /// their order, whose `Activated` reads true by `-boolValue` (a node
    /// without the key is not one) and whose `Description` is the name.
    public static func firstActivatedNode(named name: String?, in nodes: [DICOMNode]) -> DICOMNode? {
        guard let name else { return nil }
        return nodes.first { node in
            (node[DICOMNode.Key.activated]?.boolValue ?? false)
                && node[DICOMNode.Key.description]?.stringValue.map { ($0 as NSString).isEqual(to: name) } == true
        }
    }

    /// A node with no `Activated` key is activated; a number is read with
    /// `-boolValue`, text is neither "0" nor empty.
    static func isActivated(_ node: DICOMNode) -> Bool {
        switch node[DICOMNode.Key.activated] {
        case nil: return true
        case .string(let text)?: return text != "0" && !text.isEmpty
        case let value? where value.isNumber: return value.boolValue
        default: return true
        }
    }

    /// "AE@host:port", with "?" for what is not stored as the routing reads it.
    static func address(of node: DICOMNode) -> String {
        let aet = node[DICOMNode.Key.aeTitle]?.stringValue ?? "?"
        let host = node[DICOMNode.Key.address]?.stringValue ?? "?"
        return "\(aet)@\(host):\(portText(of: node) ?? "?")"
    }

    /// The port as text: a number's `-stringValue`, or the text stored.
    static func portText(of node: DICOMNode) -> String? {
        switch node[DICOMNode.Key.port] {
        case .string(let text)?: return text
        case let value? where value.isNumber: return numberText(value)
        default: return nil
        }
    }

    private static func numberText(_ value: PropertyListValue) -> String {
        switch value {
        case .integer(let number): return NSNumber(value: number).stringValue
        case .real(let number): return NSNumber(value: number).stringValue
        case .boolean(let flag): return NSNumber(value: flag).stringValue
        default: return value.text
        }
    }

    static func describe(rule: String?) -> String {
        guard let rule, !rule.isEmpty else { return "A routing rule" }
        return "The routing rule \"\(rule)\""
    }
}

/// The rules whose destination could not be resolved, and the destinations
/// that are failing, so the same problem is put in front of someone once and
/// not on every import or every batch: a destination that is down fails
/// every batch, and an alert for each made the application unusable until
/// they were all dismissed.
public struct RoutingProblemGate: Sendable, Hashable {
    private var problems: [String: String] = [:]

    public init() {}

    /// Suspends a rule, and says whether this is the first time with this
    /// problem; only the first time is worth putting in front of anyone.
    @discardableResult
    public mutating func suspend(rule: String?, because problem: String) -> Bool {
        let key = rule ?? ""
        let isNew = problems[key] != problem
        problems[key] = problem
        return isNew
    }

    public func problem(forRule rule: String?) -> String? {
        problems[rule ?? ""]
    }

    /// The destination resolved again, so a rule fixed in the preferences
    /// works without a restart.
    public mutating func resume(rule: String?) {
        problems[rule ?? ""] = nil
    }

    public mutating func resumeAll() {
        problems.removeAll()
    }

    public var suspendedRuleNames: [String] {
        Array(problems.keys)
    }

    /// Whether a send failure is worth putting in front of someone: the
    /// first failure of a destination is, the repeats are logged only.
    public mutating func shouldReport(problem: String, forDestination destination: String) -> Bool {
        suspend(rule: "destination:" + destination, because: problem)
    }

    /// The destination answered, so its next failure is news again.
    public mutating func clearProblems(forDestination destination: String) {
        resume(rule: "destination:" + destination)
    }
}
