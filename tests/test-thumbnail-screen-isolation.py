#!/usr/bin/env python3
"""Exercise the actual toolbar redraw across independent screen/panel fixtures.

The real -redrawToolbar (Objective-C before, Swift now) is compiled with
peers of the same shape (viewer_redraw_toolbar). `<git revision>` as an
optional argument reads the viewer from that revision.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import viewer_redraw_toolbar  # noqa: E402

CLASS_METHODS = r'''+ (BOOL)isFrontMost2DViewer:(id)window{return YES;}
+ (ViewerController*)frontMostDisplayed2DViewerForScreen:(id)screen{return nil;}
'''

MAIN = r'''#import "Peers.h"
static int screenUpdateDepth;
#define check(c) do {if(!(c)){NSLog(@"FAIL: %s",#c);exit(1);}}while(0)
int main(void){@autoreleasepool {
 // In the process's own argument domain: the persistent defaults of a bare
 // executable named "test" are shared with every harness of that name.
 [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"UseFloatingThumbnailsList":@YES, @"SeriesListVisible":@YES} forName:NSArgumentDomain];
 NSScreen *first=[NSScreen new],*second=[NSScreen new];screens=@[first,second];
 ViewerController *a=[ViewerController new],*b=[ViewerController new];a.window=[Window new];b.window=[Window new];a.window.screen=first;b.window.screen=second;
 a->previewMatrixScrollView=[NSObject new];b->previewMatrixScrollView=[NSObject new];
 for(int i=0;i<MAXSCREENS;i++)thumbnailsListPanel[i]=[Panel new];
 [a redrawToolbar];[b redrawToolbar];
 check(thumbnailsListPanel[0].window.visible && thumbnailsListPanel[1].window.visible);
 check(thumbnailsListPanel[0].viewer==a && thumbnailsListPanel[1].viewer==b);
 [a redrawToolbar];check(thumbnailsListPanel[1].window.visible);check(screenUpdateDepth==0);
 // Move A to B's display: release A's stale panel, attach A to its new screen.
 a.window.screen=second;[a redrawToolbar];check(thumbnailsListPanel[0].viewer==nil);check(thumbnailsListPanel[1].viewer==a);
 screens=@[first,second,[NSScreen new]];[a redrawToolbar];check(screenUpdateDepth==0);
 thumbnailsListPanel[1].fail=YES;@try{[a redrawToolbar];check(NO);}@catch(NSException *e){}check(screenUpdateDepth==0);thumbnailsListPanel[1].fail=NO;
 [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"UseFloatingThumbnailsList":@YES, @"SeriesListVisible":@NO} forName:NSArgumentDomain];
 [b redrawToolbar];check(!thumbnailsListPanel[0].window.visible && !thumbnailsListPanel[1].window.visible);
 NSLog(@"PASS: independent visible panels, owner reassignment, capacity bound, exception-safe display updates and global hide preference");
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-thumbnail-screens-') as tmp:
    test = viewer_redraw_toolbar.program(tmp, sys.argv[1] if len(sys.argv) > 1 else None, CLASS_METHODS, MAIN)
    subprocess.run([str(test)], check=True)
