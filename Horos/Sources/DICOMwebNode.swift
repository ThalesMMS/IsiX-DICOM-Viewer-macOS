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

/// How a DICOMweb node authenticates. The secret itself is in the Keychain;
/// the node keeps only the UUID that names it.
@objc(HorosDICOMwebAuthKind)
public enum DICOMwebAuthKind: Int {
    case none = 0
    case basic = 1
    case apiKey = 2
    case bearer = 3
}

/// What the nodes need from the Keychain. `DICOMwebCredentials` does it in the
/// application; a test gives its own.
/// Sendable: the launch migration converts credentials on a background queue
/// with the store it read on the main thread.
public protocol DICOMwebCredentialStoring: Sendable {
    /// Stores a new credential and returns the UUID that names it.
    func store(kind: DICOMwebAuthKind, username: String, secret: String, headerName: String) throws -> String
    /// What the credential is, without its secret: "Basic · user", "API Key · X-Api-Key", "Bearer".
    func summary(forIdentifier identifier: String) -> String
    func remove(identifier: String) throws
    /// Rewrites a credential the pilot stored (a ready Authorization value) in the current format.
    func migrateLegacy(identifier: String) throws
}

/// The Keychain, through `DICOMwebCredentials`.
public struct KeychainDICOMwebCredentialStore: DICOMwebCredentialStoring {
    public init() {}

    public func store(kind: DICOMwebAuthKind, username: String, secret: String, headerName: String) throws -> String {
        let credentialKind: DICOMwebCredentialKind
        switch kind {
        case .basic: credentialKind = .basic
        case .apiKey: credentialKind = .apiKey
        case .bearer: credentialKind = .bearer
        case .none: throw DICOMwebNode.failure(NSLocalizedString("Choose an authentication method.", comment: ""))
        }
        return try DICOMwebCredentials.store(kind: credentialKind, username: username, secret: secret, headerName: headerName)
    }

    public func summary(forIdentifier identifier: String) -> String {
        return DICOMwebCredentials.summary(forIdentifier: identifier)
    }

    public func remove(identifier: String) throws {
        try DICOMwebCredentials.remove(identifier: identifier)
    }

    public func migrateLegacy(identifier: String) throws {
        _ = try DICOMwebCredentials.migrateLegacy(identifier: identifier)
    }
}

/// A DICOMweb node (#799): a QIDO-RS/WADO-RS source, a STOW-RS destination, or
/// both.
///
/// The nodes are kept in their own preference, `DICOMWEB_SERVERS`, apart from
/// the DIMSE nodes in `SERVERS`: plugins and the DIMSE code read `SERVERS` as a
/// list of application entities, and a DICOMweb node has no AE title, address
/// or port to give them. Each entry is a dictionary of property-list values;
/// keys this version does not know are kept when a node is saved again.
///
/// No secret is ever stored here: `CredentialID` is the UUID of a Keychain item.
@objc(HorosDICOMwebNode)
public final class DICOMwebNode: NSObject {
    /// The preference that holds the nodes.
    @objc public static let defaultsKey = "DICOMWEB_SERVERS"

    /// The dictionary keys of a stored node.
    public enum Key {
        public static let identifier = "Identifier"
        public static let address = "Address"
        public static let allowInsecureHTTP = "AllowInsecureHTTP"
        public static let wadoPath = "WADOPath"
        public static let qidoPath = "QIDOPath"
        public static let name = "Name"
        public static let queryRetrieve = "QR"
        public static let retrieveSyntax = "RetrieveSyntax"
        public static let credential = "CredentialID"
        public static let send = "Send"
        public static let sendSyntax = "SendSyntax"
        /// Set on a node migrated from the pilot until its credential is rewritten.
        public static let legacyCredential = "LegacyCredential"
    }

    // MARK: Transfer syntaxes

    /// "As stored": the server sends, or receives, each object in its own syntax.
    @objc public static let asStored = "*"

