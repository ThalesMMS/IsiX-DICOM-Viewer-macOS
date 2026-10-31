#!/usr/bin/env python3
"""Execute the host's real series load under deterministic replacement/cancel races.

Only the pixels, the viewer and its UI callbacks are doubles. The series load
(ViewerSeriesLoad.swift: the loading state, the start, the acceptance and
delivery of a result, the cancellation and the close), the loader
(SeriesImageLoader.swift: the actor on its own queue, the in-order and the
concurrent decode, the opening content bounds) and the waits of
ViewerController+StudyNavigation.swift (the façades -isEverythingLoaded and
-checkEverythingLoaded, and the ViewerLoadingWait there that answers and
waits) are taken as they stand and compiled with swiftc,
with OpeningContentBounds.swift, ObservedThread.swift, DeferredCalls.swift,
IdentityToken.swift, the @try of ViewerController+ImagePipelineSupport.swift
and the real HorosObjCException, against IsiXImaging and IsiXPreferences.
Swift concurrency, the loader's queue, the decoders and main-actor delivery
are real. The probes hold an in-flight decode; they never alter the
production methods.

Of ViewerSeriesLoad.swift only its first part is compiled: the second, from
"// MARK: - The series shown", gives the viewer a series and needs the whole
viewer. The post of the viewer's notifications (postViewerNotification, in
ViewerController+RetrieveAndView.swift) is taken as the double posts it.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import objc_exception_guards
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import isix_modules
import sources

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--series-load', type=Path, default=ROOT/'Horos/Sources/ViewerSeriesLoad.swift')
parser.add_argument('--loader', type=Path, default=ROOT/'Horos/Sources/SeriesImageLoader.swift')
parser.add_argument('--study-source', type=Path, default=sources.source_path('ViewerController+StudyNavigation'))
parser.add_argument('--support-source', type=Path, default=sources.source_path('ViewerController+ImagePipelineSupport'))
parser.add_argument('--case')
args = parser.parse_args()

series_load = args.series_load.read_text(encoding='utf-8')
MARK = '// MARK: - The series shown'
assert MARK in series_load, 'ViewerSeriesLoad.swift no longer separates the load from the series shown'
series_load = series_load[:series_load.index(MARK)]
study = args.study_source.read_text(encoding='utf-8')
support = args.support_source.read_text(encoding='utf-8')

# The loader is an actor on a queue of its own, and the load does not run on a thread of its own.
loader = args.loader.read_text(encoding='utf-8')
assert re.search(r'\nactor SeriesImageLoader \{', loader), 'SeriesImageLoader is not an actor'
assert 'DispatchSerialQueue(label: "Load Image Data"' in loader and 'queue.asUnownedSerialExecutor()' in loader
assert 'Thread(target:' not in series_load + loader, 'the series load starts a thread of its own again'
assert 'await loader.load(request)' in series_load and 'checkLoad(from:' not in loader
for needed in ('NSLog("start loading")', 'NSLog("end loading: %f [s]"'):
    assert needed in loader, f'the loader no longer logs {needed}: tools/measure-native-series-load.py reads it'


def study_method(pattern):
    return re.search(pattern + r'.*?\n    }\n', study, re.S).group(0)


# The façades go into the viewer's double; the wait, with the members it
# answers and waits with, is a type of its own over the viewer.
waits = study_method(r'    @objc\(isEverythingLoaded\)') + study_method(r'    @objc\(checkEverythingLoaded\)')
wait_start = study.index('@MainActor struct ViewerLoadingWait {')
wait_type = (study[wait_start:study.index('\n', wait_start) + 1] + '    let viewer: ViewerController\n\n'
             + study_method(r'    /// Whether every image is loaded:') + study_method(r'    /// Waits, with a progress window,')
             + study_method(r'    /// Whether the loading thread is still to finish') + '}\n')
try_helper = (lambda found: found.group(0) if found else objc_exception_guards.source(log=False))(re.search(r'\n/// Runs `body` as an @try block.*?\nfunc viewerObjCTry.*?\n}\n', support, re.S))

doubles = r'''
import AppKit
import IsiXPreferences

// The pixels: a probe holds the decode of every slice that shares it.
final class Probe: @unchecked Sendable {
    let gate = NSCondition()
    var released = false, compressed = false
    var entered = 0, decoded = 0, wrongOrigin = 0
    var origin: Thread?

    func decode(from thread: Thread?) {
        gate.lock()
        if let thread, let origin, thread !== origin { wrongOrigin += 1 }
        entered += 1; gate.broadcast()
        while !released { gate.wait() }
        decoded += 1; gate.unlock()
    }
    func waitForEntry() {
        gate.lock(); let deadline = Date(timeIntervalSinceNow: 5)
        while entered == 0 && gate.wait(until: deadline) {}
        let entered = self.entered; gate.unlock()
        check(entered > 0, "no decode began")
    }
    func resume() { gate.lock(); released = true; gate.broadcast(); gate.unlock() }
    var counts: (entered: Int, decoded: Int, wrongOrigin: Int) { gate.lock(); defer { gate.unlock() }; return (entered, decoded, wrongOrigin) }
}

final class DCMPix: NSObject, @unchecked Sendable {
    let probe: Probe
    var contentProbe: Probe?
    var shutterEnabled = false
    var maxValueOfSeries: Float = 0, minValueOfSeries: Float = 0
    var isRGB = false
    var pixelRatio: Double = 1
    var rescaleType: String? = nil
    var modalityString: String? = "CT"
    var pwidth: Int { 32 }
    var pheight: Int { 32 }
    var srcFile: String? { probe.compressed ? "compressed" : "plain" }
    nonisolated(unsafe) private static let pixels = UnsafeMutablePointer<Float>.allocate(capacity: 32 * 32)
    var fImage: UnsafeMutablePointer<Float>! { contentProbe?.decode(from: nil); return DCMPix.pixels }
    init(probe: Probe) { self.probe = probe }
    func isLoaded() -> Bool { true }
    func checkLoad() { probe.decode(from: nil) }
}

enum DicomFile {
    @discardableResult
    static func isDICOMFile(_ file: String?, compressed: UnsafeMutablePointer<ObjCBool>) -> Bool {
        compressed.pointee = ObjCBool(file == "compressed"); return true
    }
}
enum BrowserController {
    static func isItCD(_ path: String?) -> Bool { false }
}
func _N2LogExceptionImpl(_ exception: NSException, _ logStack: Bool, _ place: UnsafePointer<CChar>) { NSLog("%@", exception) }
// The viewer's notifications, posted as ViewerController+RetrieveAndView.swift posts them.
func postViewerNotification(_ name: Notification.Name, _ object: Any?, _ userInfo: [AnyHashable: Any]? = nil) {
    NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
}

func check(_ value: Bool, _ message: String) {
    if !value { FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!); exit(1) }
}

// The "Data loading..." panel -checkEverythingLoaded shows while it waits.
final class Wait: NSObject {
    init?(string: String?) {}
    func showWindow(_ sender: Any?) {}
    func increment(by delta: Double) {}
    func close() {}
}

final class ViewStub: NSObject {
    func updatePresentationStateFromSeries() {}
    func setStartWLWW() {}
    func display() {}
}

struct HarnessGraph { let preferences: any PreferenceStore }
final class HarnessImageViews { let openingScaleToFit = DeferredCalls() }

// On the main actor, as the app's ViewerController is by its AppKit superclass.
@MainActor public final class ViewerController: NSObject {
    let loadingState = ViewerLoadingState()
    let imageViewsState = HarnessImageViews()
    var sessionGraph: HarnessGraph! = HarnessGraph(preferences: MemoryPreferences())
    nonisolated(unsafe) var pixLists: [NSMutableArray?] = [nil, nil]
    var volumes: [NSObject?] = [NSData(), NSData()]
    nonisolated(unsafe) var horos_maxMovieIndex: Int16 = 1
    var horos_openingScaleToFitRequested = false
    var horos_openingContentBoundsByPixels: [AnyHashable: Any]?
    var horos_imageView: ViewStub? = ViewStub()
    var horos_originalOrientation: Int16 = 0
    var horos_enableSubtraction = false
    var horos_subCtrlMinMaxComputed = false
    var horos_blending: ViewerController?
    var window: ViewStub? { horos_imageView }
    var orientations = 0, intervals = 0

    nonisolated func horos_pixList(at index: Int) -> NSMutableArray? { pixLists[index] }
    func horos_volumeData(at index: Int) -> NSObject? { volumes[index] }
    func setWindowTitle(_ sender: Any?) { check(Thread.isMainThread, "title off the main thread") }
    func subtractionUnavailableReason() -> String? { "not XA" }
    func enableSubtraction() {}
    func convertPETtoSUV() {}
    func setShutterOnOffButton(_ sender: NSNumber?) {}
    func computeIntervalAsync() {}
    func computeInterval() -> Bool { intervals += 1; return true }
    func finishOpeningScaleToFit() {}
    func computeOriginalOrientation() -> Double { check(Thread.isMainThread, "geometry off the main thread"); orientations += 1; return 0 }
'''

driver = r'''
}

@MainActor var notices = 0
@MainActor var reentrantReplacement: SeriesLoadHandle?

func pixels(_ probe: Probe, _ count: Int) -> NSMutableArray {
    let array = NSMutableArray()
    for _ in 0..<count { array.add(DCMPix(probe: probe)) }
    return array
}

func waitFinished(_ thread: Thread?) {
    let until = Date(timeIntervalSinceNow: 5)
    while !(thread?.isFinished ?? true) && until.timeIntervalSinceNow > 0 { Thread.sleep(forTimeInterval: 0.005) }
    check(thread?.isFinished ?? true, "the load did not end")
}

/// Runs the main run loop a moment: the main actor's jobs and the deferred calls run.
@MainActor func drainMain() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
}

@MainActor func resumeLater(_ probe: Probe, after milliseconds: Int) {
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { probe.resume() }
}

extension SeriesLoadRequest {
    /// A request for `lists` under `handle`: the result of a load the viewer
    /// may no longer await.
    init(lists: [NSMutableArray], handle: SeriesLoadHandle) {
        self.lists = lists
        frames = lists.map { $0.compactMap { $0 as? DCMPix } }
        volumes = []
        computeOpeningContentBounds = false
        progress = handle.loadProgress
        observedLoad = ObservedThread(handle)
    }
}

/// A result for `viewer`'s current lists, or for `lists`, under `handle`.
@MainActor func result(_ viewer: ViewerController, lists: [NSMutableArray]? = nil, handle: SeriesLoadHandle) -> SeriesLoadResult {
    let lists = lists ?? (0..<Int(viewer.horos_maxMovieIndex)).compactMap { viewer.pixLists[$0] }
    return SeriesLoadResult(request: SeriesLoadRequest(lists: lists, handle: handle), openingContentBounds: [0: .zero])
}

/// An obsolete result is refused: the pending load, the content bounds, the
/// geometry and the announcement stay as they were.
@MainActor func staleCase(_ name: String) {
    let v = ViewerController(); let probe = Probe()
    let first = pixels(probe, 2), second = pixels(probe, 2)
    v.pixLists[0] = second
    v.horosSeriesLoad.start()
    let current = v.loadingState.load!
    probe.waitForEntry()
    let cache: [AnyHashable: Any] = ["sentinel": 1]
    v.horos_openingContentBoundsByPixels = cache
    var stale: SeriesLoadResult
    switch name {
    case "restart-same-pixels":
        stale = result(v, handle: SeriesLoadHandle())
    case "changed-timepoint":
        v.horos_maxMovieIndex = 2; v.pixLists[1] = second
        stale = result(v, lists: [second, first], handle: current)
    case "closed":
        stale = result(v, handle: current); v.horos_windowWillClose = true
    case "cancelled":
        stale = result(v, handle: current); current.cancel()
    default:
        stale = result(v, lists: [first], handle: SeriesLoadHandle())
    }
    v.horosSeriesLoad.deliver(stale)
    check(v.loadingState.load === current, "obsolete result detached the current load")
    check(v.horos_openingContentBoundsByPixels?["sentinel"] != nil, "obsolete result replaced current series content bounds")
    if name != "cancelled" { check(!current.isCancelled, "obsolete result cancelled the replacement load") }
    check(notices == 0, "obsolete result announced a loaded volume")
    check(v.orientations == 0, "obsolete result recomputed viewer geometry")
    current.cancel(); probe.resume(); waitFinished(current)
}

/// A load replaced while it decodes stops at the slice it is decoding, and
/// its decodes never borrow the replacement's handle.
@MainActor func workerCase(compressed: Bool) {
    let v = ViewerController(); let a = Probe(); a.compressed = compressed
    v.horos_maxMovieIndex = 2
    v.pixLists[0] = pixels(a, 64); v.pixLists[1] = pixels(a, 64)
    v.horosSeriesLoad.start()
    let old = v.loadingState.load!
    a.waitForEntry()
    let b = Probe()
    v.pixLists[0] = pixels(b, 2); v.pixLists[1] = pixels(b, 2)
    v.horosSeriesLoad.start()
    let replacement = v.loadingState.load!
    check(old.isCancelled, "the replaced load was not cancelled")
    a.resume(); waitFinished(old); drainMain()
    b.waitForEntry()
    check(v.loadingState.load === replacement && !replacement.isCancelled, "cancelled load disturbed its replacement")
    check(notices == 0 && v.orientations == 0, "cancelled load delivered UI/geometry effects")
    let counts = a.counts
    check(counts.decoded < 128, "cancelled load decoded the entire old volume")
    if !compressed { check(counts.decoded == 1, "in-order cancellation crossed a slice/timepoint boundary") }
    replacement.cancel(); b.resume(); waitFinished(replacement)
}

@MainActor func validCase(compressed: Bool) {
    let v = ViewerController(); let p = Probe(); p.compressed = compressed; p.resume()
    v.pixLists[0] = pixels(p, 8)
    v.horosSeriesLoad.start()
    let load = v.loadingState.load
    waitFinished(load); drainMain()
    check(p.counts.decoded == 8, "valid load did not decode all slices")
    check(notices == 1 && v.loadingState.load == nil, "valid load did not finish exactly once")
    check(v.orientations == 1, "the delivery did not compute the geometry once")
    check(v.horosSeriesLoad.state == .completed, "the delivered load is not completed")
}

@MainActor func contentCancellationCase() {
    let v = ViewerController(); let decode = Probe(), content = Probe(); decode.resume()
    let store = MemoryPreferences(); store.set(true, for: ViewerPreferences.scaleToFitOnOpen)
    v.sessionGraph = HarnessGraph(preferences: store)
    let array = pixels(decode, 64)
    for case let pix as DCMPix in array { pix.contentProbe = content }
    v.pixLists[0] = array
    v.horosSeriesLoad.start()
    let old = v.loadingState.load!
    content.waitForEntry()
    check(decode.counts.decoded == 64, "content analysis started before decoding finished")
    let parked = Probe()
    v.pixLists[0] = pixels(parked, 2)
    v.horosSeriesLoad.start()
    let replacement = v.loadingState.load!
    content.resume(); waitFinished(old); drainMain()
    check(v.loadingState.load === replacement && !replacement.isCancelled, "content cancellation disturbed replacement")
    check(notices == 0 && v.horos_openingContentBoundsByPixels == nil, "cancelled content reached the viewer")
    check(content.counts.decoded <= 4, "cancelled analysis continued beyond in-flight reads")
    replacement.cancel(); parked.resume(); waitFinished(replacement)
}

/// The load an observer of the announcement starts is not cancelled.
@MainActor func reentrantCase() {
    let v = ViewerController(); let p = Probe(); p.resume()
    v.pixLists[0] = pixels(p, 2)
    let replacement = SeriesLoadHandle()
    reentrantReplacement = replacement
    let observer = NotificationCenter.default.addObserver(forName: .OsirixViewerControllerDidLoadImages, object: v, queue: nil) { _ in
        MainActor.assumeIsolated { v.loadingState.load = reentrantReplacement }
    }
    v.horosSeriesLoad.start()
    waitFinished(v.loadingState.load); drainMain()
    check(v.loadingState.load === replacement && !replacement.isCancelled, "delivery cancelled the load started by its notification observer")
    check(notices == 1, "accepted result did not announce exactly once")
    NotificationCenter.default.removeObserver(observer)
}

/// Closing while a decode is in flight waits for the loader, delivers
/// nothing, and no load starts after.
@MainActor func closeCase() {
    let v = ViewerController(); let p = Probe()
    v.pixLists[0] = pixels(p, 8)
    v.horosSeriesLoad.start()
    let load = v.loadingState.load!
    check(v.horosSeriesLoad.state == .loading, "the started load is not loading")
    p.waitForEntry()
    resumeLater(p, after: 100)
    v.horosSeriesLoad.requestCancel()
    v.horosSeriesLoad.close()
    check(load.isCancelled && !load.isExecuting && load.isFinished, "close returned before the loader left")
    check(v.loadingState.load == nil && v.horosSeriesLoad.state == .closed, "close left a pending load")
    drainMain()
    check(notices == 0 && v.orientations == 0, "a closed viewer received its load")
    v.horosSeriesLoad.start()
    check(v.loadingState.load == nil, "a load started after the close")
}

@MainActor func cancelledCase() {
    let v = ViewerController(); let p = Probe()
    v.pixLists[0] = pixels(p, 2)
    v.horosSeriesLoad.start()
    let load = v.loadingState.load!
    p.waitForEntry()
    v.horosSeriesLoad.cancel()
    check(load.isCancelled && v.loadingState.load == nil && v.horosSeriesLoad.state == .cancelled, "cancel left the load pending")
    v.horosSeriesLoad.deliver(result(v, handle: load))
    check(notices == 0 && v.orientations == 0, "a cancelled load was delivered")
    p.resume(); waitFinished(load); drainMain()
    check(notices == 0, "a cancelled load announced its volume")
}

/// A load asked about in the same pass that started it, before the loader has
/// begun: it is pending, and waiting for it waits.
@MainActor func queriedAtStartCase() {
    let v = ViewerController(); let p = Probe()
    v.pixLists[0] = pixels(p, 4)
    v.horosSeriesLoad.start()
    let load = v.loadingState.load
    check(!v.isEverythingLoaded(), "a load that has just been started reads as loaded")
    resumeLater(p, after: 200)
    v.checkEverythingLoaded()
    check(load?.isFinished ?? false, "the wait for a load that had just been started did not wait")
    check(p.counts.decoded == 4 && v.intervals == 1, "the awaited load did not decode its images")
    check(v.isEverythingLoaded(), "a finished load does not read as loaded")
    drainMain()
    check(v.loadingState.load == nil && v.isEverythingLoaded(), "a delivered load does not read as loaded")

    // A load being cancelled is not waited for, just started or not.
    let w = ViewerController(); let q = Probe()
    w.pixLists[0] = pixels(q, 4)
    w.horosSeriesLoad.start()
    let cancelled = w.loadingState.load
    w.horosSeriesLoad.requestCancel()
    let asked = Date()
    w.checkEverythingLoaded()
    check(-asked.timeIntervalSinceNow < 1 && w.intervals == 0, "a load being cancelled was waited for")
    q.resume(); waitFinished(cancelled); drainMain()
}

@main struct Check {
    @MainActor static func main() {
        let name = CommandLine.arguments[1]
        let observer = NotificationCenter.default.addObserver(forName: .OsirixViewerControllerDidLoadImages, object: nil, queue: nil) { _ in
            check(Thread.isMainThread, "the load was announced off the main thread")
            MainActor.assumeIsolated { notices += 1 }
        }
        switch name {
        case "worker-plain": workerCase(compressed: false)
        case "worker-compressed": workerCase(compressed: true)
        case "valid-plain": validCase(compressed: false)
        case "valid-compressed": validCase(compressed: true)
        case "content-cancelled": contentCancellationCase()
        case "reentrant": reentrantCase()
        case "close-during-load": closeCase()
        case "cancelled-load": cancelledCase()
        case "queried-at-start": queriedAtStartCase()
        default: staleCase(name)
        }
        NotificationCenter.default.removeObserver(observer)
        print("PASS: \(name)")
    }
}

extension Notification.Name {
    static let OsirixViewerControllerDidLoadImages = Notification.Name("OsirixViewerControllerDidLoadImagesNotification")
}
'''

cases = ['stale-series', 'restart-same-pixels', 'changed-timepoint', 'closed', 'cancelled', 'worker-plain', 'worker-compressed',
         'valid-plain', 'valid-compressed', 'content-cancelled', 'reentrant', 'close-during-load', 'cancelled-load', 'queried-at-start']
if args.case:
    assert args.case in cases
    cases = [args.case]
with tempfile.TemporaryDirectory(prefix='horos-loader-lifetime-') as tmp:
    folder = Path(tmp)
    target = ['-target', 'arm64-apple-macos15.0']
    flags = isix_modules.module_flags('IsiXImaging', folder / 'modules', target)
    flags += [flag for flag in isix_modules.module_flags('IsiXPreferences', folder / 'modules', target) if flag not in flags]
    (folder/'Harness.h').write_text('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n#include "HorosContentBounds.h"\n')
    (folder/'Check.swift').write_text(doubles + waits + driver + try_helper + wait_type)
    (folder/'Load.swift').write_text(series_load)
    include = ['-I', str(ROOT/'Horos/Sources')]
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', *target, *include, str(ROOT/'Horos/Sources/HorosObjCException.m'),
                    '-o', str(folder/'HorosObjCException.o')], check=True)
    service = [str(ROOT/'Horos/Sources'/name) for name in ('ObservedThread.swift', 'OpeningContentBounds.swift', 'DeferredCalls.swift',
                                                           'IdentityToken.swift')]
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-g', *target, *include, *flags,
                    '-import-objc-header', str(folder/'Harness.h'),
                    str(folder/'Check.swift'), str(folder/'Load.swift'), str(args.loader), *service,
                    str(folder/'HorosObjCException.o'), '-framework', 'AppKit', '-o', str(folder/'check')], check=True)
    failed = []
    for case in cases:
        result = subprocess.run([str(folder/'check'), case], timeout=30)
        if result.returncode:
            failed.append(case)
    if failed:
        raise SystemExit('FAIL: ' + ', '.join(failed))
print(f'PASS: {len(cases)} host series load lifetime scenarios')
