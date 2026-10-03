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
import AuthenticationServices
import DicomWebClient
import DicomWebOIDC
import Foundation
import Security
import Synchronization

// MARK: - Tokens

/// The OpenID Connect tokens of the nodes that sign in, in the Keychain: one
/// generic password per node, its account the node's identifier and its data
/// the token set. Nothing of it reaches the preferences.
///
/// Reads are non-interactive, as the credentials' are. The tokens read or
/// written are kept in memory for the process's later requests, so a query
/// that pages or a retrieve that sends many requests reads the Keychain once.
final class DICOMwebOIDCTokenKeychain: DicomWebOIDCTokenStore, Sendable {
    static let service = "org.horosproject.DICOMweb.oidc-tokens"

    /// The Keychain calls, replaceable so the store can be tested without the
    /// user's keychain.
    struct Backend: Sendable {
        var read: @Sendable (_ key: String) throws -> Data?
        var write: @Sendable (_ key: String, _ data: Data) throws -> Void
        var delete: @Sendable (_ key: String) throws -> Void
    }

    private let backend: Backend
    private let cache = Mutex<[String: DicomWebOIDCTokenSet]>([:])

    init(backend: Backend) { self.backend = backend }

    private func checked(_ key: String) throws -> String {
        guard UUID(uuidString: key) != nil else { throw DICOMwebCredentials.failure(errSecParam) }
        return key
    }

    func tokens(forKey key: String) throws -> DicomWebOIDCTokenSet? {
        let key = try checked(key)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        guard let data = try backend.read(key) else { return nil }
        // Tokens this version cannot read are no tokens: the node signs in again.
        guard let tokens = try? JSONDecoder().decode(DicomWebOIDCTokenSet.self, from: data) else { return nil }
        cache.withLock { $0[key] = tokens }
        return tokens
    }

    func store(_ tokens: DicomWebOIDCTokenSet, forKey key: String) throws {
        let key = try checked(key)
        try backend.write(key, try JSONEncoder().encode(tokens))
        cache.withLock { $0[key] = tokens }
    }

    func deleteTokens(forKey key: String) throws {
        let key = try checked(key)
        cache.withLock { _ = $0.removeValue(forKey: key) }
        try backend.delete(key)
    }
}

extension DICOMwebOIDCTokenKeychain.Backend {
    private static func item(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: DICOMwebOIDCTokenKeychain.service, kSecAttrAccount as String: key]
    }

    static var keychain: Self { Self(
        read: { key in
            let (status, result) = NonInteractiveKeychainRead.read(service: DICOMwebOIDCTokenKeychain.service, account: key, data: true)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result?[kSecValueData as String] as? Data
            else { throw DICOMwebCredentials.failure(status == errSecSuccess ? errSecItemNotFound : status) }
            return data
        },
        write: { key, data in
            let status = SecItemUpdate(item(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var query = item(key)
                query[kSecValueData as String] = data
                query[kSecAttrSynchronizable as String] = false
                query[kSecAttrLabel as String] = "DICOMweb sign-in"
                let added = SecItemAdd(query as CFDictionary, nil)
                guard added == errSecSuccess else { throw DICOMwebCredentials.failure(added) }
            } else if status != errSecSuccess {
                throw DICOMwebCredentials.failure(status)
            }
        },
        delete: { key in
            let status = SecItemDelete(item(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DICOMwebCredentials.failure(status) }
        }) }
}

// MARK: - Provider

/// The identity provider's requests: an ephemeral session without cookies or
/// cache that refuses every redirect, as the package's own. A node that trusts
/// its server's certificate (`DICOMwebServerTrust`) trusts it on its identity
/// provider too, for a provider on the same self-signed certificate; the
/// system's evaluation still comes first.
private final class DICOMwebOIDCSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let trustedCertificateSHA256: String
    init(trustedCertificateSHA256: String) { self.trustedCertificateSHA256 = trustedCertificateSHA256 }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              !trustedCertificateSHA256.isEmpty, let trust = challenge.protectionSpace.serverTrust,
              !SecTrustEvaluateWithError(trust, nil),
              let pinned = DICOMwebServerTrust.trusts(trust, host: challenge.protectionSpace.host, fingerprint: trustedCertificateSHA256)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: pinned))
    }
}

/// A node's OpenID Connect sign-in, over DICOM-Swift's provider: discovery,
/// PKCE, the code exchange, the ID token's verification and the refresh of
/// expired tokens, shared by every request of a node.
@objc(HorosDICOMwebOIDC)
public final class DICOMwebOIDC: NSObject {
    /// Where the tokens are. Replaced only by tests.
    // nonisolated(unsafe): the application only reads it; a test program
    // replaces it at its top level, before any provider is made and before
    // any other thread starts.
    nonisolated(unsafe) static var tokenStore: any DicomWebOIDCTokenStore = DICOMwebOIDCTokenKeychain(backend: .keychain)

