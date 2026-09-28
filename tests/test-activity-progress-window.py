#!/usr/bin/env python3
"""The activity list keeps a thread started off the main thread, the progress window follows its status and localizes its buttons, and the transfer log saves its last line (#765).

ThreadsManager.swift, ThreadModalForWindowController.swift and LogManager.swift
are compiled as they are, each with HorosObjCException and doubles for what
they call in the rest of the app, and driven as the app drives them:
- threads: -addThreadAndStart: called off the main thread starts the thread
  there and asks the main thread to add it. Until the new thread enters its
  main it is neither executing nor finished, and -subAddThread: started it
  again: -start raised, and the @catch took the thread out of the list. A
  thread whose isExecuting stays NO until the main thread has added it must
  be started once and stay listed until it exits, then leave the list.
- main: the same thread added from the main thread is started there, once,
  and listed until it exits.
- status: the progress window kept NSTextView's live backing string as the
  status it had last sized the box for, so every later status compared equal
  and the box kept the height of the first one. Five lines of status must
  make the box taller than one line, and one line again shorter.
- titles: the initializer set the Cancel and Background titles before the
  nib loaded, on nil outlets, so the English titles of the xib stayed. Run in
  Spanish, with the app's es catalog, the buttons must carry the catalog's
  titles. The window is the en ThreadModalForWindow.xib, compiled with
  ibtool, attached as a sheet to a window off screen.
- log: a transfer that passes a new dictionary for each line. On Complete,
  -addLogLine: saved the dictionary of the line before, still In Progress,
  and the entry stayed so. The entry must say Complete with the final count
  and an end time. The same mutable dictionary filled line after line, as
  the app's own callers do, must give the same entry.

`<git revision>` as an optional argument reads the three sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang, ibtool)', file=sys.stderr)
    sys.exit(SKIPPED)

EXCEPTION_HEADER = '#import <AppKit/AppKit.h>\n#import <CoreData/CoreData.h>\n#import "HorosObjCException.h"\n'

# --- threads -----------------------------------------------------------------

THREADS_DRIVER = r'''
import AppKit

/// A thread that answers isExecuting NO until the harness lets its main go
/// on: the moment between -start and the new thread's main, held open.
final class LateThread: Thread {
    private let lock = NSLock()
    private var _running = false
    private var _starts = 0
    let proceed = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)

    var running: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    var starts: Int { lock.lock(); defer { lock.unlock() }; return _starts }

    override var isExecuting: Bool { running && super.isExecuting }

    override func start() {
        lock.lock(); _starts += 1; lock.unlock()
        super.start()
    }

    override func main() {
        proceed.wait()
        lock.lock(); _running = true; lock.unlock()
        finish.wait()
    }
}

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return done()
}

@main struct Harness {
    static func main() {
        let manager = ThreadsManager.default()!
        let thread = LateThread()
        let listed = { manager.threads().contains(thread) }

        if CommandLine.arguments[1] == "threads" {
            let caller = Thread { manager.addThreadAndStart(thread) }
            caller.start()
            _ = spin(5) { thread.starts >= 1 }
            _ = spin(0.5)   // the main thread's -subAddThread: runs here
        } else {
            manager.addThreadAndStart(thread)
        }
        let listedBefore = listed()
        thread.proceed.signal()
        _ = spin(5) { thread.running }
        let listedRunning = listed()
        thread.finish.signal()
        let removed = spin(5) { !listed() && thread.isFinished }

        let ok = thread.starts == 1 && listedBefore && listedRunning && removed
        print("\(ok ? "ok" : "wrong") starts=\(thread.starts) listed before running=\(listedBefore) while running=\(listedRunning) removed after exit=\(removed)")
        exit(ok ? 0 : 1)
    }
}
'''

# --- progress window ---------------------------------------------------------

PROGRESS_DOUBLES = r'''
import AppKit

// NSThread+N2+CAPI.m and ThreadModalForWindowController+CAPI.m.
public let NSThreadNameKey = "name"
public let NSThreadIsCancelledKey = "isCancelled"
public let NSThreadSupportsCancelKey = "supportsCancel"
public let NSThreadSupportsBackgroundingKey = "supportsBackgrounding"
public let NSThreadStatusKey = "status"
public let NSThreadProgressKey = "progress"
public let NSThreadProgressDetailsKey = "progressDetails"
public let NSThreadModalForWindowControllerKey = "ThreadModalForWindowController"

@objc(N2Debug) public final class N2Debug: NSObject {
    @objc public class func isActive() -> Bool { false }
}

// NSThread (N2): the values in the thread dictionary, notified by KVO.
public extension Thread {
    @objc dynamic var status: String? {
        get { threadDictionary["status"] as? String }
        set { threadDictionary["status"] = newValue }
    }
    @objc dynamic var progressDetails: String? {
        get { threadDictionary["progressDetails"] as? String }
        set { threadDictionary["progressDetails"] = newValue }
    }
    @objc dynamic var progress: CGFloat {
        get { threadDictionary["progress"] as? CGFloat ?? -1 }
        set { threadDictionary["progress"] = newValue }
    }
    @objc var subthreadsAwareProgress: CGFloat { progress }
    @objc dynamic var supportsCancel: Bool {
        get { threadDictionary["supportsCancel"] as? Bool ?? false }
        set { threadDictionary["supportsCancel"] = newValue }
    }
    @objc dynamic var supportsBackgrounding: Bool {
        get { threadDictionary["supportsBackgrounding"] as? Bool ?? false }
        set { threadDictionary["supportsBackgrounding"] = newValue }
    }
    @objc(setIsCancelled:) func setIsCancelled(_ cancelled: Bool) { if cancelled { cancel() } }
}

// NSTextView (N2): one 16-point line per line of text.
public extension NSTextView {
    @objc(optimalSizeForWidth:)
    func optimalSize(forWidth width: CGFloat) -> NSSize {
        NSSize(width: width, height: CGFloat(string.components(separatedBy: "\n").count) * 16)
    }
}
'''

PROGRESS_DRIVER = r'''
import AppKit

@main struct Harness {
    static func main() {
        _ = NSApplication.shared
        let document = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 320),
                                styleMask: [.titled], backing: .buffered, defer: true)
        let thread = Thread { }
        thread.name = "Harness"
        thread.supportsCancel = true
        thread.supportsBackgrounding = true
        let controller = ThreadModalForWindowController(thread: thread, window: document)

        if CommandLine.arguments[1] == "titles" {
            let cancel = NSLocalizedString("Cancel", comment: ""), background = NSLocalizedString("Background", comment: "")
            guard cancel != "Cancel", background != "Background" else {
                print("skipped: the es catalog is not in use (\(cancel), \(background))")
                exit(2)
            }
            let got = (controller.cancelButton?.title ?? "nil", controller.backgroundButton?.title ?? "nil")
            let ok = got.0 == cancel && got.1 == background
            print("\(ok ? "ok" : "wrong") buttons \(got.0) / \(got.1), catalog \(cancel) / \(background)")
            exit(ok ? 0 : 1)
        }

        func height() -> CGFloat { controller.statusFieldScroll.frame.size.height }
        thread.status = "Sending 1 of 4"
        let one = height()
        thread.status = "Sending 2 of 4\nPatient\nStudy\nSeries\nImage"
        let five = height()
        thread.status = "Sending 3 of 4"
        let oneAgain = height()
        let ok = five > one && oneAgain < five && oneAgain == one
        print("\(ok ? "ok" : "wrong") status box height: one line \(one), five lines \(five), one line again \(oneAgain)")
        exit(ok ? 0 : 1)
    }
}
'''

# --- log ---------------------------------------------------------------------

LOG_HEADER = EXCEPTION_HEADER + r'''
extern void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf);

@interface DicomDatabase : NSObject
@property (readonly) NSManagedObjectContext *managedObjectContext;
- (BOOL)isLocal;
- (NSManagedObjectContext *)independentContext;
- (NSArray *)objectsForEntity:(NSEntityDescription *)entity predicate:(NSPredicate *)predicate;
- (NSEntityDescription *)logEntryEntity;
- (id)objectWithID:(id)objectID;  // N2ManagedDatabase.h
@end

@interface BrowserController : NSObject
+ (BrowserController *)currentBrowser;
@property (retain) DicomDatabase *database;
- (BOOL)isNetworkLogsActive;
@end
'''

LOG_DOUBLES = r'''
#import "harness.h"

void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { fprintf(stderr, "exception in %s: %s\n", pf, e.reason.UTF8String); }

static NSAttributeDescription *attribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *a = [NSAttributeDescription new];
    a.name = name; a.attributeType = type; a.optional = YES;
    return a;
}

@implementation DicomDatabase {
    NSManagedObjectContext *_context;
    NSEntityDescription *_logEntry;
}
- (instancetype)init {
    self = [super init];
    _logEntry = [NSEntityDescription new];
    _logEntry.name = @"LogEntry";
    NSMutableArray *attributes = [NSMutableArray array];
    for (NSString *name in @[@"message", @"type", @"originName", @"destinationName", @"patientName", @"studyName"])
        [attributes addObject:attribute(name, NSStringAttributeType)];
    for (NSString *name in @[@"numberImages", @"numberSent", @"numberError"])
        [attributes addObject:attribute(name, NSInteger32AttributeType)];
    for (NSString *name in @[@"startTime", @"endTime"])
        [attributes addObject:attribute(name, NSDateAttributeType)];
    _logEntry.properties = attributes;
    NSManagedObjectModel *model = [NSManagedObjectModel new];
    model.entities = @[_logEntry];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    [coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:NULL];
    _context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    _context.persistentStoreCoordinator = coordinator;
    return self;
}
- (NSManagedObjectContext *)managedObjectContext { return _context; }
- (BOOL)isLocal { return YES; }
- (NSManagedObjectContext *)independentContext { return _context; }
- (NSEntityDescription *)logEntryEntity { return _logEntry; }
- (NSArray *)objectsForEntity:(NSEntityDescription *)entity predicate:(NSPredicate *)predicate {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity.name];
    request.predicate = predicate;
    return [_context executeFetchRequest:request error:NULL];
}
- (id)objectWithID:(id)objectID { return [_context objectWithID:objectID]; }
@end

@implementation BrowserController
+ (BrowserController *)currentBrowser {
    static BrowserController *browser;
    if (!browser) { browser = [BrowserController new]; browser.database = [DicomDatabase new]; }
    return browser;
}
- (BOOL)isNetworkLogsActive { return YES; }
@end
'''

LOG_DRIVER = r'''
import Foundation

@main struct Harness {
    static func main() {
        let manager = LogManager.currentLogManager() as! LogManager
        let database = BrowserController.currentBrowser()!.database!
        let start = Date()
        let common: [String: Any] = ["logType": "Receive", "logStartTime": start, "logCallingAET": "SCU",
                                     "logCalledAET": "HOROS", "logPatientName": "Harness^Patient",
                                     "logStudyDescription": "Study", "logNumberTotal": 3, "logNumberError": 0]

        let uid: String
        if CommandLine.arguments[1] == "new-dictionaries" {
            uid = "transfer-new-dictionaries"
            for (received, message) in [(1, "In Progress"), (2, "In Progress"), (3, "Complete")] {
                var line = common
                line["logUID"] = uid; line["logMessage"] = message; line["logNumberReceived"] = received
                manager.addLogLine(line as NSDictionary)
            }
        } else {
            uid = "transfer-same-dictionary"
            let line = NSMutableDictionary(dictionary: common)
            line["logUID"] = uid
            for (received, message) in [(1, "In Progress"), (2, "In Progress"), (3, "Complete")] {
                line["logMessage"] = message; line["logNumberReceived"] = received
                manager.addLogLine(line)
            }
        }

        let entries = database.objects(forEntity: database.logEntryEntity(), predicate: NSPredicate(value: true)) as? [NSManagedObject] ?? []
        let entry = entries.first
        let message = entry?.value(forKey: "message") as? String ?? "nil"
        let sent = (entry?.value(forKey: "numberSent") as? NSNumber)?.intValue ?? -1
        let ended = entry?.value(forKey: "endTime") != nil
        let ok = entries.count == 1 && message == "Complete" && sent == 3 && ended
        print("\(ok ? "ok" : "wrong") \(entries.count) entry, message \(message), numberSent \(sent), endTime \(ended ? "set" : "missing")")
        exit(ok ? 0 : 1)
    }
}
'''

CASES = [
    ('threads', 'threads', 'a thread added off the main thread is started once and stays listed until it exits'),
    ('threads', 'main', 'a thread added on the main thread is started once and listed until it exits'),
    ('progress', 'status', 'the status box grows with a longer status and shrinks back'),
    ('progress', 'titles', 'the Cancel and Background buttons carry the localized titles'),
    ('log', 'new-dictionaries', 'a transfer logged with a new dictionary per line ends Complete'),
    ('log', 'same-dictionary', 'a transfer logged with one mutable dictionary ends Complete'),
]


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


failures = []
skipped = []
with tempfile.TemporaryDirectory(prefix='horos-activity-progress-') as tmp:
    tmp = Path(tmp)
    exception_o = tmp / 'exception.o'
    for name in ('HorosObjCException.h', 'HorosObjCException.m'):
        shutil.copy(root / 'Horos/Sources' / name, tmp / name)
    (tmp / 'harness.h').write_text(EXCEPTION_HEADER)
    (tmp / 'log.h').write_text(LOG_HEADER)
    builds = {
        'threads': ('Horos/Sources/ThreadsManager.swift', [('driver.swift', THREADS_DRIVER)], 'harness.h', None),
        'progress': ('Horos/Sources/ThreadModalForWindowController.swift',
                     [('doubles.swift', PROGRESS_DOUBLES), ('driver.swift', PROGRESS_DRIVER)], 'harness.h', None),
        'log': ('Horos/Sources/LogManager.swift', [('driver.swift', LOG_DRIVER)], 'log.h', LOG_DOUBLES),
    }
    executables = {}
    try:
        run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-exceptions', '-c',
             str(tmp / 'HorosObjCException.m'), '-o', str(exception_o)])
        for name, (path, swift_files, header, objc) in builds.items():
            folder = tmp / name
            folder.mkdir()
            sources = [folder / Path(path).name]
            sources[0].write_text(source(path))
            for file_name, text in swift_files:
                (folder / file_name).write_text(text)
                sources.append(folder / file_name)
            objects = [str(exception_o)]
            if objc:
                (folder / 'harness.h').write_text((tmp / header).read_text())
                (folder / 'doubles.m').write_text(objc)
                run(['xcrun', 'clang', '-x', 'objective-c', '-fobjc-arc', '-iquote', str(tmp), '-iquote', str(folder),
                     '-c', str(folder / 'doubles.m'), '-o', str(folder / 'doubles.o')])
                objects.append(str(folder / 'doubles.o'))
            run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'Horos',
                 '-import-objc-header', str(tmp / header), '-Xcc', '-iquote', '-Xcc', str(tmp),
                 *map(str, sources), *objects, '-framework', 'AppKit', '-framework', 'CoreData',
                 '-o', str(folder / 'harness')])
            executables[name] = folder / 'harness'
        # The progress window's nib next to the executable, the main bundle of
        # a tool, with the app's es catalog.
        progress = tmp / 'progress'
        xib = 'Horos/Resources/en.lproj/ThreadModalForWindow.xib'
        (progress / 'ThreadModalForWindow.xib').write_bytes(
            subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{xib}']) if revision else (root / xib).read_bytes())
        run(['xcrun', 'ibtool', '--compile', str(progress / 'ThreadModalForWindow.nib'), str(progress / 'ThreadModalForWindow.xib')])
        (progress / 'es.lproj').mkdir()
        shutil.copy(root / 'Horos/Resources/es.lproj/Localizable.strings', progress / 'es.lproj/Localizable.strings')
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    for build, case, claim in CASES:
        command = [str(executables[build]), case]
        if build == 'progress':
            command += ['-AppleLanguages', '(es)']
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        lines = (result.stdout.strip() or result.stderr.strip()).splitlines()
        detail = lines[-1] if lines else f'exit {result.returncode}'
        if result.returncode == 0:
            print('ok:', claim, '-', detail)
        elif result.returncode == SKIPPED:
            skipped.append(f'{claim}: {detail}')
        else:
            failures.append(f'{claim}: {detail}')

for item in skipped:
    print('skipped:', item, file=sys.stderr)
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
if skipped:
    sys.exit(SKIPPED)
print('PASS: threads started off the main thread stay listed, the progress window follows its status in localized buttons, and the log saves the Complete line')
