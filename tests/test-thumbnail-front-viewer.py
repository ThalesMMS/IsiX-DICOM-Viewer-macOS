#!/usr/bin/env python3
"""Only the front viewer of a screen lends its series list to the floating panel.

Viewers redraw in the background too: the toolbar's next series is applied to
every viewer, and each changed viewer ends with -redrawToolbar. A background
viewer that took the panel then received every click on a thumbnail, so the
series never loaded into the window in use until a new tiling handed the
panel back. The real -redrawToolbar is compiled with peers of the same shape.

`<git revision>` as an optional argument reads ViewerController.m from that
revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
if len(sys.argv) > 1:
    source = subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':Horos/Sources/ViewerController.m']).decode('latin1')
else:
    source = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
start = source.index('- (void) redrawToolbar\n')
method = source[start:source.index('- (void) refreshToolbar', start)]
policy = (root / 'Horos/Sources/ToolbarPolicy.swift').read_text()
policy_method = re.search(r'    @objc\(shouldKeepDetachedToolbarVisibleWhenFullScreen:\)\n    public static func shouldKeepDetachedToolbarVisible[^}]+}', policy).group(0)
code = r'''
#import <Foundation/Foundation.h>
#define MAXSCREENS 2
@interface HorosToolbarPolicy:NSObject
+ (BOOL)shouldKeepDetachedToolbarVisibleWhenFullScreen:(BOOL)fullScreen;
@end
static NSArray *screens;
#define N2LogStackTrace(x) NSLog(@"%@",x)
#define check(c) do {if(!(c)){NSLog(@"FAIL: %s",#c);exit(1);}}while(0)
@interface NSScreen:NSObject
+ (NSArray*)screens;
@end
@implementation NSScreen
+ (NSArray*)screens{return screens;}
@end
@interface Window:NSObject
@property id screen;
@property BOOL visible;
@property id toolbar;
@property BOOL customizationPaletteIsRunning;
- (void)orderOut:(id)sender;
- (void)orderBack:(id)sender;
@end
@implementation Window
- (void)orderOut:(id)sender{self.visible=NO;}
- (void)orderBack:(id)sender{self.visible=YES;}
@end
@interface Panel:NSObject
@property id thumbnailsView;
@property id viewer;
@property Window *window;
- (void)setThumbnailsView:(id)view viewer:(id)viewer;
@end
@implementation Panel
- (id)init{if((self=[super init]))self.window=[Window new];return self;}
- (void)setThumbnailsView:(id)view viewer:(id)viewer{self.thumbnailsView=view;self.viewer=viewer;self.window.visible=view!=nil;}
@end
static Panel *thumbnailsListPanel[MAXSCREENS];
@interface AppController:NSObject
+ (BOOL)USETOOLBARPANEL;
@end
@implementation AppController
+ (BOOL)USETOOLBARPANEL{return NO;}
@end
@interface ViewerController:NSObject { @public id previewMatrixScrollView; Panel *toolbarPanel; BOOL FullScreenOn; }
@property Window *window;
+ (BOOL)isFrontMost2DViewer:(id)window;
+ (ViewerController*)frontMostDisplayed2DViewerForScreen:(id)screen;
- (void)redrawToolbar;
@end
static ViewerController *front;
@implementation ViewerController
+ (BOOL)isFrontMost2DViewer:(id)window{return front.window==window;}
+ (ViewerController*)frontMostDisplayed2DViewerForScreen:(id)screen{return front.window.screen==screen?front:nil;}
METHOD
@end
int main(void){@autoreleasepool {
 // In the process's own argument domain: the persistent defaults of a bare
 // executable named "test" are shared with every harness of that name.
 [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"UseFloatingThumbnailsList":@YES, @"SeriesListVisible":@YES} forName:NSArgumentDomain];
 id display=[NSScreen new];screens=@[display];
 ViewerController *inUse=[ViewerController new],*background=[ViewerController new];
 for(ViewerController *v in @[inUse,background]){v.window=[Window new];v.window.screen=display;v.window.visible=YES;v->previewMatrixScrollView=[NSObject new];}
 thumbnailsListPanel[0]=[Panel new];
 Panel *panel=thumbnailsListPanel[0];
 front=inUse;[inUse redrawToolbar];
 check(panel.viewer==inUse && panel.thumbnailsView==inUse->previewMatrixScrollView);
 // The next series reaches the background viewer, which redraws last.
 [inUse redrawToolbar];[background redrawToolbar];
 check(panel.viewer==inUse && panel.thumbnailsView==inUse->previewMatrixScrollView);
 // Once it is the front viewer, it lends its own list.
 front=background;[background redrawToolbar];
 check(panel.viewer==background && panel.thumbnailsView==background->previewMatrixScrollView);
 // With no front viewer on the screen (a viewer still opening), it lends it as before.
 front=nil;[inUse redrawToolbar];
 check(panel.viewer==inUse);
 NSLog(@"PASS: a background viewer's redraw leaves the panel with the front viewer");
}}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-thumbnail-front-') as tmp:
    p = Path(tmp)
    (p / 'test.m').write_text(code)
    (p / 'policy.swift').write_text('import Foundation\n@objc(HorosToolbarPolicy) final class ToolbarPolicy: NSObject {\n' + policy_method + '\n}')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-c', str(p / 'test.m'), '-o', str(p / 'test.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(p / 'policy.swift'), str(p / 'test.o'), '-framework', 'Foundation', '-o', str(p / 'test')], check=True)
    sys.exit(subprocess.run([str(p / 'test')]).returncode)
