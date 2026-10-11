#!/usr/bin/env python3
"""A study's images are found by UID in one pass, with what the filter found.

-[DicomStudy roiImages] filtered every image of the study with a predicate
once per ROI SR. StudyImageIndex.swift reads the images once; this compiles it
as it stands and checks, against the predicates the method built:

- the same image, by identity, for every lookup: UIDs shared by several images
  (the first in the order given), frames, a frame no image has, a UID no image
  has, images without a UID and a lookup without one;
- each image's UID and frame are read once, however many lookups follow.

Then, in DicomStudy.swift: the images with ROIs come from the index, no image
is looked for by filtering, the list is still sorted, and the portal's yes or
no stops at the first image.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from sources import source_path, source_text  # noqa: E402

DRIVER = r'''
import Foundation

final class Image: NSObject {
    nonisolated(unsafe) static var reads = 0
    let uid: String?
    @objc let frameID: NSNumber?
    init(_ uid: String?, _ frame: Int32?) { self.uid = uid; frameID = frame.map { NSNumber(value: $0) } }
    // A method, as DicomImage's is: key-value coding calls it.
    @objc func sopInstanceUID() -> String? { Image.reads += 1; return uid }
}

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

/// The predicate -roiImages built: a nil UID is the constant nil.
func filtered(_ images: NSArray, _ uid: String?, _ frame: Int32) -> AnyObject? {
    let predicate: NSPredicate
    switch (uid, frame != 0) {
    case let (uid?, true): predicate = NSPredicate(format: "sopInstanceUID = %@ and frameID = %@", uid, NSNumber(value: frame))
    case (nil, true): predicate = NSPredicate(format: "sopInstanceUID = nil and frameID = %@", NSNumber(value: frame))
    case let (uid?, false): predicate = NSPredicate(format: "sopInstanceUID = %@", uid)
    case (nil, false): predicate = NSPredicate(format: "sopInstanceUID = nil")
    }
    return (images.filtered(using: predicate) as NSArray).firstObject as AnyObject?
}

nonisolated(unsafe) var seed: UInt64 = 0x9E3779B97F4A7C15
func next(_ bound: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(bound))
}

let pool = (0..<40).map { "1.2.840.113619.2.55.3.604688119.971.\($0)" }
var lookups = 0
for round in 0..<60 {
    let count = [0, 1, 7, 150][round % 4]
    let images = NSArray(array: (0..<count).map { _ -> Image in
        let uid: String? = next(12) == 0 ? nil : pool[next(pool.count)]
        let frame: Int32? = [nil, 0, 1, 2, 3][next(5)]
        return Image(uid, frame)
    })
    let index = StudyImageIndex(images: images)
    let wanted: [String?] = pool + ["1.2.3.unknown", "", nil]
    for uid in wanted {
        for frame: Int32 in [0, 1, 2, 3, 4, -1] {
            let expected = filtered(images, uid, frame), found = index.image(sopInstanceUID: uid, frame: frame)
            check(expected === found, "round \(round): \(uid ?? "nil") frame \(frame) finds another image than the filter")
            lookups += 1
        }
    }
}
check(StudyImageIndex(images: nil).image(sopInstanceUID: pool[0], frame: 0) == nil, "no images, and an image was found")

// One reading of each image, whatever is asked afterwards.
let many = NSArray(array: (0..<2000).map { Image(pool[$0 % pool.count] + ".\($0)", nil) })
Image.reads = 0
let index = StudyImageIndex(images: many)
for position in stride(from: 0, to: 2000, by: 4) {
    let uid = pool[position % pool.count] + ".\(position)"
    check(index.image(sopInstanceUID: uid, frame: 0) === (many[position] as AnyObject), "image \(position) not found")
}
check(Image.reads == 2000, "the images were read \(Image.reads) times for 2000 images and 500 lookups")
print("PASS: \(lookups) lookups agree with the predicate filter; 2000 images read once for 500 lookups")
'''


def check(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for position in range(opening, len(source)):
        if source[position] == '{':
            depth += 1
        elif source[position] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:position + 1]
    return ''


with tempfile.TemporaryDirectory(prefix='horos-study-image-index-') as folder:
    work = Path(folder)
    (work / 'main.swift').write_text(DRIVER)
    binary = work / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O', str(source_path('StudyImageIndex')),
                    str(work / 'main.swift'), '-o', str(binary)], check=True, timeout=600)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    print(result.stdout, end='')
    check(result.returncode == 0, 'the index does not answer as the predicate filter did\n' + result.stderr)

study = source_text('DicomStudy')
listed = body(study, 'private func imagesWithROIs(atMost limit: Int?)')
check(listed, 'imagesWithROIs(atMost:) not found')
check('StudyImageIndex(images: allImages)' in listed and 'index?.image(sopInstanceUID: uid, frame: fid)' in listed,
      'the image of a ROI SR is not looked up in the index')
check('filtered(using:' not in listed, 'the images of the study are still filtered once per ROI SR')
check('if let limit = limit, roiImages.count >= limit { break }' in listed, 'a limited search does not stop')
all_of_them = body(study, 'public dynamic func roiImages()')
check('self.imagesWithROIs(atMost: nil)' in all_of_them and 'roiImages.sort(using:' in all_of_them,
      'roiImages() no longer lists every image with ROIs, sorted')
check('self.imagesWithROIs(atMost: 1)' in body(study, 'func hasROIImages()'), 'hasROIImages() does not stop at the first image')
portal = source_text('WebPortalResponse')
at = portal.find('"hasKeyImagesOrROIImages"')
check(at > 0 and 'study?.hasROIImages()' in portal[at:at + 400] and 'roiImages()' not in portal[at:at + 400],
      'the portal lists every image with ROIs to answer whether there is one')
print('PASS: roiImages() reads the study once; the portal stops at the first image with ROIs')
