#!/usr/bin/env python3
"""Retrieve-and-view state, reload coalescing and selection preservation (#604).

Compiles `Horos/Sources/RetrieveViewing.swift` with a driver: a double-click
begins a pending item once; the viewer opening records the time to first
image; every batch counts a reload; the transfer's end settles the phase from
the peer's counters and the confirmed inventory (complete, unverified,
interrupted, cancelled); the overlay text says which; reloads are coalesced
at half a second and never deferred beyond two; the import nudge fires once
per burst and only while something is live; and the operator's image is found
again by SOP instance and frame after an out-of-order reload. A study item
keeps its own count when the viewer reloads one of its series, and follows
what is indexed after its transfer ended. Counts are of SOP instances, never of
the frames the index holds for a multiframe object.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'Horos/Sources/RetrieveViewing.swift'
failures = []
sources = root / 'Horos/Sources'
query_controller = (sources / 'QueryController.mm').read_bytes().decode('latin-1')
viewer_controller = (sources / 'ViewerController.m').read_text()
if 'valueForKey: @"noFiles"] intValue] at:' in query_controller:
    failures.append('the viewer opening still counts noFiles, which counts frames')
if query_controller.count('localCount: [HorosRetrieveViewing uniqueInstanceCountOfStudyOrSeries:') != 2:
    failures.append('both viewer openings must count the unique instances of the study or series')
if 'localCount: [HorosRetrieveViewing uniqueInstanceCountOfImages: fileList[curMovieIndex]]' not in viewer_controller:
    failures.append('the viewer reload must count the unique instances it shows, not its frames')
if 'RetrieveViewing.swift in Sources' not in (root / 'Horos.xcodeproj/project.pbxproj').read_text():
    failures.append('RetrieveViewing.swift is not in the Horos target')

DRIVER = r'''
import CoreData
import Foundation
func expect(_ ok: Bool, _ reason: String) { if !ok { print("FAIL: " + reason); exit(1) } }
let viewing = RetrieveViewing.shared
let study = "1.2.3", series = "1.2.3.4"

// 1. Pending once.
expect(viewing.begin(studyUID: study, seriesUID: series, at: 100), "the first double-click begins the item")
expect(!viewing.begin(studyUID: study, seriesUID: series, at: 101), "a second double-click on a running item is idempotent")
expect(viewing.isPending(studyUID: study, seriesUID: series), "the item is pending before the viewer opens")
expect(viewing.concernsPending(studyUIDs: ["9.9", study]), "a batch carrying the study concerns the pending item")
expect(!viewing.concernsPending(studyUIDs: ["9.9"]), "a batch of other studies does not")
expect(viewing.state(studyUID: study, seriesUID: series)?.phase == .waiting, "waiting before anything landed")
expect(viewing.state(studyUID: study, seriesUID: series)!.overlayText.contains("waiting"), "the waiting overlay says so")

// 2. Viewer opened on partial content: receiving, first-image time recorded.
viewing.viewerOpened(studyUID: study, seriesUID: series, localCount: 2, at: 103.5)
expect(!viewing.isPending(studyUID: study, seriesUID: series), "an opened item is no longer pending")
expect(abs(viewing.secondsToFirstImage(studyUID: study, seriesUID: series) - 3.5) < 1e-9, "time to first image is measured from the double-click")
viewing.expectedCount(studyUID: study, seriesUID: series, expected: 10)
let receiving = viewing.state(studyUID: study, seriesUID: series)!
expect(receiving.phase == .receiving && receiving.isPartial, "receiving while the transfer runs")
expect(receiving.overlayText == "Receiving: 2 of 10 instances available, transfer in progress", "receiving overlay: \(receiving.overlayText)")
viewing.localCountChanged(studyUID: study, seriesUID: series, localCount: 6)
expect(viewing.reloads(studyUID: study, seriesUID: series) == 1, "each applied batch counts one reload")

// 3. Complete: every expected instance imported and the inventory confirmed.
viewing.transferEnded(studyUID: study, seriesUID: series, cancelled: false, received: 10, expected: 10, failed: 0,
                      inventoryConfirmed: true, localCount: 6, at: 110)
expect(viewing.state(studyUID: study, seriesUID: series)?.phase == .interrupted, "ended with 6 of 10 local is interrupted, not complete")
viewing.localCountChanged(studyUID: study, seriesUID: series, localCount: 10)
let complete = viewing.state(studyUID: study, seriesUID: series)!
expect(complete.phase == .complete && !complete.isPartial, "10 of 10 confirmed is complete")
expect(complete.overlayText.isEmpty, "a complete series draws no overlay")
expect(viewing.begin(studyUID: study, seriesUID: series, at: 120), "a finished item can be requested again")

// 4. Unverified: counters agree, no confirmed inventory.
viewing.viewerOpened(studyUID: study, seriesUID: series, localCount: 10, at: 121)
viewing.transferEnded(studyUID: study, seriesUID: series, cancelled: false, received: 10, expected: 10, failed: 0,
                      inventoryConfirmed: false, localCount: 10, at: 125)
let unverified = viewing.state(studyUID: study, seriesUID: series)!
expect(unverified.phase == .unverified, "without a confirmed inventory the end is unverified")
expect(unverified.overlayText.contains("not verified"), "the overlay says completeness is not verified")

// 5. Interrupted by failures, and by cancellation.
let other = "5.6"
expect(viewing.begin(studyUID: other, seriesUID: "", at: 200), "a study-level item")
viewing.viewerOpened(studyUID: other, seriesUID: "5.6.1", localCount: 3, at: 202)
expect(viewing.state(studyUID: other, seriesUID: "5.6.1")?.phase == .receiving, "a study item answers for any of its series")
viewing.transferEnded(studyUID: other, seriesUID: "", cancelled: false, received: 8, expected: 10, failed: 2,
                      inventoryConfirmed: true, localCount: 8, at: 210)
let failed = viewing.state(studyUID: other, seriesUID: "")!
expect(failed.phase == .interrupted && failed.overlayText.contains("2 failed"), "failures interrupt and are named: \(failed.overlayText)")
expect(viewing.begin(studyUID: other, seriesUID: "", at: 220), "restart after an interruption")
viewing.transferEnded(studyUID: other, seriesUID: "", cancelled: true, received: 1, expected: 10, failed: 0,
                      inventoryConfirmed: true, localCount: 1, at: 221)
expect(viewing.state(studyUID: other, seriesUID: "")?.phase == .interrupted, "cancellation is an interruption")
expect(!viewing.isPending(studyUID: other, seriesUID: ""), "a cancelled item is not pending")
viewing.forget(studyUID: other, seriesUID: "")
expect(viewing.state(studyUID: other, seriesUID: "") == nil, "forgetting removes the state")

// 6. Import nudge: once per burst, only while live.
expect(viewing.begin(studyUID: "7.7", seriesUID: "", at: 300), "live item for nudges")
expect(viewing.importNudgeWanted(studyUID: "7.7", at: 300.1), "the first store nudges the importer")
expect(!viewing.importNudgeWanted(studyUID: "7.7", at: 300.3), "a store 200 ms later does not")
expect(viewing.importNudgeWanted(studyUID: "7.7", at: 300.7), "half a second later it does again")
expect(!viewing.importNudgeWanted(studyUID: "8.8", at: 301.5), "a store for a study nobody is viewing does not")
viewing.transferEnded(studyUID: "7.7", seriesUID: "", cancelled: false, received: 1, expected: 1, failed: 0,
                      inventoryConfirmed: true, localCount: 1, at: 302)
expect(!viewing.importNudgeWanted(studyUID: "7.7", at: 303), "after the transfer ended no nudge is wanted")

// 7. Coalescing.
let coalescer = RefreshCoalescer(delay: 0.5, maxDeferral: 2)
expect(coalescer.request(at: 10.0) == 0, "the first request may run immediately")
coalescer.applied(at: 10.0)
let wait = coalescer.request(at: 10.2)
expect(abs(wait - 0.3) < 1e-9, "a request 200 ms after a reload waits the rest of the half second: \(wait)")
expect(coalescer.request(at: 10.4) > 0, "a request inside the window still waits")
expect(coalescer.waitBeforeApplying(at: 10.5) == 0, "at half a second it may run")
coalescer.applied(at: 10.5)
var t = 10.6
var deferred = 0.0
// A steady stream every 100 ms: the reload must happen by two seconds.
while t < 13 { deferred = coalescer.request(at: t); if deferred == 0 { break }; t += 0.1 }
expect(t - 10.5 <= 2.0 + 1e-9, "a steady stream is not deferred past two seconds: ran at +\(t - 10.5)")
expect(coalescer.appliedReloads == 2, "two reloads applied so far")

// 9. A study item keeps its own count: the viewer's reload of one series does
// not replace it, and what is indexed after the transfer ended counts.
let late = "7.7"
expect(viewing.begin(studyUID: late, seriesUID: "", at: 300), "a study item")
viewing.viewerOpened(studyUID: late, seriesUID: "", localCount: 3, at: 301)
viewing.transferEnded(studyUID: late, seriesUID: "", cancelled: false, received: 26, expected: 26, failed: 0,
                      inventoryConfirmed: true, localCount: 26, at: 310)
expect(viewing.state(studyUID: late, seriesUID: "")?.phase == .complete, "26 of 26 confirmed is complete")
viewing.localCountChanged(studyUID: late, seriesUID: "7.7.1", localCount: 12)
let kept = viewing.state(studyUID: late, seriesUID: "")!
expect(kept.phase == .complete && kept.localCount == 26, "a series' 12 images do not make the study 12 of 26: \(kept.overlayText)")
expect(viewing.reloads(studyUID: late, seriesUID: "") == 1, "the reload still counts")
expect(viewing.begin(studyUID: late, seriesUID: "", at: 400), "the study again")
viewing.transferEnded(studyUID: late, seriesUID: "", cancelled: false, received: 26, expected: 26, failed: 0,
                      inventoryConfirmed: true, localCount: 12, at: 410)
expect(viewing.state(studyUID: late, seriesUID: "")?.phase == .interrupted, "12 indexed when the transfer ended")
viewing.importedCountChanged(studyUID: late, seriesUID: "7.7.1", localCount: 1)
expect(viewing.state(studyUID: late, seriesUID: "")!.localCount == 12, "a series' index count is not the study's")
viewing.importedCountChanged(studyUID: late, seriesUID: "", localCount: 26)
let indexed = viewing.state(studyUID: late, seriesUID: "")!
expect(indexed.phase == .complete && indexed.overlayText.isEmpty, "indexed after the transfer: complete, no false interruption")
viewing.importedCountChanged(studyUID: late, seriesUID: "", localCount: 20)
expect(viewing.state(studyUID: late, seriesUID: "")!.localCount == 26, "a lower count does not take it back")

// 8. Selection preservation after an out-of-order reload.
let sops = ["c", "a", "b", "b"]; let frames: [NSNumber] = [0, 0, 0, 1]
expect(RetrieveViewing.index(ofSOPInstanceUID: "b", frame: 1, inSOPInstanceUIDs: sops, frames: frames, fallback: 0) == 3, "frame 1 of b is found")
expect(RetrieveViewing.index(ofSOPInstanceUID: "b", frame: 7, inSOPInstanceUIDs: sops, frames: frames, fallback: 0) == 2, "a missing frame falls back to the instance")
expect(RetrieveViewing.index(ofSOPInstanceUID: "zz", frame: 0, inSOPInstanceUIDs: sops, frames: frames, fallback: 9) == 3, "an absent instance clamps the fallback")
expect(RetrieveViewing.index(ofSOPInstanceUID: "", frame: 0, inSOPInstanceUIDs: [], frames: [], fallback: 2) == 0, "an empty list yields 0")
// 10. Instances, not frames: a study of 14 instances whose multiframe objects
// add 7 frame images to the index.
final class Image: NSObject { @objc let sopInstanceUID: String; init(_ uid: String) { sopInstanceUID = uid } }
let frameImages = (0..<14).map { Image("2.25.\($0)") } + (0..<7).map { Image("2.25.\($0 % 3)") } + [Image("")]
expect(RetrieveViewing.uniqueInstanceCount(ofImages: frameImages) == 14, "21 frame images of 14 instances count 14")
func entity(_ name: String, _ attributes: [NSPropertyDescription] = []) -> NSEntityDescription {
    let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = "NSManagedObject"; e.properties = attributes; return e
}
let uidAttribute = NSAttributeDescription(); uidAttribute.name = "sopInstanceUID"; uidAttribute.attributeType = .stringAttributeType
let studyEntity = entity("Study"), seriesEntity = entity("Series"), imageEntity = entity("Image", [uidAttribute])
let toSeries = NSRelationshipDescription(); toSeries.name = "series"; toSeries.destinationEntity = seriesEntity; toSeries.maxCount = 0
let toImages = NSRelationshipDescription(); toImages.name = "images"; toImages.destinationEntity = imageEntity; toImages.maxCount = 0
studyEntity.properties = [toSeries]; seriesEntity.properties = [toImages]
let model = NSManagedObjectModel(); model.entities = [studyEntity, seriesEntity, imageEntity]
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
let localStudy = NSManagedObject(entity: studyEntity, insertInto: context)
var seriesObjects: [NSManagedObject] = []
for (index, uids) in [["2.25.0", "2.25.0", "2.25.0", "2.25.0"], ["2.25.1", "2.25.1"], ["2.25.2", "2.25.3"]].enumerated() {
    let s = NSManagedObject(entity: seriesEntity, insertInto: context)
    s.setValue(Set(uids.map { uid -> NSManagedObject in
        let image = NSManagedObject(entity: imageEntity, insertInto: context); image.setValue(uid, forKey: "sopInstanceUID"); return image
    }), forKey: "images")
    seriesObjects.append(s); _ = index
}
localStudy.setValue(Set(seriesObjects), forKey: "series")
expect(RetrieveViewing.uniqueInstanceCount(ofStudyOrSeries: localStudy) == 4, "8 frame images of 4 instances in a study count 4")
expect(RetrieveViewing.uniqueInstanceCount(ofStudyOrSeries: seriesObjects[0]) == 1, "a 4-frame object is one instance of its series")
// With one instance missing, the frames no longer cover it: interrupted.
let multi = "8.8"
expect(viewing.begin(studyUID: multi, seriesUID: "", at: 500), "a multiframe study")
viewing.viewerOpened(studyUID: multi, seriesUID: "", localCount: RetrieveViewing.uniqueInstanceCount(ofImages: frameImages.filter { $0.sopInstanceUID != "2.25.13" }), at: 501)
viewing.transferEnded(studyUID: multi, seriesUID: "", cancelled: false, received: 13, expected: 14, failed: 0,
                      inventoryConfirmed: true, localCount: 13, at: 510)
let partial = viewing.state(studyUID: multi, seriesUID: "")!
expect(partial.phase == .interrupted && partial.localCount == 13, "13 of 14 instances with 20 frame images is interrupted: \(partial.overlayText)")
expect(viewing.begin(studyUID: multi, seriesUID: "", at: 600), "the multiframe study again")
viewing.viewerOpened(studyUID: multi, seriesUID: "", localCount: RetrieveViewing.uniqueInstanceCount(ofImages: frameImages), at: 601)
viewing.transferEnded(studyUID: multi, seriesUID: "", cancelled: false, received: 14, expected: 14, failed: 0,
                      inventoryConfirmed: true, localCount: 14, at: 610)
let whole = viewing.state(studyUID: multi, seriesUID: "")!
expect(whole.phase == .complete && whole.localCount == 14, "14 of 14 is complete and counts 14, not 21")

print("ok: retrieve-and-view state, coalescing and selection preservation")
'''

if not failures:
    with tempfile.TemporaryDirectory() as tmp:
        driver = Path(tmp) / 'main.swift'
        driver.write_text(DRIVER)
        binary = Path(tmp) / 'driver'
        build = subprocess.run(['xcrun', 'swiftc', str(source), str(driver), '-o', str(binary)], capture_output=True, text=True)
        if build.returncode != 0:
            failures.append('driver did not compile:\n' + build.stderr[-3000:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append((run.stdout + run.stderr).strip() or 'driver failed without output')
            else:
                print(run.stdout.strip())

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
