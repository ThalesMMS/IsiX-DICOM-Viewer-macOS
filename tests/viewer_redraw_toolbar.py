"""The 2D viewer's -redrawToolbar compiled with peers of the same shape, for
the tests of the floating thumbnails panels.

-redrawToolbar was Objective-C in ViewerController.m and is Swift now
(ViewerController+ToolbarRefresh.swift). This compiles whichever the
revision has, against the same peers: the screens, windows, the toolbar
panel, the thumbnails panels (two, MAXSCREENS), AppController and the
toolbar policy (the app's own ToolbarPolicy method). The test gives the
class methods of the viewer that pick the front viewer and the driver
(`main`), both Objective-C; it reads `screens`, `thumbnailsListPanel[]` and
the viewers' `previewMatrixScrollView`.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

HEADER = r'''#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Foundation/Foundation.h>
#define MAXSCREENS 2
@interface HorosToolbarPolicy:NSObject
+ (BOOL)shouldKeepDetachedToolbarVisibleWhenFullScreen:(BOOL)fullScreen;
@end
@interface NSScreen:NSObject
@property(class, readonly) NSArray<NSScreen*> *screens;
@end
extern NSArray *screens;
@interface Toolbar:NSObject
@property BOOL customizationPaletteIsRunning;
@end
@interface Window:NSObject
@property(nullable) NSScreen *screen;
@property BOOL visible;
@property(nullable) Toolbar *toolbar;
- (void)orderOut:(nullable id)sender;
- (void)orderBack:(nullable id)sender;
- (void)orderFront:(nullable id)sender;
@end
@interface Panel:NSObject
@property(nullable) NSObject *thumbnailsView;
@property(nullable) id viewer;
@property(nullable) Window *window;
@property BOOL fail;
- (void)setThumbnailsView:(nullable NSObject*)view viewer:(nullable id)viewer;
@end
extern Panel * _Nullable thumbnailsListPanel[MAXSCREENS];
Panel * _Nullable AppControllerCAPIThumbnailsListPanel(NSInteger index);
void ViewerControllerLogStackTrace(NSString * _Nonnull message);
void N2LogStackTraceMessage(NSString * _Nonnull message);
#define N2LogStackTrace(x) ViewerControllerLogStackTrace(x)
@interface AppController:NSObject
+ (BOOL)USETOOLBARPANEL NS_SWIFT_NAME(usetoolbarpanel());
@end
@interface ViewerController:NSObject { @public NSObject *previewMatrixScrollView; Panel *toolbarPanel; BOOL FullScreenOn; }
@property(nullable) Window *window;
@property(readonly, nullable) NSObject *horos_previewMatrixScrollView;
@property(readonly, nullable) Panel *horos_toolbarPanel;
@property(readonly) BOOL horos_FullScreenOn;
+ (BOOL)isFrontMost2DViewer:(nullable Window*)window;
+ (nullable ViewerController*)frontMostDisplayed2DViewerForScreen:(nullable NSScreen*)screen NS_SWIFT_NAME(frontMostDisplayed2DViewer(for:));
#ifndef REDRAW_SWIFT
- (void)redrawToolbar;
#endif
@end
'''

PEERS = r'''#import "Peers.h"
NSArray *screens;
@implementation NSScreen
+ (NSArray*)screens{return screens;}
@end
@implementation Toolbar
@end
@implementation Window
- (void)orderOut:(id)sender{self.visible=NO;}
- (void)orderBack:(id)sender{self.visible=YES;}
- (void)orderFront:(id)sender{self.visible=YES;}
@end
@implementation Panel
- (id)init{if((self=[super init]))self.window=[Window new];return self;}
- (void)setThumbnailsView:(id)view viewer:(id)viewer {if(self.fail)[NSException raise:@"fixture" format:@"panel failure"];self.thumbnailsView=view;self.viewer=viewer;self.window.visible=view!=nil;}
@end
Panel *thumbnailsListPanel[MAXSCREENS];
Panel *AppControllerCAPIThumbnailsListPanel(NSInteger index){return index>=0&&index<MAXSCREENS?thumbnailsListPanel[index]:nil;}
void ViewerControllerLogStackTrace(NSString *message){NSLog(@"%@",message);}
void N2LogStackTraceMessage(NSString *message){NSLog(@"%@",message);}
@implementation AppController
+ (BOOL)USETOOLBARPANEL{return NO;}
@end
'''


def program(folder, revision, class_methods, main):
    """The test program in `folder`: the viewer's -redrawToolbar of
    `revision` (None: the tree), `class_methods` (+isFrontMost2DViewer: and
    +frontMostDisplayed2DViewerForScreen:) and `main`, which `#import "Peers.h"`."""
    def read(path):
        if revision is None:
            file = ROOT / path
            return file.read_bytes() if file.is_file() else None
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (revision, path)], capture_output=True)
        return shown.stdout if shown.returncode == 0 else None

    folder = Path(folder)
    source = (read('Horos/Sources/ViewerController.m') or b'').decode('latin1')  # empty once the class is Swift
    policy = (ROOT / 'Horos/Sources/ToolbarPolicy.swift').read_text()
    policy_method = re.search(r'    @objc\(shouldKeepDetachedToolbarVisibleWhenFullScreen:\)\n    public static func shouldKeepDetachedToolbarVisible[^}]+}', policy).group(0)
    swift = ['import Foundation\n@objc(HorosToolbarPolicy) final class ToolbarPolicy: NSObject {\n' + policy_method + '\n}\n']
    viewer = '@implementation ViewerController\n' + class_methods + '\n'
    if '- (void) redrawToolbar\n' in source:
        start = source.index('- (void) redrawToolbar\n')
        viewer += source[start:source.index('- (void) refreshToolbar', start)]
        swift_flags = []
    else:
        # Swift: the method of ViewerController+ToolbarRefresh.swift, in an
        # extension of the peer, with the peers' MAXSCREENS.
        text = read('Horos/Sources/ViewerController+ToolbarRefresh.swift').decode()
        start = text.index('    @objc(redrawToolbar)\n')
        method = text[start:text.index('\n    }\n', start) + 7]
        swift.append('let maxScreens = 2\nextension ViewerController {\n' + method + '}\n')
        viewer += ('- (NSObject*)horos_previewMatrixScrollView{return previewMatrixScrollView;}\n'
                   '- (Panel*)horos_toolbarPanel{return toolbarPanel;}\n'
                   '- (BOOL)horos_FullScreenOn{return FullScreenOn;}\n')
        swift_flags = ['-Xcc', '-DREDRAW_SWIFT']
    viewer += '@end\n'
    (folder / 'Peers.h').write_text(HEADER)
    (folder / 'peers.m').write_text(PEERS + viewer)
    (folder / 'main.m').write_text(main)
    (folder / 'peers.swift').write_text(''.join(swift))
    objects = []
    for name in ('peers', 'main'):
        # The peers do not implement what the Swift extension does.
        defines = ['-DREDRAW_SWIFT'] if swift_flags and name == 'peers' else []
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', *defines, '-I', str(folder), '-c', str(folder / (name + '.m')), '-o', str(folder / (name + '.o'))], check=True)
        objects.append(str(folder / (name + '.o')))
    executable = folder / 'test'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *swift_flags, '-import-objc-header', str(folder / 'Peers.h'),
                    str(folder / 'peers.swift'), *objects, '-framework', 'Foundation', '-o', str(executable)], check=True)
    return executable
