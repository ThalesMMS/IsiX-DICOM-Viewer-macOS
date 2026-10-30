#!/usr/bin/env python3
"""Exercise actual movie finalization with delayed and failing writer peers.

QuicktimeExport is Swift: the finalization block is taken from the
Swift source (tests/sources.py) and compiled with Swift peers of the same shape."""
from pathlib import Path
import subprocess, tempfile, sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import sources
root=Path(__file__).resolve().parents[1]
path=sources.source_path('QuicktimeExport')
s=(subprocess.check_output(['git','show',sys.argv[1]+':'+str(path.relative_to(root))]).decode('utf-8') if len(sys.argv)>1 else sources.source_text('QuicktimeExport'))
a=s.index('                if writer.status == .writing {\n                    writerInput?.markAsFinished()')
b=s.index('                _ = (object as AnyObject?)?.perform(',a)
body=s[a:b]
code=r'''
import Foundation
import AVFoundation
final class Writer {
 var status: AVAssetWriter.Status
 var fail = false, called = false
 var error: Error?
 init(_ status: AVAssetWriter.Status) { self.status = status }
 func finishWriting(completionHandler: @escaping () -> Void) {
  called = true
  DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
   self.status = self.fail ? .failed : .completed
   if self.fail { self.error = NSError(domain: "WriterTest", code: 17, userInfo: nil) }
   completionHandler()
  }
 }
 func cancelWriting() { status = .cancelled }
}
final class Input {
 func markAsFinished() {}
}
func fail(_ message: String) -> Never { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
for scenario in 0..<5 {
 let writer = Writer(scenario == 3 ? .failed : .writing); writer.fail = scenario == 1
 let writerInput: Input? = Input()
 var completed = false, failed = scenario == 4, aborted = scenario == 2; var error: NSError? = nil
 _ = (failed, aborted)
BODY
 if scenario == 0 && (!completed || writer.status != .completed) { fail("returned before writer finished") }
 if scenario == 1 && (completed || error?.code != 17) { fail("failed finalization reported success or lost error") }
 if (scenario == 2 || scenario == 4) && (completed || writer.called || writer.status != .cancelled) { fail("cancelled writer finalized") }
 if scenario == 3 && (completed || writer.called) { fail("failed writer finalized again") }
}
print("PASS: waits for delayed completion; preserves failure error; cancels without finalizing; rejects failed writer")
'''.replace('BODY',body)
with tempfile.TemporaryDirectory(prefix='horos-movie-finalization-') as folder:
 p=Path(folder);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-sanitize=address',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)

