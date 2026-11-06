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
import Synchronization

/// Original Syntax asks for `transferSyntax=*&useOrig=true`: dcm4chee-arc-light
/// sends the stored syntax for the wildcard and would otherwise convert to
/// Explicit VR Little Endian, while older servers ignore the parameter and honor
/// `useOrig`. A server that reads `*` as a syntax it does not have answers 400,
/// 404 or 406 instead, for every instance. Such an endpoint is asked again, and
/// from then on, with `useOrig=true` alone - the request Original Syntax made
/// before the wildcard was added - for as long as the application runs, unless
/// the request without it is refused as well.
public enum WADOOriginalSyntax {
    private static let refusingEndpoints = Mutex<Set<String>>([])

    /// Whether `url` is an Original Syntax request carrying the wildcard.
    public static func carriesWildcard(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        return items.contains { $0.name == "transferSyntax" && $0.value == "*" }
            && items.contains { $0.name == "useOrig" && $0.value == "true" }
    }

    /// The statuses that mean the server would not take the wildcard. Any other
    /// refusal - a credential, a missing object on a server that accepts it -
    /// is not one, and changing the request would not help.
    public static func refusesWildcard(status: Int) -> Bool {
        return status == 400 || status == 404 || status == 406
    }

    /// The endpoint a URL is sent to: scheme, host, port and path, not the query.
    public static func endpoint(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string?.lowercased()
    }

    /// `url` without `transferSyntax=*`, keeping every other parameter as it was.
    public static func withoutWildcard(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems else { return url }
        components.percentEncodedQueryItems = items.filter { !($0.name == "transferSyntax" && $0.value == "*") }
        return components.url ?? url
    }

    public static func noteRefusal(of url: URL) {
        guard let endpoint = endpoint(url) else { return }
        refusingEndpoints.withLock { _ = $0.insert(endpoint) }
    }

    /// The same instance was refused without the wildcard too: the wildcard was
    /// not the reason - an object missing from a server that accepts it, say -
    /// and the endpoint is asked with it again.
    public static func noteRefusalWithoutWildcard(of url: URL) {
        guard let endpoint = endpoint(url) else { return }
        refusingEndpoints.withLock { _ = $0.remove(endpoint) }
    }

    public static func refuses(_ url: URL) -> Bool {
        guard let endpoint = endpoint(url) else { return false }
        return refusingEndpoints.withLock { $0.contains(endpoint) }
    }

    /// What to send for `url`: without the wildcard when its endpoint refused it.
    public static func request(for url: URL) -> URL {
        return carriesWildcard(url) && refuses(url) ? withoutWildcard(url) : url
    }

    /// What a pass sends for `url`. The pass that asks again for what was
    /// refused with the wildcard (`withoutWildcard`) sends none with it,
    /// whatever the endpoint's mark says by then.
    public static func request(for url: URL, withoutWildcard pass: Bool) -> URL {
        return pass && carriesWildcard(url) ? withoutWildcard(url) : request(for: url)
    }

    /// Forgets every endpoint, for the tests.
    public static func reset() {
        refusingEndpoints.withLock { $0.removeAll() }
    }
}
