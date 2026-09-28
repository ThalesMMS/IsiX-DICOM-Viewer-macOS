import Foundation

public struct DicomWebOriginPolicy: Equatable, Sendable {
    public var configuredURL: URL
    public var allowedOrigins: Set<URL>

    public init(configuredURL: URL, allowedOrigins: Set<URL> = []) {
        self.configuredURL = configuredURL
        self.allowedOrigins = allowedOrigins
    }

    public func forwardsCredentials(to url: URL) -> Bool {
        Self.origin(url) == Self.origin(configuredURL)
    }

    public func resolve(_ reference: String, relativeTo base: URL? = nil) throws -> URL {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: reference, relativeTo: base ?? configuredURL)?.absoluteURL else {
            throw DicomWebError(kind: .originDenied)
        }
        try validate(url, from: base ?? configuredURL)
        return url
    }

    public func validate(_ url: URL, from source: URL? = nil) throws {
        guard let origin = Self.origin(url), url.user == nil, url.password == nil,
              (source ?? configuredURL).scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https",
              configuredURL.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https",
              origin == Self.origin(configuredURL) || allowedOrigins.contains(where: { Self.origin($0) == origin }) else {
            throw DicomWebError(kind: .originDenied)
        }
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

final class DicomWebRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let policy: DicomWebOriginPolicy
    let configuredHeaders: Set<String>
    init(policy: DicomWebOriginPolicy, configuredHeaders: Set<String>) {
        self.policy = policy
        self.configuredHeaders = configuredHeaders
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, (try? policy.validate(url, from: response.url)) != nil else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if !policy.forwardsCredentials(to: url) {
            for header in configuredHeaders.union(["authorization", "proxy-authorization", "cookie"]) {
                redirected.setValue(nil, forHTTPHeaderField: header)
            }
            redirected.httpShouldHandleCookies = false
        }
        completionHandler(redirected)
    }
}
