"""A stand-in 2D viewer around the real code of its docked series list.

test-series-list-divider.py and test-series-list-floating-off.py drive two
viewers' series lists through their split views. Both run the viewer's own
code of the dock (its thickness, mode and visibility, the KVO observer of
SeriesListVisible and the split view's delegate) over the real
SeriesListLayout, in a stand-in ViewerController that has only what that code
reads: the window, its split view with the dock and the image pane, the list's
scroll view and matrix.

Where ViewerController.m still has that code (an older revision, the tests'
negative control), its methods are taken from it and compiled with clang into
the stand-in, as before. Where it has moved to ViewerController+SeriesListDock.swift,
that file is compiled with swiftc as an extension of the stand-in, with the
IsiXImaging rules it calls; the stand-in's accessors and methods are declared
as ViewerController+SwiftIvars.h and the viewer's headers declare them.

A test gives its scenario: Objective-C that defines main() over these names:

    ViewerController *v = [[ViewerController alloc] initWithSplitViewClass: [NSSplitView class]
                                                                 deferWindow: YES observesVisibility: NO];
    v->splitView, v->previewMatrixScrollView, v->imagePane, [v harnessWindow]
    viewers, the array +get2DViewers and +getDisplayed2DViewers return

and the selectors of the dock ([v updateSeriesListMode], [v setMatrixVisible: YES],
[v matrixIsVisible], [v horosSeriesListThickness], the split view delegate's)
and of HorosSeriesListLayout.
"""
from pathlib import Path
import re
import subprocess
import harness_defaults  # the harness's preferences stay in its own process

ROOT = Path(__file__).resolve().parents[1]
VIEWER = 'Horos/Sources/ViewerController.m'
DOCK = 'Horos/Sources/ViewerController+SeriesListDock.swift'

# The dock's methods in ViewerController.m.
OBJC_METHODS = (
    '- (CGFloat) horosSeriesListThickness',
    '- (void) updateSeriesListMode',
    '- (void) setMatrixVisible: (BOOL) visible',
    '-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object',
    '- (void)splitViewDidResizeSubviews:(NSNotification *) notification',
    '- (BOOL)splitView: (NSSplitView *)sender canCollapseSubview: (NSView *)subview',
    '- (CGFloat)splitView:(NSSplitView *)sender constrainSplitPosition:',
    '-(BOOL) matrixIsVisible',
    '-(void) splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize',
)

# The instance variables the Swift of the dock reads, by their accessors.
IVARS = {'windowWillClose': 'BOOL', 'splitView': 'NSSplitView*', 'previewMatrixScrollView': 'NSScrollView*', 'previewMatrix': 'NSMatrix*',
         'needsToBuildSeriesMatrix': 'BOOL', 'needsToBuildSeriesPopupMenu': 'BOOL', 'FullScreenWindow': 'NSWindow*', 'FullScreenOn': 'BOOL',
         'seriesView': 'SeriesView*', 'previewRootView': 'NSView*'}

# The viewer's methods the Swift of the dock calls, and the headers that declare them.
METHODS = (('Horos/Sources/ViewerController+Menus.h', '- (NSArray*) imageViews;'),
           ('Horos/Sources/ViewerController+Navigation.h', '- (void) propagateSettings;'),
           ('Horos/Sources/ViewerController+Windows.h', '+ (NSMutableArray*) getDisplayed2DViewers;'),
           ('Horos/Sources/ViewerController+Windows.h', '+ (NSMutableArray*) get2DViewers;'),
           ('Horos/Sources/ViewerController+Windows.h', '- (void) setWindowTitle:(id) sender;'),
           ('Horos/Sources/ViewerController+Windows.h', '- (BOOL) FullScreenON;'),
           ('Horos/Sources/ViewerController+SeriesList.h', '- (void) buildMatrixPreview: (BOOL) showSelected;'))

