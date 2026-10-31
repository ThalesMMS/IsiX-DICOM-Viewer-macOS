"""The shared-database server of the app's objects, linked to tools/probe-shared-database-server.m.

tests/test-shared-database-parser.py and tools/measure-shared-database-server.py
both run the application's own server (BonjourPublisher over HorosDatabaseServer)
with the database and the browser replaced by the probe's recorders. This module
gathers the objects and links the probe the same way for both.

Since BonjourPublisher, AppController, DCMTKStoreSCU, BrowserController and
DicomDatabase moved to Swift, the Swift publisher reaches those classes through
their Swift symbols and type metadata accessors, which the probe's Objective-C
stand-ins do not define. The probe is linked with -undefined dynamic_lookup, so a
missing one is no link error: the first request that reaches it jumps to address 0
and the server dies without a word. The stand-ins below define them.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import object_probe  # noqa: E402
sys.path.insert(0, str(ROOT / "tests"))
import sources  # noqa: E402

PROBE_SOURCE = ROOT / "tools/probe-shared-database-server.m"
# HorosDatabaseServer is the current listener; N2Connection and N2ConnectionListener
# the one before, so a revision of BonjourPublisher.m from before it still links.
OBJECTS = ["BonjourPublisher", "N2Connection", "N2ConnectionListener", "N2Locker", "N2Debug", "NSException+N2",
           "SharedDatabaseAuthorization", "SharedDatabaseWire", "SharedDatabaseRequests", "HorosDatabaseServer",
           # The process graph the publisher's connections receive their dependencies from.
           "ProcessGraph",
           # N2ConnectionListener and N2Locker are Swift: the listener's
           # notification constants stay in its +CAPI.o, and it catches
           # Objective-C exceptions through HorosObjCException.
           "N2ConnectionListener+CAPI", "HorosObjCException",
           # The guards the Swift objects name (HorosObjCException.caught,
           # .throwing, .logged...), Swift members of the same class.
           "HorosObjCException+Guards",
           # N2Debug and NSException+N2 are Swift: N2Debug.o defines
           # _N2LogExceptionImpl, which the publisher logs through, and the
           # stack trace message it writes with NSException+N2.o. The variadic
           # C functions stay in N2Debug+CAPI.o: N2LogStackTrace, which the
           # private-queue helper below calls.
           "N2Debug+CAPI"]
# The earlier listener and its connection left the app with their last callers:
# a build without them links the current server alone.
EARLIER_LISTENER = {"N2Connection", "N2ConnectionListener", "N2ConnectionListener+CAPI"}
# The wire rules left the app for IsiXDICOMNetwork, and the process graph came
# with the publisher that reads it: a build has one or the other, and a
# publisher that needs neither links without them.
OPTIONAL = {"SharedDatabaseWire", "ProcessGraph", "HorosObjCException+Guards"}
# The protocol's rules (IsiXDICOMNetwork), built from the module's sources and
# linked statically, as the app links the package's product.
PROTOCOL_MODULE = "IsiXDICOMNetwork"
# The Swift BonjourPublisher.o names HorosBonjourAdvertisement and
# HorosListenBindFailure by their Swift symbols, so their own objects are linked,
# not the probe's stand-ins. A revision's BonjourPublisher.m does not. It also
# calls onMainActor and onMainActorSync, and HistoricalArchive for the archived
# replies, all Swift of module Horos. ProtectedMode, which it asks only when
# sharing is switched on (-toggleSharing:), is left out: the probe starts the
# server itself, and ProtectedMode.o would bring DCMPix with it.
SWIFT_PUBLISHER_OBJECTS = ["BonjourDiscovery", "ListenBindFailure", "MainActorCallbacks", "HistoricalArchive"]

# AppController is Swift, and final: the Swift BonjourPublisher.o calls
# its members by their Swift symbols, which the probe's Objective-C stand-in does
# not define. A Swift stand-in of module Horos defines them; the publisher it
# answers with is the probe's recorder, which BonjourPublisher only hands to
# -detachNewThreadSelector:toTarget:withObject:.
APP_CONTROLLER_STAND_IN = """
import Foundation
@objc(SharedDatabaseProbeAppController) public final class AppController: NSObject {
    private static let instance = AppController()
    private static let publisher: AnyObject? = (NSClassFromString("ProbePublisher") as? NSObject.Type)?.init()
    public class func shared() -> AppController! { return instance }
    public class func uid() -> String! { return nil }
    // The getter's own type is BonjourPublisher, which only the real object defines.
    @_silgen_name("$s5Horos13AppControllerC16bonjourPublisherAA07BonjourE0CSgvg")
    public func bonjourPublisherStandIn() -> AnyObject? { return AppController.publisher }
    public func reportListenBindFailure(forService service: String!, port: Int, errnoCode code: Int32) {}
    // Where ProcessGraph.o finds the stored properties it reads by their field
    // offsets (APP_CONTROLLER_FIELD_OFFSETS): nil, as before the nib loads.
    private var browserWindowSlot: AnyObject? = nil
    private var recentStudiesMenuSlot: AnyObject? = nil
    private var receivingIndicatorSlot: AnyObject? = nil
}
"""
# ProcessGraph.o makes the viewers' registry, caches and sync state, and keeps
# the places of the menus, the window arranger and the DICOM listener it makes
# on first use: their classes, empty, stand in for them, because the real ones
# bring the viewer with them. The server path uses none of them.
PROCESS_GRAPH_MEMBERS_STAND_IN = """
public final class ViewerRegistry { public init() {} }
public final class PresetMenuCache { public init() {} }
public final class ColourTableCache { public init() {} }
public final class ViewerSyncState { public init() {} }
public final class ApplicationMenus {}
public final class ViewerWindowArranger {}
public final class DICOMListenerController {}
"""
# ProcessGraph.o also makes the Notification Center delivery and the PACS
# On-Demand nodes as it is made: their stand-ins keep the initializers, the
# conformance and the defaults it calls, and nothing of the notifications or
# the DCMTK queries the real ones bring.
PROCESS_GRAPH_VALUES_STAND_IN = """
import Foundation
import IsiXDatabase
import IsiXInstallation
import IsiXPreferences
// Public, so that the initializers are exported; ProcessGraph.o asks for the
// initializer's default arguments by their own symbols, which these are.
public final class UserNotificationDelivery {
    public typealias Deliver = @MainActor @Sendable (_ title: String?, _ body: String?, _ kind: String, _ sound: Bool) -> Void
    public nonisolated init(policy: NotificationBurstPolicy, deliver: @escaping Deliver) {}
}
@_silgen_name("$s5Horos24UserNotificationDeliveryC6policy7deliverAC16IsiXInstallation0C11BurstPolicyV_ySSSg_AISSSbtYbScMYcctcfcfA_")
public func probeDefaultNotificationPolicy() -> NotificationBurstPolicy { NotificationBurstPolicy() }
@_silgen_name("$s5Horos24UserNotificationDeliveryC6policy7deliverAC16IsiXInstallation0C11BurstPolicyV_ySSSg_AISSSbtYbScMYcctcfcfA0_")
public func probeDefaultNotificationDelivery() -> UserNotificationDelivery.Deliver { { _, _, _, _ in } }
public struct QueryControllerDistantStudies: DistantStudyQuerying {
    public let preferences: any PreferenceStore
    public init(preferences: any PreferenceStore) { self.preferences = preferences }
    public func studies(matching filters: [String: PropertyListValue], activity: String) async -> [DistantStudySummary] { [] }
    public func patientStudies(of patient: Int, activity: String) async -> [DistantStudySummary] { [] }
}
"""
# ProcessGraph.o reads stored properties of the final AppController directly,
# through the field offsets Swift exports for them. These are those offsets,
# pointing at the stand-in's slots, which the runtime places, so they are read
# from its instance variables once the classes are loaded. The browser's window
# graph, the Recent Studies menu and the Dock's receiving indicator stay nil:
# the server path reads none of them.
APP_CONTROLLER_FIELD_OFFSETS = r"""
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
long ProbeBrowserWindowOffset __asm__("_$s5Horos13AppControllerC13browserWindowAA07BrowserE5GraphCSgvpWvd");
long ProbeRecentStudiesMenuOffset __asm__("_$s5Horos13AppControllerC17recentStudiesMenuSo6NSMenuCSgvpWvd");
long ProbeReceivingIndicatorOffset __asm__("_$s5Horos13AppControllerC18receivingIndicatorAA09ReceivingE0CvpWvd");
long ProbeBrowserWindowOffset, ProbeRecentStudiesMenuOffset, ProbeReceivingIndicatorOffset;
static long ProbeSlot(Class cls, const char *name) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar ? (long)ivar_getOffset(ivar) : 0;
}
__attribute__((constructor)) static void ProbeAppControllerFieldOffsets(void) {
    Class cls = objc_getClass("SharedDatabaseProbeAppController");
    ProbeBrowserWindowOffset = ProbeSlot(cls, "browserWindowSlot");
    ProbeRecentStudiesMenuOffset = ProbeSlot(cls, "recentStudiesMenuSlot");
    ProbeReceivingIndicatorOffset = ProbeSlot(cls, "receivingIndicatorSlot");
}
"""
# DCMTKStoreSCU is Swift too: the publisher builds a send and asks for the
# listener's send syntax by their Swift symbols. The stand-in sends nothing and
# hands the syntax back as it is, like the probe's Objective-C stand-in. A
# publisher that queues a client's send itself, instead of handing it to the
# application's publisher by message, makes the send here: the stand-in
# records it as the probe's publisher records the order it is handed.
STORE_SCU_STAND_IN = """
public final class DCMTKStoreSCU {
    public init(callingAET: String?, calledAET: String?, hostname: String?, port: Int32, filesToSend: [Any]?,
                transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        let todo: [String: Any] = ["AETitle": calledAET ?? NSNull(), "Address": hostname ?? NSNull(),
                                   "Port": String(port), "TransferSyntax": String(transferSyntax),
                                   "Files": filesToSend ?? []]
        let recorder = (NSClassFromString("ProbePublisher") as? NSObject.Type)?.init()
        _ = recorder?.perform(NSSelectorFromString("sendDICOMFilesToOsiriXNode:"), with: todo)
    }
    public func run(_ operation: Operation?) {}
    func sendFiles(_ operation: Operation? = nil) throws {}
    public static func sendSyntax(forListenerSyntax syntax: Int32) -> Int32 { return syntax }
}
// What a send that failed throws, declared as the application declares it.
struct StoreSendFailure: Error {
    let name: String
    let reason: String
    var recorded = true
}
"""
# BrowserController is Swift too: the publisher takes the class from its Swift
# type metadata accessor, then sends it Objective-C messages (+currentBrowser,
# +DefaultFolderSizeForDB, -database, -refreshDatabase:). This class of module
# Horos defines the accessor and answers them as the probe's Objective-C
# stand-in does, with the probe's database recorder (the default one, or the
# other local database HOROS_PROBE_SHOWN_DATABASE names).
BROWSER_STAND_IN = """
@objc(SharedDatabaseProbeBrowserController) public class BrowserController: NSObject {
    private static let instance = BrowserController()
    @objc public dynamic class func currentBrowser() -> BrowserController! { return instance }
    @objc(DefaultFolderSizeForDB) public class func defaultFolderSizeForDB() -> Int32 { return 10000 }
    @objc public dynamic var database: NSObject? {
        return (NSClassFromString("DicomDatabase") as? NSObject.Type)?.perform(NSSelectorFromString("shownDatabase"))?
            .takeUnretainedValue() as? NSObject
    }
    @objc(refreshDatabase:) public func refreshDatabase(_ sender: Any?) {}
}
"""
# DicomDatabase is an Objective-C class implemented in Swift: the publisher's
# casts ask for its type metadata through the accessor that implementation
# exports. The probe's recorder is a plain Objective-C class, and this is the
# accessor Swift emits for one: the runtime's wrapper of the class.
DICOM_DATABASE_METADATA = r"""
#import <Foundation/Foundation.h>
typedef struct { const void *metadata; size_t state; } ProbeMetadataResponse;
extern const void *swift_getObjCClassMetadata(const void *objcClass);
__attribute__((swiftcall)) ProbeMetadataResponse ProbeDicomDatabaseMetadata(size_t request)
    __asm__("_$sSo13DicomDatabaseCMa");
