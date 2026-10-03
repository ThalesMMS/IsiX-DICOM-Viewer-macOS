#!/usr/bin/env python3
"""Sign a DICOMweb node in with OpenID Connect against a local identity provider.

One loopback HTTPS server, on a self-signed certificate the node trusts by its
SHA-256, is both the identity provider (discovery, authorization with PKCE
S256, token endpoint, RS256 ID tokens and their JWKS, made with openssl) and
a DICOMweb node that accepts only the access tokens it issued and has not
revoked. A plain HTTP side port lets the check drive it.

The check compiles the application's DICOMweb sources with DICOM-Swift's
DicomWebOIDC product and, with the tokens in DICOMwebOIDCTokenKeychain over a
memory backend:

- a node that has not signed in fails its query as an authentication error that
  says to sign in;
- the sign-in (DICOMwebOIDCSignIn: begin, the browser's callback, complete)
  stores the tokens under the node's identifier and nothing of them in the
  node's preferences;
- the query sends the access token; once it is about to expire the next query
  refreshes it first, with the refresh token;
- a token the node refuses with 401 is renewed once and the request repeated
  once; a node that keeps refusing gets one renewal and two requests, and the
  query fails as an authentication error;
- signing out removes the tokens, and the node must sign in again;
- the token store keeps one item per node identifier, reads the backend once,
  and refuses a key that is not a UUID.

Exit 2 (skipped) without the DICOM-Swift products of a built application (see
tests/dicomweb_package.py) or without openssl.
"""
import base64, hashlib, http.server, json, os, secrets, shutil, ssl, subprocess, sys, tempfile, threading, time
import urllib.parse
from pathlib import Path
from dicomweb_package import swift_flags

root = Path(__file__).resolve().parents[1]
OPENSSL = shutil.which('openssl')
if not OPENSSL:
    print('skipped: openssl is required', file=sys.stderr)
    raise SystemExit(2)

CLIENT_ID = 'horos-test'
REDIRECT = 'thalesmms.isis.workstation:/oauth2/callback'
FIRST_LIFETIME = 64   # usable for 4 s: the provider refreshes 60 s before expiry
LATER_LIFETIME = 600


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


class IdP:
    """The provider's and the node's state, shared by both servers."""
    def __init__(self, folder):
        self.folder = folder
        self.lock = threading.Lock()
        self.codes = {}
        self.access = set()
        self.revoked = set()
        self.refresh_tokens = set()
        self.refreshes = 0
        self.reject_all = False
        self.node_requests = []
        self.issuer = ''
        subprocess.run([OPENSSL, 'genrsa', '-out', str(folder / 'signing.pem'), '2048'], check=True, capture_output=True)
        modulus = subprocess.run([OPENSSL, 'rsa', '-in', str(folder / 'signing.pem'), '-noout', '-modulus'],
                                 check=True, capture_output=True, text=True).stdout.strip().split('=', 1)[1]
        self.jwks = {'keys': [{'kty': 'RSA', 'kid': 'test-key', 'use': 'sig', 'alg': 'RS256',
                               'n': b64url(bytes.fromhex(modulus)), 'e': b64url((65537).to_bytes(3, 'big'))}]}

    def sign(self, claims):
        head = b64url(json.dumps({'alg': 'RS256', 'typ': 'JWT', 'kid': 'test-key'}).encode())
        body = b64url(json.dumps(claims).encode())
        signature = subprocess.run([OPENSSL, 'dgst', '-sha256', '-sign', str(self.folder / 'signing.pem'), '-binary'],
                                   input=f'{head}.{body}'.encode(), check=True, capture_output=True).stdout
        return f'{head}.{body}.{b64url(signature)}'

    def authorize(self, query):
        """The callback URL the browser would be sent to: the provider signs in at once."""
        values = dict(urllib.parse.parse_qsl(query))
        assert values['response_type'] == 'code' and values['client_id'] == CLIENT_ID, values
        assert values['redirect_uri'] == REDIRECT and values['code_challenge_method'] == 'S256', values
        assert 'openid' in values['scope'].split(), values
        code = secrets.token_urlsafe(16)
        with self.lock:
            self.codes[code] = values
        return REDIRECT + '?' + urllib.parse.urlencode({'code': code, 'state': values['state']})

    def tokens(self, form):
        with self.lock:
            if form.get('grant_type') == 'authorization_code':
                pending = self.codes.pop(form.get('code', ''), None)
                if (pending is None or form.get('client_id') != CLIENT_ID or form.get('redirect_uri') != REDIRECT
                        or b64url(hashlib.sha256(form.get('code_verifier', '').encode()).digest()) != pending['code_challenge']):
                    return None
                lifetime, nonce = FIRST_LIFETIME, pending['nonce']
            elif form.get('grant_type') == 'refresh_token' and form.get('refresh_token') in self.refresh_tokens:
                self.refreshes += 1
                lifetime, nonce = LATER_LIFETIME, None
            else:
                return None
            access, refresh = 'access-' + secrets.token_urlsafe(12), 'refresh-' + secrets.token_urlsafe(12)
            self.access.add(access)
            self.refresh_tokens = {refresh}
        answer = {'access_token': access, 'refresh_token': refresh, 'token_type': 'Bearer', 'expires_in': lifetime}
        if nonce is not None:
            now = int(time.time())
            answer['id_token'] = self.sign({'iss': self.issuer, 'aud': CLIENT_ID, 'sub': 'synthetic-user', 'iat': now,
                                            'exp': now + 300, 'nonce': nonce})
        return answer