    /// The syntaxes a node may ask for or send, first "As stored": those Horos
    /// decodes, which DCMTK can also write when a Send Syntax asks for it.
    @objc public static let transferSyntaxes: [String] = [
        asStored,
        "1.2.840.10008.1.2.1",      // Explicit VR Little Endian
        "1.2.840.10008.1.2",        // Implicit VR Little Endian
        "1.2.840.10008.1.2.1.99",   // Deflated Explicit VR Little Endian
        "1.2.840.10008.1.2.4.50",   // JPEG Baseline
        "1.2.840.10008.1.2.4.51",   // JPEG Extended
        "1.2.840.10008.1.2.4.57",   // JPEG Lossless
        "1.2.840.10008.1.2.4.70",   // JPEG Lossless, first-order prediction
        "1.2.840.10008.1.2.4.80",   // JPEG-LS Lossless
        "1.2.840.10008.1.2.4.81",   // JPEG-LS Near-Lossless
        "1.2.840.10008.1.2.4.90",   // JPEG 2000 Lossless
        "1.2.840.10008.1.2.4.91",   // JPEG 2000
        "1.2.840.10008.1.2.5",      // RLE Lossless
    ]

    private static let syntaxTitles: [String: String] = [
        "1.2.840.10008.1.2.1": "Explicit VR Little Endian",
        "1.2.840.10008.1.2": "Implicit VR Little Endian",
        "1.2.840.10008.1.2.1.99": "Deflated Explicit VR Little Endian",
        "1.2.840.10008.1.2.4.50": "JPEG Baseline",
        "1.2.840.10008.1.2.4.51": "JPEG Extended",
        "1.2.840.10008.1.2.4.57": "JPEG Lossless",
        "1.2.840.10008.1.2.4.70": "JPEG Lossless SV1",
        "1.2.840.10008.1.2.4.80": "JPEG-LS Lossless",
        "1.2.840.10008.1.2.4.81": "JPEG-LS Near-Lossless",
        "1.2.840.10008.1.2.4.90": "JPEG 2000 Lossless",
        "1.2.840.10008.1.2.4.91": "JPEG 2000",
        "1.2.840.10008.1.2.5": "RLE Lossless",
    ]

    /// What the pop-up menus show for a syntax.
    @objc(titleForTransferSyntax:)
    public static func title(forTransferSyntax syntax: String) -> String {
        if syntax == asStored { return NSLocalizedString("As stored", comment: "DICOMweb transfer syntax: the objects' own") }
        return syntaxTitles[syntax] ?? syntax
    }

    // MARK: Properties

    /// A UUID that names the node for as long as it exists, whatever it is renamed to.
    @objc public let identifier: String
    /// The base URL of the service, e.g. https://pacs.example/dicom-web.
    @objc public var address: String
    /// Explicit permission for unencrypted HTTP to this node; HTTPS trust is unchanged.
    @objc public var allowInsecureHTTP: Bool
    /// WADO-RS, relative to the address; empty for the address itself.
    @objc public var wadoPath: String
    /// QIDO-RS, relative to the address; empty for the address itself.
    @objc public var qidoPath: String
    @objc public var name: String
    /// Listed as a source in the Query/Retrieve window.
    @objc public var queryRetrieve: Bool
    /// Asked for in the WADO-RS Accept header; `asStored` for transfer-syntax=*.
    @objc public var retrieveSyntax: String
    /// The Keychain item's UUID; empty when the node sends no credentials.
    @objc public var credentialIdentifier: String
    /// Listed as a STOW-RS destination.
    @objc public var send: Bool
    /// The syntax objects are sent in; `asStored` sends them unchanged.
    @objc public var sendSyntax: String
    /// The node came from the pilot and its credential still has the pilot's format.
    @objc public var hasLegacyCredential: Bool
    /// Keys this version does not know, saved back unchanged.
    private var unknown: [String: Any] = [:]

