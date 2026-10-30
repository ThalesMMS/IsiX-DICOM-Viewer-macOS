#!/usr/bin/env python3
"""The 3.1.2 attachment is a hang, not a launch crash.

horosproject/horos#373 attached a machine spindump, not an exception report.
The audit line AppController.m:3362 / applicationDidFinishLaunching: is not in
that file (AppController is Swift; the launch method is read there). This test keeps the reading attached to the selectors the spindump
actually printed, and refuses to mix the NSAlert front.
-[BrowserController loadSeries:::keyImagesOnly:] is Swift
(BrowserController+DatabaseDragExport+Selection.swift).
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path, class_text

failures = []

# Redacted public stacks only. The full spindump stays off-git (other processes,
# hardware identifiers). Source: horosproject/horos/files/2238653/horoscrash.txt
EXCERPT = """
Date/Time: 2018-07-29 11:40:39 +0200
OS Version: Mac OS X 10.12.6 (Build 16G1510)
Architecture: x86_64h
Command: Horos
Version: 3.1.2 (20180713)
Event: hang
 167 -[ViewerController windowWillClose:] + 351 (Horos + 330031)
 167 +[NSThread sleepForTimeInterval:]
 167 +[ViewerController loadImageData:]
 167 +[DicomFile isDICOMFile:compressed:image:]
 167 +[DicomFile(DicomFileDCMTKCategory) getDicomField:forFile:]
 167 -[NSRecursiveLock lock]
Date/Time: 2018-07-29 12:10:44 +0200
OS Version: Mac OS X 10.12.6 (Build 16G1510)
Architecture: x86_64h
Command: Horos
Version: 3.1.2 (20180713)
Event: hang
 15 -[ViewerController loadSelectedSeries:rightClick:]
 15 -[BrowserController loadSeries:::keyImagesOnly:]
 15 -[BrowserController openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:]
 15 -[ViewerController changeImageData::::]
 15 -[ViewerController isDataVolumicIn4D:checkEverythingLoaded:tryToCorrect:]
 15 -[ViewerController checkEverythingLoaded] + 342
 15 +[NSThread sleepForTimeInterval:]
 15 -[AppController startSTORESCP:]
 15 +[ViewerController loadImageData:]
 15 +[DicomFile(DicomFileDCMTKCategory) getDicomField:forFile:]
 15 -[NSRecursiveLock lock]
