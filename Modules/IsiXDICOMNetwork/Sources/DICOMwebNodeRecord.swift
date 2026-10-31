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

/// A DICOMweb node as `DICOMWEB_SERVERS` stores it: a QIDO-RS/WADO-RS source,
/// a STOW-RS destination, or both.
///
/// Reading an entry gives every missing setting its default and an entry
/// with no identifier (written by hand) a new one; writing it stores every
/// setting, leaves out the empty optional ones, and keeps the keys this
/// version does not know unchanged. No secret is stored: the credential is
/// the UUID of a Keychain item, the client certificate a Keychain reference.
public struct DICOMwebNodeRecord: Sendable, Hashable {
    /// The keys of a stored node.
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
        public static let maximumRequests = "MaxRequests"
        public static let seriesOrder = "SeriesOrder"
        public static let excludeSeries = "ExcludeSeries"
        public static let adaptiveRequests = "AdaptiveRequests"
        public static let trustedCertificate = "TrustedCertificateSHA256"
        public static let oidcIssuer = "OIDCIssuer"
        public static let oidcClientID = "OIDCClientID"
        public static let oidcScopes = "OIDCScopes"
        public static let oidcAudience = "OIDCAudience"
        public static let oidcRedirectURI = "OIDCRedirectURI"
        public static let clientIdentity = "ClientIdentity"
        public static let clientIdentityName = "ClientIdentityName"

