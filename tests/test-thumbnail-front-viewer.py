#!/usr/bin/env python3
"""Only the front viewer of a screen lends its series list to the floating panel.

Viewers redraw in the background too: the toolbar's next series is applied to
every viewer, and each changed viewer ends with -redrawToolbar. A background
viewer that took the panel then received every click on a thumbnail, so the
series never loaded into the window in use until a new tiling handed the
panel back. The real -redrawToolbar (Objective-C before, Swift now) is
compiled with peers of the same shape (viewer_redraw_toolbar).

`<git revision>` as an optional argument reads the viewer from that revision,
the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import viewer_redraw_toolbar  # noqa: E402

CLASS_METHODS = r'''ViewerController *front;
+ (BOOL)isFrontMost2DViewer:(id)window{return front.window==window;}
+ (ViewerController*)frontMostDisplayed2DViewerForScreen:(id)screen{return front.window.screen==screen?front:nil;}
'''

MAIN = r'''#import "Peers.h"
extern ViewerController *front;
#define check(c) do {if(!(c)){NSLog(@"FAIL: %s",#c);exit(1);}}while(0)
int main(void){@autoreleasepool {
 // In the process's own argument domain: the persistent defaults of a bare
 // executable named "test" are shared with every harness of that name.
 [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"UseFloatingThumbnailsList":@YES, @"SeriesListVisible":@YES} forName:NSArgumentDomain];
 NSScreen *display=[NSScreen new];screens=@[display];
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
'''

with tempfile.TemporaryDirectory(prefix='horos-thumbnail-front-') as tmp:
    test = viewer_redraw_toolbar.program(tmp, sys.argv[1] if len(sys.argv) > 1 else None, CLASS_METHODS, MAIN)
    sys.exit(subprocess.run([str(test)]).returncode)