"""


def body(path, signature):
    # A file that is gone (ViewerController.m) has no body to give.
    source = path.read_bytes().decode('latin1') if path.exists() else ''
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


def check(condition, message):
    if not condition:
        failures.append(message)


# --- the attachment is two hangs, not a crash --------------------------------
check(EXCERPT.count('Event: hang') == 2, 'the excerpt must keep both hang events')
check(EXCERPT.count('Version: 3.1.2') == 2, 'both samples are Horos 3.1.2')
check('x86_64h' in EXCERPT, 'architecture must stay Intel as printed')
check('Exception Type:' not in EXCERPT, 'do not relabel the spindump as a crash')
check('applicationDidFinishLaunching' not in EXCERPT,
      'the audit launch frame is not in the attachment')
check('NSAlert' not in EXCERPT and 'NSRunAlertPanel' not in EXCERPT,
      'this log is not the NSAlert stack')
check('windowWillClose:' in EXCERPT and 'checkEverythingLoaded' in EXCERPT,
      'both hang signatures must remain identifiable')
check('getDicomField:forFile:' in EXCERPT, 'workers still named getDicomField')

# --- those selectors still exist, and still wait the way the log shows ------
viewer = root / 'Horos/Sources/ViewerController.m'
# -windowWillClose: is Swift, in ViewerController+WindowLifecycle.swift.
close = body(viewer, '- (void)windowWillClose:(NSNotification *)notification')
close_swift = not close
if close_swift:
    close = body(source_path('ViewerController+WindowLifecycle'), 'func windowWillClose(_ notification: Notification)')
# -checkEverythingLoaded is Swift, in ViewerController+StudyNavigation.swift.
loaded = body(source_path('ViewerController+StudyNavigation'), 'func checkEverythingLoaded()')
load_image = body(viewer, '+ (void) loadImageData:(id) dict')
volumic = body(viewer,
               '- (BOOL) isDataVolumicIn4D: (BOOL) check4D checkEverythingLoaded:(BOOL) c tryToCorrect: (BOOL) tryToCorrect')
# +loadImageData: and the volumic checks are Swift, in ViewerController+ImageLoading.swift
# and ViewerController+VolumeCheck.swift, with the same selectors.
loader_swift = not load_image
if loader_swift:
    load_image = body(source_path('ViewerController+ImageLoading'), 'nonisolated class func loadImageData(_ dict: Any!)')
if not volumic:
    volumic = body(source_path('ViewerController+VolumeCheck'),
                   'func isDataVolumicIn4D(_ check4D: Bool, checkEverythingLoaded c: Bool, tryToCorrect: Bool) -> Bool')
launch = body(source_path('AppController'),
              'func applicationDidFinishLaunching(_ aNotification: Notification!)')
isdicom = body(root / 'Horos/Sources/DicomFile.mm',
               '+ (BOOL) isDICOMFile:(NSString *) filePath compressed:(BOOL*) compressed image:(BOOL*) image')
# +isDICOMFile: is Swift (DicomFile+Classification.swift), the probe behind the DCMTK adapter.
classification = root / 'Horos/Sources/DicomFile+Classification.swift'
if not isdicom:
    isdicom = body(classification, '    class func isDICOMFile(_ file: String!, compressed: UnsafeMutablePointer<ObjCBool>!,\n'
                                   '                           image: UnsafeMutablePointer<ObjCBool>!) -> Bool')
probe_source = ((root / 'Horos/Sources/DicomFile.mm').read_bytes().decode('latin1')
                if (root / 'Horos/Sources/DicomFile.mm').exists()
                else (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKFileProbe.mm').read_text())
# +getDicomField:forFile: is Swift (DicomFile+DCMTKFields.swift): the file is read
# by lockedFile(atPath:), under the lock, through the DCMTK adapter.
fields = root / 'Horos/Sources/DicomFile+DCMTKFields.swift'
field = body(fields, 'class func getDicomField(_ field: String!, forFile path: String!) -> String! {')
locked = body(fields, 'private static func lockedFile(atPath path: String?) -> IsiXDCMTKFile? {')
browser = class_text('BrowserController')
# -loadSeries:::keyImagesOnly: is Swift, with its Objective-C selector.
browser_selection = (root / 'Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift').read_text()
# -openViewerFromImages:… is Swift too (BrowserController+ViewerOpening.swift).
viewer_opening = (root / 'Horos/Sources/BrowserController+ViewerOpening.swift').read_text()

# windowWillClose: closes the viewer's series load, which waits.
series_load = (root / 'Horos/Sources/ViewerSeriesLoad.swift').read_text()
close_wait = series_load[series_load.find('    @objc public func close()'):series_load.find('    private func retire(')]
check(close and ('horosSeriesLoad.close()' if close_swift else '[self.horosSeriesLoad close];') in close and 'Thread.sleep(forTimeInterval: 0.01)' in close_wait
      and 'horos_loadingThread' in close_wait,
      'windowWillClose: must still wait for the loading thread')
check(loaded and 'Thread.sleep(forTimeInterval: 0.1)' in loaded and '!(thread?.isFinished ?? true)' in loaded,
      'checkEverythingLoaded must still spin until loading finishes')
check(volumic and 'checkEverythingLoaded' in volumic,
      'the hang-2 caller must still reach checkEverythingLoaded')
check('Load Image Data' in load_image and ('DicomFile.isDICOMFile(' if loader_swift else 'isDICOMFile:') in load_image,
      'the worker thread name and DICOM probe must still be this path')
check(('mayTranscode:NULL' in isdicom or 'mayTranscode: nil' in isdicom)
      and ('HorosDICOMProbe::inspect(path)' in probe_source or 'HorosDICOMProbe::inspect(fileSystemPath)' in probe_source),
      'DICOM identification must use the independent lazy probe')
check('lockedFile(atPath: path)' in field and 'PapyrusLock?.lock()' in locked
      and 'IsiXDCMTKFile.file(atPath: path)' in locked and 'PapyrusLock?.unlock()' in locked,
      'getDicomField must still take PapyrusLock around loadFile')
# -loadSelectedSeries:rightClick: is Swift, in ViewerController+SeriesPopup.swift.
check('loadSelectedSeries:' in (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
      or '@objc(loadSelectedSeries:rightClick:)' in source_path('ViewerController+SeriesPopup').read_text(),
      'loadSelectedSeries: is gone')
check('@objc(openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:)' in viewer_opening and '@objc(loadSeries:::keyImagesOnly:)' in browser_selection,
      'the hang-2 browser frames are gone')

# Launch is a different method. The hang waits must not be attributed to it.
check(launch and 'windowWillClose:' not in launch and 'checkEverythingLoaded' not in launch,
      'do not treat applicationDidFinishLaunching: as the 3.1.2 hang path')

# The NSAlert defect stays a separate one: these two main-thread waits are not alert teardown.
alert = re.compile(r'NSAlert|NSRun\w*AlertPanel')
check(not alert.search(close), 'windowWillClose: grew an alert; do not fold the NSAlert defect into this hang')
check(not alert.search(loaded), 'checkEverythingLoaded grew an alert; do not fold the NSAlert defect into this hang')

if failures:
    for item in failures:
        print('FAIL:', item)
    sys.exit(1)
print('ok: 3.1.2 attachment is two hangs; launch/NSAlert attributions stay rejected')