COMMON = r'''
@interface ThumbnailCell : NSButtonCell
+ (float) thumbnailCellWidth;
@end

@interface BrowserController : NSObject
+ (int) _scrollerStyle: (NSScroller*) scroller;
@end

@interface DCMView : NSView
@property(nonatomic) float scaleValue;
@property(nonatomic) NSPoint origin;
@end

@interface SeriesView : NSView
- (NSArray*) imageViews;
@end
'''

COMMON_IMPLEMENTATION = r'''
@implementation ThumbnailCell
+ (float) thumbnailCellWidth { return 100; }
// A thumbnail's size, which a strip across the top or bottom is as thick as.
- (NSSize) cellSize { return NSMakeSize( 100, 120); }
@end

@implementation BrowserController
+ (int) _scrollerStyle: (NSScroller*) scroller { return 1; }
@end

@implementation DCMView
@end

@implementation SeriesView
- (NSArray*) imageViews { return @[]; }
@end

NSMutableArray *viewers = nil;
'''

# The window, the split view with the dock and the image pane, the list's
# scroll view and matrix; the dock's code places them.
INIT = r'''
- (id) initWithSplitViewClass: (Class) splitViewClass deferWindow: (BOOL) deferWindow observesVisibility: (BOOL) observes
{
    // With deferWindow NO, a window server window, so the split view tracks the
    // mouse events posted to it; it is never ordered in.
    NSWindow *w = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 800, 600) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: deferWindow];
    [w setReleasedWhenClosed: NO];
    if( self = [self initHarnessWithWindow: w])
    {
        harnessWindow = w;
        splitView = [[splitViewClass alloc] initWithFrame: NSMakeRect(0, 0, 800, 600)];
        [splitView setVertical: YES];
        NSView *dock = [[NSView alloc] initWithFrame: NSMakeRect(0, 0, 100, 600)];
        imagePane = [[NSView alloc] initWithFrame: NSMakeRect(109, 0, 691, 600)];
        [splitView addSubview: dock];
        [splitView addSubview: imagePane];
        previewMatrixScrollView = [[NSScrollView alloc] initWithFrame: NSMakeRect(0, 0, 100, 600)];
        previewMatrix = [[NSMatrix alloc] initWithFrame: NSMakeRect(0, 0, 100, 600) mode: NSRadioModeMatrix cellClass: [ThumbnailCell class] numberOfRows: 5 numberOfColumns: 1];
        [previewMatrix setCellSize: NSMakeSize(100, 120)];
        [previewMatrixScrollView setDocumentView: previewMatrix];
        [dock addSubview: previewMatrixScrollView];
        [[w contentView] addSubview: splitView];
        [self updateSeriesListMode];
        [splitView setDelegate: self];
        [splitView adjustSubviews];
        if( observes)
            [[NSUserDefaults standardUserDefaults] addObserver: self forKeyPath: @"SeriesListVisible" options: NSKeyValueObservingOptionNew context: nil];
    }
    return self;
}

- (NSWindow*) harnessWindow { return harnessWindow; }
+ (NSMutableArray*) get2DViewers { return viewers; }
+ (NSMutableArray*) getDisplayed2DViewers { return viewers; }
- (void) buildMatrixPreview: (BOOL) showSelected { needsToBuildSeriesMatrix = NO; }
- (NSArray*) imageViews { return @[]; }
- (void) setWindowTitle: (id) sender {}
- (void) propagateSettings {}
- (BOOL) FullScreenON { return FullScreenOn; }
'''

IVAR_BLOCK = r'''
{
@public
    NSWindow *harnessWindow;
    NSSplitView *splitView;
    NSMatrix *previewMatrix;
    NSScrollView *previewMatrixScrollView;
    NSView *imagePane, *previewRootView;
    NSWindow *FullScreenWindow;
    SeriesView *seriesView;
    BOOL windowWillClose, FullScreenOn, needsToBuildSeriesMatrix, needsToBuildSeriesPopupMenu;
}
- (id) initWithSplitViewClass: (Class) splitViewClass deferWindow: (BOOL) deferWindow observesVisibility: (BOOL) observes;
- (NSWindow*) harnessWindow;
'''


