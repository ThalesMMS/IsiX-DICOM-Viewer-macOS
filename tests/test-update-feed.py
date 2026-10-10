#!/usr/bin/env python3
"""Exercise the production Swift client with controlled URLSession responses.

A release has an arm64 and an x86_64 archive. The client picks by hardware:
Apple Silicon, also an x86_64 copy under Rosetta, takes arm64; an Intel Mac
takes x86_64 and never the older top-level keys, which name the arm64 archive
for the copies installed before the two packages.
"""
from pathlib import Path
import hashlib, json, plistlib, shutil, struct, subprocess, tempfile, ssl, threading, zipfile
from http.server import BaseHTTPRequestHandler
root = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(root / 'tools'))
from local_http import ThreadingLocalHTTPServer  # a fixture binds without the DNS
code = r'''
import Foundation
final class FeedProtocol: URLProtocol {
    static var responses: [String: (Int, Data?, NSError?)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result = Self.responses[request.url!.path]!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            if let error = result.2 { self.client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = result.1 { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
func plist(_ object: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [FeedProtocol.self]
let session = URLSession(configuration: configuration)
let errors = [NSURLErrorServerCertificateUntrusted, NSURLErrorNotConnectedToInternet,
              NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorSecureConnectionFailed]
FeedProtocol.responses = [
 "/valid": (200, plist(["Horos":"12345"]), nil),
 "/http": (503, Data(), nil),
 "/html": (200, Data("<html>unavailable</html>".utf8), nil),
 "/missing": (200, plist(["Other":"12"]), nil),
 "/array": (200, plist(["123"]), nil),
 "/number": (200, plist(["Horos":123]), nil),
 "/junk": (200, plist(["Horos":"123junk"]), nil),
 "/overflow": (200, plist(["Horos":"99999999999999999999999"]), nil),
 "/zero": (200, plist(["Horos":"0"]), nil),
 "/negative": (200, plist(["Horos":"-10"]), nil),
 "/large": (200, Data(repeating: 0, count: 1_048_577), nil)
]
for e in errors { FeedProtocol.responses["/error\(e)"] = (0, nil, NSError(domain: NSURLErrorDomain, code: e)) }
var pending = FeedProtocol.responses.count + 1
var messages: [String:String] = [:]
var heartbeat = false
DispatchQueue.main.async { heartbeat = true }
let start = Date()
for path in FeedProtocol.responses.keys {
    UpdateFeedClient.check(url: URL(string:"https://fixture.invalid\(path)")!, session: session) { version, error in
        precondition(Thread.isMainThread && heartbeat)
        if path == "/valid" { precondition(version == "12345" && error == nil) }
        else { precondition(version == nil && error != nil); messages[path] = UpdateFeedClient.message(for:error!) }
        pending -= 1
    }
}
UpdateFeedClient.check(url: URL(string:"http://fixture.invalid/not-requested")!, session: session) { version, error in
 precondition(Thread.isMainThread && version == nil && error != nil)
 precondition(UpdateFeedClient.message(for:error!).contains("HTTPS"))
 pending -= 1
}
precondition(Date().timeIntervalSince(start) < 0.5, "network start must return without waiting")
let deadline = Date().addingTimeInterval(10)
while pending > 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(pending == 0)
let distinct = ["/http", "/html"] + errors.map { "/error\($0)" }
precondition(Set(distinct.map { messages[$0]! }).count == distinct.count)
precondition(messages["/http"]!.contains("503"))
for path in ["/missing", "/array", "/number", "/junk", "/overflow", "/zero", "/negative", "/large"] {
 precondition(messages[path] == messages["/html"])
}
let summary = UpdateFeedClient.summary(installedVersion: "4.0.0", build: "20201201", availableBuild: "20191217")
precondition(summary.contains("4.0.0 (build 20201201)") && summary.contains("20191217"))
precondition(summary.contains("Channel: ThalesMMS/IsiX-DICOM-Viewer-macOS (stable releases).") && summary.hasSuffix("20191217."))
precondition(!summary.contains("comparison uses build numbers") && !summary.contains("ThalesMMS/horos"))
session.invalidateAndCancel()
print("PASS: asynchronous concurrent responses, main-thread delivery, TLS/offline/HTTP/timeout/DNS distinctions, strict plist validation and HTTPS requirement")

// The archive is offered only as an asset of this fork's releases, with a size and a digest.
let asset = "https://github.com/ThalesMMS/horos/releases/download/v1/Horos.zip"
let digest = String(repeating: "ab", count: 32)
let whole: [String: Any] = ["Horos": "2026100200", "Version": "4.0.0", "MinimumSystemVersion": "26.1",
                            "ArchiveURL": asset, "ArchiveSize": 1234, "ArchiveSHA256": digest]
let release = UpdateRelease(feed: whole)!
precondition(release.archive == UpdateRelease.Archive(url: URL(string: asset)!, size: 1234, sha256: digest))
precondition(release.version == "4.0.0" && release.minimumSystemVersion?.majorVersion == 26 && release.minimumSystemVersion?.minorVersion == 1)
precondition(release.isNewer(than: "20220801") && release.isNewer(than: nil) && release.isNewer(than: "junk"))
precondition(!release.isNewer(than: "2026100200") && !release.isNewer(than: "2026100201"))
precondition(UpdateRelease(feed: ["Horos": "2026100200"])!.archive == nil)
let rejected: [[String: Any]] = [
    ["ArchiveURL": "http://github.com/ThalesMMS/horos/releases/download/v1/Horos.zip"],
    ["ArchiveURL": "https://github.com/Other/horos/releases/download/v1/Horos.zip"],
    ["ArchiveURL": "https://github.com.example.org/ThalesMMS/horos/releases/download/v1/Horos.zip"],
    ["ArchiveURL": "https://github.com/ThalesMMS/horos/releases/download/v1/../../../../Other/x.zip"],
    ["ArchiveURL": "https://github.com/ThalesMMS/horos/releases/download/v1/%2e%2e/x.zip"],
    ["ArchiveURL": asset + "?download=1"],
    ["ArchiveURL": "https://github.com/ThalesMMS/horos/releases/download/v1/Horos.dmg"],
    ["ArchiveURL": 7],
    ["ArchiveSize": 0], ["ArchiveSize": -5], ["ArchiveSize": (4 << 30) + 1], ["ArchiveSize": "1234"],
    ["ArchiveSHA256": String(repeating: "AB", count: 32)], ["ArchiveSHA256": String(repeating: "ab", count: 31)],
    ["ArchiveSHA256": String(repeating: "zz", count: 32)],
]
for change in rejected {
    let partial = UpdateRelease(feed: whole.merging(change) { $1 })!
    precondition(partial.build == "2026100200" && partial.archive == nil, "accepted \(change)")
}
precondition(UpdateRelease(feed: whole.merging(["MinimumSystemVersion": "26.x"]) { $1 })!.minimumSystemVersion == nil)
precondition(UpdateFeedClient.stableFeedURL.absoluteString == "https://github.com/ThalesMMS/horos/releases/latest/download/stable.plist")
print("PASS: release archive accepted only as an HTTPS asset of this fork with positive size and lowercase SHA-256; build comparison by integer")

// One archive per slice, chosen by the hardware and never by the process.
func entry(_ name: String, _ size: Int, _ digest: String) -> [String: Any] {
    ["Archive": name, "ArchiveURL": "https://github.com/ThalesMMS/horos/releases/download/v2/" + name,
     "ArchiveSize": size, "ArchiveSHA256": digest]
}
let armEntry = entry("Horos-arm64.zip", 100, String(repeating: "aa", count: 32))
let intelEntry = entry("Horos-x86_64.zip", 200, String(repeating: "bb", count: 32))
let both: [String: Any] = ["Horos": "2026100700", "Architectures": ["arm64", "x86_64"],
                           "Archives": ["arm64": armEntry, "x86_64": intelEntry]].merging(armEntry) { $1 }
let onAppleSilicon = UpdateRelease(feed: both, hardware: "arm64")!
precondition(onAppleSilicon.archive?.url.lastPathComponent == "Horos-arm64.zip" && onAppleSilicon.archive?.size == 100)
let onIntel = UpdateRelease(feed: both, hardware: "x86_64")!
precondition(onIntel.archive?.url.lastPathComponent == "Horos-x86_64.zip" && onIntel.archive?.size == 200)
precondition(onIntel.archives.count == 2 && onAppleSilicon.archives == onIntel.archives)
// The hardware this Mac reports; the process slice does not enter the choice.
var translated: Int32 = 0
var translatedSize = MemoryLayout<Int32>.size
let underRosetta = sysctlbyname("sysctl.proc_translated", &translated, &translatedSize, nil, 0) == 0 && translated == 1
var appleSiliconHardware: Int32 = 0
var hardwareSize = MemoryLayout<Int32>.size
let isAppleSilicon = sysctlbyname("hw.optional.arm64", &appleSiliconHardware, &hardwareSize, nil, 0) == 0 && appleSiliconHardware == 1
precondition(UpdateRelease.hardwareArchitecture == (isAppleSilicon ? "arm64" : "x86_64"))
#if arch(x86_64)
if underRosetta {
    precondition(UpdateRelease.hardwareArchitecture == "arm64", "an x86_64 copy under Rosetta must see Apple Silicon")
    precondition(UpdateRelease(feed: both)!.archive?.url.lastPathComponent == "Horos-arm64.zip",
                 "an x86_64 copy under Rosetta must be offered the arm64 archive")
}
#endif
precondition(UpdateRelease(feed: both)!.archive == UpdateRelease(feed: both, hardware: UpdateRelease.hardwareArchitecture)!.archive)
// A feed written before the two packages: Apple Silicon keeps its archive, Intel gets none.
let olderFeed: [String: Any] = ["Horos": "2026100700"].merging(armEntry) { $1 }
precondition(UpdateRelease(feed: olderFeed, hardware: "arm64")!.archive?.url.lastPathComponent == "Horos-arm64.zip")
precondition(UpdateRelease(feed: olderFeed, hardware: "x86_64")!.archive == nil, "an Intel Mac took the arm64 archive")
// Without its own valid entry, an Intel Mac knows the release but cannot download it.
for broken in [["arm64": armEntry],
               ["arm64": armEntry, "x86_64": entry("Horos-x86_64.dmg", 200, String(repeating: "bb", count: 32))],
               ["arm64": armEntry, "x86_64": intelEntry.merging(["ArchiveURL": "https://example.org/Horos-x86_64.zip"]) { $1 }],
               ["arm64": armEntry, "x86_64": "Horos-x86_64.zip"]] as [[String: Any]] {
    let partial = UpdateRelease(feed: both.merging(["Archives": broken]) { $1 }, hardware: "x86_64")!
    precondition(partial.build == "2026100700" && partial.archive == nil, "Intel accepted \(broken)")
}
// An Apple Silicon Mac falls back on the older keys only for its own slice.
let legacyOnly = UpdateRelease(feed: both.merging(["Archives": ["x86_64": intelEntry]]) { $1 }, hardware: "arm64")!
precondition(legacyOnly.archive?.url.lastPathComponent == "Horos-arm64.zip")
print("PASS: archives by slice; Apple Silicon\(underRosetta ? " (this process under Rosetta)" : "") takes arm64, Intel takes x86_64 and never the arm64 keys")

// The feed the release script writes is the feed this client reads.
if CommandLine.arguments.count > 1 {
    let generated = NSDictionary(contentsOfFile: CommandLine.arguments[1]) as! [String: Any]
    let expected = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: [String: Any]]
    func check(_ archive: UpdateRelease.Archive?, _ slice: String) {
        let wanted = expected[slice]!
        precondition(archive?.url.absoluteString == "https://github.com/ThalesMMS/horos/releases/download/v4.0.0-test/" + (wanted["name"] as! String))
        precondition(archive?.size == (wanted["size"] as! NSNumber).int64Value && archive?.sha256 == wanted["sha256"] as? String)
    }
    for hardware in ["arm64", "x86_64"] {
        let published = UpdateRelease(feed: generated, hardware: hardware)!
        precondition(published.build == "2026100203" && published.version == "4.0.0")
        precondition(published.minimumSystemVersion?.majorVersion == 26)
        check(published.archive, hardware)
    }
    // A copy installed before the two packages reads only the older keys: the arm64 archive.
    let legacy = UpdateRelease(feed: generated.filter { $0.key != "Archives" }, hardware: "arm64")!
    check(legacy.archive, "arm64")
    precondition(generated["Architectures"] as? [String] == ["arm64", "x86_64"] && generated["ReleaseTag"] as? String == "v4.0.0-test")
    print("PASS: stable.plist written from the two release archives gives arm64 to Apple Silicon and to older copies, x86_64 to Intel")
}
'''
with tempfile.TemporaryDirectory(prefix='horos-update-feed-') as directory:
    p = Path(directory)
    (p/'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', str(root/'Horos/Sources/UpdateFeedClient.swift'), str(p/'main.swift'), '-o', str(p/'test')], check=True)
    # Synthetic release archives: one application each, with a Mach-O header of one slice.
    def release_zip(name, cpus, build='2026100203'):
        archive = p / name
        if len(cpus) == 1:
            header = struct.pack('<II', 0xfeedfacf, cpus[0]) + bytes(24)
        else:
            header = struct.pack('>II', 0xcafebabe, len(cpus)) + b''.join(struct.pack('>IIIII', cpu, 0, 0, 0, 0) for cpu in cpus)
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('IsiX DICOM Viewer.app/Contents/Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'thalesmms.isis.workstation', 'CFBundleExecutable': 'IsiX DICOM Viewer',
                'CFBundleVersion': build, 'CFBundleShortVersionString': '4.0.0', 'LSMinimumSystemVersion': '26.0'}))
            bundle.writestr('IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer', header)
            bundle.writestr('IsiX DICOM Viewer.app/Contents/PlugIns/Nested.app/Contents/Info.plist', plistlib.dumps({}))
        return archive
    arm = release_zip('Horos-4.0.0-test-arm64.zip', [0x0100000c])
    intel = release_zip('Horos-4.0.0-test-x86_64.zip', [0x01000007])
    tool = [sys.executable, str(root/'script/release-metadata.py'), '--update-feed']
    subprocess.run(tool + ['v4.0.0-test', str(root), str(intel), str(arm)], check=True, stdout=subprocess.DEVNULL)
    feed = plistlib.loads((p/'stable.plist').read_bytes())
    assert feed['ArchiveURL'].endswith('/' + arm.name) and feed['ArchiveSize'] == arm.stat().st_size, feed
    assert feed['ArchiveSHA256'] == hashlib.sha256(arm.read_bytes()).hexdigest()
    assert sorted(feed['Archives']) == ['arm64', 'x86_64'] and feed['Archives']['x86_64']['Archive'] == intel.name
    expected = {slice_: {'name': archive.name, 'size': archive.stat().st_size,
                         'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
                for slice_, archive in (('arm64', arm), ('x86_64', intel))}
    (p/'expected.json').write_text(json.dumps(expected))
    # Refused: a bad tag, an empty zip, two archives of one slice, a universal
    # application, an x86_64 archive alone, and archives of different builds.
    refusals = [(['v4.0.0 test', arm], 'tag'), (['v4.0.0-test', p/'empty.zip'], 'zip'),
                (['v4.0.0-test', arm, release_zip('Horos-again-arm64.zip', [0x0100000c])], 'two archives hold the arm64'),
                (['v4.0.0-test', release_zip('Horos-universal.zip', [0x0100000c, 0x01000007])], 'single slice'),
                (['v4.0.0-test', intel], 'needs its arm64 archive'),
                (['v4.0.0-test', arm, release_zip('Horos-other-x86_64.zip', [0x01000007], build='2026100204')], 'CFBundleVersion')]
    (p/'empty.zip').write_bytes(b'')
    for arguments, reason in refusals:
        refused = subprocess.run(tool + [str(arguments[0]), str(root)] + [str(a) for a in arguments[1:]],
                                 capture_output=True, text=True)
        assert refused.returncode != 0 and (reason in refused.stderr or reason in ('tag', 'zip')), (reason, refused.stderr)
    # An arm64 archive alone still writes a feed, for Apple Silicon only.
    single = Path(tempfile.mkdtemp(dir=p))
    shutil.copy(arm, single / arm.name)
    subprocess.run(tool + ['v4.0.0-test', str(root), str(single / arm.name)], check=True, stdout=subprocess.DEVNULL)
    alone = plistlib.loads((single / 'stable.plist').read_bytes())
    assert alone['Architectures'] == ['arm64'] and list(alone['Archives']) == ['arm64'], alone
    subprocess.run([str(p/'test'), str(p/'stable.plist'), str(p/'expected.json')], check=True)
    # The same client as an x86_64 copy: under Rosetta it must still see Apple Silicon.
    subprocess.run(['xcrun', 'swiftc', '-target', 'x86_64-apple-macos26.0', str(root/'Horos/Sources/UpdateFeedClient.swift'),
                    str(p/'main.swift'), '-o', str(p/'test-x86_64')], check=True)
    if subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0:
        subprocess.run([str(p/'test-x86_64'), str(p/'stable.plist'), str(p/'expected.json')], check=True, timeout=60)
    else:
        print('note: the x86_64 client compiled; this Mac cannot run x86_64 code, so the Rosetta case was not run')

# Exercise the production URLSession (including default certificate validation),
# not the injected protocol, against an untrusted loopback HTTPS endpoint.
with tempfile.TemporaryDirectory(prefix='horos-update-tls-') as directory:
    p = Path(directory)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-keyout', str(p/'key.pem'), '-out', str(p/'cert.pem')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'not reached with an untrusted certificate')
        def log_message(self, *args):
            pass
    server = ThreadingLocalHTTPServer(('127.0.0.1', 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(p/'cert.pem'), str(p/'key.pem'))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (p/'main.swift').write_text(r'''import Foundation
var done = false
UpdateFeedClient.check(url: URL(string: CommandLine.arguments[1])!) { version, error in
    precondition(Thread.isMainThread && version == nil)
    let error = error!
    precondition(error.domain == NSURLErrorDomain && error.code == NSURLErrorServerCertificateUntrusted, "Unexpected TLS error: \(error)")
    precondition(UpdateFeedClient.message(for: error).contains("certificate could not be verified"))
    done = true
}
let deadline = Date().addingTimeInterval(15)
while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
precondition(done)
print("PASS: real loopback HTTPS certificate rejected by the production session")
''')
    try:
        subprocess.run(['xcrun', 'swiftc', str(root/'Horos/Sources/UpdateFeedClient.swift'), str(p/'main.swift'), '-o', str(p/'test')], check=True)
        subprocess.run([str(p/'test'), f'https://127.0.0.1:{server.server_port}/feed'], check=True, timeout=20)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
