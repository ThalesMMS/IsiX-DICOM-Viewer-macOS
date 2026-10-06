#import "MPRController.h"
#import "MPRDCMView.h"
#import "MPRHostMessages.h"
#import "DCMPix.h"

/// Metal reconstructs the 3D MPR planes. The host retains its camera,
/// geometry, ROIs, tools and export. What Metal declines is computed on the
/// CPU and says why. There is no switch to the original renderer.
@interface MPRController (HorosMPRHost)
/// YES: kept for the native tools that read it.
- (BOOL)horosMPRMetalEnabled;
/// Reconstructs the three planes with the current options.
- (void)horosMPRReconstructPlanes;
/// The reason the last reconstruction kept the original pixels, or nil.
- (NSString *)horosMPRFallbackReason;
/// Wall milliseconds of the last synchronous Metal reslice, or -1 if none ran.
- (double)horosMPRLastMilliseconds;
/// Bytes of the volumes currently on the GPU, the fused one included, or 0.
- (NSInteger)horosMPRVolumeBytes;
/// Drops the GPU volume; the next reconstruction re-uploads if enabled.
- (void)horosMPRReleaseVolume;
/// Whether single planes are drawn with cubic interpolation: the
/// `HorosMPRCubicDisplay` preference (Settings → 3D), off by default.
- (BOOL)horosMPRCubicDisplay;
@end

/// MPRDCMView is Swift: it sends itself these messages through
/// HorosMPRHostViewMessages, which no header it reads can declare otherwise.
@interface MPRDCMView (HorosMPRHost) <HorosMPRHostViewMessages>
/// Returns a malloc-owned float image after preparing the camera geometry.
/// A NULL result requests the normal CPU render. Main thread only.
- (float *)horosMPRCopyImageWidth:(long *)width height:(long *)height;
/// Whether the image the last call returned is ARGB bytes, an RGB volume's
/// plane, rather than floats.
- (BOOL)horosMPRCopiedImageIsRGB;
/// The fused series' plane the last call resliced with it, malloc-owned,
/// or NULL: then the host reslices it with VTK, as it does the plane.
- (float *)horosMPRTakeFusedImageWidth:(long *)width height:(long *)height;
/// Hands `pix` the cubic display plane of the last reconstruction, or takes
/// its old one away when the last reconstruction made none.
- (void)horosMPRAttachDisplayPlaneTo:(DCMPix *)pix;
/// After VTK's render of a plane in volume rendering mode: whether the Metal
/// ray cast drew it, as the view's fallback notice and the controller's reason.
- (void)horosMPRVolumeRendered;
@end

