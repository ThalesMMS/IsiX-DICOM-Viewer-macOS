#!/usr/bin/env python3
"""The 3D MPR offers the Sync item and shares its position with the 2D viewers."""
from pathlib import Path
import subprocess
import sys
import tempfile

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


mpr = sources.source_text('MPRController')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

require('static let syncItemIdentifier = "Sync"' in mpr,
        'the MPR item does not use the identifier Sync of the 2D and orthogonal MPR viewers')
allowed = body(mpr, 'func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar)')
require('MPRController.syncItemIdentifier' in allowed, 'the MPR does not allow the Sync item')

item = body(mpr, 'func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier')
branch = item[item.find('MPRController.syncItemIdentifier'):]
require('self.isSyncOn ? "SyncLock.pdf" : "Sync.pdf"' in branch and '#selector(toggleSync(_:))' in branch,
        'the Sync item does not show the synchronization state or toggle it')
update = body(mpr, 'public dynamic func updateToolbarItems()')
require('MPRController.syncItemIdentifier' in update and 'SyncLock.pdf' in update,
        'the Sync item image does not follow the synchronization state')

state = body(mpr, 'fileprivate var isSyncOn: Bool')
require('SyncButtonBehaviorIsBetweenStudies' in state and 'horos_SYNCSERIES' in state
        and 'DCMView.syncro() != Int16(syncroOFF)' in state,
        'the MPR does not read the 2D synchronization state')
toggle = body(mpr, 'fileprivate dynamic func toggleSync(_ sender: Any?)')
require('viewer2D?.syncSeries(self)' in toggle, 'the Sync item does not use the 2D Sync action')

init = body(mpr, 'private func initialize(pix: NSMutableArray!')
for name in ('NSNotification.Name.OsirixSyncSeries', 'NSNotification.Name.OsirixDCMViewIndexChanged',
             'PatientCrosshairController.changeNotification'):
    require(name in init, 'the MPR does not observe %s' % name)

cross = body(mpr, 'public dynamic func computeCrossReferenceLines(_ sender: MPRDCMView!)')
require(cross.rstrip('}').rstrip().endswith('self.publishSyncPosition()'),
        'a move of the cross is not published')
publish = body(mpr, 'fileprivate func publishSyncPosition()')
require('HorosPublishPatientCrosshair(point, viewer, self)' in publish,
        'the MPR does not reuse the patient crosshair the 2D viewers follow')
require('!followingSync' in publish and 'isKeyWindow' in publish,
        'the MPR would send back a move it received')

slice_ = body(mpr, 'fileprivate dynamic func sliceChangedIn2DViewer(_ note: Notification?)')
require('view.is2DViewer()' in slice_ and 'self.sharesWorld(with: viewer, pix: pix)' in slice_
        and 'MPRPositionSync.projection' in slice_,
        'a 2D slice change does not bring the cross onto the slice of a viewer of the same volume')
crosshair = body(mpr, 'fileprivate dynamic func patientCrosshairChanged(_ note: Notification?)')
require('crosshair.sourceOwner !== self' in crosshair and 'HorosPatientCrosshairForViewer(viewer)' in crosshair,
        'the MPR does not follow the crosshair of other viewers')

move = body(mpr, 'private func moveCross(to target: SIMD3<Double>, halfSlice: Double)')
require('hiddenVRView?.factor()' in move and 'camera.focalPoint' in move and 'followingSync = true' in move
        and 'clear(owner: self)' in move,
        'the cross does not move all cameras by the same patient vector')

close = body(mpr, 'public override dynamic func windowWillClose(_ notification: Notification)')
require('PatientCrosshairController.shared.clear(owner: self)' in close,
        'a closed MPR leaves its crosshair behind')
require('MPRPositionSync.swift in Sources' in pbx, 'MPRPositionSync.swift is not in the Horos target')

code = r'''
import simd

func near(_ a: SIMD3<Double>?, _ b: SIMD3<Double>, _ tolerance: Double = 1e-6) -> Bool {
 guard let a else { return false }
 return simd_distance(a, b) < tolerance
}

@main struct Test {
 static func main() {
  typealias P = MPRPositionSync.Plane
  // Axial, coronal and sagittal planes through (10, -20, 35).
  let c = SIMD3<Double>(10, -20, 35)
  let axial = P(origin: SIMD3(-100, -100, 35), normal: SIMD3(0, 0, 1))
  let coronal = P(origin: SIMD3(-100, -20, -100), normal: SIMD3(0, 1, 0))
  let sagittal = P(origin: SIMD3(10, -100, -100), normal: SIMD3(1, 0, 0))
  precondition(near(MPRPositionSync.intersection([axial, coronal, sagittal]), c), "orthogonal planes")

  // Oblique planes through the same point, origins elsewhere on each plane.
  let n1 = simd_normalize(SIMD3<Double>(0.3, 0.2, 1))
  let n2 = simd_normalize(SIMD3<Double>(-0.1, 1, 0.25))
  let n3 = simd_cross(n1, n2)
  func onPlane(_ n: SIMD3<Double>) -> SIMD3<Double> { c + 40 * simd_normalize(simd_cross(n, SIMD3(1, 0, 0))) }
  let oblique = [P(origin: onPlane(n1), normal: n1), P(origin: onPlane(n2), normal: 3 * n2), P(origin: onPlane(n3), normal: n3)]
  precondition(near(MPRPositionSync.intersection(oblique), c, 1e-6), "oblique planes, unnormalized normal")

  precondition(MPRPositionSync.intersection([axial, axial, sagittal]) == nil, "parallel planes have no single point")
  precondition(MPRPositionSync.intersection([axial, coronal]) == nil, "three planes are needed")

  // A 2D slice: the cross comes onto it, keeping its position in the slice.
  let slice = P(origin: SIMD3(0, 0, 42.5), normal: SIMD3(0, 0, -1))
  precondition(near(MPRPositionSync.projection(of: c, onto: slice), SIMD3(10, -20, 42.5)), "projection onto a slice")

  // Within half a slice the cross stays; a slice further, it follows.
  precondition(!MPRPositionSync.shouldFollow(from: c, to: c + SIMD3(0, 0, 0.6), halfSlice: 0.625))
  precondition(MPRPositionSync.shouldFollow(from: c, to: c + SIMD3(0, 0, 1.25), halfSlice: 0.625))
  precondition(MPRPositionSync.shouldFollow(from: c, to: c + SIMD3(0.5, 0, 0), halfSlice: 0), "a crosshair point is followed")
  precondition(!MPRPositionSync.shouldFollow(from: c, to: c, halfSlice: 0), "no move, no follow")

  print("PASS: MPR cross centre from three planes, projection onto a 2D slice, half-slice tolerance")
 }
}
'''

if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-mpr-sync-') as folder:
        p = Path(folder)
        (p / 'test.swift').write_text(code)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                                str(root / 'Horos/Sources/MPRPositionSync.swift'), str(p / 'test.swift'),
                                '-o', str(p / 'test')])
        require(built.returncode == 0, 'MPRPositionSync.swift does not compile on its own')
        if built.returncode == 0:
            require(subprocess.run([str(p / 'test')]).returncode == 0, 'the sync geometry is wrong')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: MPR Sync item allowed, shares the 2D state, publishes and follows positions')