    /// One provider per trusted certificate, so that every request of a node,
    /// and its sign-in, share one refresh.
    private static let providers = Mutex<[String: DicomWebOIDCProvider]>([:])

    static func provider(trusting fingerprint: String) -> DicomWebOIDCProvider {
        providers.withLock { providers in
            if let existing = providers[fingerprint] { return existing }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration,
                                     delegate: DICOMwebOIDCSessionDelegate(trustedCertificateSHA256: fingerprint), delegateQueue: nil)
            let created = DicomWebOIDCProvider(tokenStore: tokenStore, session: session)
            providers[fingerprint] = created
            return created
        }
    }

    /// What the settings must be, for the sheet and for a node that cannot be used.
    @objc public static var settingsHelp: String {
        NSLocalizedString("Enter an HTTPS issuer, a client ID, scopes that include openid and a redirect URI with the app's own scheme.", comment: "DICOMweb OpenID Connect settings")
    }

    /// The node's settings, checked and normalized by the provider's rules.
    static func configuration(for node: DICOMwebNode) throws -> DicomWebOIDCConfiguration {
        let configuration = DicomWebOIDCConfiguration(
            issuerURL: node.oidcIssuer, clientID: node.oidcClientID,
            scopes: node.oidcScopes.isEmpty ? DICOMwebNode.defaultOIDCScopes : node.oidcScopes,
            audience: node.oidcAudience.isEmpty ? nil : node.oidcAudience,
            redirectURI: node.oidcRedirectURI.isEmpty ? DICOMwebNode.defaultOIDCRedirectURI : node.oidcRedirectURI)
        do { return try configuration.validated() } catch {
            throw DICOMwebClient.failure(1, settingsHelp, kind: .configuration)
        }
    }

    /// Whether the settings would be accepted, for the sheet.
    @objc(validateIssuer:clientID:scopes:audience:redirectURI:error:)
    public static func validate(issuer: String, clientID: String, scopes: String, audience: String, redirectURI: String) throws {
        let node = DICOMwebNode()
        node.oidcIssuer = issuer; node.oidcClientID = clientID; node.oidcScopes = scopes
        node.oidcAudience = audience; node.oidcRedirectURI = redirectURI
        _ = try configuration(for: node)
    }

    /// What gives a node's requests their token and renews it after a 401.
    static func authorization(for node: DICOMwebNode) throws -> any DicomWebAuthorizationProvider {
        let configuration = try configuration(for: node)
        let fingerprint = try DICOMwebServerTrust.normalizedFingerprint(node.trustedCertificateSHA256)
        return DICOMwebOIDCRequestAuthorization(
            base: provider(trusting: fingerprint).authorization(key: node.identifier, configuration: configuration))
    }

    /// Removes a node's tokens from the Keychain: its sign-out, and part of
    /// its removal.
    @objc(signOutNodeWithIdentifier:error:)
    public static func signOut(nodeIdentifier: String) throws {
        guard UUID(uuidString: nodeIdentifier) != nil else { return }
        try tokenStore.deleteTokens(forKey: nodeIdentifier)
    }

    /// An error of the identity provider, as the client's errors are: no
    /// token, code or address in its message.
    static func failure(for error: Error) -> Error {
        if error is CancellationError { return DICOMwebClient.cancelledError }
        if let oidc = error as? DicomWebOIDCError {
            if oidc == .signInRequired {
                return DICOMwebClient.failure(401, "Sign in to the DICOMweb node again: open its authentication in Locations and save it.", kind: .authentication)
            }
            return DICOMwebClient.failure(401, "DICOMweb sign-in failed. " + (oidc.errorDescription ?? "") + " Check the node's OpenID Connect settings in Locations.", kind: .authentication)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled { return DICOMwebClient.cancelledError }
            return DICOMwebClient.failure(3, "The DICOMweb node's identity provider could not be reached. Check its address, its certificate and the network.", kind: .network)
        }
        return error
    }
}

/// The package's per-request provider, with its errors told as the client's.
struct DICOMwebOIDCRequestAuthorization: DicomWebAuthorizationProvider {
    let base: DicomWebOIDCAuthorization

    func authorizationHeaders() async throws -> [String: String] {
        do { return try await base.authorizationHeaders() } catch { throw DICOMwebOIDC.failure(for: error) }
    }

    func renewAuthorization(afterRejecting rejected: [String: String]) async throws -> Bool {
        do { return try await base.renewAuthorization(afterRejecting: rejected) } catch { throw DICOMwebOIDC.failure(for: error) }
    }
}

// MARK: - Sign-in

