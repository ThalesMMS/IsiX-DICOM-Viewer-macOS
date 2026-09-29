#!/usr/bin/env python3
"""Retrieve-and-view reaches the host viewer through the existing routes (#604).

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
  -retrieveViewingStateChanged: are Swift since #832, in
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
    return (root / path).read_bytes().decode('latin1')


def read_if_present(path):
    """A file added by #832: absent at an older revision given for the negative control."""
    if len(sys.argv) > 1:
        shown = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return shown.stdout.decode('latin1') if shown.returncode == 0 else ''
    return (root / path).read_bytes().decode('latin1')


query = read('Horos/Sources/QueryController.mm')
query_header = read('Horos/Sources/QueryController.h')
viewer = read('Horos/Sources/ViewerController.m')
viewer_header = read('Horos/Sources/ViewerController.h')
viewer_retrieve = read_if_present('Horos/Sources/ViewerController+RetrieveAndView.swift')
viewer_retrieve_header = read_if_present('Horos/Sources/ViewerController+RetrieveAndView.h')
view = read('Horos/Sources/DCMView.m')
# -drawOrientation:, which draws the status, is Swift since #834; a revision
# before it has the Objective-C in DCMView.m.
ORIENTATION = 'Horos/Sources/DCMView+WindowLevel+Coordinates.swift'
if len(sys.argv) > 1:
    shown = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + ORIENTATION], capture_output=True)
    orientation = shown.stdout.decode('utf-8') if shown.returncode == 0 else None
else:
    orientation = (root / ORIENTATION).read_text(encoding='utf-8') if (root / ORIENTATION).is_file() else None
defaults = read('Horos/Sources/DefaultsOsiriX.m')
failures = []


def method(source, signature, terminator='\n}\n'):
    start = source.find(signature)
    if start < 0:
        return ''
    return source[start:source.find(terminator, start) + len(terminator)]


# --- query controller ---------------------------------------------------------
begin = method(query, '- (IBAction) retrieveAndView: (id) sender\n')
if 'beginStudyUID: HorosViewingStudyUID( item) seriesUID: HorosViewingSeriesUID( item) at: now]' not in begin:
    failures.append('retrieveAndView: does not begin a viewing session per selected item')
if begin.find('[self retrieve: self onlyIfNotAvailable: YES forViewing: YES]') < begin.find('beginStudyUID:'):
    failures.append('the session must exist before the transfer starts, or the first batch cannot open it')

added = method(query, '-(void)observeDatabaseAddNotification:(NSNotification*)notification\n')
if 'concernsPendingStudyUIDs:' not in added or 'openPendingRetrieveAndViewItemsForStudyUIDs:' not in added:
    failures.append('a database batch does not open the pending items it concerns')
if 'series.study.studyInstanceUID' not in added:
    failures.append('the batch must be matched by study instance UID')

check = method(query, '- (void) checkAndView:(id) item\n')
if 'if( checkAndViewTry < 0 && pending == NO)' not in check:
    failures.append('checkAndView: still gives up on the timer alone')
if check.count('viewerOpenedForStudyUID:') != 2:
    failures.append('both the study and the series opening must be recorded (found %d)' % check.count('viewerOpenedForStudyUID:'))
if 'if( (checkAndViewTry-- > 0 || stillPending) && [sendToPopup indexOfSelectedItem] == 0)' not in check:
    failures.append('checkAndView: does not keep polling while the transfer runs')

perform = method(query, '- (void) performRetrieve:(NSArray*) array\n')
if 'settleRetrieveViewingForItems:' not in perform or 'dispatch_async( dispatch_get_main_queue()' not in perform:
    failures.append('the end of the transfer thread does not settle the viewing state on the main thread')
if 'retrieveCancelled = [[NSThread currentThread] isCancelled]' not in perform:
    failures.append('cancellation must be read on the transfer thread, before dispatching')

settle = method(query, '- (void) settleRetrieveViewingForItems: (NSArray*) items cancelled: (BOOL) cancelled\n')
if 'transferEndedForStudyUID:' not in settle:
    failures.append('settling does not end the viewing session')