__attribute__((swiftcall)) ProbeMetadataResponse ProbeDicomDatabaseMetadata(size_t request) {
    return (ProbeMetadataResponse){ swift_getObjCClassMetadata((const void *)[NSClassFromString(@"DicomDatabase") self]), 0 };
}
"""


class MissingObject(Exception):
    """An object of the app the probe needs was not built."""

    def __init__(self, name: str, configuration: str, root: Path):
        super().__init__(f"needs a built {name}.o ({configuration}) under {root}")
        self.name = name


def swift_publisher_built() -> bool:
    return sources.is_swift("BonjourPublisher")


def app_objects(configuration: str = "Debug", objects_root: Path = ROOT, swift_publisher: bool = True) -> list[Path]:
    """The app's objects the server is made of, BonjourPublisher.o first."""
    found = []
    for name in OBJECTS + (SWIFT_PUBLISHER_OBJECTS if swift_publisher else []):
        obj = object_probe.app_object(name, configuration, objects_root)
        if obj is None and (name in OPTIONAL or name in EARLIER_LISTENER and swift_publisher):
            continue
        if obj is None:
            raise MissingObject(name, configuration, objects_root)
        found.append(obj)
    return found


def _stand_ins(work: Path) -> list[Path]:
    """The Swift stand-ins and accessor a Swift publisher needs, compiled in `work`."""
    made = []
    if sources.is_swift("DicomDatabase"):
        accessor = work / "DicomDatabaseMetadata.m"
        accessor.write_text(DICOM_DATABASE_METADATA)
        subprocess.run(["xcrun", "clang", "-c", "-fno-objc-arc", str(accessor), "-o", str(work / "DicomDatabaseMetadata.o")],
                       check=True, capture_output=True)
        made.append(work / "DicomDatabaseMetadata.o")
    if sources.is_swift("AppController"):
        stand_in = work / "AppControllerStandIn.swift"
        stand_in.write_text(APP_CONTROLLER_STAND_IN + PROCESS_GRAPH_MEMBERS_STAND_IN +
                            (STORE_SCU_STAND_IN if sources.is_swift("DCMTKStoreSCU") else "") +
                            (BROWSER_STAND_IN if sources.is_swift("BrowserController") else ""))
        # With the module's own NSLog, which the Swift objects call, and the
        # internal module it writes through.
        support = object_probe.module_support_sources()
        flags = object_probe.module_support_flags(support, work / "support", "arm64-apple-macos26.0")
        subprocess.run(["xcrun", "swiftc", "-module-name", "Horos", "-parse-as-library", "-suppress-warnings", "-wmo", "-c",
                        *flags[:2], str(stand_in), *map(str, support),
                        "-o", str(work / "AppControllerStandIn.o")], check=True, capture_output=True)
        made.append(work / "AppControllerStandIn.o")
        values = work / "ProcessGraphValuesStandIn.swift"
        values.write_text(PROCESS_GRAPH_VALUES_STAND_IN)
        modules = work / "ingest-modules"  # linked with the ingest's modules, by link()
        target = ["-target", "arm64-apple-macos26.0"]
        for name in ("IsiXDatabase", "IsiXInstallation", "IsiXPreferences"):
            object_probe.build_internal_module(name, modules, "arm64-apple-macos26.0")
        subprocess.run(["xcrun", "swiftc", "-module-name", "Horos", "-parse-as-library", "-suppress-warnings", "-wmo", "-c",
                        *target, "-I", str(modules), str(values), "-o", str(work / "ProcessGraphValuesStandIn.o")],
                       check=True, capture_output=True)
        made.append(work / "ProcessGraphValuesStandIn.o")
        offsets = work / "AppControllerFieldOffsets.m"
        offsets.write_text(APP_CONTROLLER_FIELD_OFFSETS)
        subprocess.run(["xcrun", "clang", "-c", "-fno-objc-arc", str(offsets), "-o", str(work / "AppControllerFieldOffsets.o")],
                       check=True, capture_output=True)
        made.append(work / "AppControllerFieldOffsets.o")
        made += [work / "support" / f"lib{flag[2:]}.a" for flag in flags if flag.startswith("-l")]
    return made


