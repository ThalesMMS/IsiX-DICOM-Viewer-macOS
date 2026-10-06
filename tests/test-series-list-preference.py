#!/usr/bin/env python3
"""Run the preference observer and application transition with controlled peers.

AppController is Swift: its transition is compiled with swiftc, as a
Swift category method of the Objective-C test AppController, over the same
Objective-C peers, with the helpers it reads previousDefaults through.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import tempfile

from sources import is_swift, source_text

root = Path(__file__).resolve().parents[1]


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it,
    outside comments and string literals."""
    index, depth, opened = at, 0, False
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
            if index < 0:
                break
            continue
        if text.startswith('/*', index):
            index = text.index('*/', index) + 2
            continue
        if text[index] == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == '\\' else 1
        elif text[index] == '{':
            depth, opened = depth + 1, True
        elif text[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return text[at:index + 1]
        index += 1
    return ''


app = source_text('AppController')
start = app.index('                let seriesListModeChanged =')
transition = app[start:app.index('                if Int(ObjC.int(previousDefaults?.value(forKey: "DisplayDICOMOverlays")))', start)]
# How the transition reads previousDefaults: the production helpers.
helpers = ''.join('    ' + swift_block(app, app.index(signature)) + '\n' for signature in
                  ('static func bool(_ value: Any?) -> Bool {', 'static func int(_ value: Any?) -> Int32 {'))
swift_transition = '''
import Foundation
let MAXSCREENS = 3
func thumbnailsListPanelAt(_ index: Int) -> Panel? { return testThumbnailsListPanel(Int32(index)) }
enum ObjC {
HELPERS}
extension AppController {
    @objc(transitionFrom:) func transition(from previousDefaults: NSDictionary?) {
        let defaults = UserDefaults.standard
TRANSITION
    }
}
'''.replace('HELPERS', helpers).replace('TRANSITION', transition)
pane = source_text('OSIViewerPreferencePanePref')
swift_pane = is_swift('OSIViewerPreferencePanePref')
if swift_pane:
    # The pane is Swift: its observer branch runs as a C function
    # the Objective-C driver calls, with the same key path.
    start = pane.index('        if keyPath == "values.UseFloatingThumbnailsList" {')
    observer = pane[start:pane.index('\n    }\n', start)]
    swift_observer = '''
import Foundation
@_cdecl("horos_series_list_observer")
public func horosSeriesListObserver(_ keyPathObject: NSString?) {
    let keyPath: String? = keyPathObject as String?
OBSERVER
}
'''.replace('OBSERVER', observer)
    observer = '    horos_series_list_observer(keyPath);'
else:
    start = pane.index('    if( [keyPath isEqualToString: @"values.UseFloatingThumbnailsList"])')
    observer = pane[start:pane.index('\n}\n', start)]
peers = r'''
#import <Foundation/Foundation.h>
#define MAXSCREENS 3
void NSDisableScreenUpdates(void);
void NSEnableScreenUpdates(void);
@interface NSWindow : NSObject
@property BOOL isVisible;
- (void)makeKeyAndOrderFront:(id)sender;
@end
@interface App : NSObject
@property NSWindow *keyWindow;
@end
extern App *NSApp;
@interface NSScreen : NSObject
@property (class, readonly) NSArray<NSScreen *> *screens;
@property int number;
@end
@interface Panel : NSObject
@property BOOL borrowed;
- (void)prepareForScreenReconfiguration;
@end
Panel *testThumbnailsListPanel(int index);
@interface ViewerController : NSObject
@property NSWindow *window;
@property int index;
+ (NSMutableArray *)get2DViewers;
+ (NSMutableArray *)getDisplayed2DViewers;
+ (ViewerController *)frontMostDisplayed2DViewerForScreen:(NSScreen *)screen;
+ (void)closeAllWindows;
- (void)updateSeriesListMode;
- (void)setMatrixVisible:(BOOL)visible;
- (void)redrawToolbar;
@end
@interface AppController : NSObject
+ (AppController *)sharedAppController NS_SWIFT_NAME(shared());
- (void)tileWindows:(id)sender;
- (void)preferenceChanged;
@end
@interface AppController (Transition)
- (void)transitionFrom:(NSDictionary *)previousDefaults;
@end
'''
driver = r'''
#import "peers.h"
#define check(c) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", #c); exit(1); } } while (0)
static int updateDepth, closes, layouts, tiles, redraws, attaches, keyChanges;
static NSMutableArray *events;
extern void horos_series_list_observer(NSString *keyPath);
void NSDisableScreenUpdates(void) { updateDepth++; }
void NSEnableScreenUpdates(void) { updateDepth--; }
@implementation App
@end
App *NSApp;
@implementation NSWindow
- (void)makeKeyAndOrderFront:(id)sender { NSApp.keyWindow = self; keyChanges++; }
@end
@implementation NSScreen
+ (NSArray *)screens {
    static NSArray *screens;
    if (!screens) { NSScreen *a=[NSScreen new], *b=[NSScreen new]; b.number=1; screens=@[a, b]; }
    return screens;
}
@end
@implementation Panel
- (void)prepareForScreenReconfiguration { self.borrowed = NO; [events addObject:@"detach"]; }
@end
static Panel *thumbnailsListPanel[MAXSCREENS];
Panel *testThumbnailsListPanel(int index) { return thumbnailsListPanel[index]; }
static NSArray *viewers;
@implementation ViewerController
+ (NSMutableArray *)get2DViewers { return [viewers mutableCopy]; }
+ (NSMutableArray *)getDisplayed2DViewers { return [viewers mutableCopy]; }
+ (ViewerController *)frontMostDisplayed2DViewerForScreen:(NSScreen *)screen { return viewers[screen.number]; }
+ (void)closeAllWindows { closes++; }
- (void)updateSeriesListMode {
    for (int i=0; i<MAXSCREENS; i++) check(!thumbnailsListPanel[i].borrowed);
    layouts++; [events addObject:@"layout"];
}
- (void)setMatrixVisible:(BOOL)visible { check(visible); }
- (void)redrawToolbar {
    check(tiles > 0 && NSApp.keyWindow == self.window);
    redraws++; thumbnailsListPanel[self.index].borrowed = YES; attaches++;
}
@end
@implementation AppController
+ (id)sharedAppController { static id app; if (!app) app=[self new]; return app; }
- (void)tileWindows:(id)sender {
    tiles++;
    // Actual tiling releases panel attachments; each screen needs a new owner.
    for (int i=0; i<MAXSCREENS; i++) thumbnailsListPanel[i].borrowed=NO;
}
- (void)preferenceChanged {
    NSString *keyPath = @"values.UseFloatingThumbnailsList";
OBSERVER
}
@end
int main(void) { @autoreleasepool {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setVolatileDomain:@{@"UseFloatingThumbnailsList":@NO, @"SeriesListVisible":@YES}
                       forName:NSArgumentDomain];
    events = [NSMutableArray new]; NSApp = [App new];
    NSWindow *preferences = [NSWindow new]; preferences.isVisible = YES; NSApp.keyWindow = preferences;
    ViewerController *a=[ViewerController new], *b=[ViewerController new];
    a.window=[NSWindow new]; b.window=[NSWindow new]; b.index=1; viewers=@[a,b];
    for (int i=0; i<MAXSCREENS; i++) thumbnailsListPanel[i]=[Panel new];
    AppController *app=AppController.sharedAppController;
    [app preferenceChanged]; check(closes==0 && [defaults boolForKey:@"SeriesListVisible"]);
    [app transitionFrom:@{@"UseFloatingThumbnailsList":@NO,@"SeriesListVisible":@YES}];
    check(layouts==0 && tiles==0 && keyChanges==0);
    for (int cycle=0; cycle<3; cycle++) {
        [defaults setVolatileDomain:@{@"UseFloatingThumbnailsList":@YES,@"SeriesListVisible":@YES} forName:NSArgumentDomain];
        [events removeAllObjects];
        [app transitionFrom:@{@"UseFloatingThumbnailsList":@NO,@"SeriesListVisible":@YES}];
        check(([[events subarrayWithRange:NSMakeRange(0,3)] isEqual:@[@"detach",@"detach",@"detach"]]));
        check(thumbnailsListPanel[0].borrowed && thumbnailsListPanel[1].borrowed);
        check(NSApp.keyWindow == preferences && closes==0 && updateDepth==0);
        [defaults setVolatileDomain:@{@"UseFloatingThumbnailsList":@NO,@"SeriesListVisible":@YES} forName:NSArgumentDomain];
        [app transitionFrom:@{@"UseFloatingThumbnailsList":@YES,@"SeriesListVisible":@YES}];
        check(!thumbnailsListPanel[0].borrowed && !thumbnailsListPanel[1].borrowed);
        check(NSApp.keyWindow == preferences && closes==0 && updateDepth==0);
    }
    check(layouts==12 && tiles==6 && redraws==6 && attaches==6 && viewers.count==2);
    puts("PASS: no viewer closes, detach before layout, two-screen reattachment after tiling, focus restoration and unchanged-mode no-op");
}}
'''.replace('OBSERVER', observer)
with tempfile.TemporaryDirectory(prefix='horos-series-list-preference-') as folder:
    folder = Path(folder)
    (folder/'peers.h').write_text(peers)
    (folder/'test.m').write_text(driver)
    (folder/'transition.swift').write_text(swift_transition)
    objects = [str(folder/'test.o'), str(folder/'transition.o')]
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'Transition', '-emit-object',
                    '-import-objc-header', str(folder/'peers.h'),
                    str(folder/'transition.swift'), '-o', str(folder/'transition.o')], check=True)
    if swift_pane:
        (folder/'observer.swift').write_text(swift_observer)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'Observer', '-emit-object',
                        str(folder/'observer.swift'), '-o', str(folder/'observer.o')], check=True)
        objects.append(str(folder/'observer.o'))
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I', str(folder), '-c', str(folder/'test.m'), '-o', str(folder/'test.o')], check=True)
    subprocess.run(['xcrun', 'swiftc'] + objects + ['-framework', 'Foundation', '-o', str(folder/'test')], check=True)
    subprocess.run([str(folder/'test')], check=True)
