#!/usr/bin/env python3
"""The DICOMweb and WADO-URI rules decide as the app's classes did.

The rules of the WADO-URI downloader (the Original Syntax wildcard, the
settings it reads, how an answer is read, the network log's policy and
reasons), of the WADO query manifest, of the node's WADO credential and of
the DICOMweb retrieve's requests (their order, how one that failed recovers,
what an object must be to be taken, when the automatic mode asks again) left
the app for IsiXDICOMNetwork. The same driver is compiled twice: with the
code of the revision before that change - WADOXML.swift, WADOCredentials.swift
and DICOMwebRetrieveRecovery.swift as they were, and the inline rules of
WADODownload.swift and DCMTKQueryNode+DICOMweb.swift cut from them - and with
this tree, its module and the app code that now calls it. Both print what
they decide over the same cases; the outputs must be equal.

The URLs of a manifest are compared as a set: the earlier class listed them
in the order of a dictionary, the module in the manifest's order. An element
of a manifest without its UID raised an Objective-C exception before, and is
left out now; no case here has one.

Exits 2 when the history does not reach the revision before the change.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # noqa: E402
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD = 'Horos/Sources/WADODownload.swift'
SESSION = 'Horos/Sources/DCMTKQueryNode+DICOMweb.swift'
MARK = 'enum WADOOriginalSyntax {'
# HEAD while the change is not committed; then the parent of the commit that
# moved the wildcard rule out of the downloader.
reference = ('HEAD' if MARK in history_reference.show('HEAD', DOWNLOAD).decode('utf-8')
             else history_reference.before_text_removed(DOWNLOAD, MARK))
if reference is None:
    print('skipped: the history does not reach the revision before the rules moved')
    sys.exit(2)
if MARK in (ROOT / DOWNLOAD).read_text(encoding='utf-8'):
    print('skipped: this tree still keeps the rules in the downloader')
    sys.exit(2)


def old(path):
    return history_reference.show(reference, path).decode('utf-8')


def cut(text, start, end, include_end=False):
    """The text from `start` to `end`, which must each occur once from there."""
    at = text.index(start)
    stop = text.index(end, at + len(start))
    return text[at:stop + (len(end) if include_end else 0)]


client_source = (ROOT / 'Horos/Sources/DICOMwebClient.swift').read_text(encoding='utf-8')
# The client's error kinds and how it reads them, unchanged: both sides use them.
CLIENT = ('import Foundation\n'
          + cut(client_source, '@objc(HorosDICOMwebErrorKind)', '// MARK: - Store results')
          + '''
public final class DICOMwebClient: NSObject {
    static let kindKey = "HorosDICOMwebErrorKind"
    @objc public static let retryAfterKey = "HorosDICOMwebRetryAfter"
    static let objectsHandedOverKey = "HorosDICOMwebObjectsHandedOver"
'''
          + cut(client_source, '    @objc(errorKindForError:)', '    /// Whether a QIDO-RS error says the node does not implement')
          + '''    // What the retrieve's port asks of the client; never called here.
    public var retrieveFallbackTransferSyntax: String? { nil }
    public func accepts(retrievedTransferSyntax syntax: String) -> Bool { false }
    public func retrieve(path: String, stagingDirectory: String, fallbackOnly: Bool,
                         objectHandler handler: @escaping (String) -> String?) throws -> NSNumber { 0 }
    public func previewImage(study: String, series: String, instance: String?) throws -> Data { Data() }
}
''')

download = old(DOWNLOAD)
session = old(SESSION)
OLD_RULES = '''import Foundation
import Synchronization
import IsiXDICOMNetwork

''' + cut(download, MARK, '/// One request of a pass') + '''
''' + cut(session, 'struct DICOMwebRetrieveRequest: Sendable {', '/// The requests of one DICOMweb retrieve') + '''
enum Outcome { case success, throttled, transient, neutral }

final class Issues {
    var networkIssues: [String: Int] = [:]
    func recordNetworkIssue(_ reason: String) {
''' + cut(download, '        // Bound diagnostic growth', '    private func updateNetworkLog') + '''}

final class Settings {
    var maximumConcurrentDownloads = 0
    var adaptiveRequests = false
    func concurrency() -> Int32 {
''' + cut(download, '        var WADOMaximumConcurrentDownloads = ', '        let node = self.limiterNode').replace('\n                            ', '\n        ') + '''        return WADOMaximumConcurrentDownloads
    }
    func timeout() -> Float {
''' + cut(download, 'var timeout = UserDefaults.standard.float', '{ timeout = 240 }', True) + '''
        return timeout
    }
    func attempts() -> Int {
''' + cut(download, '        var attempts = UserDefaults.standard.integer(forKey: "WADORetryAttempts")',
          '        if adaptiveRequests { attempts = max(attempts, 4) }', True) + '''
        return attempts
    }
}

final class Dataset {
    let sources: [String]
    init(_ sources: [String]) { self.sources = sources }
    func stringValues(forTag tag: UInt32, inItemsOfSequence sequence: UInt32) -> [Data]? { sources.map { Data($0.utf8) } }
}

enum Rules {
    static func carriesWildcard(_ url: URL) -> Bool { WADOOriginalSyntax.carriesWildcard(url) }
    static func endpoint(_ url: URL) -> String? { WADOOriginalSyntax.endpoint(url) }
    static func noteRefusal(_ url: URL) { WADOOriginalSyntax.noteRefusal(of: url) }
    static func noteRefusalWithoutWildcard(_ url: URL) { WADOOriginalSyntax.noteRefusalWithoutWildcard(of: url) }
    static func sent(_ url: URL, pass passWithoutWildcard: Bool) -> URL {
        passWithoutWildcard && WADOOriginalSyntax.carriesWildcard(url as URL)
            ? WADOOriginalSyntax.withoutWildcard(url as URL) : WADOOriginalSyntax.request(for: url as URL)
    }
    static func policy(_ urls: [URL]) -> String {
        let entry = NSMutableDictionary()
''' + cut(download, '        var policies = Set<String>()', '        updateNetworkLog()\n    }\n\n    private func recordNetworkIssue') + '''        return entry["logWADOPolicy"] as? String ?? ""
    }
    static func issues(_ reasons: [String]) -> [String: Int] {
        let issues = Issues()
        reasons.forEach(issues.recordNetworkIssue)
        return issues.networkIssues
    }
''' + cut(download, '    static func untrustedServerReason(', '    public override init()') + '''
    static func failureReason(_ error: Error) -> String {
        let failure = error as NSError
        let category = Self.untrustedServerReason(error, host: nil) != nil ? "TLS" : "Transport"
        let domain = failure.domain == NSURLErrorDomain ? "NSURLErrorDomain" : "error"
        return "\\(category) \\(domain) \\(failure.code)"
    }
    static func strains(_ error: Error) -> Bool {
        let failed = error as NSError
        return failed.domain == NSURLErrorDomain && Self.untrustedServerReason(error, host: nil) == nil
               && failed.code != NSURLErrorCancelled
    }
    static func settings(nodeLimit: Int, adaptive: Bool) -> (Int32, Float, Int) {
        let settings = Settings()
        settings.maximumConcurrentDownloads = nodeLimit
        settings.adaptiveRequests = adaptive
        return (settings.concurrency(), settings.timeout(), settings.attempts())
    }
    static func length(_ response: URLResponse) -> Int64 {
        let httpResponse = response as? HTTPURLResponse
''' + cut(download, '            var length: Int64 = 0', 'length = response.expectedContentLength\n            }', True) + '''
        return length
    }
    static func body(_ d: NSMutableData) -> (String, Bool) {
        var `extension` = "dcm"
''' + cut(download, '                if let prefix = NSString(bytes: d.bytes', '`extension` = "osirixzip"\n                }', True) + '''
''' + cut(download, '                var looksLikeDICOM = false', '== 0\n                }', True) + '''
        return (`extension`, looksLikeDICOM)
    }
    static func pick(_ pending: [DICOMwebRetrieveRequest], ordered: [String]?) -> Int {
        struct Pool { var pending: [DICOMwebRetrieveRequest] }
        struct Plan { let orderedSeries: [String] }
        let pool = Pool(pending: pending)
        let plan = ordered.map { Plan(orderedSeries: $0) }
''' + cut(session, '                        var index = 0, best = Int.max', '                        return pool.pending.remove(at: index)') + '''        return index
    }
    static func recovery(_ request: DICOMwebRetrieveRequest, _ error: NSError, taken set: Set<String>) -> Int? {
        struct Taken { let set: Set<String>; func read<T>(_ body: (Set<String>) -> T) -> T { body(set) } }
        let taken = Taken(set: set)
''' + cut(session, '        let made = request.attempts + 1', '        NSLog("---- retrieve: attempt').replace('{ return }', '{ return nil }') + '''        return action.rawValue
    }
    static func repeats(adaptive: Bool, outcome: Outcome, request: DICOMwebRetrieveRequest, error: NSError?) -> Bool {
        let requestError = error
''' + cut(session, '                    let handedOver = (requestError?.userInfo', '\n', True) + '''        return ''' + cut(session, 'if adaptive && (outcome == .throttled', ' {\n').removeprefix('if ') + '''
    }
    static func belongs(study: String, series: String, request: DICOMwebRetrieveRequest, dataset: Dataset?, actualStudy: String?,
                        actualSeries: String?, objectUID: String?, seen unique: Set<String>) -> Bool {
''' + cut(session, '            var valid = dataset != nil && actualStudy != nil', '!unique.contains(objectUID ?? "")', True) + '''
        return valid
    }
    static func request(path: String, uid: String?, series: String?, attempts: Int) -> DICOMwebRetrieveRequest {
        var request = DICOMwebRetrieveRequest(path: path, uid: uid, series: series)
        request.attempts = attempts
        return request
    }
}
'''

new_session = (ROOT / SESSION).read_text(encoding='utf-8')
NEW_RULES = '''import Foundation
import IsiXDICOMNetwork

enum Outcome { case success, throttled, transient, neutral }

final class Dataset {
    let sources: [String]
    init(_ sources: [String]) { self.sources = sources }
    func stringValues(forTag tag: UInt32, inItemsOfSequence sequence: UInt32) -> [Data]? { sources.map { Data($0.utf8) } }
}

enum Rules {
    static func carriesWildcard(_ url: URL) -> Bool { WADOOriginalSyntax.carriesWildcard(url) }
    static func endpoint(_ url: URL) -> String? { WADOOriginalSyntax.endpoint(url) }
    static func noteRefusal(_ url: URL) { WADOOriginalSyntax.noteRefusal(of: url) }
    static func noteRefusalWithoutWildcard(_ url: URL) { WADOOriginalSyntax.noteRefusalWithoutWildcard(of: url) }
    static func sent(_ url: URL, pass: Bool) -> URL { WADOOriginalSyntax.request(for: url, withoutWildcard: pass) }
    static func policy(_ urls: [URL]) -> String { WADONetworkTally.policy(for: urls) }
    static func issues(_ reasons: [String]) -> [String: Int] {
        var tally = WADONetworkTally()
        reasons.forEach { tally.record($0) }
        return tally.issues
    }
    static func untrustedServerReason(_ error: Error, host: String?) -> String? {
        let error = error as NSError
        return WADORequestRules.untrustedServerReason(domain: error.domain, code: error.code,
                                                      description: error.localizedDescription, host: host)
    }
    static func failureReason(_ error: Error) -> String {
        let failure = error as NSError
        return WADORequestRules.failureReason(domain: failure.domain, code: failure.code)
    }
    static func strains(_ error: Error) -> Bool {
        let failure = error as NSError
        return WADORequestRules.strainsNode(domain: failure.domain, code: failure.code)
    }
    static func settings(nodeLimit: Int, adaptive: Bool) -> (Int32, Float, Int) {
        let settings = WADORetrieveSettings(nodeLimit: nodeLimit, preferences: UserDefaults.standard)
        return (settings.maximumConcurrentDownloads, settings.timeout,
                WADORetrieveSettings.retryAttempts(preferences: UserDefaults.standard, adaptive: adaptive))
    }
    static func length(_ response: URLResponse) -> Int64 {
        let httpResponse = response as? HTTPURLResponse
        return WADORequestRules.expectedLength(contentLength: httpResponse?.value(forHTTPHeaderField: "Content-Length"),
                                               isHTTP: httpResponse != nil, expectedContentLength: response.expectedContentLength)
    }
    static func body(_ d: NSMutableData) -> (String, Bool) {
        let head = d.subdata(with: NSRange(location: 0, length: min(d.length, 136)))
        return (WADORequestRules.fileExtension(ofBody: head), WADORequestRules.looksLikeDICOM(head))
    }
    static func pick(_ pending: [DICOMwebRetrieveRequest], ordered: [String]?) -> Int {
        DICOMwebRetrieveQueue.nextIndex(of: pending, orderedSeries: ordered)
    }
    static func recovery(_ request: DICOMwebRetrieveRequest, _ error: NSError, taken: Set<String>) -> Int? {
        let queue = DICOMwebRetrieveQueue(limit: 1)
        taken.forEach(queue.take)
        return queue.recovery(of: request, failure: DICOMwebClient.requestFailure(error))?.rawValue
    }
    static func repeats(adaptive: Bool, outcome: Outcome, request: DICOMwebRetrieveRequest, error: NSError?) -> Bool {
        let failure = error.map { DICOMwebClient.requestFailure($0) }
        return ''' + cut(new_session, 'adaptive && DICOMwebRetrieveQueue.repeatsAdaptively(', 'outcome == .transient)', True) + '''
    }
    static func belongs(study: String, series: String, request: DICOMwebRetrieveRequest, dataset: Dataset?, actualStudy: String?,
                        actualSeries: String?, objectUID: String?, seen unique: Set<String>) -> Bool {
''' + cut(new_session, '            let identified = dataset != nil', '                return "WADO-RS returned invalid') + '''            return false
        }
        _ = (dataset, objectUID, actualSeries)
        return true
    }
    static func request(path: String, uid: String?, series: String?, attempts: Int) -> DICOMwebRetrieveRequest {
        var request = DICOMwebRetrieveRequest(path: path, uid: uid, series: series)
        request.attempts = attempts
        return request
    }
}
'''

DRIVER = harness_defaults.SWIFT + harness_defaults.DOMAINS + r'''
import Foundation
import IsiXDICOMNetwork

func show(_ value: Any?) -> String { value.map { "\($0)" } ?? "nil" }
var line = 0
func out(_ key: String, _ value: Any?) { line += 1; print("\(line) \(key)\t\(show(value))") }

// The in-memory Keychain of the WADO credential.
var keychain: [String: Data] = [:]
DICOMwebCredentials.backend = DICOMwebCredentials.Backend(
    read: { id, wantData in keychain[id].map { (wantData ? $0 : nil, nil) } },
    add: { id, data, _ in keychain[id] = data },
    update: { id, data, _ in
        guard keychain[id] != nil else { return false }
        if let data { keychain[id] = data }
        return true
    },
    delete: { id in keychain[id] = nil })

// --- the WADO query manifest ---
let folder = CommandLine.arguments[1]
for (name, xml) in [
    ("plain", "<wado_query wadoURL=\"http://h:8080/wado\"><Patient><Study StudyInstanceUID=\"1.2\"><Series SeriesInstanceUID=\"1.2.3\"><Instance SOPInstanceUID=\"1.2.3.4\"/><Instance SOPInstanceUID=\"1.2.3.5\"/></Series><Series SeriesInstanceUID=\"1.2.4\"><Instance SOPInstanceUID=\"1.2.4.1\"/></Series></Study></Patient></wado_query>"),
    ("repeated", "<wado_query wadoURL=\"https://pacs/w\"><Study StudyInstanceUID=\"9\"><Series SeriesInstanceUID=\"9.1\"><Instance SOPInstanceUID=\"9.1.1\"/><Instance SOPInstanceUID=\"9.1.1\"/></Series></Study><Study StudyInstanceUID=\"9\"><Series SeriesInstanceUID=\"9.2\"><Instance SOPInstanceUID=\"9.2.1\"/></Series><Series SeriesInstanceUID=\"9.1\"><Instance SOPInstanceUID=\"9.1.2\"/></Series></Study><Study StudyInstanceUID=\"8\"><Series SeriesInstanceUID=\"9.1\"><Instance SOPInstanceUID=\"9.1.1\"/></Series></Study></wado_query>"),
    ("no url", "<wado_query><Study StudyInstanceUID=\"5\"><Series SeriesInstanceUID=\"5.1\"><Instance SOPInstanceUID=\"5.1.1\"/></Series></Study></wado_query>"),
    ("empty", "<wado_query wadoURL=\"http://h/w\"/>"),
    ("broken", "<wado_query wadoURL=\"http://h/w\"><Study StudyInstanceUID=\"1\"><Series SeriesInstanceUID=\"1.1\"><Instance SOPInstanceUID=\"1.1.1\"/>"),
] {
    let path = folder + "/" + name + ".xml"
    try! xml.write(toFile: path, atomically: true, encoding: .utf8)
    let manifest = WADOXML()
    manifest.parseURL(URL(fileURLWithPath: path))
    out("xml \(name) url", manifest.wadoURL)
    out("xml \(name) urls", (manifest.getWADOUrls().map { "\($0)" }).sorted())
    var listed: [String] = []
    for case let (study as String, series as NSDictionary) in manifest.studies ?? NSMutableDictionary() {
        for case let (one as String, instances as NSDictionary) in series {
            for case let instance as String in instances.allKeys { listed.append("\(study)/\(one)/\(instance)") }
        }
    }
    out("xml \(name) studies", listed.sorted())
    manifest.wadoURL = "http://other/w"
    out("xml \(name) urls again", (manifest.getWADOUrls().map { "\($0)" }).sorted())
}
let unread = WADOXML()
unread.parseURL(URL(fileURLWithPath: folder + "/missing.xml"))
out("xml missing", [show(unread.studies), "\(unread.getWADOUrls().count)"])

// --- the WADO credential ---
for (user, password) in [("u", "p"), ("reader", "p@ss:w/rd-ção"), ("", "p"), ("u", ""), ("ü", "ä:ö")] {
    out("basic \(user):\(password)", WADOCredentials.basicAuthorization(username: user, password: password))
}
out("basic nil", WADOCredentials.basicAuthorization(username: nil, password: "p"))
let origins = ["https://pacs/wado", "https://PACS:443/other", "http://pacs/wado", "https://pacs:8443/wado", "https://evil/wado",
               "http://pacs:80/x", "file:///tmp/x"]
for a in origins {
    for b in origins {
        let original = { () -> URLRequest in
            var request = URLRequest(url: URL(string: a)!)
            request.setValue("Basic secret", forHTTPHeaderField: "Authorization")
            return request
        }()
        var next = URLRequest(url: URL(string: b)!)
        next.setValue("stale", forHTTPHeaderField: "Authorization")
        out("redirect \(a) -> \(b)", [WADOCredentials.sameOrigin(URL(string: b)!, URL(string: a)) ? "same" : "other",
                                      show(WADOCredentials.redirect(next, from: original).value(forHTTPHeaderField: "Authorization")),
                                      show(WADOCredentials.redirect(next, from: nil).value(forHTTPHeaderField: "Authorization"))])
    }
}
let saved = NSMutableDictionary(dictionary: ["WADOUsername": "reader", "WADOPassword": "old"])
try! WADOCredentials.save(username: "reader", password: "p@ss:w/rd", in: saved, keepStoredPassword: false)
out("saved keys", (saved.allKeys as! [String]).sorted())
out("saved password", WADOCredentials.password(forServer: saved).password)
out("saved authorization", try? WADOCredentials.authorization(forServer: saved))
out("plain password", WADOCredentials.password(forServer: ["WADOPassword": "plain"]).password)
out("no password", [show(WADOCredentials.password(forServer: [:]).password), "\(WADOCredentials.password(forServer: [:]).unavailable)"])
// Each probe starts from an empty suite: the one of the reference run stays
// in the test's folder with its passwords already moved, and the second
// probe then found nothing left to migrate.
let suiteName = harnessDomainName("dicomweb-rules-equivalence-" + (CommandLine.arguments[0] as NSString).lastPathComponent)
let suite = UserDefaults(suiteName: suiteName)!
suite.removePersistentDomain(forName: suiteName)
suite.set([["WADOUsername": "a", "WADOPassword": "one", "AETitle": "A"], ["WADOPassword": "orphan", "AETitle": "B"],
           ["WADOUsername": "c", "WADOPassword": "", "AETitle": "C"], ["AETitle": "D"], "not a node"] as [Any], forKey: "SERVERS")
out("migrated", WADOCredentials.migrateServers(in: suite))
out("migrated servers", (suite.array(forKey: "SERVERS") ?? []).map { entry -> String in
    guard let node = entry as? [String: Any] else { return show(entry) }
    return node.keys.sorted().map { $0 == "WADOCredential" ? "\($0)=<id>" : "\($0)=\(show(node[$0]))" }.joined(separator: ",")
})
out("migrated again", WADOCredentials.migrateServers(in: suite))

// --- the WADO-URI downloader ---
let wildcard = URL(string: "http://Pacs:8080/wado?requestType=WADO&studyUID=1&objectUID=2&contentType=application/dicom&transferSyntax=*&useOrig=true")!
let other = URL(string: "http://pacs:8080/wado?requestType=WADO&objectUID=3&transferSyntax=*&useOrig=true")!
let elsewhere = URL(string: "https://user:pw@other/wado?objectUID=4&transferSyntax=*&useOrig=true#x")!
let explicit = URL(string: "http://pacs:8080/wado?objectUID=5&transferSyntax=1.2.840.10008.1.2.1")!
let encoded = URL(string: "http://pacs:8080/wado?objectUID=6&transferSyntax=%2A&useOrig=true")!
let urls = [wildcard, other, elsewhere, explicit, encoded]
for url in urls {
    out("wildcard \(url)", [Rules.carriesWildcard(url) ? "carries" : "no", show(Rules.endpoint(url)),
                           Rules.sent(url, pass: false).absoluteString, Rules.sent(url, pass: true).absoluteString])
}
Rules.noteRefusal(wildcard)
for url in urls { out("after refusal \(url)", [Rules.sent(url, pass: false).absoluteString, Rules.sent(url, pass: true).absoluteString]) }
Rules.noteRefusalWithoutWildcard(other)
for url in urls { out("after both \(url)", Rules.sent(url, pass: false).absoluteString) }
out("policy", Rules.policy(urls + [URL(string: "ftp://h/x?transferSyntax=bad%20one")!, URL(fileURLWithPath: "/tmp/x"),
                                   URL(string: "http://h/x?transferSyntax=" + String(repeating: "1", count: 65))!,
                                   URL(string: "http://h/x?transferSyntax=")!, URL(string: "http://h/x?useOrig=false")!]))
out("policy many", Rules.policy((0..<12).map { URL(string: "http://h/x?transferSyntax=1.\($0)")! }))
out("policy none", Rules.policy([]))
out("issues", Rules.issues((0..<30).map { "reason \($0 % 23)" } + ["HTTP 404", "HTTP 404"]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
for code in [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
             NSURLErrorSecureConnectionFailed, NSURLErrorTimedOut, NSURLErrorCancelled, NSURLErrorCannotConnectToHost] {
    for domain in [NSURLErrorDomain, "Other"] {
        let error = NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "described \(code)"])
        out("failure \(domain) \(code)", [show(Rules.untrustedServerReason(error, host: "pacs")), show(Rules.untrustedServerReason(error, host: nil)),
                                          Rules.failureReason(error), "\(Rules.strains(error))"])
    }
}
for (limit, concurrency, timeout, attempts) in [(0, nil, nil, nil), (0, 6, 600, 3), (3, -2, 100, -4), (20, 0, Float.nan, 9), (-1, 2, 240.5, 5)] as [(Int, Int?, Float?, Int?)] {
    let stored: [(String, Any?)] = [("WADOMaximumConcurrentDownloads", concurrency), ("WADOTimeout", timeout), ("WADORetryAttempts", attempts)]
    for (key, value) in stored {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    for adaptive in [false, true] {
        let (c, t, a) = Rules.settings(nodeLimit: limit, adaptive: adaptive)
        out("settings \(limit) \(show(concurrency)) \(show(timeout)) \(show(attempts)) \(adaptive)", [String(c), t.isNaN ? "nan" : String(t), String(a)])
    }
}
let page = URL(string: "http://h/x")!
for (header, length) in [("1234", 9), (" 77xyz", 9), ("-5", 9), ("99999999999999999999", 9), ("abc", 9)] as [(String?, Int)] {
    let response = HTTPURLResponse(url: page, statusCode: 200, httpVersion: nil, headerFields: header.map { ["Content-Length": $0] })!
    out("length \(show(header))", Rules.length(response))
}
out("length http none", Rules.length(HTTPURLResponse(url: page, statusCode: 200, httpVersion: nil, headerFields: [:])!))
for expected in [12, 0, -1] {
    out("length file \(expected)", Rules.length(URLResponse(url: URL(fileURLWithPath: "/tmp/x"), mimeType: nil, expectedContentLength: expected, textEncodingName: nil)))
}
for (name, bytes) in [("dicom", [UInt8](repeating: 0, count: 128) + Array("DICM".utf8) + [1]),
                      ("dicom short", [UInt8](repeating: 0, count: 128) + Array("DICM".utf8)),
                      ("dicom nul", [UInt8](repeating: 0, count: 128) + [68, 73, 0, 77, 1]),
                      ("zip", Array("PK\u{3}\u{4}".utf8) + [UInt8](repeating: 7, count: 200)),
                      ("zip short", Array("PKx".utf8)), ("page", Array("<html>login</html>".utf8)),
                      ("utf8", [0xC3, 0xA9, 0x41]), ("big", [UInt8](repeating: 0, count: 128) + Array("DICM".utf8) + [UInt8](repeating: 9, count: 5000))] {
    let (ext, magic) = Rules.body(NSMutableData(bytes: bytes, length: bytes.count))
    out("body \(name)", [ext, "\(magic)"])
}

// --- the DICOMweb retrieve's requests ---
func request(_ path: String, uid: String? = nil, series: String? = nil, attempts: Int = 0) -> DICOMwebRetrieveRequest {
    Rules.request(path: path, uid: uid, series: series, attempts: attempts)
}
let pendings: [[DICOMwebRetrieveRequest]] = [
    [request("a", series: "s1")],
    [request("a", series: "s1"), request("b", series: "s2"), request("c")],
    [request("a", series: "s3"), request("b", series: "s2"), request("c", series: "s9")],
    [request("a", series: "s9"), request("b", series: "s8")],
    [request("a", uid: "i", series: "s2"), request("b", series: "s2"), request("c", uid: "j", series: "s1")],
]
for (index, pending) in pendings.enumerated() {
    for ordered in [nil, [], ["s2", "s1"], ["s1", "s2", "s3"]] as [[String]?] {
        out("pick \(index) \(show(ordered))", Rules.pick(pending, ordered: ordered))
    }
}
func clientError(_ kind: Int?, _ code: Int, handedOver: Int? = nil, retryAfter: String? = nil, domain: String = "HorosDICOMweb") -> NSError {
    var info: [String: Any] = [:]
    if let kind { info[DICOMwebClient.kindKey] = kind }
    if let handedOver { info[DICOMwebClient.objectsHandedOverKey] = handedOver }
    if let retryAfter { info[DICOMwebClient.retryAfterKey] = retryAfter }
    return NSError(domain: domain, code: code, userInfo: info)
}
var errors: [(String, NSError)] = []
for kind in 0...11 {
    for code in [0, 206, 404, 408, 418, 425, 429, 500, 501, 503, 504] {
        errors.append(("\(kind)/\(code)", clientError(kind, code)))
        errors.append(("\(kind)/\(code)+2", clientError(kind, code, handedOver: 2)))
    }
}
errors.append(("credentials", clientError(nil, 1, domain: "HorosDICOMwebCredentials")))
errors.append(("unknown", clientError(nil, 3)))
errors.append(("bad kind", clientError(99, 503)))
for (name, error) in errors {
    out("facade \(name)", (1...4).map { DICOMwebRetrieveRecovery.action(for: error, attempts: $0).rawValue })
    for target in [request("studies/1"), request("studies/1/series/2", series: "2"), request("i", uid: "u", series: "2")] {
        for attempts in [0, 1, 2] {
            var asked = target
            asked.attempts = attempts
            out("recover \(name) \(target.path) \(attempts)", [show(Rules.recovery(asked, error, taken: [])), show(Rules.recovery(asked, error, taken: ["u"]))])
        }
    }
}
for retryAfter in [nil, "7", " 12 ", "600", "-3", "soon", "1.5"] as [String?] {
    out("delay \(show(retryAfter))", (1...9).map { DICOMwebRetrieveRecovery.delay(beforeAttempt: $0, retryAfter: retryAfter) })
}
for adaptive in [false, true] {
    for outcome in [Outcome.success, .throttled, .transient, .neutral] {
        for attempts in [0, 2, 3, 4] {
            for error in [nil, clientError(9, 503), clientError(9, 503, handedOver: 1), clientError(9, 503, handedOver: 0)] as [NSError?] {
                out("repeat \(adaptive) \(outcome) \(attempts) \(show(error?.userInfo[DICOMwebClient.objectsHandedOverKey]))",
                    Rules.repeats(adaptive: adaptive, outcome: outcome, request: request("p", attempts: attempts), error: error))
            }
        }
    }
}
let asked = [request("studies/s"), request("studies/s/series/a", series: "a"), request("i", uid: "i", series: "a")]
for (study, series) in [("s", ""), ("s", "a"), ("s", "b")] {
    for target in asked {
        for object in [("s", "a", "i"), ("s", "a", "j"), ("t", "a", "i"), ("s", "b", "i"), ("s", "a", ""), (nil, "a", "i"),
                       ("s", nil, "i"), ("s", "a", nil)] as [(String?, String?, String?)] {
            for sources in [[], ["i"], ["x", ""]] as [[String]] {
                for dataset in [Dataset(sources), nil] as [Dataset?] {
                    for seen in [[], ["i"], ["j"]] as [Set<String>] {
                        out("belongs \(study) \(series) \(target.path) \(object) \(sources) \(dataset != nil) \(seen.sorted())",
                            Rules.belongs(study: study, series: series, request: target, dataset: dataset, actualStudy: object.0,
                                          actualSeries: object.1, objectUID: object.2, seen: seen))
                    }
                }
            }
        }
    }
}
'''


def build_and_run(folder, sources, name):
    folder.mkdir()
    (folder / 'main.swift').write_text(DRIVER)
    paths = []
    for file, text in sources:
        (folder / file).write_text(text)
        paths.append(str(folder / file))
    executable = folder / f'dicomweb-rules-{name}'
    built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-name', 'Harness',
                            '-module-cache-path', str(folder / 'module-cache'),
                            *isix_modules.module_flags('IsiXDICOMNetwork', folder / 'modules'),
                            str(folder / 'main.swift'), *paths,
                            *(str(ROOT / 'Horos/Sources' / file) for file in ('DICOMwebCredentials.swift', 'NonInteractiveKeychainRead.swift')),
                            '-o', str(executable)], capture_output=True, text=True, timeout=600)
    if built.returncode:
        print(f'FAIL: the {name} sources do not compile\n{built.stderr[-4000:]}')
        sys.exit(1)
    (folder / 'xml').mkdir()
    run = subprocess.run([str(executable), str(folder / 'xml')], capture_output=True, text=True, timeout=60)
    if run.returncode:
        print(f'FAIL: the {name} driver ended with {run.returncode}\n{run.stderr[-3000:]}')
        sys.exit(1)
    return run.stdout.splitlines()


with tempfile.TemporaryDirectory(prefix='dicomweb-rules-equivalence-') as directory:
    work = Path(directory)
    before = build_and_run(work / 'old', [
        ('Client.swift', CLIENT), ('Rules.swift', OLD_RULES),
        ('WADOXML.swift', old('Horos/Sources/WADOXML.swift')),
        ('WADOCredentials.swift', old('Horos/Sources/WADOCredentials.swift')),
        ('DICOMwebRetrieveRecovery.swift', old('Horos/Sources/DICOMwebRetrieveRecovery.swift')),
    ], 'old')
    after = build_and_run(work / 'new', [
        ('Client.swift', CLIENT), ('Rules.swift', NEW_RULES),
        ('WADOXML.swift', (ROOT / 'Horos/Sources/WADOXML.swift').read_text(encoding='utf-8')),
        ('WADOCredentials.swift', (ROOT / 'Horos/Sources/WADOCredentials.swift').read_text(encoding='utf-8')),
        ('DICOMwebRetrieveRecovery.swift', (ROOT / 'Horos/Sources/DICOMwebRetrieveRecovery.swift').read_text(encoding='utf-8')),
        ('DICOMwebClient+Retrieving.swift', (ROOT / 'Horos/Sources/DICOMwebClient+Retrieving.swift').read_text(encoding='utf-8')),
    ], 'new')

differences = [(a, b) for a, b in zip(before, after) if a != b]
if len(before) != len(after):
    differences.append((f'{len(before)} lines', f'{len(after)} lines'))
for a, b in differences[:20]:
    print(f'FAIL: before {a}\n      after  {b}')
if differences:
    print(f'FAIL: {len(differences)} differences in {len(before)} cases (reference {reference[:12]})')
    sys.exit(1)
if len(before) < 1000:
    print(f'FAIL: only {len(before)} cases ran')
    sys.exit(1)
print(f'PASS: {len(before)} cases decide the same before ({reference[:12]}) and after: manifest, credential, '
      'wildcard, policy, reasons, settings, answers, order, recovery, automatic repeats, objects')