    /// A new node: a source, not a destination, with no address yet.
    @objc public override init() {
        identifier = UUID().uuidString
        address = ""
        allowInsecureHTTP = false
        wadoPath = ""
        qidoPath = ""
        name = NSLocalizedString("DICOMweb Node", comment: "")
        queryRetrieve = true
        retrieveSyntax = DICOMwebNode.asStored
        credentialIdentifier = ""
        send = false
        sendSyntax = DICOMwebNode.asStored
        hasLegacyCredential = false
        super.init()
    }

    /// A node as stored. Missing values take their defaults; an entry with no
    /// identifier (written by hand) is given one.
    @objc(initWithDictionary:)
    public init(dictionary: [String: Any]) {
        func text(_ key: String) -> String {
            if let value = dictionary[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
            return ""
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            if let value = dictionary[key] as? NSNumber { return value.boolValue }
            if let value = dictionary[key] as? NSString { return value.boolValue }
            return fallback
        }
        let stored = text(Key.identifier)
        identifier = UUID(uuidString: stored) != nil ? stored : UUID().uuidString
        address = text(Key.address)
        allowInsecureHTTP = flag(Key.allowInsecureHTTP, false)
        wadoPath = text(Key.wadoPath)
        qidoPath = text(Key.qidoPath)
        name = text(Key.name)
        queryRetrieve = flag(Key.queryRetrieve, true)
        let retrieve = text(Key.retrieveSyntax)
        retrieveSyntax = retrieve.isEmpty ? DICOMwebNode.asStored : retrieve
        credentialIdentifier = text(Key.credential)
        send = flag(Key.send, false)
        let sent = text(Key.sendSyntax)
        sendSyntax = sent.isEmpty ? DICOMwebNode.asStored : sent
        hasLegacyCredential = flag(Key.legacyCredential, false)
        let known: Set<String> = [Key.identifier, Key.address, Key.allowInsecureHTTP, Key.wadoPath, Key.qidoPath, Key.name, Key.queryRetrieve,
                                  Key.retrieveSyntax, Key.credential, Key.send, Key.sendSyntax, Key.legacyCredential]
        unknown = dictionary.filter { !known.contains($0.key) }
        super.init()
    }

    /// The node as it is stored.
    @objc public var dictionaryRepresentation: [String: Any] {
        var node = unknown
        node[Key.identifier] = identifier
        node[Key.address] = address
        node[Key.allowInsecureHTTP] = allowInsecureHTTP
        node[Key.wadoPath] = wadoPath
        node[Key.qidoPath] = qidoPath
        node[Key.name] = name
        node[Key.queryRetrieve] = queryRetrieve
        node[Key.retrieveSyntax] = retrieveSyntax
        node[Key.send] = send
        node[Key.sendSyntax] = sendSyntax
        if credentialIdentifier.isEmpty { node.removeValue(forKey: Key.credential) } else { node[Key.credential] = credentialIdentifier }
        if hasLegacyCredential { node[Key.legacyCredential] = true } else { node.removeValue(forKey: Key.legacyCredential) }
        return node
    }

    // MARK: Validation

    static func failure(_ message: String) -> NSError {
        NSError(domain: "HorosDICOMwebNode", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// The address as it is stored: HTTPS by default; remote HTTP requires an
    /// explicit choice for this node. No credentials, query, fragment or trailing slash.
    @objc(normalizedAddress:error:)
    public static func normalizedAddress(_ text: String) throws -> String {
        try normalizedAddress(text, allowInsecureHTTP: false)
    }

    @objc(normalizedAddress:allowInsecureHTTP:error:)
    public static func normalizedAddress(_ text: String, allowInsecureHTTP: Bool) throws -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw failure(NSLocalizedString("Enter the address of the DICOMweb service.", comment: "")) }
        while value.hasSuffix("/") { value.removeLast() }
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, components.url != nil
        else { throw failure(NSLocalizedString("Enter an HTTPS address, such as https://pacs.example/dicom-web. For remote HTTP, enable Allow Insecure HTTP for this node.", comment: "")) }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { throw failure(NSLocalizedString("The address cannot contain a user name, password, query or fragment. Set credentials in the Auth column.", comment: "")) }
        guard scheme == "https" || (scheme == "http" && (allowInsecureHTTP || loopbackHosts.contains(host.lowercased())))
        else { throw failure(NSLocalizedString("Enter an HTTPS address, such as https://pacs.example/dicom-web. For remote HTTP, enable Allow Insecure HTTP for this node.", comment: "")) }
        return value
    }

    private static let pathCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@%")

    /// A WADO or QIDO path as it is stored: relative, without leading or
    /// trailing slashes, "." or "..", query or fragment. Empty means the address.
    @objc(normalizedPath:error:)
    public static func normalizedPath(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        let problem = NSLocalizedString("A path is relative to the address: letters, digits and slashes, without \"..\", query or fragment.", comment: "")
        // Another scheme or host is not a path: "https://other", "//other".
        guard !trimmed.contains("://"), !trimmed.hasPrefix("//") else { throw failure(problem) }
        for segment in segments {
            // Escapes are allowed, but not to spell a dot segment or a slash.
            guard segment.unicodeScalars.allSatisfy({ pathCharacters.contains($0) }),
                  let decoded = String(segment).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("/")
            else { throw failure(problem) }
        }
        return segments.joined(separator: "/")
    }

    /// Throws the first problem that keeps the node from being used.
    @objc(validateAndReturnError:)
    public func validate() throws {
        _ = try DICOMwebNode.normalizedAddress(address, allowInsecureHTTP: allowInsecureHTTP)
        _ = try DICOMwebNode.normalizedPath(wadoPath)
        _ = try DICOMwebNode.normalizedPath(qidoPath)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw DICOMwebNode.failure(NSLocalizedString("Enter a name for the DICOMweb node.", comment: "")) }
        guard DICOMwebNode.transferSyntaxes.contains(retrieveSyntax), DICOMwebNode.transferSyntaxes.contains(sendSyntax)
        else { throw DICOMwebNode.failure(NSLocalizedString("Choose a transfer syntax from the list.", comment: "")) }
        guard credentialIdentifier.isEmpty || UUID(uuidString: credentialIdentifier) != nil
        else { throw DICOMwebNode.failure(NSLocalizedString("The node's credential reference is invalid. Set its authentication again.", comment: "")) }
    }

