#!/usr/bin/env python3
"""DICOM send makes one batch per patient, always lets its controller go, and shares its global slots under a lock.

SendController.swift is compiled as it is, with MutableArrayCategory.swift
and the real HorosObjCException, over doubles for the rest: DCMTKStoreSCU
records the files of each run and the patient name its operation queue
carries, and never opens a connection; ThreadsManager starts the thread it
is given. Each case runs in a process of its own and waits, spinning the main
run loop, for every controller to be released, which is what
-releaseSelfWhenDone: does once the send unlocks `_lock`.

- batches: three patients, interleaved. The former loop compared each image
  with a previous patient UID that started nil and was only set on a change;
  -compare:options: sent to nil answered NSOrderedSame, so every image went
  in one batch under the last patient's name. One batch per patient, each
  under its own name.
- filtered-patient: the first patient has only ROI SR images, filtered out
  with sendROIs off, the second has images. The emptied batch must not stop
  the next one (the former -addObject: of a nil name raised, and the
  exception dropped the patients after it).
- unnamed: a study without a name. -addObject: of the nil name raised: the
  images were not sent and the controller never let go.
- all-filtered: nothing left after the ROI filter. No -sendDICOMFilesOffis:
  ran to unlock `_lock`: the thread in -releaseSelfWhenDone: waited forever
  and the controller leaked. It must be released, with nothing sent.
- empty: -sendToNode:objects: with no objects; the same leak.
- concurrent: eight sends at once, with MaximumSendGlobalControllerConcurrentThreads
  at 4. The former counter, without a lock, also counted the sends waiting
  for their turn: once four were waiting and none running, each saw the
  others and all waited forever. All eight must be sent, never more than
  three at a time (a send starts when none runs or when it makes fewer than
  the maximum, as before), and every controller released.
- dicomweb: a DICOMweb node as the destination. Its files, all
  patients together, go to the STOW-RS send on the activity thread, and none
  to DCMTKStoreSCU or the direct transfer; the controller is released.
- tsan: the concurrent case under ThreadSanitizer, which must report no data
  race in SendController.swift. Skipped, not failed, when the toolchain
  cannot build with -sanitize=thread.

`<git revision>` as an optional argument reads SendController.swift from
that revision, the negative control.
"""
from pathlib import Path
import subprocess
import signal
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/SendController.swift'
source = (subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
          if revision else (root / path).read_text())

