#!/usr/bin/env python3
"""Nothing raises a modal panel from inside `applicationDidFinishLaunching:`.

"It hangs on startup" covers several different things, and they are told apart by
one question - what is the main thread's stack right now.
`tools/probe-startup-blocking.py` asks it once a second and prints the answer, so
each report can be given a cause instead of a guess.

The first thing it found: with the DICOM listener off and the Query/Retrieve
window open at quit, the main thread sat here for as long as it was watched -

    main -> applicationDidFinishLaunching: -> initAutoQuery: (QueryController.mm:4898)
         -> NSRunCriticalAlertPanel -> runModalForWindow:

- because `-applicationDidFinishLaunching:` builds that window, and building it
  raised a critical panel about the listener. The launch does not finish while a
modal panel is up, and the statement right after the one that raised it is
`[[QueryController currentQueryController] showWindow: self]`, so the panel
appeared with no Q&R window behind it to explain what it was about.

Raised on the next turn of the run loop instead, the stack becomes

    main -> __33-[QueryController initAutoQuery:]_block_invoke -> NSRunCriticalAlertPanel

with `applicationDidFinishLaunching:` gone from it, and the windows are on screen:
`get name of every window` answers "DICOM Query/Retrieve, ..., db DB, ...".

That turn is the main run loop's, not the main queue's: a modal inside a block of
the queue stops the queue until someone answers, and with no one at the machine an
import waiting for it received nothing. The two warnings go through `onMainRunLoop`;
the program below runs the real function in a real launch, with the main queue as
its control.
"""
from pathlib import Path
import ast
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
query = (root / 'Horos/Sources/QueryController.swift').read_text(encoding='utf-8')
probe = root / 'tools/probe-startup-blocking.py'


def body(signature, source):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
        index += 1
    return ''


def startup_panel_problems(region):
    live = re.sub(r'//[^\n]*', '', region)
    panels = [m.start() for m in re.finditer(
        r'\bHorosAlertPanel\.run(?:Critical|Informational)?\s*\(', live)]
    problems = []
    if len(panels) < 2:
        problems.append('one of the two warnings this window raises is gone: no DICOM locations, '
                        'and the listener not running')
    deferred = []
    for callback in re.finditer(r'\bonMainRunLoop\s*\{', live):
        opening = callback.end() - 1
        depth = 0
        for index in range(opening, len(live)):
            depth += (live[index] == '{') - (live[index] == '}')
            if depth == 0:
                deferred.append((opening, index))
                break
    if any(not any(start < panel < end for start, end in deferred) for panel in panels):
        problems.append('a warning does not come from the main run loop: raised inline, a window '
                        'built during applicationDidFinishLaunching: stops the launch on a modal '
                        'panel; raised from the main queue, it stops that queue')
    if 'listenerRequired(forServers:' not in live:
        problems.append('the warning no longer asks whether any node actually needs the listener')
    return problems


# --- the listener panel does not hold up the launch ---------------------------
region = body('public convenience init!(autoQuery autoQR: Bool)', query)
if not region:
    failures.append('-initAutoQuery: is gone')
else:
    failures.extend(startup_panel_problems(region))
    if not startup_panel_problems(region):
        # The compatibility wrapper still runs a modal alert, so renaming must
        # preserve this launch-deferral test. Mutants are rejected by behavior.
        assert not startup_panel_problems(region.replace('HorosAlertPanel.runCritical(', 'HorosAlertPanel.run('))
        for site in range(2):
            parts = region.split('onMainRunLoop {')
            mutant = 'onMainRunLoop {'.join(parts[:site + 1]) + 'DispatchQueue.main.async {' \
                + 'onMainRunLoop {'.join(parts[site + 1:])
            assert startup_panel_problems(mutant), 'the main queue passed at warning %d' % site
        assert startup_panel_problems(region.replace('HorosAlertPanel.runCritical', 'missingPanel', 1))
        assert startup_panel_problems(region.replace('listenerRequired(forServers:', 'missingRequirement('))
        assert startup_panel_problems('onMainRunLoop {}'
                                      'HorosAlertPanel.runCritical(); HorosAlertPanel.runCritical();'
                                      'listenerRequired(forServers:')

# --- in a launch, the panel waits for it and leaves the main queue served -----
LAUNCH = r'''
import AppKit

nonisolated(unsafe) var launchReturned = false
nonisolated(unsafe) var queueServed = false

@MainActor func raisePanel() {
    let raisedAfterLaunch = launchReturned
    let panel = NSPanel(contentRect: NSRect(x: -9000, y: -9000, width: 1, height: 1),
                        styleMask: .borderless, backing: .buffered, defer: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        queueServed = true
        MainActor.assumeIsolated { NSApp.abortModal() }
    }
    // Timers run in the modal mode, whatever happens to the queue.
    RunLoop.main.add(Timer(timeInterval: 3, repeats: false) { _ in
        MainActor.assumeIsolated { NSApp.abortModal() }
    }, forMode: .common)
    NSApp.runModal(for: panel)
    print("raisedAfterLaunch=\(raisedAfterLaunch) queueServed=\(queueServed)")
    exit(0)
}

final class LaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("queue") {
            DispatchQueue.main.async { MainActor.assumeIsolated { raisePanel() } }
        } else {
            onMainRunLoop { raisePanel() }
        }
        launchReturned = true
    }
}

let delegate = LaunchDelegate()
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
'''

with tempfile.TemporaryDirectory() as scratch:
    scratch = Path(scratch)
    (scratch / 'main.swift').write_text(LAUNCH, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'LaunchPanel',
                            str(root / 'Horos/Sources/MainActorCallbacks.swift'), str(scratch / 'main.swift'),
                            '-o', str(scratch / 'launch')], capture_output=True, text=True, timeout=180)
    if built.returncode != 0:
        failures.append('the launch program does not build:\n%s' % built.stderr[-2000:])
    else:
        def launch(*arguments):
            return subprocess.run([str(scratch / 'launch'), *arguments], capture_output=True,
                                  text=True, timeout=30).stdout.strip()

        answer = launch()
        if answer != 'raisedAfterLaunch=true queueServed=true':
            failures.append('onMainRunLoop in a launch: %r' % answer)
        control = launch('queue')
        if control != 'raisedAfterLaunch=true queueServed=false':
            failures.append('the control did not starve the main queue, so the check proves '
                            'nothing: %r' % control)

# --- and the probe that says so is here ---------------------------------------
if not probe.exists():
    failures.append('the tool that samples the main thread during startup is gone')
else:
    text = probe.read_text()
    try:
        ast.parse(text)
    except SyntaxError as error:
        failures.append('the probe does not parse: %s' % error)
    for needed in ('sample', 'com.apple.main-thread'):
        if needed not in text:
            failures.append('the probe does not read the main thread from sample(1): %r missing'
                            % needed)
    if 'interval' not in text:
        failures.append('the probe takes a single sample, so it cannot tell a block from work')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the two warnings wait for the launch to finish and leave the main queue served, and '
      'the main thread can be sampled while an application starts')