    /// Whether the node can be queried or sent to as it is.
    @objc public var isValid: Bool { (try? validate()) != nil }

    private func endpoint(_ path: String) -> String {
        guard let base = try? DICOMwebNode.normalizedAddress(address, allowInsecureHTTP: allowInsecureHTTP),
              let relative = try? DICOMwebNode.normalizedPath(path) else { return "" }
        return relative.isEmpty ? base : base + "/" + relative
    }

    /// The QIDO-RS base URL: the address, with the QIDO path when there is one. Empty when the node is not valid.
    @objc public var qidoEndpoint: String { endpoint(qidoPath) }
    /// The WADO-RS base URL: the address, with the WADO path when there is one. Empty when the node is not valid.
    @objc public var wadoEndpoint: String { endpoint(wadoPath) }
    /// The STOW-RS base URL: the address; STOW-RS posts to {Address}/studies.
    @objc public var stowEndpoint: String { endpoint("") }

    // MARK: The stored list

    /// The Keychain the nodes' credentials are in. Replaced only by tests.
    // nonisolated(unsafe): the application only reads it; a test program
    // replaces it at its top level, before any node is read and before any
    // other thread starts. Remove when the tests inject the store another way.
    nonisolated(unsafe) public static var credentialStore: DICOMwebCredentialStoring = KeychainDICOMwebCredentialStore()

    private static let lock = NSLock()

    /// Every stored node, valid or not, in the order the Locations pane shows them.
    public static func nodes(in defaults: UserDefaults) -> [DICOMwebNode] {
        let stored = defaults.array(forKey: defaultsKey) ?? []
        return stored.compactMap { ($0 as? [String: Any]).map(DICOMwebNode.init(dictionary:)) }
    }

