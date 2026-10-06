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

# The browser has an independent Objective-C export path. Compile its real
# dispatch finalization sequence against a delayed writer peer, while the Swift
# production path above retains its cancellation/failure scenarios.
browser = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('mac_roman')
a = browser.index('            dispatch_semaphore_t finished = dispatch_semaphore_create(0);')
b = browser.index('#endif', a) + len('#endif')
native_body = browser[a:b]
native = r'''
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>
@interface WriterPeer : NSObject
@property BOOL completed;
@property BOOL fail;
@property(retain) NSError *error;
- (void)finishWritingWithCompletionHandler:(void (^)(void))handler;
@end
@implementation WriterPeer
- (void)finishWritingWithCompletionHandler:(void (^)(void))handler {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (self.fail) self.error = [NSError errorWithDomain:@"SyntheticWriter" code:17 userInfo:nil];
        self.completed = YES;
        handler();
    });
}
@end
int main(void) { @autoreleasepool {
    for (int scenario = 0; scenario < 2; ++scenario) {
        WriterPeer *peer = [[WriterPeer alloc] init]; peer.fail = scenario == 1;
        // AVFoundation's real declaration checks the production selector ABI;
        // the controlled peer supplies only completion timing and an error.
        AVAssetWriter *writer = (id)peer;
BODY
        if (!peer.completed || (scenario == 1 && peer.error.code != 17)) abort();
    }
    puts("PASS: browser's real C finalization waits for asynchronous success/failure completion");
} }
'''.replace('BODY', native_body)
with tempfile.TemporaryDirectory(prefix='horos-browser-movie-finalization-') as folder:
    p = Path(folder)
    (p / 'main.m').write_text(native)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-Wdeprecated-declarations',
                    str(p / 'main.m'), '-framework', 'Foundation', '-framework', 'AVFoundation', '-o', str(p / 'test')], check=True)
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
        text = (root / 'Horos/Sources' / filename).read_bytes().decode('mac_roman')
        start = text.index('AVURLAsset *asset = [AVURLAsset URLAssetWithURL:')
        end = text.index('if( video_tracks.count)', start)
        body = text[start:end].replace(source_variable, 'sourcePath')
        loaders.append(body)
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