def read(revision, path):
    """`path` at `revision` (None: the tree), or None when it is not there."""
    encoding = 'utf-8' if path.endswith('.swift') else 'latin1'
    if revision:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode(encoding) if shown.returncode == 0 else None
    file = ROOT / path
    return file.read_bytes().decode(encoding) if file.is_file() else None


def run(command):
    built = subprocess.run(command, capture_output=True, text=True)
    if built.returncode:
        raise SystemExit('FAIL: the harness does not build:\n' + (built.stdout + built.stderr)[-5000:])


def has_objc_dock(revision):
    viewer = read(revision, VIEWER) or ''
    return '- (void) updateSeriesListMode' in viewer


def _objc(revision, scenario):
    """The stand-in with the dock's methods of ViewerController.m."""
    viewer = read(revision, VIEWER)
    methods = []
    for signature in OBJC_METHODS:
        match = re.search(r'\n(' + re.escape(signature) + r'.*?\n\})\n', viewer, re.S)
        if match is None:
            # Older revisions had no -splitView:canCollapseSubview: of their own.
            if 'canCollapseSubview' in signature:
                continue
            raise SystemExit(f'FAIL: {signature} is gone from ViewerController.m at {revision}; this harness needs a new look')
        methods.append(match.group(1))
    # File-level state the methods share, declared among them.
    region = viewer[viewer.index(OBJC_METHODS[0]):viewer.index(OBJC_METHODS[-1])]
    statics = '\n'.join(re.findall(r'^static [A-Za-z]+ \w+ = [^;]+;$', region, re.M))
    return ('#import <Cocoa/Cocoa.h>\n#import "SeriesListLayoutCheck-Swift.h"\n' + COMMON
            + '@interface ViewerController : NSObject <NSSplitViewDelegate>\n' + IVAR_BLOCK + '@end\n'
            + COMMON_IMPLEMENTATION
            + '@implementation ViewerController\n- (id) initHarnessWithWindow: (NSWindow*) window { return [super init]; }\n'
            + INIT + statics + '\n\n' + '\n\n'.join(methods) + '\n@end\n' + scenario + harness_defaults.OBJC)


def _swift_declarations(revision):
    """The stand-in's interface, with the declarations of the viewer's headers."""
    ivars_header = read(revision, 'Horos/Sources/ViewerController+SwiftIvars.h')
    if ivars_header is None:
        # Gone since the class is Swift: its accessors keep the header's Swift
        # names and semantics, so its last revision describes them.
        import history_reference
        path = 'Horos/Sources/ViewerController+SwiftIvars.h'
        ivars_header = read(history_reference.before_removal(path), path)
    accessors = []
    for name in IVARS:
        match = re.search(r'^@property\b[^\n]*\bhoros_' + name + r'\b[^\n]*;$', ivars_header, re.M)
        if match is None:
            raise SystemExit(f'FAIL: horos_{name} is gone from ViewerController+SwiftIvars.h; this harness needs a new look')
        accessors.append(match.group(0))
    methods = []
    for path, declaration in METHODS:
        header = read(revision, path)
        if header is None or declaration not in header:
            raise SystemExit(f'FAIL: {path} no longer declares {declaration}; this harness needs a new look')
        methods.append(declaration)
    return ('#import <Cocoa/Cocoa.h>\n' + COMMON
            + '@interface ViewerController : NSWindowController\n' + IVAR_BLOCK + '\n'.join(methods) + '\n@end\n'
            + '@interface ViewerController (SwiftIvars)\n' + '\n'.join(accessors) + '\n@end\n')


def _swift_implementation():
    accessors = []
    for name, kind in IVARS.items():
        accessors.append('- (%s) horos_%s { return %s; }' % (kind, name, name))
        # The harness writes the flags; the objects, retained or read-only, it only reads.
        if kind == 'BOOL':
            accessors.append('- (void) setHoros_%s: (BOOL) value { %s = value; }' % (name, name))
    return ('@implementation ViewerController\n- (id) initHarnessWithWindow: (NSWindow*) window { return [super initWithWindow: window]; }\n'
            + INIT + '\n'.join(accessors) + '\n@end\n')