    @objc public static func allNodes() -> [DICOMwebNode] { nodes(in: .standard) }

    public static func save(_ nodes: [DICOMwebNode], to defaults: UserDefaults) {
        defaults.set(nodes.map { $0.dictionaryRepresentation }, forKey: defaultsKey)
    }

    @objc(saveNodes:)
    public static func save(_ nodes: [DICOMwebNode]) { save(nodes, to: .standard) }

    /// The valid nodes with Q&R on: the Query/Retrieve window's sources.
    public static func queryRetrieveNodes(in defaults: UserDefaults) -> [DICOMwebNode] {
        nodes(in: defaults).filter { $0.queryRetrieve && $0.isValid }
    }

    @objc public static func queryRetrieveNodes() -> [DICOMwebNode] { queryRetrieveNodes(in: .standard) }

    /// The valid nodes with Send on: STOW-RS destinations.
    public static func sendNodes(in defaults: UserDefaults) -> [DICOMwebNode] {
        nodes(in: defaults).filter { $0.send && $0.isValid }
    }

    @objc public static func sendNodes() -> [DICOMwebNode] { sendNodes(in: .standard) }

    public static func node(withIdentifier identifier: String, in defaults: UserDefaults) -> DICOMwebNode? {
        nodes(in: defaults).first { $0.identifier == identifier }
    }

    @objc(nodeWithIdentifier:)
    public static func node(withIdentifier identifier: String) -> DICOMwebNode? { node(withIdentifier: identifier, in: .standard) }

