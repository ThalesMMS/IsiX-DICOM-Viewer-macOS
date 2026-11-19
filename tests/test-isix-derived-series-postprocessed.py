#!/usr/bin/env python3
"""A series a plugin computes opens as a post-processed series.

IsiXViewerAdapter.openDerivedSeries opens the images a plugin computed in a
new 2D viewer: copies of the source images, whose pixels are the plugin's,
in one volume the new viewer owns, listed with the files of the source
images. The copies still name the source file and keep the revision read
from it, so only the viewer's post-processed mark tells that their pixels
are no file's: Revert Series of the 2D viewer refuses a post-processed
series, and a volume window opened on it neither asks the 2D viewer to read
the files again on Revert nor restores the scissors' cut from the files on
Tab. Unmarked, those read frame `index` of the source file over the
plugin's pixels.

The adapter's openDerivedSeries, the lookup of its sources and
IsiXObjectIdentities are taken as they stand from IsiXViewerAdapter.swift
and compiled with swiftc, with the plugin kit's sources, over Objective-C
doubles of ViewerController, DCMView and DCMPix that answer the messages
they send and record what the new viewer is told. Checked:

* one new viewer opens, marked post-processed; the source viewer is not;
* its images are copies of the sources the plugin named, in the plugin's
  order, holding the plugin's samples and still naming the source files,
  listed with the sources' files.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / 'Horos/Sources/IsiXViewerAdapter.swift'
KIT = sorted((ROOT / 'IsiXPluginKit/Sources').glob('*.swift'))


def extract(text, pattern, what):
    found = re.search(pattern, text, re.S | re.M)
    if not found:
        raise SystemExit(f'FAIL: IsiXViewerAdapter.swift has no {what}')
    return found.group(0)


text = ADAPTER.read_text(encoding='utf-8')
identities = extract(text, r'^@MainActor\nfinal class IsiXObjectIdentities \{\n.*?^\}\n', 'IsiXObjectIdentities')
# The adapter's stored properties, its init and the lookup of an image, up to
# the first of the backend's requirements.
head = extract(text, r'^@MainActor\nfinal class IsiXViewerAdapter: IsiXViewerBackend \{\n.*?(?=^    // MARK: series and images\n)',
               'IsiXViewerAdapter class with its lookup of an image')
opening = extract(text, r'^    func openDerivedSeries\(_ series: IsiXDerivedSeries\) throws -> any IsiXViewerBackend \{\n.*?^    \}\n',
                  'openDerivedSeries')

HEADER = r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <AppKit/AppKit.h>
@interface ROI : NSObject
@end
// The DCMPix properties the adapter sets, spelled as DCMPix.h declares them.
@interface DCMPix : NSObject <NSCopying>
@property long frameNo;
@property(setter=setID:) long ID;
@property long tot;
@property(nonatomic) long pwidth, pheight;
@property(nonatomic, setter=setRGB:) BOOL isRGB;
@property(setter=setfImage:) float* fImage;
@property(copy) NSString *srcFile;
- (void)computePixMinPixMax;
@property(readonly) float probeMinimum, probeMaximum;
@end
@interface DCMView : NSObject
@property short curImage;
- (void)setWLWW:(float)wl :(float)ww;
@end
// On the main actor, as the app's viewer is by its AppKit superclass.
NS_SWIFT_UI_ACTOR
@interface ViewerController : NSObject
@property(retain) id window;
- (short)maxMovieIndex;
- (short)curMovieIndex;
- (NSMutableArray*)pixList:(long)i;
- (NSMutableArray*)fileList:(long)i;
- (NSMutableArray*)roiList:(long)i;
- (DCMView*)imageView;
- (void)needsDisplayUpdate;
- (void)setWL:(float)wl WW:(float)ww;
- (void)setPostprocessed:(BOOL)v;
- (BOOL)postprocessed;
// What the harness gives the viewer and reads back.
@property(retain) NSMutableArray *probePixes, *probeFiles;
@property(retain) NSData *probeVolume;
@property(readonly) NSMutableArray *probeOpened;
@end
'''

DOUBLE = r'''
#import "Harness.h"
@implementation ROI
@end
@implementation DCMPix
- (id)copyWithZone:(NSZone*)zone {
 DCMPix *copy = [[DCMPix allocWithZone:zone] init];
 copy.frameNo = self.frameNo; copy.ID = self.ID; copy.tot = self.tot;
 copy.pwidth = self.pwidth; copy.pheight = self.pheight; copy.isRGB = self.isRGB;
 copy.fImage = self.fImage; copy.srcFile = self.srcFile;
 return copy;
}
- (void)computePixMinPixMax {
 _probeMinimum = INFINITY; _probeMaximum = -INFINITY;
 for (long i = 0; i < self.pwidth * self.pheight; i++) {
  _probeMinimum = MIN(_probeMinimum, self.fImage[i]); _probeMaximum = MAX(_probeMaximum, self.fImage[i]);
 }
}
@end
@implementation DCMView
- (void)setWLWW:(float)wl :(float)ww {}
@end
@implementation ViewerController {
 BOOL postprocessed;
 DCMView *view;
}
- (id)init {
 if ((self = [super init])) {
  self.window = [[NSObject new] autorelease];
  view = [DCMView new];
  _probeOpened = [NSMutableArray new];
 }
 return self;
}
- (short)maxMovieIndex { return 1; }
- (short)curMovieIndex { return 0; }
- (NSMutableArray*)pixList:(long)i { return i == 0 ? self.probePixes : nil; }
- (NSMutableArray*)fileList:(long)i { return i == 0 ? self.probeFiles : nil; }
- (NSMutableArray*)roiList:(long)i { return nil; }
- (DCMView*)imageView { return view; }
- (void)needsDisplayUpdate {}
- (void)setWL:(float)wl WW:(float)ww {}
- (void)setPostprocessed:(BOOL)v { postprocessed = v; }
- (BOOL)postprocessed { return postprocessed; }
// -newWindow::: of the app: a new viewer on these slices, files and volume,
// handed over +1 (the new family), which the window keeps in the app.
- (ViewerController*)newWindow:(NSMutableArray*)pixes :(NSMutableArray*)files :(NSData*)volume {
 ViewerController *made = [[ViewerController alloc] init];
 made.probePixes = pixes; made.probeFiles = files; made.probeVolume = volume;
 [_probeOpened addObject:made];
 return made;
}
@end
'''

STUBS = '''
// The backend's other requirements, which openDerivedSeries does not use.
extension IsiXViewerAdapter {
    private static var absent: IsiXPluginError { .hostFailure("Not in the harness.") }
    func seriesSummary() throws -> IsiXSeriesSummary { throw Self.absent }
    func currentPosition() throws -> IsiXSlicePosition { throw Self.absent }
    func setCurrentSlice(_ slice: Int) throws { throw Self.absent }
    func image(slice: Int?, phase: Int?) throws -> IsiXImage { throw Self.absent }
    func windowLevel() throws -> IsiXWindowLevel { throw Self.absent }
    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws { throw Self.absent }
    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws { throw Self.absent }
    func rois(slice: Int?, phase: Int?) throws -> [IsiXROI] { throw Self.absent }
    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI { throw Self.absent }
    func removeROI(_ id: IsiXROIID) throws { throw Self.absent }
    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics { throw Self.absent }
    func setNeedsDisplay() {}
}
'''

MAIN = '''
@main
struct DerivedSeriesHarness {
    @MainActor static func main() throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        // A source viewer of three 4 x 2 slices, each read from its own file.
        let width = 4, height = 2, count = width * height
        let stored = UnsafeMutablePointer<Float>.allocate(capacity: 3 * count)
        stored.initialize(repeating: -1000, count: 3 * count)
        let source = ViewerController()
        source.probePixes = NSMutableArray()
        source.probeFiles = NSMutableArray()
        for slice in 0..<3 {
            let pix = DCMPix()
            pix.pwidth = width
            pix.pheight = height
            pix.fImage = stored + slice * count
            pix.frameNo = 0
            pix.id = slice
            pix.tot = 3
            pix.srcFile = "/source/slice-\\(slice).dcm"
            source.probePixes.add(pix)
            source.probeFiles.add("image-\\(slice)")
        }

        // The plugin's series: its own samples, placed at slices 2 and 0.
        let samples: [[Float]] = [(0..<count).map { Float($0) }, (0..<count).map { Float(100 + $0) }]
        let adapter = IsiXViewerAdapter(viewer: source, identities: IsiXObjectIdentities())
        let opened = try adapter.openDerivedSeries(IsiXDerivedSeries(images: [
            IsiXDerivedImage(sourceSlice: 2, pixels: try IsiXPixelBuffer(width: width, height: height, samples: samples[0])),
            IsiXDerivedImage(sourceSlice: 0, pixels: try IsiXPixelBuffer(width: width, height: height, samples: samples[1])),
        ]))

        check(source.probeOpened.count == 1, "openDerivedSeries opened \\(source.probeOpened.count) viewers, not one")
        if let created = source.probeOpened.firstObject as? ViewerController {
            check(created.postprocessed(),
                  "the new viewer is not marked post-processed: Revert Series, and the volume window's Revert and Tab, "
                  + "would read the source files' frames over the plugin's pixels")
            check(opened.isOpen && opened.viewerID != adapter.viewerID, "the backend returned is not the new viewer's")
            let pixes = (created.probePixes as? [DCMPix]) ?? []
            check(pixes.count == 2, "the new viewer has \\(pixes.count) images, not the plugin's 2")
            for (index, pix) in pixes.enumerated() where index < 2 {
                let values = Array(UnsafeBufferPointer(start: pix.fImage, count: count))
                check(values == samples[index], "image \\(index) does not hold the plugin's samples: \\(values)")
                check(pix.probeMinimum == samples[index].min() && pix.probeMaximum == samples[index].max(),
                      "image \\(index)'s range was not measured on the plugin's samples")
                check(pix.tot == 2 && pix.id == index, "image \\(index) is not numbered in the new series")
            }
            check(pixes.map { $0.srcFile ?? "" } == ["/source/slice-2.dcm", "/source/slice-0.dcm"],
                  "the copies are not the plugin's sources, in its order")
            check((created.probeFiles as? [String]) == ["image-2", "image-0"], "the new viewer is not listed with the sources' files")
            check((source.probePixes as? [DCMPix])?.allSatisfy { $0.fImage.pointee == -1000 } == true,
                  "the source viewer's pixels changed")
        }
        check(!source.postprocessed(), "the source viewer was marked post-processed in place of the new one")

        if failures.isEmpty {
            print("PASS: a plugin's derived series opens in a new viewer marked post-processed, with the plugin's pixels")
        } else {
            for failure in failures { FileHandle.standardError.write("FAIL: \\(failure)\\n".data(using: .utf8)!) }
            exit(1)
        }
    }
}
'''

if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

with tempfile.TemporaryDirectory(prefix='horos-derived-series-') as tmp:
    folder = Path(tmp)
    (folder / 'Harness.h').write_text(HEADER)
    (folder / 'Double.m').write_text(DOUBLE)
    (folder / 'Harness.swift').write_text('import AppKit\n\n' + identities + '\n' + head + opening + '}\n' + STUBS + MAIN)
    target = ['-target', 'arm64-apple-macos15.0']
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', *target, '-I', str(folder), str(folder / 'Double.m'),
                    '-o', str(folder / 'Double.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'DerivedSeriesHarness', *target,
                    '-import-objc-header', str(folder / 'Harness.h'), *map(str, KIT), str(folder / 'Harness.swift'),
                    str(folder / 'Double.o'), '-framework', 'AppKit', '-o', str(folder / 'harness')], check=True)
    result = subprocess.run([str(folder / 'harness')], capture_output=True, text=True, timeout=60)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)
