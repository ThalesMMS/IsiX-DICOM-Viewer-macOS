#!/usr/bin/env python3
"""Drive the real alert bridge without presenting UI; preserve 1/0/-1 and button order."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
annotations_source = (root / "Preference Panes/OSICustomImageAnnotations/OSICustomImageAnnotations+CAPI.m").read_text()
annotations_bridges = annotations_source[annotations_source.index("NSInteger CIARunAlertPanel("):]
program = r'''
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "HorosAlertPanel.h"
#include <assert.h>
ANNOTATIONS_BRIDGES
static void check(BOOL value) { if (!value) abort(); }
static NSModalResponse answer;
static NSArray *titles;
static NSAlertStyle style;
static int invocations;
static BOOL deferred;
static void (^pending)(NSModalResponse);
static void inspect(NSAlert *alert) {
    [titles release];
    titles = [[alert.buttons valueForKey:@"title"] copy];
    style = alert.alertStyle;
    check([alert.messageText isEqual:@"Title"]);
    check([alert.informativeText isEqual:@"100% literal %@"]);
    invocations++;
}
// The selected position comes from the driver; AppKit returns the actual
// configured NSButton.tag, not a synthetic NSAlertFirstButtonReturn + position.
static NSModalResponse buttonResponse(NSAlert *alert, NSModalResponse selection) {
    NSInteger index = selection - NSAlertFirstButtonReturn;
    if (index < 0 || index >= (NSInteger)alert.buttons.count) return selection;
    NSButton *button = alert.buttons[index];
    NSInteger expected = [button.title isEqual:@"Other"] ? NSAlertThirdButtonReturn
        : [button.title isEqual:@"Cancel"] ? NSAlertSecondButtonReturn : NSAlertFirstButtonReturn;
    if (button.tag != expected) fprintf(stderr, "SDK button tag %ld, expected %ld\n", (long)button.tag, (long)expected);
    check(button.tag == expected);
    return button.tag;
}
static NSModalResponse run(NSAlert *alert, SEL selector) { inspect(alert); return buttonResponse(alert, answer); }
static void begin(NSAlert *alert, SEL selector, NSWindow *window, void (^completion)(NSModalResponse)) {
    inspect(alert);
    if (deferred) pending = [^(NSModalResponse selection) { completion(buttonResponse(alert, selection)); } copy];
    else completion(buttonResponse(alert, answer));
}
int main(void) { @autoreleasepool {
    method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)run);
    method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(beginSheetModalForWindow:completionHandler:)), (IMP)begin);
    check(HorosAlertPanel.defaultResponse == 1 && HorosAlertPanel.alternateResponse == 0 && HorosAlertPanel.otherResponse == -1);
    for (int index = 0; index < 3; index++) {
        answer = NSAlertFirstButtonReturn + index;
        NSInteger result = [HorosAlertPanel runWithTitle:@"Title" message:@"100% literal %@" defaultButton:@"Confirm" alternateButton:@"Cancel" otherButton:@"Other"];
        check(result == (NSInteger[]){1,0,-1}[index]);
        check([titles isEqual:@[@"Confirm", @"Cancel", @"Other"]]);
        check(style == NSAlertStyleWarning);
        check(CIARunAlertPanel(@"Title", @"100% literal %@", @"Confirm", @"Cancel", @"Other") == (NSInteger[]){1,0,-1}[index]);
        check(style == NSAlertStyleWarning && [titles isEqual:@[@"Confirm", @"Cancel", @"Other"]]);
        check(CIARunInformationalAlertPanel(@"Title", @"100% literal %@", @"Confirm", @"Cancel", @"Other") == (NSInteger[]){1,0,-1}[index]);
        check(style == NSAlertStyleInformational && [titles isEqual:@[@"Confirm", @"Cancel", @"Other"]]);
        __block int callbacks = 0;
        [HorosAlertPanel beginWithTitle:@"Title" message:@"100% literal %@" defaultButton:@"Confirm" alternateButton:@"Cancel" otherButton:@"Other" modalForWindow:(NSWindow *)@"unused" completionHandler:^(NSInteger response) {
            callbacks++; check(response == (NSInteger[]){1,0,-1}[index]);
        }];
        check(callbacks == 1);
    }
    answer = NSAlertSecondButtonReturn;
    check([HorosAlertPanel runInformationalWithTitle:@"Title" message:@"100% literal %@" defaultButton:@"Confirm" alternateButton:nil otherButton:@"Other"] == -1);
    check([titles isEqual:@[@"Confirm", @"Other"]] && style == NSAlertStyleInformational);
    answer = NSModalResponseAbort;
    check([HorosAlertPanel runCriticalWithTitle:@"Title" message:@"100% literal %@" defaultButton:nil alternateButton:nil otherButton:nil] == 0);
    check(titles.count == 1 && style == NSAlertStyleCritical);
    __block int delayedCallbacks = 0;
    deferred = YES;
    @autoreleasepool {
        [HorosAlertPanel beginWithTitle:@"Title" message:@"100% literal %@" defaultButton:@"Confirm" alternateButton:@"Cancel" otherButton:nil modalForWindow:(NSWindow *)@"unused" completionHandler:^(NSInteger response) {
            delayedCallbacks++; check(response == HorosAlertAlternateResponse);
        }];
    }
    check(delayedCallbacks == 0);
    pending(NSAlertSecondButtonReturn);
    [pending release]; pending = nil;
    check(delayedCallbacks == 1);
    deferred = NO;
    [HorosAlertPanel beginWithTitle:@"Title" message:@"100% literal %@" defaultButton:@"Confirm" alternateButton:nil otherButton:nil modalForWindow:(NSWindow *)@"unused" completionHandler:nil];
    check(invocations == 16);
    answer = NSAlertFirstButtonReturn;
    check(HorosRunAlertPanel(@"Title", @"%ld%% %@ %%@", @"Confirm", @"Cancel", @"Other", (long)100, @"literal") == 1);
    check(style == NSAlertStyleWarning && [titles isEqual:@[@"Confirm", @"Cancel", @"Other"]]);
    answer = NSAlertSecondButtonReturn;
    check(HorosRunInformationalAlertPanel(@"Title", @"%@", @"Confirm", nil, @"Other", @"100% literal %@") == -1);
    check(style == NSAlertStyleInformational);
    check(HorosRunCriticalAlertPanel(@"Title", @"%@", @"Confirm", @"Cancel", @"Other", @"100% literal %@") == 0);
    check(style == NSAlertStyleCritical);
    answer = NSModalResponseAbort;
    check(HorosRunAlertPanel(@"Title", @"%@", nil, nil, nil, @"100% literal %@") == 0);
    check(invocations == 20);
    puts("PASS: button order, styles, literal messages, historical responses, abort and one deferred sheet completion after pool drain");
} }
'''
# The SQL rebuild is BrowserController+DatabaseMaintenance.swift.
maintenance = (root / 'Horos/Sources/BrowserController+DatabaseMaintenance.swift').read_text()
def swift_method(signature):
    start = maintenance.index(signature)
    opening = maintenance.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += {'{': 1, '}': -1}.get(maintenance[end], 0)
        end += 1
    return maintenance[start:end]

# -shouldTerminate: is BrowserController+Window.swift; it runs against peers
# with the real alert bridge (HorosAlertPanel.m).
window_source = (root / 'Horos/Sources/BrowserController+Window.swift').read_text()
def window_method(signature):
    start = window_source.index(signature)
    opening = window_source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += {'{': 1, '}': -1}.get(window_source[end], 0)
        end += 1
    return window_source[start:end]

browser_program = r'''
import AppKit
import ObjectiveC
func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }
nonisolated(unsafe) var answer = NSApplication.ModalResponse.alertFirstButtonReturn
nonisolated(unsafe) var threadCount = 0
nonisolated(unsafe) var drainDuringAlert = false
nonisolated(unsafe) var modalCalls = 0
let run: @convention(block) (NSAlert) -> NSApplication.ModalResponse = { alert in
    modalCalls += 1
    MainActor.assumeIsolated {
        check(alert.messageText == "Background Operations", "title")
        check(alert.informativeText.contains("will be cancelled"), "message")
        check(alert.buttons.map { $0.title } == ["Cancel", "Quit"], "buttons")
    }
    if drainDuringAlert { threadCount = 0 }
    return answer
}
method_setImplementation(class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))!, imp_implementationWithBlock(run))
final class NSFullScreenWindow: NSWindow {}
final class DatabasePeer: NSObject {
    var saves = 0
    func save(_ error: Any?) -> Bool { saves += 1; return true }
}
enum ViewerController { static func closeAllWindows() {} }
final class ThreadsManager: NSObject {
    nonisolated(unsafe) static let manager = ThreadsManager()
    static func `default`() -> ThreadsManager? { manager }
    func threadsCount() -> Int { threadCount }
}
enum SendController { static func sendControllerObjects() -> Int { 0 } }
@MainActor final class BrowserPeer: NSObject {
    var horos_databaseIvar: DatabasePeer?
    var detached = 0
    var database: DatabasePeer? {
        get { horos_databaseIvar }
        set { horos_databaseIvar = newValue; if newValue == nil { detached += 1 } }
    }
    @objc func shouldTerminateCallback(_ timer: Timer!) {}
}
extension BrowserPeer {
METHOD
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let database = DatabasePeer()
    let browser = BrowserPeer()
    for scenario in 0..<4 {
        browser.database = database
        threadCount = scenario == 2 ? 0 : 2
        drainDuringAlert = scenario == 3
        answer = scenario == 1 ? .alertSecondButtonReturn : .alertFirstButtonReturn
        let before = browser.detached, calls = modalCalls
        let result = browser.shouldTerminate(nil)
        check(result == (scenario != 0), "result")
        check(browser.detached == before + (scenario != 0 ? 1 : 0), "detached")
        check(modalCalls == calls + (scenario != 2 ? 1 : 0), "asked")
    }
    check(database.saves == 4, "saved")
    print("PASS: actual Browser termination Cancel/Quit/no-threads/drained-thread guards")
}
'''.replace('METHOD', window_method('func shouldTerminate(_ sender: Any!) -> Bool'))

# The rebuild runs in Swift against peers; an Objective-C trampoline catches
# the exception a refused rebuild raises, which Swift cannot.
catch_header = r'''
#import <Foundation/Foundation.h>
NSString *_Nullable CatchException(void (NS_NOESCAPE ^_Nonnull block)(void));
'''
catch_source = r'''
#import "Catch.h"
NSString *CatchException(void (NS_NOESCAPE ^block)(void)) {
    @try { block(); } @catch (NSException *error) { return error.name; }
    return nil;
}
'''
rebuild_program = r'''
import AppKit
import ObjectiveC
func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }
nonisolated(unsafe) var completion: ((NSApplication.ModalResponse) -> Void)?
nonisolated(unsafe) var sheets = 0, modals = 0
nonisolated(unsafe) var answer = NSApplication.ModalResponse.alertFirstButtonReturn
@MainActor func inspect(_ alert: NSAlert) {
    check(alert.alertStyle == .informational, "style")
    check(alert.informativeText.contains("SQL index"), "message")
    check(alert.buttons.map { $0.title } == ["OK", "Cancel"], "buttons")
}
let begin: @convention(block) (NSAlert, NSWindow?, ((NSApplication.ModalResponse) -> Void)?) -> Void = { alert, window, handler in
    MainActor.assumeIsolated { inspect(alert) }; check(window != nil, "a sheet on no window"); sheets += 1; completion = handler
}
let run: @convention(block) (NSAlert) -> NSApplication.ModalResponse = { alert in
    MainActor.assumeIsolated { inspect(alert) }; modals += 1; return answer
}
method_setImplementation(class_getInstanceMethod(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:)))!,
                         imp_implementationWithBlock(begin))
method_setImplementation(class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))!, imp_implementationWithBlock(run))

final class DatabasePeer: NSObject {
    var allowed = true
    func rebuildAllowed() -> Bool { allowed }
}
@MainActor final class BrowserPeer: NSObject {
    var database: DatabasePeer?
    var window: NSWindow?
    var rebuilds = 0
    func initiateRebuildSql() -> Thread! { rebuilds += 1; return nil }
}
extension BrowserPeer {
METHOD
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let database = DatabasePeer()
    let browser = BrowserPeer()
    browser.database = database
    browser.window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn] {
        let before = browser.rebuilds
        browser.rebuildSQLFile(nil)
        check(browser.rebuilds == before && completion != nil, "the rebuild did not wait for the answer")
        completion?(response); completion = nil
        check(browser.rebuilds == before + (response == .alertFirstButtonReturn ? 1 : 0), "only OK rebuilds")
    }
    check(sheets == 3 && modals == 0, "the question is a sheet on the browser window")
    // No window: asked app-modally, as AppKit does for a sheet on no window.
    browser.window = nil
    answer = .alertSecondButtonReturn
    browser.rebuildSQLFile(nil)
    answer = .alertFirstButtonReturn
    browser.rebuildSQLFile(nil)
    check(modals == 2 && browser.rebuilds == 2, "without a window the answer is still asked for and kept")
    database.allowed = false
    let before = sheets + modals
    let raised = CatchException { browser.rebuildSQLFile(nil) }
    check(raised == NSExceptionName.genericException.rawValue && sheets + modals == before, "a refused rebuild asks or does not raise")
    print("PASS: actual Browser rebuild OK-only/deferred/no-window/refusal")
}
'''.replace('METHOD', swift_method('@objc(rebuildSQLFile:)'))

with tempfile.TemporaryDirectory(prefix='horos-alert-responses-') as folder:
    path = Path(folder)
    (path / 'main.m').write_text(program.replace('ANNOTATIONS_BRIDGES', annotations_bridges))
    subprocess.run(['xcrun', 'clang', '-fblocks', '-Werror', '-Wdeprecated-declarations', '-I', str(root / 'Horos/Sources'), str(path / 'main.m'), str(root / 'Horos/Sources/HorosAlertPanel.m'), '-framework', 'AppKit', '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)

    (path / 'browser.swift').write_text(browser_program)
    subprocess.run(['xcrun', 'clang', '-c', '-fblocks', '-I', str(root / 'Horos/Sources'), str(root / 'Horos/Sources/HorosAlertPanel.m'), '-o', str(path / 'HorosAlertPanel.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-import-objc-header', str(root / 'Horos/Sources/HorosAlertPanel.h'), str(path / 'browser.swift'),
                    str(path / 'HorosAlertPanel.o'), '-o', str(path / 'browser')], check=True)
    subprocess.run([str(path / 'browser')], check=True)

    (path / 'Catch.h').write_text(catch_header)
    (path / 'Catch.m').write_text(catch_source)
    (path / 'rebuild.swift').write_text(rebuild_program)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-I', str(path), str(path / 'Catch.m'), '-o', str(path / 'Catch.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-import-objc-header', str(path / 'Catch.h'), str(path / 'rebuild.swift'),
                    str(path / 'Catch.o'), '-o', str(path / 'rebuild')], check=True)
    subprocess.run([str(path / 'rebuild')], check=True)