def handler(idp, side):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, status, body=b'', kind='application/json', headers=()):
            self.send_response(status)
            for name, value in headers:
                self.send_header(name, value)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path, _, query = self.path.partition('?')
            if side:
                if path == '/authorize':
                    location = idp.authorize(urllib.parse.urlsplit(urllib.parse.unquote(query)).query)
                    return self.send(200, location.encode(), 'text/plain')
                if path == '/revoke':
                    with idp.lock:
                        idp.revoked |= idp.access
                    return self.send(200)
                if path == '/reject-all':
                    idp.reject_all = True
                    return self.send(200)
                if path == '/stats':
                    with idp.lock:
                        return self.send(200, json.dumps({'refreshes': idp.refreshes, 'requests': idp.node_requests,
                                                          'issued': sorted(idp.access)}).encode())
                return self.send(404)
            if path == '/idp/.well-known/openid-configuration':
                return self.send(200, json.dumps({
                    'issuer': idp.issuer, 'authorization_endpoint': idp.issuer + '/authorize',
                    'token_endpoint': idp.issuer + '/token', 'jwks_uri': idp.issuer + '/jwks',
                    'code_challenge_methods_supported': ['S256'],
                    'id_token_signing_alg_values_supported': ['RS256']}).encode())
            if path == '/idp/jwks':
                return self.send(200, json.dumps(idp.jwks).encode())
            if path == '/idp/authorize':
                return self.send(302, headers=[('Location', idp.authorize(query))])
            if path.startswith('/dicom-web/'):
                header = self.headers.get('Authorization', '')
                token = header[7:] if header.startswith('Bearer ') else ''
                with idp.lock:
                    idp.node_requests.append(token)
                    accepted = token in idp.access and token not in idp.revoked and not idp.reject_all
                if not accepted:
                    return self.send(401, b'{}', headers=[('WWW-Authenticate', 'Bearer')])
                return self.send(200, b'[]', 'application/dicom+json')
            return self.send(404)

        def do_POST(self):
            path = self.path.partition('?')[0]
            body = self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode()
            if side or path != '/idp/token':
                return self.send(404)
            answer = idp.tokens(dict(urllib.parse.parse_qsl(body)))
            if answer is None:
                return self.send(400, b'{"error":"invalid_grant"}')
            return self.send(200, json.dumps(answer).encode())
    return Handler