/// One sign-in of a node: the provider's authorization URL, opened in a
/// browser session (`ASWebAuthenticationSession`) that returns at the node's
/// redirect URI, then the code exchange, whose tokens go to the Keychain.
///
/// `start(window:completion:)` does it all. `begin` and `complete` are its two
/// halves, around the browser, and `authorizationURL`, `finished` and
/// `failure` say where it is.
// Main actor: started from the authentication sheet, and its browser session
// presents on a window.
@MainActor
@objc(HorosDICOMwebOIDCSignIn)
public final class DICOMwebOIDCSignIn: NSObject {
    @objc public let nodeIdentifier: String
    /// The provider's authorization URL, once `begin` has discovered it.
    @objc public private(set) var authorizationURL: URL?
    @objc public private(set) var finished = false
    /// Why it ended without tokens; nil when it succeeded or is still going.
    @objc public private(set) var failure: NSError?

    private var login: (provider: DicomWebOIDCProvider, id: UUID, scheme: String)?
    private var browser: ASWebAuthenticationSession?
    private let presenter = DICOMwebOIDCPresenter()
    private var onFinish: ((NSError?) -> Void)?
    /// The sign-ins under way, kept until they end.
    private static var running: [ObjectIdentifier: DICOMwebOIDCSignIn] = [:]

    @objc(initWithNodeIdentifier:)
    public init(nodeIdentifier: String) {
        self.nodeIdentifier = nodeIdentifier
        super.init()
    }

    private func end(_ error: Error?) {
        failure = error.map { DICOMwebOIDC.failure(for: $0) as NSError }
        finished = true
        browser = nil
        Self.running.removeValue(forKey: ObjectIdentifier(self))
        let finish = onFinish
        onFinish = nil
        finish?(failure)
    }

    /// Discovers the node's provider and makes its authorization URL, with
    /// PKCE, state and nonce. `completion` gets nil once `authorizationURL`
    /// is set, or the failure, which also ends the sign-in.
    @objc(beginWithCompletion:)
    public func begin(completion: ((NSError?) -> Void)?) {
        Self.running[ObjectIdentifier(self)] = self
        let configuration: DicomWebOIDCConfiguration, provider: DicomWebOIDCProvider, key: String
        do {
            guard let node = DICOMwebNode.node(withIdentifier: nodeIdentifier), node.usesOIDC else {
                throw DICOMwebClient.failure(1, DICOMwebOIDC.settingsHelp, kind: .configuration)
            }
            configuration = try DICOMwebOIDC.configuration(for: node)
            provider = DICOMwebOIDC.provider(trusting: try DICOMwebServerTrust.normalizedFingerprint(node.trustedCertificateSHA256))
            key = node.identifier
        } catch {
            end(error)
            completion?(failure)
            return
        }
        Task { @MainActor in
            do {
                let request = try await provider.beginLogin(key: key, configuration: configuration)
                self.login = (provider, request.id, request.callbackScheme)
                self.authorizationURL = request.authorizationURL
                completion?(nil)
            } catch {
                self.end(error)
                completion?(self.failure)
            }
        }
    }

    /// Ends the sign-in with the browser's callback: checks it, exchanges the
    /// code and stores the tokens. `completion` gets nil or the failure.
    @objc(completeWithCallbackURL:completion:)
    public func complete(callbackURL: URL, completion: ((NSError?) -> Void)?) {
        if let completion { onFinish = completion }
        guard let login, !finished else {
            end(DicomWebOIDCError.invalidCallback)
            return
        }
        Task { @MainActor in
            do {
                try await login.provider.completeLogin(id: login.id, callbackURL: callbackURL)
                self.end(nil)
            } catch {
                self.end(error)
            }
        }
    }

    /// Signs in through the browser, on `window`. `completion` gets nil when
    /// the tokens are in the Keychain, or the failure; a sign-in the user
    /// cancelled fails as cancelled.
    @objc(startWithWindow:completion:)
    public func start(window: NSWindow?, completion: ((NSError?) -> Void)?) {
        presenter.window = window
        onFinish = completion
        begin { [weak self] failure in
            guard let self, failure == nil, let url = self.authorizationURL, let login = self.login else { return }
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(login.scheme)) { @Sendable [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let callbackURL {
                        self.complete(callbackURL: callbackURL, completion: nil)
                    } else {
                        Task { await login.provider.cancelLogin(id: login.id) }
                        let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        self.end(cancelled ? DICOMwebClient.cancelledError : DicomWebOIDCError.invalidCallback)
                    }
                }
            }
            session.presentationContextProvider = self.presenter
            self.browser = session
            if !session.start() { self.end(DicomWebOIDCError.invalidCallback) }
        }
    }

    /// Stops a sign-in under way.
    @objc public func cancel() {
        guard !finished else { return }
        browser?.cancel()
        if let login { Task { await login.provider.cancelLogin(id: login.id) } }
        end(DICOMwebClient.cancelledError)
    }
}

/// The window a sign-in's browser session presents on. Apart from the sign-in,
/// whose Objective-C interface does not name AuthenticationServices.
@MainActor
private final class DICOMwebOIDCPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var window: NSWindow?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}