    /// `name`, or `name 2`, `name 3`… if another node already has it.
    public static func uniqueName(_ name: String, among nodes: [DICOMwebNode], excluding identifier: String? = nil) -> String {
        let taken = Set(nodes.filter { $0.identifier != identifier }.map { $0.name.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        var index = 2
        while taken.contains("\(name) \(index)".lowercased()) { index += 1 }
        return "\(name) \(index)"
    }

    // MARK: Migration from the pilot

    /// The pilot's retrieve mode for a DICOMweb node in `SERVERS`.
    static let pilotRetrieveMode = 3

    /// Moves the pilot's DICOMweb entries out of `SERVERS` into `DICOMWEB_SERVERS`.
    ///
    /// Each entry with `retrieveMode = 3` becomes a node: its `DICOMwebURL` the
    /// address, its description the name, its credential kept, Q&R on and Send
    /// off, and leaves `SERVERS`. Its AE title, address and port were never
    /// used. The new list is written before `SERVERS`, and an entry whose node
    /// already exists is only removed, so running it again, or after it was
    /// interrupted between the two writes, changes nothing more.
    ///
    /// Returns how many entries left `SERVERS`.
    @discardableResult
    public static func migrateLegacyServers(in defaults: UserDefaults) -> Int {
        lock.lock(); defer { lock.unlock() }
        // A list given as an argument of the launch (`-SERVERS`) is not the
        // one of the preferences, and writing what is left of it would replace
        // that one for good (#855).
        guard defaults.volatileDomain(forName: UserDefaults.argumentDomain)["SERVERS"] == nil,
              let servers = defaults.array(forKey: "SERVERS") else { return 0 }
        var nodes = self.nodes(in: defaults)
        var remaining: [Any] = []
        var moved = 0
        for entry in servers {
            guard let server = entry as? [String: Any],
                  (server["retrieveMode"] as? NSNumber)?.intValue == pilotRetrieveMode
                    || (server["retrieveMode"] as? NSString)?.integerValue == pilotRetrieveMode
            else { remaining.append(entry); continue }
            moved += 1
            let url = (server["DICOMwebURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let address = (try? normalizedAddress(url)) ?? url
            let credential = (server["DICOMwebCredentialID"] as? String) ?? ""
            let description = ((server["Description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let already = nodes.contains { node in
                node.address == address && (credential.isEmpty || node.credentialIdentifier == credential)
            }
            if already { continue }
            let node = DICOMwebNode()
            node.address = address
            node.name = uniqueName(description.isEmpty ? (URLComponents(string: address)?.host ?? node.name) : description, among: nodes)
            node.credentialIdentifier = UUID(uuidString: credential) != nil ? credential : ""
            node.hasLegacyCredential = !node.credentialIdentifier.isEmpty
            node.queryRetrieve = true
            node.send = false
            nodes.append(node)
        }
        guard moved > 0 else { return 0 }
        save(nodes, to: defaults)
        defaults.set(remaining, forKey: "SERVERS")
        NSLog("DICOMweb: moved %ld node(s) from SERVERS to %@", moved, defaultsKey)
        return moved
    }

    /// Rewrites, in the current format, the credentials of the nodes the pilot
    /// left, keeping their identifiers. A credential that cannot be read now
    /// (a locked Keychain) keeps its mark and is tried at the next launch.
    /// Returns how many were rewritten.
    @discardableResult
    public static func migrateLegacyCredentials(in defaults: UserDefaults, store: DICOMwebCredentialStoring) -> Int {
        let done = convertLegacyCredentials(pendingLegacyCredentials(in: defaults), store: store)
        clearLegacyMarks(done, in: defaults)
        return done.count
    }

    static func pendingLegacyCredentials(in defaults: UserDefaults) -> [String] {
        nodes(in: defaults).filter { $0.hasLegacyCredential }.map { $0.credentialIdentifier }
    }

    static func convertLegacyCredentials(_ identifiers: [String], store: DICOMwebCredentialStoring) -> Set<String> {
        var done = Set<String>()
        for identifier in identifiers {
            do {
                if !identifier.isEmpty { try store.migrateLegacy(identifier: identifier) }
                done.insert(identifier)
            } catch {
                NSLog("DICOMweb: a node's credential could not be converted yet; it will be tried again at the next launch")
            }
        }
        return done
    }

    static func clearLegacyMarks(_ done: Set<String>, in defaults: UserDefaults) {
        guard !done.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let current = nodes(in: defaults)
        for node in current where node.hasLegacyCredential && done.contains(node.credentialIdentifier) {
            node.hasLegacyCredential = false
        }
        save(current, to: defaults)
    }

    /// Run once at launch, after the defaults are registered: moves the
    /// pilot's nodes out of `SERVERS` at once, and converts their credentials
    /// in the background, so the Keychain never holds up the launch. The marks
    /// are cleared on the main thread, where the Locations pane saves the list.
    @objc public static func migrateLegacyServers() {
        migrateLegacyServers(in: .standard)
        let pending = pendingLegacyCredentials(in: .standard)
        guard !pending.isEmpty else { return }
        let store = credentialStore
        DispatchQueue.global(qos: .utility).async {
            let done = convertLegacyCredentials(pending, store: store)
            DispatchQueue.main.async { clearLegacyMarks(done, in: .standard) }
        }
    }
}

// MARK: Authentication edits

/// What an edit of a node's authentication asks the Keychain to do.
public enum DICOMwebAuthChange: Equatable {
    /// Nothing: the stored credential, or its absence, stays.
    case keep
    /// Remove the stored credential.
    case remove
    /// Store a new credential and drop the old one.
    case store(kind: DICOMwebAuthKind, username: String, secret: String, headerName: String)
}

/// The authentication edit, apart from its window, so it can be tested.
public enum DICOMwebAuthentication {
    /// A summary's separator: "Basic · user".
    static let separator = " \u{00B7} "

    /// The method and the non-secret detail (user name or header name) a
    /// credential summary names; nil for a summary this version cannot read.
    public static func parse(summary: String) -> (kind: DICOMwebAuthKind, detail: String)? {
        let parts = summary.components(separatedBy: separator)
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        let detail = parts.count > 1 ? parts[1...].joined(separator: separator) : ""
        switch head.lowercased() {
        case "none", "": return (.none, "")
        case "basic": return (.basic, detail)
        case "api key": return (.apiKey, detail)
        case "bearer": return (.bearer, "")
        default: return nil
        }
    }

    private static let tokenCharacters = CharacterSet(charactersIn:
        "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    /// Headers the client sets itself, which an API key must not replace.
    private static let reservedHeaders: Set<String> = ["accept", "content-type", "content-length", "host",
                                                        "transfer-encoding", "connection", "cookie"]

    private static func hasLineBreakOrControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// What to do with what the authentication sheet was given.
    ///
    /// Secret fields are always empty when the sheet opens, so an empty secret
    /// means "keep the one stored", which is possible only when the method and
    /// its user or header name are those of the stored credential.
    /// `existingSummary` is nil when the node has no credential.
    public static func resolve(existingSummary: String?, kind: DICOMwebAuthKind, username: String,
                               secret: String, headerName: String) throws -> DICOMwebAuthChange {
        let existing = existingSummary.flatMap(parse(summary:))
        let hasCredential = existingSummary != nil
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasLineBreakOrControl(secret) {
            throw DICOMwebNode.failure(NSLocalizedString("The secret cannot contain line breaks or control characters.", comment: ""))
        }
        switch kind {
        case .none:
            return hasCredential ? .remove : .keep
        case .basic:
            guard !user.isEmpty, !user.contains(":"), !hasLineBreakOrControl(user) else {
                throw DICOMwebNode.failure(NSLocalizedString("Enter a user name. It cannot contain a colon.", comment: ""))
            }
            if secret.isEmpty {
                if let existing, existing.kind == .basic, existing.detail == user { return .keep }
                throw DICOMwebNode.failure(NSLocalizedString("Enter the password.", comment: ""))
            }
            return .store(kind: .basic, username: user, secret: secret, headerName: "")
        case .apiKey:
            guard !header.isEmpty, header.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                  !reservedHeaders.contains(header.lowercased()) else {
                throw DICOMwebNode.failure(NSLocalizedString("Enter the name of the header that carries the API key, such as X-Api-Key.", comment: ""))
            }
            if secret.isEmpty {
                if let existing, existing.kind == .apiKey, existing.detail.caseInsensitiveCompare(header) == .orderedSame { return .keep }
                throw DICOMwebNode.failure(NSLocalizedString("Enter the API key.", comment: ""))
            }
            return .store(kind: .apiKey, username: "", secret: secret, headerName: header)
        case .bearer:
            if secret.isEmpty {
                if let existing, existing.kind == .bearer { return .keep }
                throw DICOMwebNode.failure(NSLocalizedString("Enter the bearer token.", comment: ""))
            }
            return .store(kind: .bearer, username: "", secret: secret, headerName: "")
        }
    }

    /// Applies a change to a node: stores the new credential before the old
    /// one is removed, so a failure leaves the node with a working reference.
    /// The caller saves the node afterwards.
    public static func apply(_ change: DICOMwebAuthChange, to node: DICOMwebNode, store: DICOMwebCredentialStoring) throws {
        switch change {
        case .keep:
            return
        case .remove:
            if !node.credentialIdentifier.isEmpty { try store.remove(identifier: node.credentialIdentifier) }
            node.credentialIdentifier = ""
            node.hasLegacyCredential = false
        case let .store(kind, username, secret, headerName):
            let identifier = try store.store(kind: kind, username: username, secret: secret, headerName: headerName)
            guard UUID(uuidString: identifier) != nil else {
                throw DICOMwebNode.failure(NSLocalizedString("The node's credential reference is invalid. Set its authentication again.", comment: ""))
            }
            let previous = node.credentialIdentifier
            node.credentialIdentifier = identifier
            node.hasLegacyCredential = false
            if !previous.isEmpty, previous != identifier {
                do { try store.remove(identifier: previous) } catch {
                    NSLog("DICOMweb: the previous credential of a node could not be removed from the Keychain")
                }
            }
        }
    }
}
