#import "DCMView.h"
#import "ViewerController.h"
@class HorosPlanarPerformanceTrace;
@class CAMetalLayer;

/// Rendering changes only; controllers, DICOM pixels and plugin APIs remain
/// the host's. These entry points are main-thread-only.
@interface ViewerController (HorosPlanarHost)
/// Always YES: every view draws its picture with Metal (#728).
- (BOOL)horosPlanarMetalEnabled;
@end

@interface DCMView (HorosPlanarHost)
- (NSDictionary *)horosPlanarSnapshot;
/// Draws the view's picture into its layer and presents it with the current
/// transaction; NO, with a reason, when it cannot.
- (BOOL)horosDrawPlanarInLayer:(CAMetalLayer *)layer inverted:(BOOL)inverted;
/// A frame with no picture: the clear colour, white or black, inverted with the view.
- (void)horosClearLayer:(CAMetalLayer *)layer white:(BOOL)white inverted:(BOOL)inverted;
/// The picture the view shows, BGRA, rows from the top, `width` x `height`
/// backing pixels, as it draws it: for a capture.
- (NSData *)horosPlanarPixelsWidth:(NSInteger)width height:(NSInteger)height inverted:(BOOL)inverted;
/// The same picture magnified: the square of `side` backing pixels whose top
/// left, top right and bottom left corners show these points of the view's
/// bounds.
- (NSData *)horosPlanarPixelsSide:(NSInteger)side topLeft:(NSPoint)topLeft topRight:(NSPoint)topRight
    bottomLeft:(NSPoint)bottomLeft inverted:(BOOL)inverted;
- (NSString *)horosPlanarFallbackReason;
/// Which submission path drew the last planar frame, or an empty string when
/// none has (#609). Diagnostics: the picture is the same either way.
- (NSString *)horosPlanarBackendName;
/// The GPU time the last planar submission reported, in milliseconds.
- (double)horosPlanarGPUMilliseconds;
/// Lets another host bridge (the MPR one) show the same paused-renderer notice.
- (void)horosSetPlanarFallbackReason:(NSString *)reason;
/// That notice, when a bridge has set one.
- (NSString *)horosEngineNotice;
- (void)horosInvalidatePlanar;
- (HorosPlanarPerformanceTrace *)horosPlanarPerformanceTrace;
- (double)horosPlanarLastCommandMilliseconds;
@end