for needed in ('countOfSuboperations', 'countOfSuccessfulSuboperations', 'imageInventoryConfirmed', 'localCompletenessForItem:',
               '[node retrieveInventory]', 'inventory.inventoryConfirmed', 'inventory.importedCount'):
    if needed not in settle:
        failures.append('the settled state ignores %s' % needed)
if '[NSThread isMainThread] == NO' not in settle:
    failures.append('settling can run off the main thread, where the state is not read')

# A transfer that never starts still has to end the session it was begun for:
# an already complete study, one already in transfer, or a selection refused
# because the destination is another node (#610).
retrieve = method(query, '-(void) retrieve:(id)sender onlyIfNotAvailable:(BOOL) onlyIfNotAvailable forViewing: (BOOL) forViewing items:(NSArray*) items showGUI:(BOOL) showGUI\n')
if 'settleRetrieveViewingForItems: unstarted' not in retrieve:
    failures.append('a viewing session whose transfer never starts is never settled; the viewer keeps saying "transfer in progress"')
if 'startedTransfer = YES' not in retrieve or 'if( startedTransfer)' not in retrieve:
    failures.append('the items handed to the transfer thread are not told apart from the ones that were not')
if 'removeObjectsInArray: selectedItems' not in retrieve:
    failures.append('items that did start a transfer would be settled twice')

nudge = method(query, '- (void) observeStoreCompletedNotification:(NSNotification*) notification\n')
if 'importNudgeWantedForStudyUID:' not in nudge or 'initiateImportFilesFromIncomingDirUnlessAlreadyImporting' not in nudge:
    failures.append('a completed C-STORE does not nudge the importer')
if 'name:@"HorosDICOMStoreCompleted"' not in query:
    failures.append('the store-completed notification is not observed')

for declaration in ('- (NSArray*) pendingRetrieveAndViewItems;', '- (void) openPendingRetrieveAndViewItemsForStudyUIDs:(NSArray*) studyUIDs;'):
    if declaration not in query_header:
        failures.append('QueryController.h lacks %r' % declaration)

# --- viewer -------------------------------------------------------------------
refresh = method(viewer, '-(void)refreshDatabase:(NSArray*)newImages\n')
if '[coalescer requestAt: now]' not in refresh or 'afterDelay: wait' not in refresh:
    failures.append('same-series reloads are not coalesced')
if 'indexOfSOPInstanceUID: shownSOP frame: shownFrame' not in refresh:
    failures.append('the reload does not restore the operator\'s image by SOP instance and frame')
if refresh.find('shownSOP = ') > refresh.find('openViewerFromImages:'):
    failures.append('the shown image must be captured before the reload replaces the lists')
if 'localCountChangedForStudyUID:' not in refresh:
    failures.append('the reload does not report the new local count')
if '[coalescer appliedAt:' not in refresh:
    failures.append('the coalescer is never told a reload ran')

for signature in ('@objc(retrieveStatusOverlay)\n    func retrieveStatusOverlay() -> String! {\n',
                  '@objc(isReceivingPartialSeries)\n    func isReceivingPartialSeries() -> Bool {\n',
                  '@objc(retrieveViewingStateChanged:)\n    func retrieveViewingStateChanged(_ note: Notification!) {\n'):
    if not method(viewer_retrieve, signature, '\n    }\n'):
        failures.append('ViewerController+RetrieveAndView.swift lacks %s' % signature.strip().split('\n')[0])
if 'name:@"HorosRetrieveViewingStateDidChange"' not in viewer:
    failures.append('the viewer does not redraw on a state change')
if '#import "ViewerController+RetrieveAndView.h"' not in viewer_header:
    failures.append('ViewerController.h does not import ViewerController+RetrieveAndView.h')
for declaration in ('- (NSString*) retrieveStatusOverlay;', '- (BOOL) isReceivingPartialSeries;'):
    if declaration not in viewer_retrieve_header:
        failures.append('ViewerController+RetrieveAndView.h lacks %r' % declaration)

# --- image view ---------------------------------------------------------------
if orientation is None:
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
if 'forKey: @"HorosProgressiveRetrieveViewing"' not in defaults or '@"YES" forKey: @"HorosProgressiveRetrieveViewing"' not in defaults:
    failures.append('HorosProgressiveRetrieveViewing is not registered on by default')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: retrieve-and-view is wired through the query window, the viewer reload and the image overlay')