def _protocol_module(work: Path, optimized: bool) -> list[Path]:
    """The static library of the protocol's module, for a publisher that imports it,
    optimized as the app builds it for a Release publisher."""
    if f"import {PROTOCOL_MODULE}" not in sources.source_text("BonjourPublisher"):
        return []
    import importlib.util
    spec = importlib.util.spec_from_file_location("isix_modules", ROOT / "tests/isix_modules.py")
    isix_modules = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(isix_modules)
    folder = work / ("protocol-module-optimized" if optimized else "protocol-module")
    library = isix_modules.build_module(PROTOCOL_MODULE, folder,
                                        ["-target", "arm64-apple-macos26.0"] + (["-O"] if optimized else []))
    # With the internal modules it depends on, built beside it.
    return [library] + [folder / f"lib{each}.a" for each in isix_modules.dependencies(PROTOCOL_MODULE)]


def _probe_source(work: Path) -> tuple[Path, list[Path]]:
    """The recorder, and the objects it needs, for a Swift publisher.

    Use the production queue adapter. The existing parser recorder remains the
    workload: only its database/context dependencies follow the current
    private-queue contract, rather than bypassing the adapter.
    """
    if 'N2ManagedObjectContextPerformAndWait' not in sources.source_text("BonjourPublisher"):
        return PROBE_SOURCE, []
    managed_source = (ROOT / "Nitrogen/Sources/N2ManagedDatabase+CAPI.m").read_text()
    start = managed_source.index('void N2ManagedObjectContextPerformAndWait(')
    opening = managed_source.index('{', start)
    depth, ending = 1, opening + 1
    while depth:
        depth += (managed_source[ending] == '{') - (managed_source[ending] == '}')
        ending += 1
    helper = work / "ManagedContextQueue.m"
    helper.write_text('#import <CoreData/CoreData.h>\n#import "N2Debug.h"\n' + managed_source[start:ending])
    helper_object = work / "ManagedContextQueue.o"
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks',
                    '-DHOROS_BRIDGING_HEADER', '-I', str(ROOT / 'Nitrogen/Sources'),
                    str(helper), '-o', str(helper_object)], check=True)
    recorder = PROBE_SOURCE.read_text()
    assert '@interface ProbeContext : NSObject @end' in recorder
    recorder = recorder.replace('@interface ProbeContext : NSObject @end',
                                '@interface ProbeContext : NSManagedObjectContext @end')
    recorder = recorder.replace('@implementation ProbeContext\n',
        '@implementation ProbeContext\n- (instancetype)init { return [super initWithConcurrencyType:NSPrivateQueueConcurrencyType]; }\n')
    assert '- (instancetype)independentDatabase { return self; }' in recorder
    recorder = recorder.replace('- (instancetype)independentDatabase { return self; }',
        '- (instancetype)independentDatabase { return self; }\n- (instancetype)privateQueueIndependentDatabase { return self; }')
    patched = work / "probe-shared-database-server.m"
    patched.write_text(recorder)
    return patched, [helper_object]


