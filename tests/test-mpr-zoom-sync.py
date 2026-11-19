#!/usr/bin/env python3
"""Sync Zoom of the 3D MPR and of the curved MPR brings the planes to one zoom.

The Sync Zoom button of both windows only writes its setting through a
binding, and the cross-reference lines carry the zoom of the selected plane to
the other two only when that plane asks for them with itself as the sender.
So turning the button on left the planes at their zooms, and a pinch, which
asks for the lines without a sender and cancels the deferred pass at its end,
never reached the other planes.

Checked here, by the text of the sources: both windows keep an
MPRZoomSynchronizer, which observes the setting for as long as it lives and,
when it changes, asks MPRZoomSync (IsiXImaging, with its own suite,
MPRZoomSyncTests) whether the planes follow the selected one; the pinch of a
plane of the 3D MPR selects the plane and tells the synchronizer when it ends
or is cancelled, after its own last reconstruction, and not at its steps; the
planes that follow are those the rules name, each reconstructed once without
asking the others to follow in turn.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


def body(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth, index = 0, opening
    while index < len(text):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
        index += 1
    return ''


rules = (root / 'Modules/IsiXImaging/Sources/ViewerReconstruction/MPRZoomSync.swift').read_text(encoding='utf-8')
require('public static func propagates(at moment: Moment, isOn: Bool) -> Bool' in rules
        and 'public static func followers(of source: Int, scales: [Float?]) -> [Int]' in rules,
        'MPRZoomSync must decide when the planes follow and which do')
require((root / 'Modules/IsiXImaging/Tests/ViewerReconstruction/MPRZoomSyncTests.swift').is_file(),
        'MPRZoomSync has no suite')

# The key observed is the one of the state the cross-reference lines of both
# windows ask, which is the Sync Zoom setting.
require('static let planesLayoutZoomSync = ForcedPreference(ReconstructionPreferences.syncsZoomLevelMPR, to: true)'
        in sources.source_text('MPRController'), 'the state of the planes must be over the Sync Zoom setting')

sync = (root / 'Horos/Sources/MPRZoomSynchronizer.swift').read_text(encoding='utf-8')
require('MPRZoomSynchronizer.swift in Sources' in (root / 'Horos.xcodeproj/project.pbxproj').read_text(),
        'MPRZoomSynchronizer.swift is not in the Horos target')
KEY = 'Self.settingKeyPath'
require('static let settingKeyPath = ReconstructionPreferences.controllerKeyPath(MPRController.planesLayoutZoomSync.key)' in sync,
        'the synchronizer must observe the key of the state the windows ask')
require('NSUserDefaultsController.shared.addObserver(self, forKeyPath: ' + KEY in body(sync, 'init(window: any ZoomSyncedWindow)')
        and sync.count('addObserver(') == 1, 'the synchronizer must observe the setting from its creation, once')
require('NSUserDefaultsController.shared.removeObserver(self, forKeyPath: ' + KEY in body(sync, 'isolated deinit')
        and sync.count('removeObserver(') == 1, 'the synchronizer must stop observing when it is deallocated')
require('private weak var window: (any ZoomSyncedWindow)?' in sync, 'the synchronizer must not keep its window alive')
observed = body(sync, 'override func observeValue(forKeyPath')
require(re.search(r'onMainActor \{ \[weak self\] in\s*guard let self, let window = self\.window else \{ return \}\s*'
                  r'self\.zoomChanged\(at: \.settingChanged, in: window\.selectedZoomSyncedPlane\)', observed) is not None,
        'a change of the setting must bring the planes to the selected one, on the main actor')
require('zoomChanged(at: .pinchEnded, in: plane)' in body(sync, 'func pinchEnded(in plane: any ZoomSyncedPlane)'),
        'the end of a pinch must hand the zoom of its plane on')

changed = body(sync, 'func zoomChanged(at moment: MPRZoomSync.Moment, in plane: (any ZoomSyncedPlane)?)')
require('!window.isClosingZoomSyncedWindow' in changed, 'a closing window must not reconstruct')
require('MPRZoomSync.propagates(at: moment, isOn: window.syncsZoom)' in changed,
        'the synchronizer must ask the rules, with the setting of the window')
require('MPRZoomSync.followers(of: source, scales: planes.map { $0?.camera?.parallelScale })' in changed,
        'the synchronizer must ask the rules which planes follow')
loop = body(changed, 'for index in followers')
order = [loop.find(part) for part in ('camera.parallelScale = scale', 'camera.forceUpdate = true',
                                      'follower.restoreCamera()', 'follower.updateViewMPR(false)')]
require(-1 not in order and order == sorted(order),
        'a plane that follows takes the scale, then is reconstructed once, without a sender')
# The window keeps its low level of detail on after the full pass of a wheel
# step: the planes that follow are drawn at full detail, and the flag is given back.
require('var lowLOD: Bool { get set }' in body(sync, 'protocol ZoomSyncedWindow'),
        'the window of Sync Zoom must say whether its planes are drawn at the low level of detail')
lod = [changed.find(part) for part in ('let wasLow = window.lowLOD', 'window.lowLOD = false',
                                       'defer { window.lowLOD = wasLow }', 'for index in followers')]
require(-1 not in lod and lod == sorted(lod),
        'the planes that follow must be reconstructed at full detail, with the low level of detail given back after')
require(changed.rstrip('} \n').endswith('plane.restoreCamera()'),
        'the shared 3D view must be left on the camera of the plane the zoom came from')

# Both windows keep a synchronizer from the loading of their nib, answer it
# with the state their cross-reference lines read, and those lines carry the
# zoom of the selected plane as before.
for name, state in (('MPRController', 'Self'), ('CPRController', 'MPRController')):
    text = sources.source_text(name)
    require('@objc public dynamic var lowLOD: Bool {' in text, name + ' must give Sync Zoom its low level of detail')
    require('private(set) lazy var zoomSync = MPRZoomSynchronizer(window: self)' in text
            and '_ = zoomSync' in body(text, 'func awakeFromNib()'),
            name + ' must keep a synchronizer from the loading of its nib')
    conformance = body(sync, 'extension %s: ZoomSyncedWindow' % name)
    for part in ('{ [mprView1, mprView2, mprView3] }', '{ selectedView() }', '{ windowWillClose() }',
                 '{ %s.planesLayoutZoomSync.value(in: preferenceStore) }' % state):
        require(part in conformance, '%s as a window of Sync Zoom: %s is missing' % (name, part))
    lines = body(text, 'func computeCrossReferenceLines(_ sender:')
    require(re.search(r'if sender != nil \{\s*if [^\n]*planesLayoutZoomSync\.value\(in: self\.preferenceStore\) \{\s*'
                      r'MPRZoomSynchronizer\.carryZoom\(of: self\.selectedView\(\), to: \[mprView1, mprView2, mprView3\]\)', lines) is not None,
            name + ': the cross-reference lines asked by a plane must carry the zoom of the selected one')
carry = body(sync, 'static func carryZoom(of selected:')
require('guard let scale = selected?.camera?.parallelScale else { return }' in carry
        and 'where plane !== selected' in carry and 'plane.camera?.parallelScale = scale' in carry
        and 'updateViewMPR' not in carry, 'the lines carry the scale to the other cameras and reconstruct them themselves')
for view in ('MPRDCMView', 'CPRMPRDCMView'):
    require('extension %s: ZoomSyncedPlane {}' % view in sync, view + ' must be a plane of Sync Zoom')

# The pinch of a plane of the 3D MPR.
view = sources.source_text('MPRDCMView')
pinch = body(view, 'func magnify(with anEvent: NSEvent)')
require('if self.window?.firstResponder !== self { self.window?.makeFirstResponder(self) }' in pinch,
        'the pinched plane must become the selected one')
require('defer { if self.finishGesture(anEvent) { windowControllerIvar?.zoomSync.pinchEnded(in: self) } }' in pinch
        and pinch.count('zoomSync') == 1, 'the end of a pinch, and not its steps, must hand its zoom on')
finish = body(view, 'private func finishGesture(_ anEvent: NSEvent) -> Bool')
order = [finish.find(part) for part in ('guard anEvent.phase.contains(.ended) || anEvent.phase.contains(.cancelled) else { return false }',
                                        'NSObject.cancelPreviousPerformRequests(withTarget: controller', 'controller.lowLOD = false',
                                        '_camera?.forceUpdate = true', 'self.restoreCamera()', 'self.updateViewMPR(false)', 'return true')]
require(-1 not in order and order == sorted(order),
        'the end of a gesture must cancel the deferred pass and reconstruct its plane before it is reported')
require('zoomSync' not in body(view, 'func rotate(with anEvent: NSEvent)'), 'a rotation changes no zoom')

# The curved MPR has no pinch of its own to hand on.
curved = sources.source_text('CPRMPRDCMView')
require(body(curved, 'func magnify(with anEvent: NSEvent)').strip('{} \n') == '',
        'the planes of the curved MPR took a pinch: its end must hand the zoom on as the 3D MPR does')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: Sync Zoom brings the planes together when turned on and at the end of a pinch')