# The browser has an independent export path (BrowserController+MovieExport.swift).
# Compile its real finalization sequence against a delayed writer peer, while
# the QuicktimeExport path above retains its cancellation/failure scenarios.
browser = sources.source_text('BrowserController+MovieExport')
a = browser.index('                let finished = DispatchSemaphore(value: 0)')
b = browser.index('                finished.wait()\n', a) + len('                finished.wait()\n')
native_body = browser[a:b]
native = r'''
import Foundation
final class WriterPeer: @unchecked Sendable {
    var completed = false, fail = false
    var error: NSError?
    func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            if self.fail { self.error = NSError(domain: "SyntheticWriter", code: 17, userInfo: nil) }
            self.completed = true
            handler()
        }
    }
}
for scenario in 0..<2 {
    let peer = WriterPeer(); peer.fail = scenario == 1
    // The controlled peer supplies only completion timing and an error.
    let writer = peer
BODY
    if !peer.completed || (scenario == 1 && peer.error?.code != 17) { abort() }
}
print("PASS: browser's real finalization waits for asynchronous success/failure completion")
'''.replace('BODY', native_body)
with tempfile.TemporaryDirectory(prefix='horos-browser-movie-finalization-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(native)
    subprocess.run(['xcrun', 'swiftc', '-sanitize=address', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=10)

# Loading tracks is asynchronous in the current SDK. The synchronous import
# paths retain the callback result across their MRC lifetime boundary. Exercise
# the verbatim production sequences with real AVFoundation assets.
if len(sys.argv) == 1:
    import shutil
    if not shutil.which('ffmpeg'):
        print('skipped: movie metadata fixture needs ffmpeg', file=sys.stderr)
        raise SystemExit(2)
    loaders = []
    for filename, source_variable in (('DCMPix.m', 'self.srcFile'), ('DicomFile.mm', 'filePath')):
        path = root / 'Horos/Sources' / filename
        text = path.read_bytes().decode('mac_roman') if path.is_file() else ''
        if filename == 'DCMPix.m' and 'AVURLAsset *asset = [AVURLAsset URLAssetWithURL:' not in text:
            # DCMPix reads a movie in Swift (DCMPix+NonDICOM.swift), where ARC keeps the
            # tracks the callback gives: it waits for them, then reads the frame. The
            # frame it reads is checked by test-dcmpix-non-dicom-formats; the Objective-C
            # sequence left is DicomFile's, run for both legs.
            swift = (root / 'Horos/Sources/DCMPix+NonDICOM.swift').read_text()
            for needle in ('asset.loadTracks(withMediaType: .video)', 'loaded.signal()', 'loaded.wait()',
                           'AVAssetReader(asset: asset)', 'kCVPixelFormatType_32ARGB'):
                if needle not in swift:
                    print('FAIL: the Swift movie reading no longer has %r' % needle)
                    raise SystemExit(1)
            loaders.append(None)
            continue
        if filename == 'DicomFile.mm' and not text:
            # DicomFile reads a movie in Swift too (DicomFile+NonDICOMReaders.swift):
            # the tracks are held by an object the callback fills, then the frames
            # are counted. The counts and sizes it gives are compared with the
            # Objective-C's by test-dicom-file-equivalence.
            swift = (root / 'Horos/Sources/DicomFile+NonDICOMReaders.swift').read_text()
            for needle in ('asset.loadTracks(withMediaType: .video)', 'tracksLoaded.signal()', 'tracksLoaded.wait()',
                           'AVAssetReader(asset: asset)', 'kCVPixelFormatType_32ARGB', 'CMSampleBufferInvalidate(sample)'):
                if needle not in swift:
                    print('FAIL: the Swift movie reading of DicomFile no longer has %r' % needle)
                    raise SystemExit(1)
            loaders.append(None)
            continue
        start = text.index('AVURLAsset *asset = [AVURLAsset URLAssetWithURL:')
        end = text.index('if( video_tracks.count)', start)
        body = text[start:end].replace(source_variable, 'sourcePath')
        loaders.append(body)
    if all(body is None for body in loaders):
        print('PASS: both movie readings are Swift, where ARC keeps the tracks the callback gives; '
              'no Objective-C sequence is left to run')
        raise SystemExit(0)
    loaders = [body if body is not None else loaders[-1] for body in loaders]
    metadata = r'''
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
static BOOL checkAsset(NSString *sourcePath, BOOL valid, int loader) {
    NSError *error = nil;
    if (loader == 0) {
PIX_LOADER
        if (!valid) return video_tracks.count == 0;
        if (video_tracks.count != 1 || !asset_reader) return NO;
        AVAssetReaderTrackOutput *output = [[[AVAssetReaderTrackOutput alloc] initWithTrack:video_tracks[0]
            outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32ARGB)}] autorelease];
        [asset_reader addOutput:output]; if (![asset_reader startReading]) return NO;
        int frames = 0; CMSampleBufferRef sample;
        while ((sample = [output copyNextSampleBuffer])) {
            CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
            if (!image || CVPixelBufferGetWidth(image) != 16 || CVPixelBufferGetHeight(image) != 16) { CFRelease(sample); return NO; }
            ++frames; CFRelease(sample);
        }
        return frames == 2 && asset_reader.status == AVAssetReaderStatusCompleted;
    } else {
FILE_LOADER
        if (!valid) return video_tracks.count == 0;
        return video_tracks.count == 1 && asset_reader != nil;
    }
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        for (int loader = 0; loader < 2; ++loader) {
            if (!checkAsset([NSString stringWithUTF8String:argv[1]], YES, loader)
                || !checkAsset([NSString stringWithUTF8String:argv[2]], NO, loader)) return 1;
        }
        puts("PASS: production DCMPix/DicomFile async metadata under synchronous MRC, two decoded frames, invalid movie rejected");
    }
    return 0;
}
'''.replace('PIX_LOADER', loaders[0]).replace('FILE_LOADER', loaders[1])
    with tempfile.TemporaryDirectory(prefix='horos-movie-metadata-') as folder:
        p = Path(folder)
        (p / 'invalid.mov').write_bytes(b'not a movie')
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'color=c=white:s=16x16:r=2', '-frames:v', '2', '-c:v', 'libx264',
                        '-pix_fmt', 'yuv420p', str(p / 'fixture.mov')], check=True)
        (p / 'metadata.m').write_text(metadata)
        for optimize in ('-O0', '-Os'):
            subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', optimize,
                            '-target', 'arm64-apple-macos26.0', '-fsanitize=address,undefined',
                            '-Werror=deprecated-declarations', str(p / 'metadata.m'),
                            '-framework', 'Foundation', '-framework', 'AVFoundation',
                            '-framework', 'CoreMedia', '-framework', 'CoreVideo',
                            '-o', str(p / 'metadata')], check=True)
            subprocess.run([str(p / 'metadata'), str(p / 'fixture.mov'), str(p / 'invalid.mov')],
                           check=True, timeout=15)