        static let known: Set<String> = [identifier, address, allowInsecureHTTP, wadoPath, qidoPath, name, queryRetrieve,
                                         retrieveSyntax, credential, send, sendSyntax, legacyCredential, maximumRequests,
                                         seriesOrder, excludeSeries, adaptiveRequests, trustedCertificate, oidcIssuer,
                                         oidcClientID, oidcScopes, oidcAudience, oidcRedirectURI, clientIdentity,
                                         clientIdentityName]
    }

    /// "As stored": the server sends, or receives, each object in its own syntax.
    public static let asStored = "*"
    /// A few requests at once, which a server answering one study at a time
    /// should take without throttling.
    public static let defaultMaximumRequests = 4

    /// A stored limit, clamped into 1...16.
    public static func validMaximumRequests(_ value: Int) -> Int { min(max(value, 1), 16) }

    /// A syntax as saved: empty, and Implicit VR Little Endian, which earlier
    /// versions offered and DICOMweb does not carry, read as "As stored".
    public static func storedSyntax(_ saved: String) -> String {
        saved.isEmpty || saved == "1.2.840.10008.1.2" ? asStored : saved
    }

    /// A UUID that names the node for as long as it exists, whatever it is renamed to.
    public var identifier: String
    /// The base URL of the service, e.g. https://pacs.example/dicom-web.
    public var address = ""
    /// Explicit permission for unencrypted HTTP to this node.
    public var allowInsecureHTTP = false
    /// WADO-RS, relative to the address; empty for the address itself.
    public var wadoPath = ""
    /// QIDO-RS, relative to the address; empty for the address itself.
    public var qidoPath = ""
    public var name: String
    /// Listed as a source in the Query/Retrieve window.
    public var queryRetrieve = true
    /// Asked for in the WADO-RS Accept header; `asStored` for transfer-syntax=*.
    public var retrieveSyntax = DICOMwebNodeRecord.asStored
    /// The Keychain item's UUID; empty when the node sends no credentials.
    public var credentialIdentifier = ""
    /// Listed as a STOW-RS destination.
    public var send = false
    /// The syntax objects are sent in; `asStored` sends them unchanged.
    public var sendSyntax = DICOMwebNodeRecord.asStored
    /// The node came from the pilot and its credential still has the pilot's format.
    public var hasLegacyCredential = false
    /// How many requests the node is sent at the same time, 1...16.
    public var maximumRequests = DICOMwebNodeRecord.defaultMaximumRequests {
        didSet { maximumRequests = Self.validMaximumRequests(maximumRequests) }
    }
    /// The order the series are asked for in, 0...2; anything else reads as 0.
    public var seriesOrder = 0 {
        didSet { if !(0...2).contains(seriesOrder) { seriesOrder = 0 } }
    }
    /// Words or phrases that leave out of a retrieve each series whose description contains one.
    public var excludedSeries: [String] = []
    /// Requests at once move between 1 and `maximumRequests` with the node's answers.
    public var adaptiveRequests = false
    /// The SHA-256 of a server certificate trusted besides the system's anchors; empty for none.
    public var trustedCertificateSHA256 = ""
    /// The OpenID Connect settings; the issuer empty when the node does not sign in.
    public var oidcIssuer = ""
    public var oidcClientID = ""
    public var oidcScopes = ""
    public var oidcAudience = ""
    public var oidcRedirectURI = ""
    /// The Keychain's persistent reference to the client certificate; nil for none.
    public var clientIdentityReference: Data?
    /// The certificate's name, as it was when chosen.
    public var clientIdentityName = ""
    /// Keys this version does not know, saved back unchanged.
    public var unknown: [String: PropertyListValue] = [:]

    /// A new node with every default: a source, not a destination, with no address yet.
    public init(identifier: String = UUID().uuidString, name: String) {
        self.identifier = identifier
        self.name = name
    }

    /// A node as stored. Missing values take their defaults; an entry with no
    /// identifier (written by hand) is given one.
    public init(entry: [String: PropertyListValue]) {
        func text(_ key: String) -> String {
            guard let value = entry[key] else { return "" }
            if case .string(let text) = value { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            return value.isNumber ? value.text : ""
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            guard let value = entry[key] else { return fallback }
            if case .string = value { return value.boolValue }
            return value.isNumber ? value.boolValue : fallback
        }
        let stored = text(Key.identifier)
        identifier = UUID(uuidString: stored) != nil ? stored : UUID().uuidString
        name = text(Key.name)
        address = text(Key.address)
        allowInsecureHTTP = flag(Key.allowInsecureHTTP, false)
        wadoPath = text(Key.wadoPath)
        qidoPath = text(Key.qidoPath)
        queryRetrieve = flag(Key.queryRetrieve, true)
        retrieveSyntax = Self.storedSyntax(text(Key.retrieveSyntax))
        credentialIdentifier = text(Key.credential)
        send = flag(Key.send, false)
        sendSyntax = Self.storedSyntax(text(Key.sendSyntax))
        hasLegacyCredential = flag(Key.legacyCredential, false)
        switch entry[Key.maximumRequests] {
        case let value? where value.isNumber:
            maximumRequests = Self.validMaximumRequests(value.intValue)
        case .string(let text)?:
            if let parsed = Int(text.trimmingCharacters(in: .whitespaces)) { maximumRequests = Self.validMaximumRequests(parsed) }
        default:
            break
        }
        let order: Int
        switch entry[Key.seriesOrder] {
        case let value? where value.isNumber: order = value.intValue
        case .string(let text)?: order = Int(text) ?? 0
        default: order = 0
        }
        // Observers do not run in an initializer: clamped here as they would.
        seriesOrder = (0...2).contains(order) ? order : 0
        if case .array(let values)? = entry[Key.excludeSeries] {
            excludedSeries = values.compactMap(\.stringValue)
        }
        adaptiveRequests = flag(Key.adaptiveRequests, false)
        // Kept as written: the table stores it normalized, and one written by
        // hand in another form is refused when the node is used, never dropped.
        trustedCertificateSHA256 = text(Key.trustedCertificate)
        oidcIssuer = text(Key.oidcIssuer)
        oidcClientID = text(Key.oidcClientID)
        oidcScopes = text(Key.oidcScopes)
        oidcAudience = text(Key.oidcAudience)
        oidcRedirectURI = text(Key.oidcRedirectURI)
        // Data in the preferences; base64 text from a hand-written argument.
        switch entry[Key.clientIdentity] {
        case .data(let data)?: clientIdentityReference = data
        case .string(let text)?: clientIdentityReference = Data(base64Encoded: text)
        default: clientIdentityReference = nil
        }
        if clientIdentityReference?.isEmpty == true { clientIdentityReference = nil }
        clientIdentityName = clientIdentityReference == nil ? "" : text(Key.clientIdentityName)
        unknown = entry.filter { !Key.known.contains($0.key) }
    }

    /// A node as stored, from the dictionary the preferences hand out; nil
    /// for an entry that is not a dictionary of property-list values.
    public init?(propertyList: Any) {
        guard let dictionary = propertyList as? [String: Any],
              let entry = PropertyListValue.dictionary(dictionary) else { return nil }
        self.init(entry: entry)
    }

    /// Whether the node signs in with OpenID Connect.
    public var usesOIDC: Bool { !oidcIssuer.isEmpty }

    /// The node as it is stored.
    public var entry: [String: PropertyListValue] {
        var node = unknown
        node[Key.identifier] = .string(identifier)
        node[Key.address] = .string(address)
        node[Key.allowInsecureHTTP] = .boolean(allowInsecureHTTP)
        node[Key.wadoPath] = .string(wadoPath)
        node[Key.qidoPath] = .string(qidoPath)
        node[Key.name] = .string(name)
        node[Key.queryRetrieve] = .boolean(queryRetrieve)
        node[Key.retrieveSyntax] = .string(retrieveSyntax)
        node[Key.send] = .boolean(send)
        node[Key.sendSyntax] = .string(sendSyntax)
        node[Key.maximumRequests] = .integer(maximumRequests)
        node[Key.seriesOrder] = .integer(seriesOrder)
        node[Key.excludeSeries] = excludedSeries.isEmpty ? nil : .array(excludedSeries.map(PropertyListValue.string))
        node[Key.adaptiveRequests] = .boolean(adaptiveRequests)
        node[Key.trustedCertificate] = trustedCertificateSHA256.isEmpty ? nil : .string(trustedCertificateSHA256)
        for (key, value) in [(Key.oidcIssuer, oidcIssuer), (Key.oidcClientID, oidcClientID), (Key.oidcScopes, oidcScopes),
                             (Key.oidcAudience, oidcAudience), (Key.oidcRedirectURI, oidcRedirectURI)] {
            node[key] = value.isEmpty || !usesOIDC ? nil : .string(value)
        }
        if let clientIdentityReference, !clientIdentityReference.isEmpty {
            node[Key.clientIdentity] = .data(clientIdentityReference)
            node[Key.clientIdentityName] = .string(clientIdentityName)
        } else {
            node[Key.clientIdentity] = nil
            node[Key.clientIdentityName] = nil
        }
        node[Key.credential] = credentialIdentifier.isEmpty ? nil : .string(credentialIdentifier)
        node[Key.legacyCredential] = hasLegacyCredential ? .boolean(true) : nil
        return node
    }

    /// The node as the preferences store it.
    public var propertyList: [String: Any] {
        entry.mapValues(\.object)
    }
}

/// Encoded as the stored entry: a node encoded with PropertyListEncoder is the
/// dictionary `DICOMWEB_SERVERS` holds.
extension DICOMwebNodeRecord: Codable {
    public init(from decoder: Decoder) throws {
        self.init(entry: try decoder.singleValueContainer().decode([String: PropertyListValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entry)
    }
}