doubles = r'''
import AppKit

/// What the doubles saw, across threads.
enum Recorder {
    static let lock = NSLock()
    static var batches: [[String]] = []
    static var queueNames: [String] = []
    static var running = 0
    static var maxRunning = 0
    static var storeDelay: TimeInterval = 0
}

final class HorosAlertPanel: NSObject {
    static func run(title: String?, message: String?, defaultButton: String?, alternateButton: String?, otherButton: String?) {}
    static func runCritical(title: String?, message: String?, defaultButton: String?, alternateButton: String?, otherButton: String?) {}
}

extension UserDefaults {
    class func defaultAETitle() -> String { return "HARNESS" }
}

// NSUserDefaultsController+N2.
extension NSUserDefaultsController {
    func addObserver(_ observer: NSObject, forValuesKey key: String, options: NSKeyValueObservingOptions, context: UnsafeMutableRawPointer?) {
        addObserver(observer, forKeyPath: "values." + key, options: options, context: context)
    }
    func removeObserver(_ observer: NSObject, forValuesKey key: String) {
        removeObserver(observer, forKeyPath: "values." + key)
    }
}

final class DCMNetServiceDelegate: NSObject {
    class func dicomServersListSendOnly(_ sendOnly: Bool, qrOnly: Bool) -> [Any]? { return [] }
}

// DICOMwebIntegration.swift and DICOMwebSendActivity.swift: a node is
// DICOMweb when its dictionary names one; its send is recorded.
final class DICOMwebSources: NSObject {
    static func sendDestinations() -> [[String: Any]] { return [] }
    static func isDICOMwebServer(_ server: [AnyHashable: Any]?) -> Bool { return server?["DICOMwebNode"] != nil }
    static func storeURL(forServer server: [AnyHashable: Any]?) -> String { return "" }
}

final class DICOMwebSendActivity: NSObject {
    static var sends: [(files: [String], node: String, activity: Bool)] = []
    static func send(files: [String], patientName: String?, to server: [AnyHashable: Any]?, thread: Thread) {
        Recorder.lock.lock()
        sends.append((files, server?["DICOMwebNode"] as? String ?? "", thread === Thread.current && thread.supportsCancel))
        Recorder.lock.unlock()
    }
}

enum SendWhatFilter {
    static func resolvedIndex(_ requested: Int, hasKeyImages: Bool, hasSecondaryCaptures: Bool) -> Int { return 0 }
}

struct TransferSyntaxCodes { var rawValue: UInt32 }
let SendExplicitLittleEndian = TransferSyntaxCodes(rawValue: 0)

final class ThreadsManager: NSObject {
    static let shared = ThreadsManager()
    class func `default`() -> ThreadsManager! { return shared }
    func addThreadAndStart(_ thread: Thread!) { thread.start() }
}

// NSThread+N2: progress, status and supportsCancel, by associated objects.
private var progressKey = 0, statusKey = 0, cancelKey = 0
extension Thread {
    @objc var progress: CGFloat {
        get { return (objc_getAssociatedObject(self, &progressKey) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
        set { objc_setAssociatedObject(self, &progressKey, NSNumber(value: Double(newValue)), .OBJC_ASSOCIATION_RETAIN) }
    }
    @objc var status: String? {
        get { return objc_getAssociatedObject(self, &statusKey) as? String }
        set { objc_setAssociatedObject(self, &statusKey, newValue, .OBJC_ASSOCIATION_COPY) }
    }
    @objc var supportsCancel: Bool {
        get { return (objc_getAssociatedObject(self, &cancelKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &cancelKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN) }
    }
}

final class DirectTransferPolicy: NSObject {
    static let routeDirect = "direct"
    static func route(server: [String: Any], destinationChosen: Bool, authorized: Bool) -> String { return "dicom" }
}

final class DirectTransferService: NSObject {
    static let shared = DirectTransferService()
    func send(files: [String], toHost host: String, port: Int, token: String, activityThread: Thread?) -> Bool { return false }
}

final class DCMTKStoreSCU: NSObject {
    let files: [String]

    init?(callingAET: String?, calledAET: String?, hostname: String?, port: Int32, filesToSend: [Any]?,
          transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        files = (filesToSend as? [String]) ?? []
        super.init()
    }

    func run(_ operation: Operation!) {
        Recorder.lock.lock()
        Recorder.batches.append(files)
        Recorder.queueNames.append(OperationQueue.current?.name ?? "?")
        Recorder.running += 1
        Recorder.maxRunning = max(Recorder.maxRunning, Recorder.running)
        let delay = Recorder.storeDelay
        Recorder.lock.unlock()

        Thread.sleep(forTimeInterval: delay)

        Recorder.lock.lock()
        Recorder.running -= 1
        Recorder.lock.unlock()
    }
}
'''

