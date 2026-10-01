#!/usr/bin/env python3
"""Exercise the production cursor gate for all four viewer mouse handlers.

-mouseUp:, -mouseMoved:, -mouseDown: and the gate's helper stay in DCMView.m;
-mouseDragged: is Swift since #834, in DCMView+MouseDragging.swift. Its gate
line is compiled as it is, with xcrun swiftc, in an extension of the same
Objective-C double the other three handlers run in. A revision given as the
argument that predates #834 runs its Objective-C -mouseDragged: gate instead.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import subprocess,sys,tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402
root=Path(__file__).resolve().parents[1]
path='Horos/Sources/DCMView.m'
s=(subprocess.check_output(['git','show',sys.argv[1]+':'+path],cwd=root) if len(sys.argv)>1 else (root/path).read_bytes()).decode('latin1')
if len(sys.argv)>1:
 run=subprocess.run(['git','show',sys.argv[1]+':Horos/Sources/DCMView+MouseDragging.swift'],cwd=root,capture_output=True)
 swift=run.stdout.decode('utf-8') if run.returncode==0 else None
else:
 swift=source_text('DCMView+MouseDragging')
if len(sys.argv) == 1:
 assert 'CGCursorIsVisible()' not in s, 'production routing must not use unsupported global cursor visibility'
helper=''
if '- (BOOL) shouldIgnoreHiddenCursorEvent:' in s:
 a=s.index('- (BOOL) shouldIgnoreHiddenCursorEvent:');b=s.index('- (void)mouseUp:',a);helper=s[a:b]
handlers=[]
markers=['- (void)mouseUp:','-(void) mouseMoved:','- (void) mouseDown:']+([] if swift else ['- (void)mouseDragged:'])
for i,marker in enumerate(markers):
 a=s.index(marker);gate=next(line for line in s[a:].splitlines() if 'CGCursorIsVisible() == NO' in line or 'if( [self shouldIgnoreHiddenCursorEvent:' in line)
 handlers.append(f'-(void)handler{i}:(Event*)event {{Event*theEvent=event;{gate}\n delivered++;}}')
extension=None
if swift:
 a=swift.index('    @objc(mouseDragged:)')
 gate=next(line for line in swift[a:].splitlines() if 'if self.shouldIgnoreHiddenCursorEvent(' in line)
 extension=f'''import Foundation
extension View {{
    @objc(handler3:) func handler3(_ event: Event) {{
{gate}
        self.delivered += 1
    }}
}}
'''
bridge=r'''
#import <Foundation/Foundation.h>
@interface Event:NSObject
@property(retain) NSObject*window;
@end
@interface View:NSObject {
@public BOOL lensActive;int delivered;
}
@property(retain) NSObject*window;
@property int delivered;
HELPERDECL
@end
'''.replace('HELPERDECL','-(BOOL)shouldIgnoreHiddenCursorEvent:(Event*)event;' if swift else '')
code=r'''
#import "bridge.h"
SWIFTHEADER
@implementation Event
@end
#define NSEvent Event
#define NSWindow NSObject
static BOOL cursorVisible;
#define CGCursorIsVisible() cursorVisible
@implementation View
@synthesize delivered;
HELPER
HANDLERS
@end
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 for(int visible=0;visible<2;visible++)for(int lens=0;lens<2;lens++)for(int receiver=0;receiver<2;receiver++)for(int destination=0;destination<3;destination++){
  View*v=[View new];v.window=receiver?[NSObject new]:nil;
  Event*e=[Event new];e.window=destination==0?nil:(destination==1?v.window:[NSObject new]);
  cursorVisible=visible;v->lensActive=lens;
  BOOL accept=LEGACYVISIBLE lens || (receiver && destination==1);
  [v handler0:e];[v handler1:e];[v handler2:e];[v handler3:e];
  check(v->delivered==(accept?4:0));
 }
 NSLog(@"PASS: down/up/move/drag, visible/hidden cursor, local/foreign/missing windows independent of visibility, loupe compatibility");
}}
'''.replace('LEGACYVISIBLE','visible ||' if len(sys.argv)>1 else '').replace('SWIFTHEADER','#import "Harness-Swift.h"' if swift else '').replace('HELPER',helper).replace('HANDLERS','\n'.join(handlers))
with tempfile.TemporaryDirectory(prefix='horos-cursor-events-') as d:
 p=Path(d);(p/'test.m').write_text(code);(p/'bridge.h').write_text(bridge)
 if extension:
  (p/'dragged.swift').write_text(extension)
  subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-name','Harness',
    '-import-objc-header',str(p/'bridge.h'),'-emit-objc-header','-emit-objc-header-path',str(p/'Harness-Swift.h'),
    '-c',str(p/'dragged.swift'),'-o',str(p/'dragged.o')],check=True)
  subprocess.run(['xcrun','clang','-c','-fno-objc-arc','-fsanitize=undefined','-I',str(p),str(p/'test.m'),'-o',str(p/'test.o')],check=True)
  subprocess.run(['xcrun','swiftc',str(p/'dragged.o'),str(p/'test.o'),'-framework','Foundation','-sanitize=undefined','-o',str(p/'test')],check=True)
 else:
  subprocess.run(['xcrun','clang','-fno-objc-arc','-fsanitize=undefined','-framework','Foundation','-I',str(p),str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