def _helpers(revision):
    """The app's helpers the Swift of the dock calls."""
    def take(path, pattern):
        text = read(revision, path)
        match = text and re.search(pattern, text, re.S)
        if not match:
            raise SystemExit(f'FAIL: {path} changed; this harness needs a new look')
        return match.group(0)
    return ('import AppKit\n'
            + take('Horos/Sources/ViewerController+ImagePipelineSupport.swift', r'\nenum ViewerSender \{.*?\n}\n')
            + take('Horos/Sources/ViewerController+SeriesPopup.swift', r'\n(?:///[^\n]*\n)*func viewerSameString\(.*?\n}\n')
            + take('Horos/Sources/MainActorCallbacks.swift', r'\nfunc onMainActor\(.*?\n}\n'))


def build(revision, scenario, folder):
    """The harness program for `scenario`, built in `folder`."""
    folder = Path(folder)
    layout = read(revision, 'Horos/Sources/SeriesListLayout.swift')
    identification = read(revision, 'Horos/Sources/SeriesListIdentification.swift')
    (folder / 'SeriesListLayout.swift').write_text(layout)
    swift = [str(folder / 'SeriesListLayout.swift')]
    if identification:
        (folder / 'SeriesListIdentification.swift').write_text(identification)
        swift.append(str(folder / 'SeriesListIdentification.swift'))
    objects = []
    if has_objc_dock(revision):
        run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'SeriesListLayoutCheck', '-wmo',
             '-c', *swift, '-o', str(folder / 'layout.o'), '-emit-objc-header-path', str(folder / 'SeriesListLayoutCheck-Swift.h')])
        (folder / 'check.m').write_text(_objc(revision, scenario), encoding='latin1')
        objects.append(str(folder / 'layout.o'))
    else:
        # The rules of the dock in IsiXImaging, as a module of their own.
        module = folder / 'IsiXImaging'
        module.mkdir()
        rules = read(revision, 'Modules/IsiXImaging/Sources/ViewerSeriesList/SeriesListDock.swift')
        (module / 'SeriesListDock.swift').write_text(rules)
        run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-name', 'IsiXImaging', '-wmo', '-c',
             str(module / 'SeriesListDock.swift'), '-o', str(folder / 'rules.o'),
             '-emit-module', '-emit-module-path', str(module / 'IsiXImaging.swiftmodule')])
        (folder / 'StandIn.h').write_text(_swift_declarations(revision), encoding='latin1')
        (folder / 'ViewerController+SeriesListDock.swift').write_text(read(revision, DOCK))
        (folder / 'Helpers.swift').write_text(_helpers(revision))
        swift += [str(folder / 'ViewerController+SeriesListDock.swift'), str(folder / 'Helpers.swift')]
        run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-name', 'SeriesListLayoutCheck', '-wmo',
             '-I', str(module), '-import-objc-header', str(folder / 'StandIn.h'),
             '-c', *swift, '-o', str(folder / 'layout.o'), '-emit-objc-header-path', str(folder / 'SeriesListLayoutCheck-Swift.h')])
        (folder / 'check.m').write_text('#import "StandIn.h"\n#import "SeriesListLayoutCheck-Swift.h"\n' + COMMON_IMPLEMENTATION
                                        + _swift_implementation() + scenario + harness_defaults.OBJC, encoding='latin1')
        objects += [str(folder / 'layout.o'), str(folder / 'rules.o')]
    run(['xcrun', 'clang', '-c', '-fobjc-arc', '-fmodules', '-Wno-objc-method-access', '-I', str(folder),
         str(folder / 'check.m'), '-o', str(folder / 'check.o')])
    binary = folder / 'horos-series-list-dock-check'
    run(['xcrun', 'swiftc', *objects, str(folder / 'check.o'), '-o', str(binary)])
    return binary