driver = r'''
import AppKit

final class Study: NSObject {
    @objc var patientUID: String?
    @objc var name: String?
    init(_ uid: String?, _ name: String?) { patientUID = uid; self.name = name }
}

final class Series: NSObject {
    @objc var study: Study
    @objc var name: String?
    @objc var id: String?
    init(_ study: Study, _ name: String?, _ id: String?) { self.study = study; self.name = name; self.id = id }
}

final class Image: NSObject {
    @objc var series: Series
    @objc var completePath: String
    @objc var completePathResolved: String
    @objc var isKeyImage = false
    @objc var modality = "CT"
    init(_ series: Series, _ path: String) { self.series = series; completePath = path; completePathResolved = path }
}

func images(_ study: Study, _ seriesName: String?, _ seriesID: String?, _ paths: [String]) -> [Image] {
    let series = Series(study, seriesName, seriesID)
    return paths.map { Image(series, $0) }
}

let node: NSDictionary = ["AETitle": "NOWHERE", "Address": "127.0.0.1", "Port": 1, "Description": "harness"]

UserDefaults.standard.register(defaults: [
    "sendROIs": false,
    "SendControllerConcurrentThreads": 1,
    "MaximumSendControllerConcurrentThreads": 4,
    "MaximumSendGlobalControllerConcurrentThreads": 4,
    "syntaxListOffis": 0,
    "lastSendServer": 0,
    "lastSendWhat": 0,
])

/// What -sendFiles:toNode: does, without writing sendROIs and
/// syntaxListOffis to the user defaults.
func send(_ objects: [Image]) {
    let controller = SendController(files: objects)
    _ = Unmanaged.passRetained(controller) // released when the send ends
    controller.sendToNode(node, objects: objects)
}

/// Spins the main run loop until every controller has been released.
func released(within seconds: TimeInterval) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        if SendController.sendControllerObjects() == 0 { return true }
    }
    return false
}

func finish(_ ok: Bool, _ detail: String) -> Never {
    print("\(ok ? "ok" : "wrong") \(detail)")
    exit(ok ? 0 : 1)
}

func recorded() -> ([[String]], [String], Int) {
    Recorder.lock.lock(); defer { Recorder.lock.unlock() }
    return (Recorder.batches, Recorder.queueNames, Recorder.maxRunning)
}

let which = CommandLine.arguments[1]
switch which {
case "batches":
    let alpha = Study("P1", "Alpha"), beta = Study("P2", "Beta"), gamma = Study("P3", "Gamma")
    let a = images(alpha, "CT", "1", ["/a1", "/a2", "/a3"])
    let b = images(beta, "CT", "1", ["/b1", "/b2"])
    let g = images(gamma, "CT", "1", ["/g1"])
    send([b[0], a[0], g[0], a[1], b[1], a[2]])
    let done = released(within: 10)
    let (batches, names, _) = recorded()
    let got = zip(names, batches).map { "\($0): \($1.sorted())" }.sorted()
    let expected = ["Sending... Alpha: [\"/a1\", \"/a2\", \"/a3\"]",
                    "Sending... Beta: [\"/b1\", \"/b2\"]",
                    "Sending... Gamma: [\"/g1\"]"]
    finish(done && got == expected, "released=\(done) \(got)")
case "filtered-patient":
    let alpha = Study("P1", "Alpha"), beta = Study("P2", "Beta")
    send(images(alpha, "OsiriX ROI SR", "5002", ["/a-roi"]) + images(beta, "CT", "1", ["/b1", "/b2"]))
    let done = released(within: 10)
    let (batches, names, _) = recorded()
    finish(done && batches.map { $0.sorted() } == [["/b1", "/b2"]] && names == ["Sending... Beta"],
           "released=\(done) \(names) \(batches)")
case "unnamed":
    send(images(Study("P1", nil), "CT", "1", ["/u1", "/u2"]))
    let done = released(within: 10)
    let (batches, _, _) = recorded()
    finish(done && batches.map { $0.sorted() } == [["/u1", "/u2"]], "released=\(done) \(batches)")
case "all-filtered":
    send(images(Study("P1", "Alpha"), "OsiriX ROI SR", "5002", ["/r1", "/r2"]))
    let done = released(within: 5)
    let (batches, _, _) = recorded()
    finish(done && batches.isEmpty, "released=\(done) sent=\(batches)")
case "empty":
    send([])
    let done = released(within: 5)
    let (batches, _, _) = recorded()
    finish(done && batches.isEmpty, "released=\(done) sent=\(batches)")
case "dicomweb":
    let web: NSDictionary = ["DICOMwebNode": "7B0E1C9A-0000-4000-8000-000000000799", "AETitle": "DICOMweb", "Description": "web",
                             "Address": "https://pacs.example/dicom-web", "retrieveMode": 3]
    let alpha = Study("P1", "Alpha"), beta = Study("P2", "Beta")
    let objects = images(alpha, "CT", "1", ["/w1", "/w2"]) + images(beta, "CT", "1", ["/w3"])
    // In a function, so no global keeps the controller alive.
    func sendToWeb() {
        let controller = SendController(files: objects)
        _ = Unmanaged.passRetained(controller) // released when the send ends
        controller.sendToNode(web, objects: objects)
    }
    sendToWeb()
    let done = released(within: 10)
    let (batches, _, _) = recorded()
    Recorder.lock.lock(); let sends = DICOMwebSendActivity.sends; Recorder.lock.unlock()
    finish(done && batches.isEmpty && sends.count == 1 && sends[0].files.sorted() == ["/w1", "/w2", "/w3"]
           && sends[0].node.hasSuffix("0799") && sends[0].activity,
           "released=\(done) dimse=\(batches) dicomweb=\(sends.map { ($0.files, $0.activity) })")
case "concurrent", "tsan":
    Recorder.storeDelay = 0.3
    for i in 1...8 {
        send(images(Study("P\(i)", "Patient \(i)"), "CT", "1", ["/c\(i)"]))
    }
    let done = released(within: 20)
    let (batches, _, maxRunning) = recorded()
    finish(done && batches.count == 8 && maxRunning <= 3,
           "released=\(done) sent=\(batches.count)/8 at most \(maxRunning) at a time")
default:
    finish(false, "unknown case \(which)")
}
'''

