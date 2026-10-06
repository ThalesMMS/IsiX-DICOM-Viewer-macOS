#!/usr/bin/env python3
"""A series drop must not wait for another viewer's load.

horosproject/horos#333 said drag-and-drop of a series sometimes froze Horos.
There is no spindump on that issue. The closest stack is hang 2 of the 3.1.2
hang pair:
loadSelectedSeries → changeImageData → isDataVolumic → checkEverythingLoaded.
That wait is not a distinct lock from the PapyrusLock cycle, not the RC
volume-discovery hang, and not the image-file promises.

The drop itself (DatabaseObjectXIDs → loadSelectedSeries) does not call
checkEverythingLoaded. The hang-shaped wait on this path is the peer
isDataVolumic probe inside changeImageData, which used to run
checkEverythingLoaded on every other same-study viewer. A drop while any of
those is still loading sleeps the main thread until that load finishes.

This test keeps the drop path attached to that reading and refuses to mix the
other fronts. It does not claim the 2018 Intel freeze is reproduced here.

-changeImageData:::: and -finalizeSeriesViewing are Swift
(ViewerController+RetrieveAndView.swift): the peer probe and the cancel are read
there, in their Swift spelling; the drop methods stay in ViewerController.m.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []
viewer = root / 'Horos/Sources/ViewerController.m'
browser = root / 'Horos/Sources/BrowserController.m'
policy_src = root / 'Horos/Sources/SeriesReplaceLoadPolicy.swift'
retrieve_and_view = sources.source_path('ViewerController+RetrieveAndView')


def body(path, signature):
    source = path.read_bytes().decode('latin1')
    start = 0
    while True:
        at = source.find(signature, start)
        if at < 0:
            return ''
        after = source[at + len(signature):].lstrip()
        if after.startswith('{'):
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
        start = at + 1


def check(condition, message):
    if not condition:
        failures.append(message)


def comments_stripped(text):
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


drop = body(viewer, '- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender')
xid_at = drop.find('DatabaseObjectXIDsPasteboardTypes')
xid = drop[xid_at:] if xid_at >= 0 else ''
# The filenames fallback is the next top-level else after the XID branch.
filenames_at = xid.find('NSFilenamesPboardType')
xid_branch = xid[:filenames_at] if filenames_at >= 0 else xid
load_sel = body(viewer, '- (void) loadSelectedSeries: (id) series rightClick: (BOOL) rightClick')
entered = body(viewer, '- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender')
updated = body(viewer, '- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender')
change = body(retrieve_and_view, 'func changeImageData(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!, _ newViewerWindow: Bool)')
peer_at = change.find('Try to find another viewer')
peer = change[peer_at:peer_at + 900] if peer_at >= 0 else ''
finalize = body(retrieve_and_view, 'func finalizeSeriesViewing()')
close = body(viewer, '- (void)windowWillClose:(NSNotification *)notification')
loaded = body(viewer, '-(void) checkEverythingLoaded')
two_arg = body(viewer, '- (BOOL) isDataVolumicIn4D: (BOOL) check4D checkEverythingLoaded:(BOOL) c;')
# O2ViewerThumbnailsMatrix is Swift.
thumb = sources.source_text('O2ViewerThumbnailsMatrix')

# --- drop of a series is loadSelectedSeries, not a load wait -----------------
check(xid_branch and 'loadSelectedSeries:' in xid_branch,
      'the DatabaseObjectXIDs drop must still load the series')
check('checkEverythingLoaded' not in comments_stripped(xid_branch),
      'the series drop itself must not wait for checkEverythingLoaded')
check('checkEverythingLoaded' not in comments_stripped(load_sel),
      'loadSelectedSeries: must not wait for the current load before replacing')
check('loadSeries' in load_sel,
      'loadSelectedSeries: must still hand the series to BrowserController')
check('checkEverythingLoaded' not in comments_stripped(entered),
      'draggingEntered: must not wait for a load')
check('checkEverythingLoaded' not in comments_stripped(updated),
      'draggingUpdated: must not wait for a load')
check('loadSelectedSeries:' not in entered and 'loadSeries' not in entered,
      'draggingEntered: must not start a series load')
check('loadSelectedSeries:' not in updated and 'loadSeries' not in updated,
      'draggingUpdated: must not start a series load')
check('O2PasteboardTypeDatabaseObjectXIDs' in thumb and 'beginDraggingSession(with:' in thumb,
      'thumbnail drag must still advertise series XIDs, not a file promise')

# --- the hang-2 wait on this path is the peer volumic probe ------------------
check(peer and 'v !== self' in peer,
      'changeImageData must still look at peer viewers for slice position')
check(not re.search(r'\bv\.isDataVolumic\b', peer),
      'peer probe still uses isDataVolumic, which waits for that viewer to finish loading')
check('SeriesReplaceLoadPolicy.' in peer,
      'peer probe must take its wait/correct flags from SeriesReplaceLoadPolicy')
check('peerVolumicProbeWaitsForLoad' in peer and 'peerVolumicProbeCorrectsPeer' in peer,
      'peer probe must name both policy flags')
# The two-argument form forwards wait/4D flags but still corrects.
check(not re.search(r'isDataVolumicIn4D\(\s*false\s*,\s*checkEverythingLoaded:\s*true\s*\)',
                     comments_stripped(peer)),
      'peer probe must not call the two-argument overload that still corrects')

# --- do not import the other waits, and do not touch the other fronts --------
# windowWillClose: closes the viewer's series load, which waits.
series_load = (root / 'Horos/Sources/ViewerSeriesLoad.swift').read_text()
cancel = series_load[series_load.find('    @objc public func cancel()'):series_load.find('    @objc public func requestCancel()')]
retire = series_load[series_load.find('    private func retire('):]
check(finalize and 'self.horosSeriesLoad.cancel()' in finalize and 'retire(cancelling: true)' in cancel
      and 'if cancelling { worker.cancel() }' in retire and 'sleep' not in cancel,
      'finalizeSeriesViewing must still cancel the current load on replace')
check('sleepForTimeInterval' not in finalize and 'sleep(forTimeInterval' not in finalize,
      'do not join the cancelled load the way windowWillClose: does (hang 1 of the 3.1.2 pair)')
close_wait = series_load[series_load.find('    @objc public func close()'):series_load.find('    private func retire(')]
check(close and '[self.horosSeriesLoad close];' in close and 'Thread.sleep(forTimeInterval: 0.01)' in close_wait
      and 'horos_loadingThread' in close_wait,
      'windowWillClose: keeps its wait; the drop fix does not remove it')
check(loaded and 'sleepForTimeInterval' in loaded,
      'checkEverythingLoaded still exists; do not pretend this issue removed it')
check('NSFilePromiseProvider' not in drop and 'HorosDraggedImagePromise' not in drop,
      'the series-drop destination must not be rewritten as the image-file promise')
check('_analyzeVolumeAtPath:' not in drop and '_analyzeVolumeAtPath:' not in load_sel,
      'do not route the series-drop hang through the volume-discovery path')
check('[PapyrusLock lock]' not in drop and '[PapyrusLock lock]' not in load_sel,
      'do not import the PapyrusLock cycle into the drop methods')

# The two-argument wrapper forwards both flags and still corrects.
check(two_arg and 'isDataVolumicIn4D: check4D checkEverythingLoaded: c tryToCorrect: YES' in comments_stripped(two_arg),
      'the two-argument isDataVolumicIn4D:checkEverythingLoaded: must forward check4D and c')
check('isDataVolumicIn4D: NO checkEverythingLoaded: YES tryToCorrect: YES' not in comments_stripped(two_arg),
      'the two-argument overload must not discard its flags')

# --- Swift policy: no wait, no mutation of the peer, drop replaces ----------
check(policy_src.is_file(), 'SeriesReplaceLoadPolicy.swift is missing')
if policy_src.is_file():
    code = r'''
import Foundation

@main struct Test {
 static func main() {
  precondition(SeriesReplaceLoadPolicy.peerVolumicProbeWaitsForLoad == false,
               "a peer used only for slice millimetres must not block the drop")
  precondition(SeriesReplaceLoadPolicy.peerVolumicProbeCorrectsPeer == false,
               "accepting a drop must not correct another viewer's geometry")
  precondition(SeriesReplaceLoadPolicy.seriesDropWaitsForCurrentLoad == false,
               "the drop must not wait for the current series to finish loading")
  precondition(SeriesReplaceLoadPolicy.decision(closing: true, alreadyDisplayed: false, inFourDGroup: false)
               == "ignoreClosing")
  precondition(SeriesReplaceLoadPolicy.decision(closing: false, alreadyDisplayed: true, inFourDGroup: true)
               == "switchFourDIndex")
  precondition(SeriesReplaceLoadPolicy.decision(closing: false, alreadyDisplayed: true, inFourDGroup: false)
               == "ignoreAlreadyDisplayed")
  precondition(SeriesReplaceLoadPolicy.decision(closing: false, alreadyDisplayed: false, inFourDGroup: false)
               == "replaceWithoutWaitingForLoad")
  print("ok: series replace policy does not wait for a peer or current load")
 }
}
'''
    with tempfile.TemporaryDirectory(prefix='horos-series-drag-') as folder:
        test_file = Path(folder) / 'test.swift'
        test_file.write_text(code)
        compiled = Path(folder) / 'test'
        compiled_run = subprocess.run(
            ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
             str(policy_src), str(test_file), '-framework', 'Foundation',
             '-o', str(compiled)],
            capture_output=True, text=True)
        if compiled_run.returncode != 0:
            failures.append('swiftc SeriesReplaceLoadPolicy: ' + compiled_run.stderr.strip())
        else:
            ran = subprocess.run([str(compiled)], capture_output=True, text=True)
            if ran.returncode != 0:
                failures.append('SeriesReplaceLoadPolicy: ' + (ran.stderr or ran.stdout).strip())

if failures:
    for item in failures:
        print('FAIL:', item)
    sys.exit(1)
print('ok: series drop does not wait for a peer load; file promises, the 3.1.2 hangs, the volume hang and the PapyrusLock cycle stay distinct')
