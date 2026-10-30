#!/usr/bin/env python3
"""Retrieve-and-view reaches the host viewer through the existing routes.

Source level, on the real methods, with `<git revision>` as an optional
argument for the negative control:

* the query controller begins one viewing session per selected item, opens a
  pending item on the database batch that brings its study (not only on the
  one-second timer), keeps polling while the transfer runs, records the
  opening, and settles the state from the peer's counters and the confirmed
  inventory when the transfer thread ends; a completed C-STORE for a pending
  study nudges the importer;
* the viewer coalesces same-series reloads, restores the operator's image by
  SOP instance and frame instead of resetting to the first, and reports the
  new local count;
  (its -retrieveStatusOverlay, -isReceivingPartialSeries and
  -retrieveViewingStateChanged: are Swift, in
  ViewerController+RetrieveAndView.swift, declared for Objective-C in
  ViewerController+RetrieveAndView.h, which ViewerController.h imports;)
* the image view draws the retrieve status over the image;
* the preference that gates the new arrival behaviour is registered on.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]


def read(path):
    if len(sys.argv) > 1:
        return subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]).decode('latin1')
    return ((root / path).read_bytes() if (root / path).exists() else b'').decode('latin1')


def read_if_present(path):
    """A file added by the Swift migration: absent at an older revision given for the negative control."""
    if len(sys.argv) > 1:
        shown = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return shown.stdout.decode('latin1') if shown.returncode == 0 else ''
    return (root / path).read_bytes().decode('latin1')


# The Query window is Swift, split by responsibility; what it exposes to the
# Objective-C callers is its @objc declarations.
query = ''.join(read('Horos/Sources/%s.swift' % name) for name in (
    'QueryController', 'QueryController+Retrieve', 'QueryController+Results'))
viewer = read('Horos/Sources/ViewerController.m')
viewer_header = read('Horos/Sources/ViewerController.h')
viewer_retrieve = read_if_present('Horos/Sources/ViewerController+RetrieveAndView.swift')
viewer_retrieve_header = read_if_present('Horos/Sources/ViewerController+RetrieveAndView.h')
# -drawOrientation:, which draws the status, is Swift; a revision
# before it has the Objective-C in DCMView.m, which is read only then.
ORIENTATION = 'Horos/Sources/DCMView+WindowLevel+Coordinates.swift'
if len(sys.argv) > 1:
    shown = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + ORIENTATION], capture_output=True)
    orientation = shown.stdout.decode('utf-8') if shown.returncode == 0 else None
else:
    orientation = (root / ORIENTATION).read_text(encoding='utf-8') if (root / ORIENTATION).is_file() else None
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()
failures = []


def method(source, signature, terminator='\n}\n'):
    start = source.find(signature)
    if start < 0:
        return ''
    return source[start:source.find(terminator, start) + len(terminator)]


# --- query controller ---------------------------------------------------------
END = '\n    }\n'
begin = method(query, '    public func retrieveAndView(_ sender: Any?) {\n', END)
if 'RetrieveViewing.shared.begin(studyUID: QueryController.viewingStudyUID(item), seriesUID: QueryController.viewingSeriesUID(item), at: now)' not in begin:
    failures.append('retrieveAndView: does not begin a viewing session per selected item')
if begin.find('retrieve(self, onlyIfNotAvailable: true, forViewing: true)') < begin.find('RetrieveViewing.shared.begin('):
    failures.append('the session must exist before the transfer starts, or the first batch cannot open it')

added = method(query, '    nonisolated func observeDatabaseAddNotification(_ notification: Notification) {\n', END)
if 'concernsPending(studyUIDs:' not in added or '#selector(openPendingRetrieveAndViewItems(forStudyUIDs:))' not in added:
    failures.append('a database batch does not open the pending items it concerns')
if 'series.study.studyInstanceUID' not in added:
    failures.append('the batch must be matched by study instance UID')

check = method(query, '    func checkAndView(_ item: Any?) {\n', END) + \
    method(query, '    private func checkAndView(_ item: Any?, in context: NSManagedObjectContext,', END)
if 'if checkAndViewTry < 0 && !pending {' not in check:
    failures.append('checkAndView: still gives up on the timer alone')
if check.count('RetrieveViewing.shared.viewerOpened(studyUID:') != 2:
    failures.append('both the study and the series opening must be recorded (found %d)' % check.count('RetrieveViewing.shared.viewerOpened(studyUID:'))
if 'let tries = self.checkAndViewTry\n                    self.checkAndViewTry -= 1\n                    if (tries > 0 || stillPending) && self.sendToPopup.indexOfSelectedItem == 0 {' not in check:
    failures.append('checkAndView: does not keep polling while the transfer runs')

perform = method(query, '    public nonisolated func performRetrieve(_ array: [Any]!) {\n', END) + \
    method(query, '    private nonisolated func performRetrieveOnThisThread(_ given: [Any]) {\n', END)
settle = method(query, '    nonisolated func settleRetrieveViewing(forItems items: [Any]!, cancelled: Bool) {\n', END)
# Cancellation is read on the transfer thread, as the argument; settling hops
# to the main thread itself.
if 'settleRetrieveViewing(forItems: array, cancelled: Thread.current.isCancelled)' not in perform \
        or 'DispatchQueue.main.async' not in settle:
    failures.append('the end of the transfer thread does not settle the viewing state on the main thread')
if 'viewing.transferEnded(studyUID:' not in settle:
    failures.append('settling does not end the viewing session')
for needed in ('countOfSuboperations', 'countOfSuccessfulSuboperations', 'imageInventoryConfirmed', 'localCompleteness(forItem:',
               'node.retrieveInventory', 'inventory.inventoryConfirmed', 'inventory.scopeImportedCount', 'inventory.scopeExpectedCount'):
    if needed not in settle:
        failures.append('the settled state ignores %s' % needed)
refresh = method(query, '    nonisolated func retrieveInventoryDidRefresh(_ notification: Notification) {\n', END)
if 'importedCountChanged(studyUID:' not in refresh or 'inventory.scopeImportedCount' not in refresh:
    failures.append('what is indexed after the transfer ended does not reach the viewing state')
if 'guard Thread.isMainThread else {' not in settle:
    failures.append('settling can run off the main thread, where the state is not read')

# A transfer that never starts still has to end the session it was begun for:
# an already complete study, one already in transfer, or a selection refused
# because the destination is another node.
retrieve = method(query, '    func retrieve(_ sender: Any?, onlyIfNotAvailable: Bool, forViewing: Bool, items: [Any]!, showGUI: Bool) {\n', END)
if 'settleRetrieveViewing(forItems: unstarted' not in retrieve:
    failures.append('a viewing session whose transfer never starts is never settled; the viewer keeps saying "transfer in progress"')
if 'startedTransfer = true' not in retrieve or 'if startedTransfer {' not in retrieve:
    failures.append('the items handed to the transfer thread are not told apart from the ones that were not')
if 'unstarted.removeObjects(in: selectedItems' not in retrieve:
    failures.append('items that did start a transfer would be settled twice')

nudge = method(query, '    nonisolated func observeStoreCompletedNotification(_ notification: Notification) {\n', END)
if 'importNudgeWanted(studyUID:' not in nudge or 'initiateImportFilesFromIncomingDirUnlessAlreadyImporting' not in nudge:
    failures.append('a completed C-STORE does not nudge the importer')
if 'name: NSNotification.Name("HorosDICOMStoreCompleted")' not in query:
    failures.append('the store-completed notification is not observed')

for declaration in ('@objc(pendingRetrieveAndViewItems)\n    public nonisolated func pendingRetrieveAndViewItems() -> [Any] {',
                    '@objc(openPendingRetrieveAndViewItemsForStudyUIDs:)\n    public func openPendingRetrieveAndViewItems(forStudyUIDs studyUIDs: [Any]!) {'):
    if declaration not in query:
        failures.append('QueryController does not expose %r' % declaration.split('\n')[0])

# --- viewer -------------------------------------------------------------------
refresh = method(viewer, '-(void)refreshDatabase:(NSArray*)newImages\n')
# Since the class is Swift, -refreshDatabase: is in ViewerController+DatabaseRefresh.swift
# and the observers are registered in ViewerController+Lifecycle.swift.
swift_refresh = read_if_present('Horos/Sources/ViewerController+DatabaseRefresh.swift') if not refresh else ''
swift_lifecycle = read_if_present('Horos/Sources/ViewerController+Lifecycle.swift') if not refresh else ''
if swift_refresh:
    refresh = swift_refresh[swift_refresh.index('    public override func refreshDatabase(_ newImages: [Any]!) {'):]
    spelled = {'[coalescer requestAt: now]': 'coalescer?.request(at: now)',
               'indexOfSOPInstanceUID: shownSOP frame: shownFrame': 'RetrieveViewing.index(ofSOPInstanceUID: shownSOP, frame: shownFrame',
               'shownSOP = ': 'let shownSOP = ',
               'openViewerFromImages:': '.openViewer(fromImages:',
               'localCountChangedForStudyUID:': 'RetrieveViewing.shared.localCountChanged(studyUID:',
               '[coalescer appliedAt:': 'coalescer?.applied(at:',
               'afterDelay: wait': 'afterDelay: wait'}
else:
    spelled = {key: key for key in ('[coalescer requestAt: now]', 'indexOfSOPInstanceUID: shownSOP frame: shownFrame', 'shownSOP = ',
                                    'openViewerFromImages:', 'localCountChangedForStudyUID:', '[coalescer appliedAt:', 'afterDelay: wait')}
if spelled['[coalescer requestAt: now]'] not in refresh or spelled['afterDelay: wait'] not in refresh:
    failures.append('same-series reloads are not coalesced')
if spelled['indexOfSOPInstanceUID: shownSOP frame: shownFrame'] not in refresh:
    failures.append('the reload does not restore the operator\'s image by SOP instance and frame')
if refresh.find(spelled['shownSOP = ']) > refresh.find(spelled['openViewerFromImages:']):
    failures.append('the shown image must be captured before the reload replaces the lists')
if spelled['localCountChangedForStudyUID:'] not in refresh:
    failures.append('the reload does not report the new local count')
if spelled['[coalescer appliedAt:'] not in refresh:
    failures.append('the coalescer is never told a reload ran')

for signature in ('@objc(retrieveStatusOverlay)\n    func retrieveStatusOverlay() -> String! {\n',
                  '@objc(isReceivingPartialSeries)\n    func isReceivingPartialSeries() -> Bool {\n',
                  '@objc(retrieveViewingStateChanged:)\n    func retrieveViewingStateChanged(_ note: Notification!) {\n'):
    if not method(viewer_retrieve, signature, '\n    }\n'):
        failures.append('ViewerController+RetrieveAndView.swift lacks %s' % signature.strip().split('\n')[0])
if 'name:@"HorosRetrieveViewingStateDidChange"' not in viewer \
        and 'name: Notification.Name("HorosRetrieveViewingStateDidChange")' not in (swift_lifecycle or ''):
    failures.append('the viewer does not redraw on a state change')
if '#import "ViewerController+RetrieveAndView.h"' not in viewer_header:
    failures.append('ViewerController.h does not import ViewerController+RetrieveAndView.h')
# Objective-C sees the two by their @objc names, through the generated interface.
for declaration in ('@objc(retrieveStatusOverlay)', '@objc(isReceivingPartialSeries)'):
    if declaration not in (viewer_retrieve or ''):
        failures.append('ViewerController+RetrieveAndView.swift does not export %r' % declaration)

# --- image view ---------------------------------------------------------------
if orientation is None:
    view = read('Horos/Sources/DCMView.m')
    if 'retrieveStatusOverlay]' not in view or 'DrawNSStringGL: receiving' not in view:
        failures.append('DCMView does not draw the retrieve status')
    if view.find('DrawNSStringGL: receiving') < view.find('self.curDCM.missingPixelsReason.length'):
        failures.append('the retrieve status must follow the missing-pixels reason, both truthful about the frame')
else:
    if ('private let kRetrieveStatusOverlay = #selector(ViewerController.retrieveStatusOverlay)' not in orientation
            or 'objcProperty(objcObject(self.windowController()), kRetrieveStatusOverlay)' not in orientation
            or 'self.drawNSStringGL(receiving as String?' not in orientation):
        failures.append('DCMView does not draw the retrieve status')
    if orientation.find('self.drawNSStringGL(receiving as String?') < orientation.find('if ((objcProperty(self.curDCM, kMissingPixelsReasonGetter) as! NSString?)?.length ?? 0) != 0 {'):
        failures.append('the retrieve status must follow the missing-pixels reason, both truthful about the frame')

# --- preference ---------------------------------------------------------------
if defaults.get('HorosProgressiveRetrieveViewing') != 'YES':
    failures.append('HorosProgressiveRetrieveViewing is not registered on by default')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: retrieve-and-view is wired through the query window, the viewer reload and the image overlay')