CASES = {
    'batches': 'three interleaved patients go in three batches, each under its own name',
    'filtered-patient': 'a patient emptied by the ROI filter does not stop the next patient\'s batch',
    'unnamed': 'a study without a name is sent and its controller released',
    'all-filtered': 'a selection emptied by the ROI filter releases its controller',
    'empty': 'a send with no objects releases its controller',
    'concurrent': 'eight sends at once all finish, never more than three at a time',
    'dicomweb': 'a DICOMweb destination gets every file by STOW-RS on the activity thread, none by C-STORE',
}

# Exercise the production Objective-C entry point under the app's Swift 6
# isolation rules. The broad batching doubles remain Swift 5 for historical
# behavior controls; this narrow lifecycle probe inherits real AppKit isolation.
release_start = source.index('    @objc(releaseSelfWhenDone:)')
release_end = source.index('\n    @objc(numberFiles)', release_start)
release_method = source[release_start:release_end]
isolation_probe = r"""
import AppKit
import Synchronization
nonisolated enum ReleaseRecorder {
    static let state = Mutex((count: 0, main: true))
}
// Explicit UI isolation reproduces the executor contract observed in the host.
@MainActor final class ReleaseProbe: NSWindowController {
    private let _lock = NSRecursiveLock()
    RELEASE_METHOD
    func begin() {
        _lock.lock()
        Thread.detachNewThreadSelector(#selector(releaseSelfWhenDone(_:)), toTarget: self, with: nil)
    }
    func finish() { _lock.unlock() }
    deinit {
        ReleaseRecorder.state.withLock { $0.count += 1; $0.main = $0.main && Thread.isMainThread }
    }
}
@main struct ReleaseMain {
    @MainActor static func main() {
        for iteration in 0..<16 {
            autoreleasepool {
                let controller = ReleaseProbe(window: nil)
                _ = Unmanaged.passRetained(controller) // Production creator's +1.
                controller.begin()
                Thread.sleep(forTimeInterval: 0.01)
                precondition(ReleaseRecorder.state.withLock { $0.count } == iteration)
                controller.finish()
                let deadline = Date(timeIntervalSinceNow: 0.05)
                while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
            }
            precondition(ReleaseRecorder.state.withLock { $0.count == iteration + 1 && $0.main })
        }
        print("PASS: detached production callback waits and releases exactly once on main")
    }
}
"""

