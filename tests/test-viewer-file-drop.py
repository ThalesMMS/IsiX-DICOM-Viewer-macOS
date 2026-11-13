#!/usr/bin/env python3
"""Image files dropped on a window that shows a series become series of its study.

Dropped on the row of a study in the database window, image files and PDFs are
converted into new series of that study. Dropped on the 2D viewer they were laid
on the image as layer ROIs, and the windows opened from a viewer (MPR,
orthogonal MPR, PET-CT, volume and surface rendering, endoscopy) took no files
at all, the curved reconstruction only the file of a curved path.

Every such window now hands a drop of files to one entry, ViewerFileDropTarget,
which asks IsiXDICOMFile's ViewerFileDrop what the drop is (its tests are
Modules/IsiXDICOMFile/Tests/ViewerFileDropTests.swift) and converts with
StudyFileImporter into the database of the study the window shows. What is
read here is the wiring, which needs the application around it:

- the windows opened from a 2D viewer are registered for files where their
  window arrives, once for all of them, and answer a drag through the entry;
  none of them has drag methods of its own but the curved reconstruction, which
  asks the entry first and keeps its curved path;
- the 2D viewer asks the entry before its own file branch, in the three
  messages of a drag, and still lays pictures and reads ROI files there;
- only a drag from another application is the entry's: the images dragged
  from one viewer to another carry their files too;
- the study that takes no files refuses the drag while it is over the window;
- the files go into the database of the study, not into the one the database
  window shows, and are converted from the main run loop, once the drop is
  answered: the conversion may end with an alert, which is a modal.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []

TARGET = 'Horos/Sources/ViewerFileDropTarget.swift'
IMPORTER = 'Horos/Sources/StudyFileImporter.swift'
BASE = 'Horos/Sources/Window3DController.swift'
VIEWER = 'Horos/Sources/ViewerController+DragAndDrop.swift'
CURVED = 'Horos/Sources/CPRController.swift'
OPENED_FROM_A_VIEWER = ['MPRController', 'OrthogonalMPRViewer', 'OrthogonalMPRPETCTViewer', 'VRController', 'EndoscopyVRController',
                        'SRController', 'EndoscopyViewer', 'ROIVolumeController', 'CPRController']


def source(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode() if shown.returncode == 0 else ''
    file = root / path
    return file.read_text(encoding='utf-8') if file.exists() else ''


def code(path):
    """The source without its comment lines."""
    return '\n'.join(line for line in source(path).splitlines() if not line.strip().startswith('//'))


def check(condition, message):
    if not condition:
        failures.append(message)


def body(text, signature):
    """The text of the declaration that starts with `signature`, to its closing brace."""
    at = text.find(signature)
    if at < 0:
        return ''
    depth = 0
    for index in range(text.index('{', at), len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    return ''


target = code(TARGET)
check(target, f'{TARGET} is not there: no window has an entry for the files dropped on it')

# --- the windows opened from a 2D viewer
base = code(BASE)
setter = body(base, 'public nonisolated override var window: NSWindow? {')
check('ViewerFileDropTarget.register(newValue)' in setter,
      'the windows opened from a 2D viewer are not registered for files where their window arrives')
check('registerForDraggedTypes([fileNamesType])' in body(target, 'static func register(_ window: NSWindow?)'),
      'registering a window does not make it a destination of dragged files')
extension = body(target, 'extension Window3DController {')
for selector, call in (('draggingEntered:', 'ViewerFileDropTarget.operation(for: sender, on: self) ?? []'),
                       ('draggingUpdated:', 'ViewerFileDropTarget.operation(for: sender, on: self) ?? []'),
                       ('performDragOperation:', 'ViewerFileDropTarget.perform(sender, on: self) ?? false')):
    method = body(extension, f'@objc({selector})')
    check(call in method, f'the windows opened from a 2D viewer do not answer -{selector} through the entry')
for name in OPENED_FROM_A_VIEWER:
    text = code(f'Horos/Sources/{name}.swift')
    check(re.search(r'class %s: (Window3DController|VRController)\b' % name, text), f'{name} is no longer a window opened from a 2D viewer')
    own = re.findall(r'@objc\((draggingEntered:|draggingUpdated:|performDragOperation:)\)', text)
    if name == 'CPRController':
        check(sorted(own) == ['draggingEntered:', 'draggingUpdated:', 'performDragOperation:'], 'the curved reconstruction lost its drag methods')
    else:
        check(not own, f'{name} answers a drag by itself ({", ".join(own)}), beside the entry of every window')

# --- the curved reconstruction keeps its curved path
curved = code(CURVED)
for selector in ('draggingEntered:', 'draggingUpdated:'):
    method = body(curved, f'@objc({selector})')
    check('override dynamic func' in method and 'ViewerFileDropTarget.operation(for: sender, on: self) ??' in method
          and '.contains(.generic) ? .generic : []' in method, f'the curved reconstruction does not ask the entry first in -{selector}, or lost its own answer')
performing = body(curved, '@objc(performDragOperation:)')
asked, path = performing.find('ViewerFileDropTarget.perform(sender, on: self)'), performing.find('pathExtension == "curvedPath"')
check(0 <= asked < path and 'self.loadBezierPathFromFile(file)' in performing,
      'the curved reconstruction does not ask the entry before it reads a curved path, or no longer reads one')

# --- the 2D viewer
viewer = code(VIEWER)
performing = body(viewer, '@objc(performDragOperation:)')
asked = performing.find('} else if let taken = ViewerFileDropTarget.perform(sender, on: self) {')
own = performing.find('let desiredType = paste.availableType(from: [NSPasteboard.PasteboardType("NSFilenamesPboardType")])')
check(0 <= asked < own, 'the 2D viewer does not ask the entry before its own file branch')
for kept in ('addLayerRoiToCurrentSlice(with: im', 'roiLoad(fromSeries: file as String)', 'try importROIFiles(roiFiles)'):
    check(kept in performing[max(own, 0):], f'the 2D viewer no longer does what it did with the files that are its own: {kept}')
check('viewerSync.draggedViewer = nil\n            return taken' in performing, 'a drop the entry took leaves the viewer marked as the one a drag started from')
for selector in ('draggingEntered:', 'draggingUpdated:'):
    method = body(viewer, f'@objc({selector})')
    check('ViewerFileDropTarget.operation(for: sender, on: self) ?? (sender.draggingSourceOperationMask.contains(.generic) ? .generic : [])' in method,
          f'the 2D viewer does not ask the entry in -{selector}, or lost its own answer')

# --- the entry
files = body(target, 'static func files(of drag: NSDraggingInfo) -> [String]?')
check('drag.draggingSource == nil' in files, 'a drag of this application, which carries the files of its own images, is taken for files dropped from outside')
operation = body(target, 'static func operation(for drag: NSDraggingInfo, on controller: OSIWindowController) -> NSDragOperation?')
check('ViewerFileDrop.answer(' in operation and 'refusal: StudyFileImporter.refusal(of: study(of: controller))' in operation
      and 'case .refuse: return []' in operation and 'case .windowsOwn: return nil' in operation,
      'the drag is not answered while it is over the window: a study that takes no files would refuse only once the files are dropped')
check('NSEvent.modifierFlags.contains(.option)' in operation and 'drag.draggingSourceOperationMask.contains(.copy)' in operation,
      'the answer to a drag leaves out Option, or what the source offers')
study = body(target, 'static func study(of controller: OSIWindowController) -> DicomStudy?')
check('controller.currentStudy() ?? (controller as? Window3DController)?.viewer()?.currentStudy()' in study,
      'the study of a window is not its own, or else the one of the 2D viewer it was opened from')
drop = body(target, 'static func drop(_ paths: [String], optionPressed: Bool, on controller: OSIWindowController) -> Bool?')
decided, destination, converted = (drop.find('ViewerFileDrop.decision(for: paths, optionPressed: optionPressed, in: kind(of: controller)) == .newSeries'),
                                   drop.find('StudyFileImporter.destination(showing: study(of: controller))'),
                                   drop.find('StudyFileImporter.convert(paths, into: taken.study, database: taken.database)'))
check(0 <= decided < destination < converted, 'the entry does not decide, then ask the study, then convert into the database of the study')
run_loop = drop.find('onMainRunLoop {')
check(0 <= run_loop < converted and 'return true' in drop[converted:], 'the files are converted before the drop is answered, or outside the main run loop')
check('DispatchQueue.main' not in target and 'Task {' not in target and 'Task { @MainActor' not in target,
      'the entry reaches the conversion, which may show an alert, through the main queue or a task')
check('showSeries(of: taken.study)' in drop and 'viewer.buildMatrixPreview(false)' in body(target, 'private static func showSeries(of study: DicomStudy)'),
      'the series lists of the 2D viewers of the study are not told of the new series')
check('ViewerFileDropTarget.drop(paths, optionPressed: optionPressed, on: self)' in body(target, '@objc(horos_dropFiles:optionPressed:)'),
      'what drives a window without a drag does not go through the entry')

# --- the importer
importer = code(IMPORTER)
destination = body(importer, 'static func destination(showing study: DicomStudy?) -> (study: DicomStudy, database: DicomDatabase)?')
check('DicomDatabase(for: study.managedObjectContext)' in destination and 'refusal(of: study, in: database) == nil' in destination
      and 'browser' not in destination, 'the files do not go into the database of the study, or a study that takes none is not refused')
refusal = body(importer, 'static func refusal(of study: DicomStudy?, in database: DicomDatabase?) -> ViewerFileDrop.Refusal?')
for asked in ('database?.isLocal()', 'database?.isReadOnly', 'isDistantRow(study)', 'study?.lockedStudy?.boolValue'):
    check(asked in refusal, f'a study is not refused for {asked}')
row = body(importer, 'static func study(ofRow item: Any?, in browser: BrowserController) -> DicomStudy?')
check('refusal(of: study, in: database) == nil' in row and '!isDistantRow(item)' in row, 'the row of a study and the window of one no longer refuse the same studies')
converting = body(importer, 'static func convert(_ paths: [String], into study: DicomStudy, database: DicomDatabase) -> Outcome')
check('StudyFileImporter(study: study, database: database).convert(paths)' in converting
      and 'NSLocalizedString("These files could not be converted to DICOM:", comment: "")' in converting,
      'the files dropped on a window are not converted as those dropped on a row, with the same alert for those that could not be')
check('return convert(paths, into: study, database: database)' in body(importer, 'static func convert(_ paths: [String], into study: DicomStudy, browser: BrowserController) -> Outcome?'),
      'the row of a study converts by another way than the window of one')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: every window that shows a series hands the files dropped on it to one entry, which converts images and PDFs into the study, in its database')
