#!/usr/bin/env python3
"""The 2017 NSAlert dealloc stack is MainMenu load, not plugin install.

horosproject/horos#214 crashed in -[NSAlert dealloc] while NSApplicationMain
was still loading a nib. A line number next to NSRunAlertPanel("Plugins
Installation") does not put that alert on that stack. AppController is created
from MainMenu.xib, so +initialize runs inside that loadNib, and the volume-wait
panel is the alert that helper owns.

AppController is Swift since #830: +initialize stayed in AppController+CAPI.m
and sends +initializeAppController, the Swift body of the former +initialize.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
failures = []

# Sanitized thread-0 stack from horosproject/horos#214. No UUID, no images.
HISTORICAL = """
objc_msgSend
-[NSAlert dealloc]
-[__NSSingleObjectArrayI dealloc]
AutoreleasePoolPage::pop
_CFAutoreleasePoolPop
loadNib
+[NSBundle(NSNibLoading) _loadNibFile:nameTable:options:withZone:ownerBundle:]
-[NSBundle(NSNibLoading) loadNibNamed:owner:topLevelObjects:]
+[NSBundle(NSNibLoading) loadNibNamed:owner:]
NSApplicationMain
start
"""

for frame in ('-[NSAlert dealloc]', 'loadNib',
              '+[NSBundle(NSNibLoading) loadNibNamed:owner:]', 'NSApplicationMain'):
    if frame not in HISTORICAL:
        failures.append('historical stack lost %s' % frame)

for frame in ('Plugins Installation', 'installPlugin', 'applicationDidFinishLaunching',
              'checkForUpdates', 'ViewerController'):
    if frame in HISTORICAL:
        failures.append('historical stack names a later caller: %s' % frame)

menu = (root / 'Horos/Resources/en.lproj/MainMenu.xib').read_bytes().decode('latin1')
info = (root / 'Horos/Info.plist').read_bytes().decode('latin1')
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
app = sources.source_text('AppController')
capi = sources.source_text('AppController+CAPI')
# NSPanel (N2) is Swift since #709; the assertions read its Swift spelling.
panel = sources.source_text('NSPanel+N2')
helper = (root / 'Horos/Sources/ModalAlertPanel.swift').read_text()

if 'NSMainNibFile' not in info or 'MainMenu' not in info:
    failures.append('the application no longer names MainMenu as the main nib')
if 'customClass="AppController"' not in menu:
    failures.append('MainMenu.xib no longer instantiates AppController')

def braced(source, start):
    """From `start` to the brace that closes the first block after it."""
    depth = 0
    for index in range(source.find('{', start), len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return ''


# The Objective-C +initialize is the forwarder; the Swift method is its body.
start = capi.find('+ (void) initialize')
if start < 0:
    start = capi.find('+ (void)initialize')
forwarder = braced(capi, start) if start >= 0 else ''
start = app.find('class func initializeAppController()')
if 'initializeAppController' not in forwarder or start < 0:
    failures.append('+[AppController initialize] is gone')
else:
    body = braced(app, start)
    if 'NSPanel.alert(withTitle:' not in body or 'DatabaseLocation.dataDirectoryName' not in body:
        failures.append('+initialize no longer raises the volume-wait panel during MainMenu load')
    if 'HorosAlertPanel.run' in body and 'Plugins Installation' in body:
        failures.append('plugin installation moved into +initialize')

if 'Plugins Installation' not in app or 'HorosAlertPanel.run' not in app:
    failures.append('the plugin-install alert, the false lead, disappeared')

code = [line for line in panel.splitlines() if not line.lstrip().startswith('//')]
if any('NSGetAlertPanel(' in line for line in code):
    failures.append('NSPanel+N2 builds an alert with NSGetAlertPanel again')
if not any('ModalAlertPanel.panel(' in line for line in code):
    failures.append('the volume-wait panel is not the Swift helper')
if 'objc_setAssociatedObject' not in helper:
    failures.append('ModalAlertPanel no longer keeps the NSAlert alive with its window')

if failures:
    print('FAIL: ' + '; '.join(failures))
    raise SystemExit(1)
print('PASS: 2017 stack is MainMenu loadNib, plugin install is not on it, and the volume-wait panel in +initialize keeps its NSAlert')