CHECK = r'''
import Foundation
import DicomWebClient
import DicomWebOIDC

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

/// The side port's answer, as text.
func side(_ path: String) -> String {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var text = ""
    URLSession.shared.dataTask(with: URL(string: CommandLine.arguments[2] + path)!) { data, _, _ in
        text = String(decoding: data ?? Data(), as: UTF8.self); done.signal()
    }.resume()
    done.wait()
    return text
}

struct Stats: Decodable { let refreshes: Int; let requests: [String]; let issued: [String] }
func stats() -> Stats { try! JSONDecoder().decode(Stats.self, from: Data(side("/stats").utf8)) }

final class Memory: @unchecked Sendable {
    let lock = NSLock()
    var items: [String: Data] = [:]
    var reads = 0
    var backend: DICOMwebOIDCTokenKeychain.Backend {
        .init(read: { key in self.lock.withLock { self.reads += 1; return self.items[key] } },
              write: { key, data in self.lock.withLock { self.items[key] = data } },
              delete: { key in self.lock.withLock { _ = self.items.removeValue(forKey: key) } })
    }
}

@main
struct Check {
    static func main() {
        // The node, as the preferences hold it.
        let node = DICOMwebNode()
        node.name = "OIDC"
        node.address = CommandLine.arguments[1] + "/dicom-web"
        node.trustedCertificateSHA256 = CommandLine.arguments[3]
        node.oidcIssuer = CommandLine.arguments[1] + "/idp"
        node.oidcClientID = "horos-test"
        UserDefaults.standard.register(defaults: [DICOMwebNode.defaultsKey: [node.dictionaryRepresentation]])
        let memory = Memory()
        DICOMwebOIDC.tokenStore = DICOMwebOIDCTokenKeychain(backend: memory.backend)

        Thread.detachNewThread {
            run(node: node, memory: memory)
            print(failures == 0 ? "PASS: OpenID Connect sign-in, refresh after expiry, one renewal after 401, sign-out, token store" : "FAILED: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
    }

    static func onMain<T>(_ body: @MainActor @escaping () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    static func wait(_ what: String, _ condition: @MainActor @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(30)
        while !onMain(condition) {
            guard Date() < deadline else { check(false, "\(what) did not happen within 30 s"); return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func query(_ node: DICOMwebNode) -> NSError? {
        do {
            let client = DICOMwebClient(node: try DICOMwebSources.configuration(for: node), timeout: 10)
            client.repeatsBusyRequests = false
            try client.verify()
            return nil
        } catch { return error as NSError }
    }

    static func run(node: DICOMwebNode, memory: Memory) {
        // Not signed in yet.
        let before = query(node)
        check(before.map { DICOMwebClient.errorKind(for: $0) } == .authentication
              && before?.localizedDescription.contains("Sign in") == true,
              "a node that has not signed in fails as authentication and says to sign in: \(String(describing: before))")
        check(stats().requests.isEmpty, "nothing was sent to the node without a token")

        // Sign in: the browser's part is the side port's.
        let signIn = onMain { DICOMwebOIDCSignIn(nodeIdentifier: node.identifier) }
        onMain { signIn.begin(completion: nil) }
        wait("the authorization URL") { signIn.authorizationURL != nil || signIn.finished }
        guard let authorization = onMain({ signIn.authorizationURL }) else { check(false, "no authorization URL: \(String(describing: onMain { signIn.failure }))"); return }
        let parameters = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems ?? []
        check(parameters.contains { $0.name == "code_challenge_method" && $0.value == "S256" }, "the authorization asks for PKCE S256")
        let callback = URL(string: side("/authorize?" + authorization.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))!
        onMain { signIn.complete(callbackURL: callback, completion: nil) }
        wait("the sign-in") { signIn.finished }
        check(onMain { signIn.failure } == nil, "the sign-in succeeded: \(String(describing: onMain { signIn.failure }))")
        let stored = try? DICOMwebOIDC.tokenStore.tokens(forKey: node.identifier)
        check(stored != nil && memory.items.keys.sorted() == [node.identifier], "the tokens are stored under the node's identifier")
        let preferences = (try? PropertyListSerialization.data(fromPropertyList: node.dictionaryRepresentation, format: .xml, options: 0)) ?? Data()
        let plist = String(decoding: preferences, as: UTF8.self)
        check(stored.map { !plist.contains($0.accessToken) && !plist.contains($0.refreshToken ?? "-") } == true
              && !plist.contains("access-") && !plist.contains("refresh-"), "no token in the node's preferences")

        // The query carries the access token.
        let first = stored?.accessToken ?? ""
        check(query(node) == nil, "the signed-in query succeeded")
        var seen = stats()
        check(seen.requests == [first] && seen.refreshes == 0, "the query sent the access token once, no refresh: \(seen.requests.count) \(seen.refreshes)")

        // After expiry (60 s early), the next query refreshes first.
        Thread.sleep(forTimeInterval: 5)
        check(query(node) == nil, "the query after expiry succeeded")
        seen = stats()
        let second = (try? DICOMwebOIDC.tokenStore.tokens(forKey: node.identifier))?.accessToken ?? ""
        check(seen.refreshes == 1 && second != first && seen.requests.last == second && seen.requests.count == 2,
              "an expired token is refreshed before the request: \(seen.refreshes) refreshes, \(seen.requests.count) requests")

        // A 401 to a valid token: one renewal, one repetition.
        _ = side("/revoke")
        check(query(node) == nil, "the query after a revoked token succeeded")
        seen = stats()
        let third = (try? DICOMwebOIDC.tokenStore.tokens(forKey: node.identifier))?.accessToken ?? ""
        check(seen.refreshes == 2 && seen.requests.count == 4 && seen.requests[2] == second && seen.requests[3] == third && third != second,
              "a 401 renews the token once and repeats the request once: \(seen.refreshes) refreshes, \(seen.requests.count) requests")

        // A node that keeps refusing: still one renewal and one repetition.
        _ = side("/reject-all")
        let refused = query(node)
        seen = stats()
        check(refused.map { DICOMwebClient.errorKind(for: $0) } == .authentication, "a second 401 fails as authentication: \(String(describing: refused))")
        check(seen.refreshes == 3 && seen.requests.count == 6, "a refused renewal is tried once: \(seen.refreshes) refreshes, \(seen.requests.count) requests")

        // Sign out.
        do { try DICOMwebOIDC.signOut(nodeIdentifier: node.identifier) } catch { check(false, "sign-out failed: \(error)") }
        check(memory.items.isEmpty && (try? DICOMwebOIDC.tokenStore.tokens(forKey: node.identifier)) == nil, "sign-out removes the tokens")
        let after = query(node)
        check(after?.localizedDescription.contains("Sign in") == true, "after sign-out the node must sign in again: \(String(describing: after))")
        check(stats().requests.count == 6, "nothing was sent after sign-out")

        // The store on its own.
        let own = Memory()
        let store = DICOMwebOIDCTokenKeychain(backend: own.backend)
        let key = UUID().uuidString
        let tokens = DicomWebOIDCTokenSet(accessToken: "a", refreshToken: "r", tokenType: "Bearer", expiresAt: Date(),
                                          configuration: .init(issuerURL: "https://idp.example", clientID: "c", redirectURI: "x-app:/cb"))
        do {
            try store.store(tokens, forKey: key)
            let fresh = DICOMwebOIDCTokenKeychain(backend: own.backend)
            check(try fresh.tokens(forKey: key) == tokens && (try fresh.tokens(forKey: key)) == tokens && own.reads == 1,
                  "the store reads its item once and keeps it: \(own.reads) reads")
            try fresh.deleteTokens(forKey: key)
            check(try fresh.tokens(forKey: key) == nil && own.items.isEmpty, "deleting removes the item")
        } catch { check(false, "token store: \(error)") }
        do { _ = try store.tokens(forKey: "not-a-node"); check(false, "a key that is not a node identifier was read") } catch {}
        own.items[key] = Data("not tokens".utf8)
        do { check(try DICOMwebOIDCTokenKeychain(backend: own.backend).tokens(forKey: key) == nil, "an unreadable item is no tokens") }
        catch { check(false, "an unreadable item failed the read: \(error)") }
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-oidc-') as folder:
        p = Path(folder)
        subprocess.run([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(p / 'key.pem'),
                        '-out', str(p / 'cert.pem'), '-days', '1', '-subj', '/CN=127.0.0.1',
                        '-addext', 'subjectAltName=IP:127.0.0.1', '-addext', 'extendedKeyUsage=serverAuth'],
                       check=True, capture_output=True)
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert((p / 'cert.pem').read_text())).hexdigest()
        idp = IdP(p)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler(idp, side=False))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(p / 'cert.pem'), str(p / 'key.pem'))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        base = f'https://127.0.0.1:{server.server_port}'
        idp.issuer = base + '/idp'
        control = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler(idp, side=True))
        for running in (server, control):
            threading.Thread(target=running.serve_forever, daemon=True).start()
        try:
            (p / 'check.swift').write_text(CHECK)
            names = ['DICOMwebIntegration.swift', 'DICOMwebNode.swift', 'DICOMwebClient.swift', 'DICOMwebCredentials.swift',
                     'DICOMwebMultipart.swift', 'DicomNodeConfiguration.swift', 'NonInteractiveKeychainRead.swift',
                     'DICOMwebOIDC.swift']
            build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings',
                                    *[str(root / 'Horos/Sources' / n) for n in names], str(p / 'check.swift'),
                                    *swift_flags(p), '-o', str(p / 'check')], capture_output=True, text=True, timeout=600)
            if build.returncode:
                print(build.stderr[-4000:])
                print('FAIL: the check does not compile')
                return 1
            run = subprocess.run([str(p / 'check'), base, f'http://127.0.0.1:{control.server_port}', fingerprint],
                                 capture_output=True, text=True, timeout=180)
            output = run.stdout + run.stderr
            print(output.strip())
            # No token reaches the output.
            leaked = [token for token in idp.access | idp.refresh_tokens if token in output]
            if leaked:
                print('FAIL: a token appeared in the output')
                return 1
            return run.returncode
        finally:
            for running in (server, control):
                running.shutdown()
                running.server_close()


if __name__ == '__main__':
    raise SystemExit(main())
