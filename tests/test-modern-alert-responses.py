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
browser = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('mac_roman')
def browser_method(signature):
    start = browser.index(signature)
    opening = browser.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += {'{': 1, '}': -1}.get(browser[end], 0)
        end += 1
    return browser[start:end]

browser_program = r'''
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "HorosAlertPanel.h"
static void check(BOOL value) { if (!value) abort(); }
static NSInteger answer;
static NSInteger threadCount;
static BOOL drainDuringAlert;
static int modalCalls;
static void (^completion)(NSModalResponse);
static void begin(NSAlert *alert, SEL selector, NSWindow *window, void (^handler)(NSModalResponse)) {
    check(alert.alertStyle == NSAlertStyleInformational);
    check([alert.informativeText containsString:@"SQL index"]);
    check([[alert.buttons valueForKey:@"title"] isEqual:@[@"OK", @"Cancel"]]);
    completion = [handler copy];
}
static NSModalResponse run(NSAlert *alert, SEL selector) {
    modalCalls++;
    check([alert.messageText isEqual:@"Background Operations"]);
    check([alert.informativeText containsString:@"will be cancelled"]);
    check([[alert.buttons valueForKey:@"title"] isEqual:@[@"Cancel", @"Quit"]]);
    if (drainDuringAlert) threadCount = 0;
    return answer;
}
@interface NSFullScreenWindow : NSWindow @end
@implementation NSFullScreenWindow @end
@interface DatabasePeer : NSObject
@property BOOL allowed;
@property int saves;
- (BOOL)rebuildAllowed;
- (BOOL)save:(NSError **)error;
@end
@implementation DatabasePeer
- (BOOL)rebuildAllowed { return self.allowed; }
- (BOOL)save:(NSError **)error { self.saves++; return YES; }
@end
@interface ViewerController : NSObject
+ (void)closeAllWindows;
@end
@implementation ViewerController
+ (void)closeAllWindows {}
@end
@interface ThreadsManager : NSObject
+ (instancetype)defaultManager;
- (NSInteger)threadsCount;
@end
@implementation ThreadsManager
+ (instancetype)defaultManager { static id manager; if (!manager) manager = [self new]; return manager; }
- (NSInteger)threadsCount { return threadCount; }
@end
@interface SendController : NSObject
+ (NSInteger)sendControllerObjects;
@end
@implementation SendController
+ (NSInteger)sendControllerObjects { return 0; }
@end
@interface BrowserPeer : NSObject {
    DatabasePeer *_database;
}
@property int rebuilds;
@property int detached;
@property(readonly) NSWindow *window;
- (void)initiateRebuildSql;
- (void)setDatabase:(DatabasePeer *)database;
- (IBAction)rebuildSQLFile:(id)sender;
- (BOOL)shouldTerminate:(id)sender;
- (void)shouldTerminateCallback:(NSTimer *)timer;
@end
@implementation BrowserPeer
- (NSWindow *)window { return nil; }
- (void)initiateRebuildSql { self.rebuilds++; }
- (void)setDatabase:(DatabasePeer *)database { _database = database; if (!database) self.detached++; }
- (void)shouldTerminateCallback:(NSTimer *)timer {}
METHODS
@end
int main(void) { @autoreleasepool {
    method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(beginSheetModalForWindow:completionHandler:)), (IMP)begin);
    method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)run);
    DatabasePeer *database = [DatabasePeer new]; database.allowed = YES;
    BrowserPeer *browser = [BrowserPeer new]; [browser setDatabase:database];
    for (NSInteger response = NSAlertFirstButtonReturn; response <= NSAlertThirdButtonReturn; ++response) {
        int before = browser.rebuilds;
        [browser rebuildSQLFile:nil];
        check(browser.rebuilds == before);
        completion(response); [completion release]; completion = nil;
        check(browser.rebuilds == before + (response == NSAlertFirstButtonReturn));
    }
    database.allowed = NO;
    BOOL raised = NO;
    @try { [browser rebuildSQLFile:nil]; } @catch (NSException *error) { raised = [error.name isEqual:NSGenericException]; }
    check(raised && completion == nil); database.allowed = YES;
    for (int scenario = 0; scenario < 4; ++scenario) {
        [browser setDatabase:database];
        threadCount = scenario == 2 ? 0 : 2;
        drainDuringAlert = scenario == 3;
        answer = scenario == 1 ? NSAlertSecondButtonReturn : NSAlertFirstButtonReturn;
        int before = browser.detached, calls = modalCalls;
        BOOL result = [browser shouldTerminate:nil];
        check(result == (scenario != 0));
        check(browser.detached == before + (scenario != 0));
        check(modalCalls == calls + (scenario != 2));
    }
    check(database.saves == 4);
    puts("PASS: actual Browser rebuild OK-only/deferred/refusal and termination Cancel/Quit/no-threads/drained-thread guards");
} }
'''.replace('METHODS', browser_method('-(IBAction)rebuildSQLFile:') + '\n' + browser_method('- (BOOL)shouldTerminate:'))

with tempfile.TemporaryDirectory(prefix='horos-alert-responses-') as folder:
    path = Path(folder)
    (path / 'main.m').write_text(program.replace('ANNOTATIONS_BRIDGES', annotations_bridges))
    subprocess.run(['xcrun', 'clang', '-fblocks', '-Werror', '-Wdeprecated-declarations', '-I', str(root / 'Horos/Sources'), str(path / 'main.m'), str(root / 'Horos/Sources/HorosAlertPanel.m'), '-framework', 'AppKit', '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)

    (path / 'browser.m').write_text(browser_program)
    subprocess.run(['xcrun', 'clang', '-fblocks', '-Werror', '-Wdeprecated-declarations', '-I', str(root / 'Horos/Sources'), str(path / 'browser.m'), str(root / 'Horos/Sources/HorosAlertPanel.m'), '-framework', 'AppKit', '-o', str(path / 'browser')], check=True)
    subprocess.run([str(path / 'browser')], check=True)