failures = []
skipped = []
with tempfile.TemporaryDirectory(prefix='horos-send-batches-') as tmp:
    p = Path(tmp)
    for name, method in [('isolation-current', release_method),
                         ('isolation-original', release_method.replace('nonisolated public func', 'public func'))]:
        probe = p / (name + '.swift')
        probe.write_text(source.split('import AppKit', 1)[0] + isolation_probe.replace('RELEASE_METHOD', method))
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6',
                                '-strict-concurrency=complete', '-warnings-as-errors',
                                '-enable-actor-data-race-checks',
                                '-parse-as-library', str(probe), '-o', str(p / name)],
                               capture_output=True, text=True)
        if built.returncode:
            print('FAIL: lifecycle Swift 6 compile:', built.stderr)
            sys.exit(1)
        result = subprocess.run([str(p / name)], capture_output=True, text=True, timeout=10)
        if name == 'isolation-current':
            if result.returncode:
                print('FAIL: lifecycle:', result.stdout, result.stderr)
                sys.exit(1)
            print(result.stdout.strip())
        # Darwin's dispatch executor assertion raises SIGTRAP without necessarily
        # writing stderr. The same executable body differs only in isolation.
        elif result.returncode != -signal.SIGTRAP:
            print('FAIL: original callback did not demonstrate actor isolation trap:',
                  result.returncode, result.stdout, result.stderr)
            sys.exit(1)
        else:
            print('ok: original main-actor callback traps on the detached NSThread')

    (p / 'SendController.swift').write_text(source)
    (p / 'MutableArrayCategory.swift').write_text((root / 'Horos/Sources/MutableArrayCategory.swift').read_text())
    (p / 'Doubles.swift').write_text(doubles)
    (p / 'main.swift').write_text(driver)
    (p / 'bridging.h').write_text('#import <Cocoa/Cocoa.h>\n#import "HorosObjCException.h"\n')
    swift_sources = [str(p / name) for name in ('main.swift', 'SendController.swift', 'MutableArrayCategory.swift', 'Doubles.swift')]
    # The main-actor callbacks the controller uses, and the end of its sheet.
    swift_sources.append(str(root / 'Horos/Sources/MainActorCallbacks.swift'))
    swift_sources.append(str(root / 'Nitrogen/Sources/NSWindow+N2.swift'))

    def build(name, sanitize):
        extra = ['-sanitize=thread', '-g'] if sanitize else []
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', *(['-fsanitize=thread'] if sanitize else []),
                        '-I', str(root / 'Horos/Sources'),
                        str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / f'{name}-exception.o')],
                       check=True, capture_output=True)
        subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-swift-version', '5', *extra,
                        '-import-objc-header', str(p / 'bridging.h'), '-I', str(root / 'Horos/Sources'),
                        *swift_sources, str(p / f'{name}-exception.o'), '-o', str(p / name)],
                       check=True, capture_output=True)

    try:
        build('send', False)
    except subprocess.CalledProcessError as e:
        print('FAIL: SendController did not build:', e.stderr.decode(errors='replace')[-3000:])
        sys.exit(1)

    def run(binary, case, timeout=40):
        try:
            return subprocess.run([str(p / binary), case], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired as e:
            return subprocess.CompletedProcess(e.cmd, -1, (e.stdout or b'').decode(errors='replace') if isinstance(e.stdout, bytes) else (e.stdout or ''),
                                               (e.stderr or b'').decode(errors='replace') if isinstance(e.stderr, bytes) else (e.stderr or ''))

    for case, claim in CASES.items():
        result = run('send', case)
        if result.returncode == 0:
            print('ok:', claim)
        else:
            lines = result.stdout.strip().splitlines()
            detail = lines[-1] if lines else (f'timed out' if result.returncode == -1 else f'exit {result.returncode}')
            failures.append(f'{claim}: {detail}')

    claim = 'ThreadSanitizer reports no data race in SendController.swift'
    try:
        build('send-tsan', True)
    except subprocess.CalledProcessError as e:
        skipped.append(f'{claim}: no -sanitize=thread build ({e.stderr.decode(errors="replace").strip().splitlines()[-1:]})')
    else:
        result = run('send-tsan', 'tsan', timeout=60)
        reports = result.stderr.split('WARNING: ThreadSanitizer: ')[1:]
        ours = [r for r in reports if 'SendController.swift' in r or 'globalDCMTKSCUCounter' in r]
        if ours:
            first = next((line.strip() for line in ours[0].splitlines() if 'SendController.swift' in line), '')
            failures.append(f'{claim}: {len(ours)} report(s), first at {first}')
        elif result.returncode != 0:
            lines = result.stdout.strip().splitlines()
            failures.append(f'{claim}: the case did not finish ({lines[-1] if lines else "timed out"})')
        else:
            print('ok:', claim, f'({len(reports)} report(s) elsewhere)' if reports else '')

for item in skipped:
    print('SKIP:', item)
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: one batch per patient, every controller released, global send slots under a lock')