def link(objects: list[Path], swift_publisher: bool, work: Path, output: Path, optimization: str = "-O1") -> Path:
    """The probe server: `objects` (BonjourPublisher first, as app_objects returns
    them, possibly with a revision's publisher in its place), plus, for a Swift
    publisher, the stand-ins and the recorder that follows the private-queue
    contract. Every intermediate file goes to `work`."""
    work.mkdir(parents=True, exist_ok=True)
    objects = list(objects)
    probe_source = PROBE_SOURCE
    if swift_publisher:
        objects += _stand_ins(work)
        if "DatabaseIngest." in sources.source_text("BonjourPublisher"):
            modules = work / "ingest-modules"
            objects.append(object_probe.ingest_stand_in(work, modules, "arm64-apple-macos26.0"))
            # ProcessGraph.o makes the scheduler of the incoming files.
            object_probe.build_internal_module("IsiXDatabase", modules, "arm64-apple-macos26.0")
            # ... and the worker that reslices the series of the viewers.
            object_probe.build_internal_module("IsiXImaging", modules, "arm64-apple-macos26.0")
            objects += sorted(modules.glob("lib*.a"))
        probe_source, helpers = _probe_source(work)
        objects += helpers
        objects += _protocol_module(work, "/Release/" in str(objects[0]))
    sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run(["xcrun", "clang", "-fno-objc-arc", optimization, "-g0", "-mmacosx-version-min=26.0"] +
                   (["-DHOROS_PROBE_SWIFT_PUBLISHER"] if swift_publisher else []) +
                   [str(probe_source)] + [str(o) for o in objects] +
                   ["-framework", "Cocoa", "-framework", "CoreData", "-framework", "Network", "-lc++",
                    f"-L{sdk}/usr/lib/swift", "-L/usr/lib/swift", "-Wl,-rpath,/usr/lib/swift",
                    "-Wl,-undefined,dynamic_lookup", "-o", str(output)],
                   check=True, capture_output=True)
    return output
