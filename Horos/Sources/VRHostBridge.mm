#import "VRHostBridge.h"
#import "DCMPix.h"
#import "Horos-Swift.h"
#import <objc/runtime.h>
#import <Accelerate/Accelerate.h>
#include <vtkCamera.h>
#include <vtkMath.h>
#include <vtkRenderWindow.h>
#include <vtkVolumeProperty.h>
#include <vtkBoxWidget.h>
#include <vtkVolume.h>
#include <vtkMatrix4x4.h>
#include <vtkImageData.h>
#include <vtkFixedPointRayCastImage.h>
#include <vtkTextActor.h>
#include <vtkVolumeMapper.h>
#include <vtkLight.h>
#include <vtkLightCollection.h>
#include <vtkRenderer.h>
#include <algorithm>
#include <cmath>
#include <vector>

// The fused series has its own renderer, volume and reason.
static char rendererKey, uploadedKey, reasonKey, millisecondsKey;
static char fusedRendererKey, fusedUploadedKey, fusedReasonKey, fusedMillisecondsKey;
static char mprVolumeMetalKey, mprVolumeMetalDrawnKey;

/// VTK's ray-cast image grid for one mapper: viewport width and height, the
/// in-use rectangle's top-left origin, and its size, in ray pixels.
static NSArray *HorosRayCastImageRegion(vtkHorosFixedPointVolumeRayCastMapper *mapper) {
    if (!mapper) return nil;
    vtkFixedPointRayCastImage *image = mapper->GetRayCastImage();
    int *viewport = image->GetImageViewportSize(), *origin = image->GetImageOrigin(), *size = image->GetImageInUseSize();
    return @[@(viewport[0]), @(viewport[1]), @(origin[0]), @(viewport[1] - origin[1] - size[1]), @(size[0]), @(size[1])];
}

/// One mapper's ray-cast image as the view shows it: the in-use rectangle,
/// premultiplied RGBA in 15 bits, bottom row first, whichever engine filled it.
static NSData *HorosRayCastImagePixels(vtkHorosFixedPointVolumeRayCastMapper *mapper) {
    if (!mapper) return nil;
    vtkFixedPointRayCastImage *image = mapper->GetRayCastImage();
    int *size = image->GetImageInUseSize(), *memory = image->GetImageMemorySize();
    unsigned short *pixels = image->GetImage();
    if (!pixels || size[0] <= 0 || size[1] <= 0) return nil;
    NSUInteger row = (NSUInteger)size[0] * 4;
    NSMutableData *data = [NSMutableData dataWithLength:row * size[1] * sizeof(unsigned short)];
    unsigned short *out = (unsigned short *)data.mutableBytes;
    for (int y = 0; y < size[1]; ++y)
        memcpy(out + y * row, pixels + (NSUInteger)y * memory[0] * 4, row * sizeof(unsigned short));
    return data;
}

/// A projection's values into the fourth word of VTK's ray-cast image, as the
/// volume stores them: (value + offset) * factor, rounded and clamped to 16
/// bits; 0 for no value. `values` holds one float a pixel, top row first, the
/// image `stride` words a row, bottom row first.
static void HorosWriteFullDepthProjection(unsigned short *rgba, NSUInteger stride, int width, int height,
                                          const float *values, float offset, float factor) {
    for (int y = 0; y < height; ++y) {
        unsigned short *out = rgba + (NSUInteger)(height - 1 - y) * stride + 3;
        const float *in = values + (NSUInteger)y * width;
        for (int x = 0; x < width; ++x, out += 4) {
            double word = std::isfinite(in[x]) ? std::round(((double)in[x] + offset) * factor) : 0;
            *out = (unsigned short)std::min(65535.0, std::max(0.0, word));
        }
    }
}

/// How many of VTK's ray samples make a millimetre: the exponent that turns
/// the opacity VTK applies per sample into the renderer's opacity per
/// millimetre. Nominally superSampling / spacing (one sample per unit of VTK's
/// scaled frame); in practice the mapper's sample distance (BESTRENDERING, 1.6
/// units) gives superSampling / (spacing × 1.6), measured against VTK.
/// HorosVolumeMetalOpacityExponent overrides
/// it without a rebuild. Both volumes of a fused view share the frame, so the
/// fused series uses the image's spacing too.
static double HorosSamplesPerMillimetre(double superSampling, double spacingX) {
    double rayStep = [[NSUserDefaults standardUserDefaults] floatForKey:@"BESTRENDERING"];
    if (rayStep <= 0) rayStep = 1.6;
    double samplesPerMillimetre = superSampling > 0 ? superSampling / (spacingX * rayStep) : 1;
    double override = [[NSUserDefaults standardUserDefaults] doubleForKey:@"HorosVolumeMetalOpacityExponent"];
    return override > 0 ? override : samplesPerMillimetre;
}

/// The fused series' opacity as VTK holds it: setBlendingFactor: fills a table,
/// and BuildFunctionFromTable spreads its first 255 entries evenly over the
/// fused window, clamped outside it. As the renderer's points (x in 0…256 over
/// the window): `opacity` per millimetre of ray for composite rendering, and
/// `projectionOpacity`, the curve itself, which a projection paints with.
static void HorosFusedOpacityPoints(const double *table, double samplesPerMillimetre,
                                    NSMutableArray *opacity, NSMutableArray *projectionOpacity) {
    for (int i = 0; i < 255; ++i) {
        double x = i * 256.0 / 254.0, y = MIN(1, MAX(0, table[i]));
        [opacity addObject:@(x)];
        [opacity addObject:@(1 - pow(1 - y, samplesPerMillimetre))];
        [projectionOpacity addObject:@(x)];
        [projectionOpacity addObject:@(y)];
    }
}

/// An RGB volume's transfer tables as the renderer takes them: VTK's
/// component colour functions for red, green and blue over the byte's
/// 0...255, one table after the other, and the components' shared opacity
/// function at those 256 values, per millimetre of ray for composite rendering
/// and as it is for a projection's painting. Nil, with the reason, when a
/// component is weighted as the renderer does not weigh it.
static NSString *HorosColourTables(vtkVolumeProperty *property, double samplesPerMillimetre,
                                   NSData **clut, NSData **opacityTable, NSData **projectionTable) {
    if (property->GetComponentWeight(0) != 0) return @"An RGB volume that weighs its alpha keeps the original renderer.";
    NSMutableData *tables = [NSMutableData dataWithLength:3 * 256 * 4];
    unsigned char *bytes = (unsigned char *)tables.mutableBytes;
    for (int component = 1; component <= 3; ++component) {
        if (property->GetComponentWeight(component) != 1) return @"A weighted RGB component keeps the original renderer.";
        double colours[3 * 256];
        property->GetRGBTransferFunction(component)->GetTable(0, 255, 256, colours);
        for (int i = 0; i < 256; ++i) {
            for (int channel = 0; channel < 3; ++channel)
                bytes[4 * (256 * (component - 1) + i) + channel] = (unsigned char)fmin(255, fmax(0, colours[3 * i + channel] * 255 + 0.5));
            bytes[4 * (256 * (component - 1) + i) + 3] = 255;
        }
    }
    double alphas[256];
    property->GetScalarOpacity(1)->GetTable(0, 255, 256, alphas);
    NSMutableData *perMillimetre = [NSMutableData dataWithLength:256 * sizeof(float)], *raw = [NSMutableData dataWithLength:256 * sizeof(float)];
    float *composite = (float *)perMillimetre.mutableBytes, *painted = (float *)raw.mutableBytes;
    for (int i = 0; i < 256; ++i) {
        double alpha = MIN(1, MAX(0, alphas[i]));
        composite[i] = (float)(1 - pow(1 - alpha, samplesPerMillimetre));
        painted[i] = (float)alpha;
    }
    *clut = tables; *opacityTable = perMillimetre; *projectionTable = raw;
    return nil;
}

/// A volume's ray-cast image as VTK displays it: premultiplied RGBA in its
/// 15-bit fixed-point range, row 0 at the top. Composite rendering converts
/// Metal's premultiplied colour and accumulated opacity. A projection's scalar
/// is a value, not an opacity: VTK paints it with the colour and the unscaled
/// opacity curve at that value, so `projection` is the snapshot to
/// paint it with, or nil for composite rendering.
static NSData *HorosVolumePicture(NSData *bgra, NSData *scalar, NSDictionary *projection) {
    // An RGB volume's projection: three values a pixel, painted with the
    // mapper's own tables.
    if ([projection[@"colourVolume"] boolValue])
        return [HorosMPRColourPlane pictureWithComponents:scalar count:(NSInteger)(bgra.length / 4) tables:projection[@"componentTables"]];
    NSUInteger count = scalar.length / sizeof(float);
    if (projection[@"projectionOpacityTable"])
        return [HorosVolumeRenderer projectionPictureWithScalar:scalar level:[projection[@"level"] doubleValue]
            width:[projection[@"width"] doubleValue] colourTable:projection[@"clut"] opacityTable:projection[@"projectionOpacityTable"]
            background:[projection[@"scalarBackground"] doubleValue]];
    if (projection)
        return [HorosVolumeRenderer projectionPictureWithScalar:scalar level:[projection[@"level"] doubleValue]
            width:[projection[@"width"] doubleValue] clut:projection[@"clut"] opacityPoints:projection[@"projectionOpacity"]
            background:[projection[@"scalarBackground"] doubleValue]];
    if (count == 0 || bgra.length != count * 4) return nil;
    // Per pixel: each colour byte c becomes (c * 32767 + 127) / 255, a table of
    // 256 entries, and the opacity, clamped to [0, 1] with NaN as 0, becomes
    // opacity * 32767 + 0.5 truncated; R, G, B, A. Accelerate does it a row of
    // pixels at a time: a loop over a megapixel image cost 20 ms in Debug.
    NSMutableData *picture = [NSMutableData dataWithLength:count * 4 * sizeof(unsigned short)];
    NSMutableData *planes = [NSMutableData dataWithLength:count * 4];
    NSMutableData *wide = [NSMutableData dataWithLength:count * 4 * sizeof(unsigned short)];
    NSMutableData *opacity = [NSMutableData dataWithData:scalar];
    if (!picture || !planes || !wide || !opacity) return nil;
    Pixel_16U table[256];
    for (unsigned c = 0; c < 256; ++c) table[c] = (Pixel_16U)((c * 32767u + 127u) / 255u);
    unsigned char *plane = (unsigned char *)planes.mutableBytes;
    unsigned short *channel = (unsigned short *)wide.mutableBytes;
    vImage_Buffer source = {(void *)bgra.bytes, 1, count, count * 4};
    vImage_Buffer b8 = {plane, 1, count, count}, g8 = {plane + count, 1, count, count},
                  r8 = {plane + 2 * count, 1, count, count}, a8 = {plane + 3 * count, 1, count, count};
    vImage_Buffer r16 = {channel, 1, count, count * 2}, g16 = {channel + count, 1, count, count * 2},
                  b16 = {channel + 2 * count, 1, count, count * 2}, a16 = {channel + 3 * count, 1, count, count * 2};
    vImage_Buffer rgba = {picture.mutableBytes, 1, count, count * 8};
    if (vImageConvert_ARGB8888toPlanar8(&source, &b8, &g8, &r8, &a8, kvImageNoFlags) != kvImageNoError ||
        vImageLookupTable_Planar8toPlanar16(&r8, &r16, table, kvImageNoFlags) != kvImageNoError ||
        vImageLookupTable_Planar8toPlanar16(&g8, &g16, table, kvImageNoFlags) != kvImageNoError ||
        vImageLookupTable_Planar8toPlanar16(&b8, &b16, table, kvImageNoFlags) != kvImageNoError) return nil;
    float *values = (float *)opacity.mutableBytes;
    const float zero = 0, one = 1, scale = 32767, half = 0.5f;
    for (NSUInteger i = 0; i < count; ++i) if (values[i] != values[i]) values[i] = 0;
    vDSP_vclip(values, 1, &zero, &one, values, 1, count);
    vDSP_vsmsa(values, 1, &scale, &half, values, 1, count);
    vDSP_vfixu16(values, 1, channel + 3 * count, 1, count);
    if (vImageConvert_Planar16UtoARGB16U(&r16, &g16, &b16, &a16, &rgba, kvImageNoFlags) != kvImageNoError) return nil;
    return picture;
}

// Why the mapper refused the ray-cast geometry, one text per cause so that a
// trace can count them.
static NSString *HorosGeometryRefusalReason(vtkHorosFixedPointVolumeRayCastMapper *mapper) {
    switch (mapper->GetGeometryRefusal()) {
        case vtkHorosFixedPointVolumeRayCastMapper::GeometryClippingPlane: return @"The crop uses the original renderer.";
        case vtkHorosFixedPointVolumeRayCastMapper::GeometryNoRows: return @"The ray caster has no rows to cast.";
        case vtkHorosFixedPointVolumeRayCastMapper::GeometryNoViewport: return @"The view has no size yet.";
        default: return @"The 3D view has no volume yet.";
    }
}

@interface VRView (HorosRenderWindow)
- (BOOL)prepareRenderWindow;
@end

@interface VRController (HorosVolumeHostPrivate)
- (NSData *)horosVolumeData;
- (NSArray *)horosVolumePixList;
- (NSData *)horosVolumeMetalRenderWithCamera:(NSArray *)camera near:(double)near far:(double)far
                                     width:(NSInteger)width height:(NSInteger)height imageRegion:(NSArray *)imageRegion
                             geometryDepth:(NSData *)geometryDepth
                                 scalarOut:(NSMutableData *)scalarOut error:(NSError **)error;
- (NSData *)horosFusedVolumeMetalRenderSnapshot:(NSDictionary *)snapshot width:(NSInteger)width height:(NSInteger)height
                                    imageRegion:(NSArray *)imageRegion geometryDepth:(NSData *)geometryDepth
                                      scalarOut:(NSMutableData *)scalarOut error:(NSError **)error;
- (void)horosFusedVolumeMetalRelease;
- (NSData *)horosVolumeMetalRender:(NSDictionary *)snapshot fused:(BOOL)fused width:(NSInteger)width height:(NSInteger)height
                       imageRegion:(NSArray *)imageRegion geometryDepth:(NSData *)geometryDepth
                         scalarOut:(NSMutableData *)scalarOut error:(NSError **)error;
@end

@implementation VRView (HorosVolumeHost)

- (BOOL)horosRenderMetalImageForMapper:(vtkHorosFixedPointVolumeRayCastMapper *)mapper
                            renderer:(vtkRenderer *)renderer volume:(vtkVolume *)renderVolume {
    // A fused series has its own mapper and volume, drawn after the image's:
    // each fills its own ray-cast image, and VTK composes the two, the fused
    // one over the image, premultiplied.
    BOOL fused = blendingVolume && renderVolume == blendingVolume && mapper == blendingVolumeMapper;
    // The MPR's hidden view is on the CPU engine; it asks for Metal plane by
    // plane, in volume rendering mode.
    BOOL mprPlane = [[controller style] isEqualToString:@"noNib"];
    if ((mprPlane ? !self.horosMPRVolumeMetal : engine != 2) || renderer != aRenderer ||
        (renderVolume != self.volume && !fused)) return NO;
    if (mprPlane) objc_setAssociatedObject(self, &mprVolumeMetalDrawnKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @autoreleasepool {
        // A series fused and then closed leaves its volume on the GPU until
        // the image's next frame.
        if (!fused && !blendingVolume) [controller horosFusedVolumeMetalRelease];
        NSString *reason = nil;
        NSDictionary *snapshot = nil;
        // MIP, MinIP and mean draw in Metal, sampled and painted as VTK's ray
        // caster does; the snapshot carries its step and planes. A crop
        // is clipped in Metal against the mapper's own planes, and the clipping
        // range is the camera's own. VTK's cropping regions, which the
        // host never turns on, are planes too when they are one box.
        if (!fused && (isRGB || advancedCLUT)) reason = [self horosVolumeSnapshot][@"error"];
        if (!reason && !mapper->PrepareMPRGeometry(renderer, renderVolume, true))
            reason = HorosGeometryRefusalReason(mapper);
        // The fused snapshot reads the planes PrepareMPRGeometry just set up.
        if (!reason && fused) reason = (snapshot = [self horosFusedVolumeSnapshot])[@"error"];

        NSData *pixels = nil, *picture = nil;
        NSMutableData *opacity = [NSMutableData data];
        vtkFixedPointRayCastImage *image = mapper->GetRayCastImage();
        int *size = image->GetImageInUseSize();
        if (!reason) {
            NSArray *region = [HorosRayCastImageRegion(mapper) subarrayWithRange:NSMakeRange(0, 4)];
            // As in VTK's CPU pass, stop each ray at already drawn geometry.
            // Without this, ribs behind an ROI are painted over it too.
            std::vector<float> depth = mapper->CaptureGeometryDepth(renderer, factor);
            NSData *geometryDepth = depth.empty() ? nil : [NSData dataWithBytes:depth.data() length:depth.size() * sizeof(float)];
            NSError *error = nil;
            // The view's own state: a preset preview shares its controller's
            // renderer and volume, not its camera and tables.
            if (!fused) {
                double snapshotFrom = [HorosMetalPerformanceTrace now];
                snapshot = [self horosVolumeSnapshot];
                [HorosMetalPerformanceTrace recordHostOperation:@"vr.host_snapshot" startedAt:snapshotFrom];
            }
            pixels = fused ? [controller horosFusedVolumeMetalRenderSnapshot:snapshot width:size[0] height:size[1]
                                                                 imageRegion:region geometryDepth:geometryDepth scalarOut:opacity error:&error]
                           : [controller horosVolumeMetalRender:snapshot fused:NO width:size[0] height:size[1]
                                                   imageRegion:region geometryDepth:geometryDepth scalarOut:opacity error:&error];
            if (!pixels) reason = error.localizedDescription ?: @"Metal could not render this volume.";
        }
        NSUInteger count = (NSUInteger)size[0] * size[1];
        // An RGB volume's projection hands back three values a pixel.
        BOOL colourProjection = (fused ? isBlendingRGB : isRGB) && renderingMode != 0;
        BOOL ready = pixels.length == count * 4 && opacity.length == count * sizeof(float) * (colourProjection ? 3 : 1) && count > 0;
        if (!reason && !ready) reason = @"Metal returned an incomplete image.";
        double convertedFrom = [HorosMetalPerformanceTrace now];
        if (!reason) {
            picture = HorosVolumePicture(pixels, opacity, renderingMode == 0 ? nil : snapshot);
            if (picture.length != count * 4 * sizeof(unsigned short)) reason = @"Metal returned an incomplete image.";
        }
        if (reason) [HorosMetalPerformanceTrace recordRefusal:fused ? @"vr.fusion.refusal" : @"vr.refusal" reason:reason];
        objc_setAssociatedObject(controller, fused ? &fusedReasonKey : &reasonKey, reason, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (textWLWW) {
            NSString *imageReason = objc_getAssociatedObject(controller, &reasonKey);
            NSString *fusedReason = blendingVolume ? objc_getAssociatedObject(controller, &fusedReasonKey) : nil;
            NSString *status = imageReason ? [@"CPU fallback: " stringByAppendingString:imageReason] : @"Metal";
            if (fusedReason) status = [status stringByAppendingFormat:@"\nFused series, CPU fallback: %@", fusedReason];
            NSString *label = [NSString stringWithFormat:@"WL: %.4g WW: %.4g\n%@", wl, ww, status];
            textWLWW->SetInput(label.UTF8String);
        }
        if (reason) return NO;

        // ClearImage(), as one memset: its loop over the whole image memory
        // cost milliseconds in Debug.
        unsigned short *rgba = image->GetImage();
        memset(rgba, 0, (size_t)image->GetImageMemorySize()[0] * image->GetImageMemorySize()[1] * 4 * sizeof(unsigned short));
        const unsigned short *painted = (const unsigned short *)picture.bytes;
        NSUInteger row = (NSUInteger)size[0] * 4, stride = (NSUInteger)image->GetImageMemorySize()[0] * 4;
        // VTK keeps the bottom row first.
        for (int y = 0; y < size[1]; ++y)
            memcpy(rgba + (NSUInteger)(size[1] - 1 - y) * stride, painted + (NSUInteger)y * row, row * sizeof(unsigned short));
        // A projection captured in full depth (-prepareFullDepthCapture): the
        // fourth word is the projected value as the volume stores it, which
        // -imageInFullDepthWidth: reads back. VTK's caster wrote it through
        // the linear opacity table the capture installs; Metal paints the
        // opacity curve there, and the 16-bit export held the curve.
        if (fullDepthMode && renderingMode != 0 && !colourProjection)
            HorosWriteFullDepthProjection(rgba, stride, size[0], size[1], (const float *)opacity.bytes,
                                          fused ? blendingOFFSET16 : OFFSET16, fused ? blendingValueFactor : valueFactor);
        [HorosMetalPerformanceTrace recordHostOperation:fused ? @"vr.fusion.host_convert" : @"vr.host_convert" startedAt:convertedFrom];
        return YES;
    }
}

/// VTK's ray-cast image as the hook renders into it: the viewport in ray
/// pixels, the in-use rectangle's top-left origin, and its size. The native
/// comparison renders Metal on this same grid.
- (NSArray *)horosRayCastImageRegion { return HorosRayCastImageRegion(volumeMapper); }

/// What the view shows: the in-use rectangle of VTK's ray-cast image,
/// premultiplied RGBA in 15 bits, rows as VTK keeps them (bottom row first),
/// whichever engine filled it. The native comparison reads it.
- (NSData *)horosRayCastImagePixels { return HorosRayCastImagePixels(volumeMapper); }

- (BOOL)horosHasFusedVolume { return blendingVolume != nil; }

- (NSDictionary *)horosMPRColourTables { return [self horosColourTablesFused:NO refresh:YES]; }

/// The image's or the fused series' mapper tables; inside VTK's own render,
/// which has just brought them up to date, without initialising the volume
/// again.
- (NSDictionary *)horosColourTablesFused:(BOOL)fusedSeries refresh:(BOOL)refresh {
    vtkHorosFixedPointVolumeRayCastMapper *mapper = fusedSeries ? blendingVolumeMapper : volumeMapper;
    vtkVolume *colourVolume = fusedSeries ? blendingVolume : volume;
    vtkVolumeProperty *property = fusedSeries ? blendingVolumeProperty : volumeProperty;
    if (!mapper || !colourVolume || !property || !aRenderer) return @{@"error": @"The 3D view has no volume yet."};
    if (!(fusedSeries ? isBlendingRGB : isRGB)) return @{@"error": @"The volume is not RGB."};
    if (refresh) mapper->PerVolumeInitialization(aRenderer, colourVolume);
    float *shift = mapper->GetTableShift(), *scale = mapper->GetTableScale();
    NSMutableArray *tables = [NSMutableArray array];
    for (int c = 0; c < 4; ++c) {
        double weight = property->GetComponentWeight(c);
        if (weight == 0) continue;
        // The alpha component carries no colour; it is weighted 0 (setup of the view).
        if (c == 0) return @{@"error": @"An RGB volume that weighs its alpha keeps the original renderer."};
        int size = mapper->GetTableSize(c);
        unsigned short *opacity = mapper->GetScalarOpacityTable(c), *colour = mapper->GetColorTable(c);
        if (size <= 0 || !opacity || !colour) return @{@"error": @"The colour tables are not ready."};
        [tables addObject:@{@"component": @(c), @"weight": @(weight), @"shift": @(shift[c]), @"scale": @(scale[c]), @"size": @(size),
                            @"opacity": [NSData dataWithBytes:opacity length:(NSUInteger)size * sizeof(unsigned short)],
                            @"colour": [NSData dataWithBytes:colour length:(NSUInteger)size * 3 * sizeof(unsigned short)]}];
    }
    return @{@"tables": tables};
}

- (BOOL)horosMPRVolumeMetal { return [objc_getAssociatedObject(self, &mprVolumeMetalKey) boolValue]; }

- (void)horosSetMPRVolumeMetal:(BOOL)on {
    objc_setAssociatedObject(self, &mprVolumeMetalKey, on ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &mprVolumeMetalDrawnKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString *)horosMPRVolumeMetalReasonDrawn:(BOOL *)drawn {
    *drawn = [objc_getAssociatedObject(self, &mprVolumeMetalDrawnKey) boolValue];
    NSString *image = [controller horosVolumeMetalFallbackReason];
    NSString *fusedReason = blendingVolume ? [controller horosFusedVolumeMetalFallbackReason] : nil;
    if (fusedReason) return image ? [image stringByAppendingFormat:@" Fused series: %@", fusedReason]
                                  : [@"Fused series: " stringByAppendingString:fusedReason];
    return image;
}

- (NSArray *)horosFusedRayCastImageRegion { return blendingVolume ? HorosRayCastImageRegion(blendingVolumeMapper) : nil; }

- (NSData *)horosFusedRayCastImagePixels { return blendingVolume ? HorosRayCastImagePixels(blendingVolumeMapper) : nil; }

- (NSString *)horosMPRGeometryRefusalWidth:(long *)width height:(long *)height {
    if (!volumeMapper || !aCamera) return @"The 3D view has no volume yet.";
    if (!aCamera->GetParallelProjection()) return @"A perspective plane keeps the original renderer.";
    if (!clipRangeActivated) return @"A plane without a clipping range keeps the original renderer.";
    if (volumeMapper->GetCropping()) return @"VTK cropping regions keep the original renderer.";
    if (![self prepareRenderWindow]) return @"The plane has no window yet.";
    if (!volumeMapper->PrepareMPRGeometry(aRenderer, volume)) return HorosGeometryRefusalReason(volumeMapper);
    int size[2];
    volumeMapper->GetRayCastImage()->GetImageInUseSize(size);
    *width = size[0];
    *height = size[1];
    return size[0] > 0 && size[1] > 0 ? nil : @"The view has no size yet.";
}

- (NSString *)horosMPRFusedGeometryRefusalWidth:(long *)width height:(long *)height {
    if (!blendingVolumeMapper || !blendingVolume) return @"The fused series has no volume yet.";
    if (blendingVolumeMapper->GetCropping()) return @"VTK cropping regions keep the original renderer.";
    if (!blendingVolumeMapper->PrepareMPRGeometry(aRenderer, blendingVolume)) return HorosGeometryRefusalReason(blendingVolumeMapper);
    int size[2];
    blendingVolumeMapper->GetRayCastImage()->GetImageInUseSize(size);
    *width = size[0];
    *height = size[1];
    return size[0] > 0 && size[1] > 0 ? nil : @"The view has no size yet.";
}

- (NSDictionary *)horosMPRFusedVolume {
    if (!blendingController || !blendingVolume || !blendingReader || !blendingFirstObject || !blendingData || !blendingPixList.count)
        return @{@"error": @"The fused series has no volume yet."};
    DCMPix *first = blendingFirstObject;
    // A reversed stack: the blending reader takes the signed interval
    // and the transform below places the slices by it, as the image's does.
    double dz = fabs(first.sliceInterval);
    if (dz == 0) dz = fabs(first.sliceThickness);
    double sx = first.pixelSpacingX, sy = first.pixelSpacingY;
    if (sx <= 0 || sy <= 0) { sx = 1; sy = 1; }
    if (dz <= 0 || !isfinite(dz) || !isfinite(sx) || !isfinite(sy)) return @{@"error": @"The fused volume spacing is not usable."};
    // The float buffer VTK converts to 16 bits from, found among the fused
    // viewer's volumes: the phase setBlendingPixSource: or
    // movieBlendingChangeSource: gave the reader.
    NSUInteger expected = [HorosVolumeAllocation byteCountForWidth:first.pwidth height:first.pheight
                                                             slices:blendingPixList.count bytesPerVoxel:4];
    NSData *voxels = nil;
    for (long i = 0; i < MAX(1, (long)[blendingController maxMovieIndex]) && !voxels; ++i)
        if ([blendingController volumeData:i].bytes == blendingData) voxels = [blendingController volumeData:i];
    if (!voxels || expected == 0 || voxels.length < expected) return @{@"error": @"The fused volume bytes do not match its slices."};
    // As -mprVoxelToWorldTransform places the volume, for the blending reader
    // and volume: the reader's origin and spacing through the volume's matrix,
    // out of VTK's frame scaled by `factor`, column by column.
    vtkImageData *input = blendingReader->GetOutput();
    if (!input || !isfinite(factor) || factor <= 0) return @{@"error": @"The fused volume transform is unavailable."};
    double origin[3], spacing[3];
    input->GetOrigin(origin);
    input->GetSpacing(spacing);
    vtkMatrix4x4 *matrix = blendingVolume->GetMatrix();
    NSMutableArray *transform = [NSMutableArray arrayWithCapacity:16];
    for (int column = 0; column < 4; ++column)
        for (int row = 0; row < 4; ++row)
        {
            double value = row == 3 ? (column == 3 ? 1 : 0) :
                (column < 3 ? matrix->GetElement(row, column) * spacing[column] :
                 matrix->GetElement(row, 3) + matrix->GetElement(row, 0) * origin[0] +
                 matrix->GetElement(row, 1) * origin[1] + matrix->GetElement(row, 2) * origin[2]) / factor;
            [transform addObject:@(value)];
        }
    // A ray that misses the volume leaves 0 in VTK's 16-bit image, which
    // -imageInFullDepthWidth:... reads back as -blendingOFFSET16.
    // An RGB fused series is its ARGB bytes, which only the 3D view's
    // renderer draws.
    return @{@"volume": voxels, @"width": @(first.pwidth), @"height": @(first.pheight), @"depth": @(blendingPixList.count),
             @"transform": transform, @"background": @(-blendingOFFSET16), @"sampleStep": @(MIN(sx, MIN(sy, dz))),
             @"colour": @(isBlendingRGB)};
}

/// The view's camera in the volume's own millimetre frame (the VTK world
/// divided by the view's factor) and the rays' near and far distances: the
/// same for every volume the view draws.
- (NSDictionary *)horosVolumeCameraSnapshot {
    double position[3], focal[3], viewUp[3];
    aCamera->GetPosition(position); aCamera->GetFocalPoint(focal); aCamera->GetViewUp(viewUp);
    // VTK works in the local frame scaled by `factor`; the renderer wants millimetres.
    NSMutableArray *camera = [NSMutableArray array];
    for (int i = 0; i < 3; ++i) [camera addObject:@(position[i] / factor)];
    for (int i = 0; i < 3; ++i) [camera addObject:@(focal[i] / factor)];
    for (int i = 0; i < 3; ++i) [camera addObject:@(viewUp[i])];
    [camera addObject:@(aCamera->GetParallelProjection() ? 1 : 0)];
    [camera addObject:@(aCamera->GetParallelScale() / factor)];
    [camera addObject:@(aCamera->GetViewAngle())];
    // The eye VTK is rendering in stereo: its camera shears the view by
    // tan(-eye angle / 2) for the left eye, + for the right.
    BOOL stereo = [self renderWindow] && [self renderWindow]->GetStereoRender();
    if (stereo)
        [camera addObject:@(tan(vtkMath::RadiansFromDegrees((aCamera->GetLeftEye() ? -0.5 : 0.5) * aCamera->GetEyeAngle())))];
    // The window centre moves VTK's projection, and with it the overlays and
    // picking; the volume must move with them. Its shear slot is 0 without stereo.
    double windowCenter[2];
    aCamera->GetWindowCenter(windowCenter);
    if (windowCenter[0] != 0 || windowCenter[1] != 0) {
        if (!stereo) [camera addObject:@0];
        [camera addObject:@(windowCenter[0])];
        [camera addObject:@(windowCenter[1])];
    }
    double near = 0, far = -1;
    if (clipRangeActivated) { near = 0; far = clippingRangeThickness / factor; }
    // VTK starts every ray on the near plane and samples it every
    // SampleDistance; a projection takes both from the mapper, in millimetres,
    // so its samples fall where VTK's do. With a clipping range the near
    // plane is the camera's own, [0, thickness].
    if (renderingMode != 0) {
        double range[2];
        aCamera->GetClippingRange(range);
        near = range[0] / factor; far = range[1] / factor;
    }
    return @{@"camera": camera, @"near": @(near), @"far": @(far)};
}

/// VTK samples every unit of its scaled frame (pixelSpacingX / superSampling
/// millimetres) in composite rendering; compositing with a coarser step locks
/// a boundary sample's colour into the pixel, so the renderer walks the same
/// distance. A fused series is sampled in the same frame.
static double HorosCompositeSampleStep(double sx, double sy, double dz, double superSampling) {
    return superSampling > 0 ? MIN(sx, MIN(sy, dz)) / superSampling : MIN(sx, MIN(sy, dz));
}

/// A volume property's shading and the renderer's lights, as VTK's ray caster
/// lights a sample with them (vtkEncodedGradientShader): each light
/// switched on adds its intensity times its ambient colour to the ambient term
/// and its intensity to the diffuse and specular ones. The headlight VTK
/// creates, the host's only light, has a black ambient colour, so the
/// material's ambient adds nothing; with no light yet, that headlight is the
/// one the next render makes.
static NSArray *HorosShading(vtkRenderer *renderer, vtkVolumeProperty *property) {
    double ambient = 0, intensity = 0;
    bool lit = false;
    vtkCollectionSimpleIterator it;
    vtkLight *light = nullptr;
    if (renderer)
        for (renderer->GetLights()->InitTraversal(it); (light = renderer->GetLights()->GetNextLight(it)); ) {
            if (!light->GetSwitch()) continue;
            double colour[3];
            light->GetAmbientColor(colour);
            ambient += light->GetIntensity() * (colour[0] + colour[1] + colour[2]) / 3;
            intensity += light->GetIntensity();
            lit = true;
        }
    if (!lit) { ambient = 0; intensity = 1; }
    return @[@(property->GetShade() ? 1 : 0), @(property->GetAmbient()), @(property->GetDiffuse()), @(property->GetSpecular()),
             @(property->GetSpecularPower()), @(ambient), @(intensity)];
}

/// The crop reaches VTK as clipping planes on the mapper - the box widget's
/// or a saved camera's, possibly rotated - and the renderer clips each ray
/// against the same planes, in voxel index space, as VTK's ray caster clips
/// it. Planes that do not cut into the voxel centres, such as the six
/// restoreCamera installs around an uncropped volume, change nothing. The
/// crop callback gives a fused series' mapper the same planes.
static NSArray *HorosCuttingPlanes(vtkHorosFixedPointVolumeRayCastMapper *mapper, long width, long height, NSUInteger depth,
                                   NSString **error) {
    NSMutableArray *clippingPlanes = [NSMutableArray array];
    const float *voxelPlanes = NULL;
    int planeCount = mapper ? mapper->GetVoxelClippingPlanes(&voxelPlanes) : 0;
    std::vector<float> planes(voxelPlanes, voxelPlanes + 4 * planeCount);
    // VTK's cropping regions. The host never turns them on; a
    // subvolume, the one set of regions that is a single box, keeps the
    // samples inside six axis-aligned planes, given in the data's coordinates.
    // Any other set of regions is not one convex volume.
    if (mapper && mapper->GetCropping()) {
        vtkImageData *input = vtkImageData::SafeDownCast(mapper->GetInput());
        if (mapper->GetCroppingRegionFlags() != VTK_CROP_SUBVOLUME) {
            *error = @"VTK cropping regions other than a subvolume use the original renderer.";
            return nil;
        }
        if (!input) { *error = @"The 3D view has no volume yet."; return nil; }
        double origin[3], spacing[3], *bounds = mapper->GetCroppingRegionPlanes();
        input->GetOrigin(origin);
        input->GetSpacing(spacing);
        for (int axis = 0; axis < 3; ++axis) {
            if (spacing[axis] <= 0) { *error = @"The volume spacing is not usable."; return nil; }
            double low = (bounds[2 * axis] - origin[axis]) / spacing[axis], high = (bounds[2 * axis + 1] - origin[axis]) / spacing[axis];
            float lower[4] = {0, 0, 0, (float)-low}, upper[4] = {0, 0, 0, (float)high};
            lower[axis] = 1; upper[axis] = -1;
            planes.insert(planes.end(), lower, lower + 4);
            planes.insert(planes.end(), upper, upper + 4);
        }
    }
    double lastVoxel[3] = {width - 1.0, height - 1.0, depth - 1.0};
    for (size_t i = 0; i + 4 <= planes.size(); i += 4) {
        const float *plane = planes.data() + i;
        BOOL cuts = NO;
        for (int corner = 0; corner < 8 && !cuts; ++corner) {
            double distance = plane[3];
            for (int axis = 0; axis < 3; ++axis) distance += plane[axis] * (((corner >> axis) & 1) ? lastVoxel[axis] : 0);
            cuts = distance < -1e-4;
        }
        if (cuts) for (int k = 0; k < 4; ++k) [clippingPlanes addObject:@(plane[k])];
    }
    return clippingPlanes;
}

- (NSDictionary *)horosVolumeSnapshot {
    NSAssert([NSThread isMainThread], @"Volume snapshots require the main thread");
    if (aCamera == nil || volumeProperty == nil || firstObject == nil || factor <= 0) return @{@"error": @"The 3D view has no volume yet."};
    NSArray *pix = [controller horosVolumePixList];
    NSData *volume = [controller horosVolumeData];
    if (pix.count == 0 || volume == nil) return @{@"error": @"The 3D view has no volume yet."};
    DCMPix *first = pix.firstObject;
    double dz = first.sliceInterval != 0 ? fabs(first.sliceInterval) : fabs(first.sliceThickness);
    double sx = first.pixelSpacingX > 0 ? first.pixelSpacingX : 1, sy = first.pixelSpacingY > 0 ? first.pixelSpacingY : 1;
    if (dz <= 0 || !isfinite(dz)) return @{@"error": @"The volume spacing is not usable."};

    NSDictionary *view = [self horosVolumeCameraSnapshot];
    BOOL projection = renderingMode != 0;

    unsigned char rgba[1024];
    for (int i = 0; i < 256; ++i) {
        rgba[4 * i] = (unsigned char)fmin(255, fmax(0, table[i][0] * 255 + 0.5));
        rgba[4 * i + 1] = (unsigned char)fmin(255, fmax(0, table[i][1] * 255 + 0.5));
        rgba[4 * i + 2] = (unsigned char)fmin(255, fmax(0, table[i][2] * 255 + 0.5));
        rgba[4 * i + 3] = 255;
    }
    // The host divides its opacity curve by superSampling and VTK applies it
    // per unit of the scaled frame (pixelSpacingX / superSampling millimetres);
    // the renderer wants opacity per millimetre, so each point is converted:
    // α_mm = 1 − (1 − y / ss)^(ss / sx).
    // Two readings of that curve are possible: `unit` takes VTK at its word
    // (opacity per scaled unit, corrected to millimetres by the exponent
    // superSampling / spacing), `sample` takes the value as VTK's fixed-point
    // mapper uses it in practice, once per millimetre of ray. The preference
    // HorosVolumeMetalOpacityModel switches it without a rebuild.
    NSMutableArray *opacity = [NSMutableArray array];
    double samplesPerMillimetre = HorosSamplesPerMillimetre(superSampling, sx);
    // A projection paints with the curve itself: outside composite blending
    // VTK neither divides it by superSampling nor corrects it for the step.
    NSMutableArray *projectionOpacity = [NSMutableArray array];
    for (NSString *point in currentOpacityArray) {
        NSPoint pt = NSPointFromString(point);
        double y = renderingMode == 0 && superSampling > 0 ? pt.y / superSampling : pt.y;
        double perMillimetre = 1 - pow(1 - MIN(1, MAX(0, y)), samplesPerMillimetre);
        [opacity addObject:@(pt.x - 1000)];
        [opacity addObject:@(perMillimetre)];
        [projectionOpacity addObject:@(pt.x - 1000)];
        [projectionOpacity addObject:@(pt.y)];
    }
    // The 16-bit CLUT: colour and opacity functions over the whole
    // value range, not over the window, which VTK evaluates into its own
    // tables. The renderer takes 4096 entries of the same functions over the
    // volume's range; the opacity, which the host has already divided by
    // superSampling in volume rendering, goes to millimetres as the curve does.
    double level = wl, windowWidth = ww > 0 ? ww : 1;
    NSData *clut = [NSData dataWithBytes:rgba length:sizeof(rgba)], *opacityTable = nil, *projectionOpacityTable = nil;
    if (advancedCLUT) {
        const int entries = 4096;
        double lowest = [controller minimumValue], highest = [controller maximumValue];
        if (!(highest > lowest) || !colorTransferFunction || !opacityTransferFunction)
            return @{@"error": @"The 16-bit CLUT has no value range."};
        std::vector<double> colours(3 * entries), alphas(entries);
        double from = (OFFSET16 + lowest) * valueFactor, to = (OFFSET16 + highest) * valueFactor;
        colorTransferFunction->GetTable(from, to, entries, colours.data());
        opacityTransferFunction->GetTable(from, to, entries, alphas.data());
        NSMutableData *table = [NSMutableData dataWithLength:4 * entries];
        NSMutableData *perMillimetre = [NSMutableData dataWithLength:entries * sizeof(float)];
        NSMutableData *raw = [NSMutableData dataWithLength:entries * sizeof(float)];
        unsigned char *bytes = (unsigned char *)table.mutableBytes;
        float *composite = (float *)perMillimetre.mutableBytes, *painted = (float *)raw.mutableBytes;
        for (int i = 0; i < entries; ++i) {
            for (int channel = 0; channel < 3; ++channel)
                bytes[4 * i + channel] = (unsigned char)fmin(255, fmax(0, colours[3 * i + channel] * 255 + 0.5));
            bytes[4 * i + 3] = 255;
            double alpha = MIN(1, MAX(0, alphas[i]));
            composite[i] = (float)(1 - pow(1 - alpha, samplesPerMillimetre));
            painted[i] = (float)alpha;
        }
        clut = table; opacityTable = perMillimetre; projectionOpacityTable = raw;
        level = (lowest + highest) / 2; windowWidth = highest - lowest;
        [opacity removeAllObjects]; [projectionOpacity removeAllObjects];
    }
    // An RGB volume: VTK holds the ARGB bytes as independent
    // components, alpha weighted 0, and red, green and blue each with its
    // colour function - its own ramp, or the CLUT over the window for all three
    // - and one opacity function, both over the byte's 0...255. The renderer
    // takes the three colour tables one after the other and the opacity table
    // at those 256 values; the window maps a byte to its own entry.
    if (isRGB) {
        NSString *tableError = HorosColourTables(volumeProperty, samplesPerMillimetre, &clut, &opacityTable, &projectionOpacityTable);
        if (tableError) return @{@"error": tableError};
        level = 127.5; windowWidth = 255;
        [opacity removeAllObjects]; [projectionOpacity removeAllObjects];
    }
    // VTK places the volume in the patient frame: user matrix of the DICOM
    // cosines and a position that resolves to the first slice's origin.
    NSArray *columns = [self mprVoxelToWorldTransform];
    if (columns.count != 16) return @{@"error": @"The volume transform is unavailable."};
    NSMutableArray *transform = [NSMutableArray arrayWithCapacity:16];
    for (int row = 0; row < 4; ++row)
        for (int column = 0; column < 4; ++column)
            [transform addObject:columns[column * 4 + row]];
    NSString *planeError = nil;
    NSArray *clippingPlanes = HorosCuttingPlanes(volumeMapper, first.pwidth, first.pheight, pix.count, &planeError);
    if (planeError) return @{@"error": planeError};
    if (clippingPlanes.count > 4 * (NSUInteger)[HorosVolumeRenderer maximumClippingPlanes])
        return @{@"error": @"More than 32 crop planes use the original renderer."};
    NSArray *shading = HorosShading(aRenderer, volumeProperty);
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithDictionary:@{
             @"camera": view[@"camera"], @"near": view[@"near"], @"far": view[@"far"], @"level": @(level), @"width": @(windowWidth),
             @"clut": clut, @"opacity": opacity, @"mode": @(renderingMode),
             @"shading": shading, @"clippingPlanes": clippingPlanes, @"movieIndex": @([controller curMovieIndex]),
             @"volume": volume, @"volumeWidth": @(first.pwidth), @"volumeHeight": @(first.pheight), @"volumeDepth": @(pix.count),
             @"spacing": @[@(sx), @(sy), @(dz)], @"transform": transform, @"superSampling": @(superSampling),
             @"sampleStep": @(projection && volumeMapper ? volumeMapper->GetSampleDistance() / factor :
                 HorosCompositeSampleStep(sx, sy, dz, superSampling)),
             @"anchoredProjection": @(projection), @"projectionOpacity": projectionOpacity,
             @"scalarBackground": @(isRGB ? -1 : [controller minimumValue])}];
    if (isRGB) {
        snapshot[@"colourVolume"] = @YES;
        snapshot[@"componentTables"] = [self horosColourTablesFused:NO refresh:NO][@"tables"] ?: @[];
    }
    if (opacityTable) {
        snapshot[@"opacityTable"] = opacityTable;
        snapshot[@"projectionOpacityTable"] = projectionOpacityTable;
    }
    return snapshot;
}

- (NSDictionary *)horosFusedVolumeSnapshot {
    NSAssert([NSThread isMainThread], @"Volume snapshots require the main thread");
    if (!blendingVolume || !blendingVolumeMapper || !blendingVolumeProperty) return @{@"error": @"The fused series has no volume yet."};
    if (aCamera == nil || firstObject == nil || factor <= 0) return @{@"error": @"The 3D view has no volume yet."};
    // The fused voxels, their size and their placement are the MPR's.
    NSDictionary *fused = [self horosMPRFusedVolume];
    if (fused[@"error"]) return fused;
    NSArray *pix = [controller horosVolumePixList];
    DCMPix *first = pix.firstObject ?: firstObject;
    double dz = first.sliceInterval != 0 ? fabs(first.sliceInterval) : fabs(first.sliceThickness);
    double sx = first.pixelSpacingX > 0 ? first.pixelSpacingX : 1, sy = first.pixelSpacingY > 0 ? first.pixelSpacingY : 1;
    if (dz <= 0 || !isfinite(dz)) return @{@"error": @"The volume spacing is not usable."};
    NSDictionary *view = [self horosVolumeCameraSnapshot];
    BOOL projection = renderingMode != 0;

    // setBlendingCLUT: and setBlendingWLWW:: build the fused colour function
    // from blendingtable over the fused window, as the image's is built.
    unsigned char rgba[1024];
    for (int i = 0; i < 256; ++i) {
        rgba[4 * i] = (unsigned char)fmin(255, fmax(0, blendingtable[i][0] * 255 + 0.5));
        rgba[4 * i + 1] = (unsigned char)fmin(255, fmax(0, blendingtable[i][1] * 255 + 0.5));
        rgba[4 * i + 2] = (unsigned char)fmin(255, fmax(0, blendingtable[i][2] * 255 + 0.5));
        rgba[4 * i + 3] = 255;
    }
    // The fused table is not divided by superSampling: VTK applies it per
    // sample as it is.
    NSMutableArray *opacity = [NSMutableArray array], *projectionOpacity = [NSMutableArray array];
    HorosFusedOpacityPoints(alpha, HorosSamplesPerMillimetre(superSampling, sx), opacity, projectionOpacity);
    // An RGB fused series: its components' tables, as the image's.
    NSData *clut = [NSData dataWithBytes:rgba length:sizeof(rgba)], *opacityTable = nil, *projectionOpacityTable = nil;
    double level = blendingWl, windowWidth = blendingWw > 0 ? blendingWw : 1;
    if (isBlendingRGB) {
        NSString *tableError = HorosColourTables(blendingVolumeProperty, HorosSamplesPerMillimetre(superSampling, sx),
                                                 &clut, &opacityTable, &projectionOpacityTable);
        if (tableError) return @{@"error": tableError};
        level = 127.5; windowWidth = 255;
        [opacity removeAllObjects]; [projectionOpacity removeAllObjects];
    }
    // The renderer takes the transform row by row; the MPR's is column by column.
    NSArray *columns = fused[@"transform"];
    NSMutableArray *transform = [NSMutableArray arrayWithCapacity:16];
    for (int row = 0; row < 4; ++row)
        for (int column = 0; column < 4; ++column)
            [transform addObject:columns[column * 4 + row]];
    long width = [fused[@"width"] longValue], height = [fused[@"height"] longValue];
    NSUInteger depth = [fused[@"depth"] unsignedIntegerValue];
    NSString *planeError = nil;
    NSArray *clippingPlanes = HorosCuttingPlanes(blendingVolumeMapper, width, height, depth, &planeError);
    if (planeError) return @{@"error": planeError};
    if (clippingPlanes.count > 4 * (NSUInteger)[HorosVolumeRenderer maximumClippingPlanes])
        return @{@"error": @"More than 32 crop planes use the original renderer."};
    // The fused property is shaded only if something turns it on; nothing in
    // the host does.
    NSArray *shading = HorosShading(aRenderer, blendingVolumeProperty);
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithDictionary:@{@"camera": view[@"camera"], @"near": view[@"near"], @"far": view[@"far"],
             @"level": @(level), @"width": @(windowWidth),
             @"clut": clut, @"opacity": opacity, @"mode": @(renderingMode),
             @"shading": shading, @"clippingPlanes": clippingPlanes,
             @"volume": fused[@"volume"], @"volumeWidth": @(width), @"volumeHeight": @(height), @"volumeDepth": @(depth),
             @"transform": transform, @"superSampling": @(superSampling),
             // The fused mapper samples in the same world frame and at the same
             // SampleDistance as the image's.
             @"sampleStep": @(projection ? blendingVolumeMapper->GetSampleDistance() / factor :
                 HorosCompositeSampleStep(sx, sy, dz, superSampling)),
             @"anchoredProjection": @(projection), @"projectionOpacity": projectionOpacity,
             // A ray that misses the fused volume leaves 0 in VTK's 16-bit image.
             @"scalarBackground": isBlendingRGB ? @(-1) : fused[@"background"]}];
    if (isBlendingRGB) {
        snapshot[@"colourVolume"] = @YES;
        snapshot[@"opacityTable"] = opacityTable;
        snapshot[@"projectionOpacityTable"] = projectionOpacityTable;
        snapshot[@"componentTables"] = [self horosColourTablesFused:YES refresh:NO][@"tables"] ?: @[];
    }
    return snapshot;
}

@end

@implementation VRController (HorosVolumeHost)

- (NSData *)horosVolumeData { return volumeData[curMovieIndex]; }
- (NSArray *)horosVolumePixList { return pixList[curMovieIndex]; }

- (NSDictionary *)horosVolumeSnapshot { return [[self view] horosVolumeSnapshot]; }

- (NSData *)horosVolumeMetalRenderWithWidth:(NSInteger)width height:(NSInteger)height
                                   scalarOut:(NSMutableData *)scalarOut error:(NSError **)error {
    return [self horosVolumeMetalRenderWithCamera:nil near:0 far:-1 width:width height:height scalarOut:scalarOut error:error];
}

- (NSData *)horosVolumeMetalRenderWithCamera:(NSArray<NSNumber *> *)camera near:(double)near far:(double)far
                                        width:(NSInteger)width height:(NSInteger)height
                                    scalarOut:(NSMutableData *)scalarOut error:(NSError **)error {
    return [self horosVolumeMetalRenderWithCamera:camera near:near far:far width:width height:height
                                     imageRegion:@[] scalarOut:scalarOut error:error];
}

- (NSData *)horosVolumeMetalRenderWithCamera:(NSArray *)camera near:(double)near far:(double)far
                                     width:(NSInteger)width height:(NSInteger)height imageRegion:(NSArray *)imageRegion
                                 scalarOut:(NSMutableData *)scalarOut error:(NSError **)error {
    return [self horosVolumeMetalRenderWithCamera:camera near:near far:far width:width height:height
                                     imageRegion:imageRegion geometryDepth:nil scalarOut:scalarOut error:error];
}

- (NSData *)horosVolumeMetalRenderWithCamera:(NSArray *)camera near:(double)near far:(double)far
                                     width:(NSInteger)width height:(NSInteger)height imageRegion:(NSArray *)imageRegion
                             geometryDepth:(NSData *)geometryDepth
                                 scalarOut:(NSMutableData *)scalarOut error:(NSError **)error {
    NSAssert([NSThread isMainThread], @"Volume rendering requires the main thread");
    double snapshotFrom = [HorosMetalPerformanceTrace now];
    NSDictionary *snapshot = [self horosVolumeSnapshot];
    [HorosMetalPerformanceTrace recordHostOperation:@"vr.host_snapshot" startedAt:snapshotFrom];
    if (camera.count == 12 && !snapshot[@"error"]) {
        NSMutableDictionary *overridden = [NSMutableDictionary dictionaryWithDictionary:snapshot];
        overridden[@"camera"] = camera; overridden[@"near"] = @(near); overridden[@"far"] = @(far);
        snapshot = overridden;
    }
    return [self horosVolumeMetalRender:snapshot fused:NO width:width height:height imageRegion:imageRegion
                        geometryDepth:geometryDepth scalarOut:scalarOut error:error];
}

- (NSData *)horosFusedVolumeMetalRenderSnapshot:(NSDictionary *)snapshot width:(NSInteger)width height:(NSInteger)height
                                    imageRegion:(NSArray *)imageRegion geometryDepth:(NSData *)geometryDepth
                                      scalarOut:(NSMutableData *)scalarOut error:(NSError **)error {
    NSAssert([NSThread isMainThread], @"Volume rendering requires the main thread");
    return [self horosVolumeMetalRender:snapshot fused:YES width:width height:height imageRegion:imageRegion
                        geometryDepth:geometryDepth scalarOut:scalarOut error:error];
}

/// Renders one volume's snapshot with its own renderer: the image's, or the
/// fused series', each holding its own volume on the GPU.
- (NSData *)horosVolumeMetalRender:(NSDictionary *)snapshot fused:(BOOL)fused width:(NSInteger)width height:(NSInteger)height
                       imageRegion:(NSArray *)imageRegion geometryDepth:(NSData *)geometryDepth
                         scalarOut:(NSMutableData *)scalarOut error:(NSError **)error {
    const void *rendererSlot = fused ? &fusedRendererKey : &rendererKey, *uploadedSlot = fused ? &fusedUploadedKey : &uploadedKey;
    NSString *reason = snapshot[@"error"];
    HorosVolumeRenderer *renderer = objc_getAssociatedObject(self, rendererSlot);
    if (!reason && !renderer) {
        NSError *failure = nil;
        renderer = [HorosVolumeRenderer makeAndReturnError:&failure];
        if (renderer) {
            objc_setAssociatedObject(self, rendererSlot, renderer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else reason = failure.localizedDescription ?: @"Metal is unavailable.";
    }
    if (!reason) {
        NSData *volume = snapshot[@"volume"];
        NSInteger w = [snapshot[@"volumeWidth"] integerValue], h = [snapshot[@"volumeHeight"] integerValue], d = [snapshot[@"volumeDepth"] integerValue];
        NSUInteger expected = [HorosVolumeAllocation byteCountForWidth:w height:h slices:d bytesPerVoxel:4];
        if (expected == 0 || volume.length < expected) reason = @"The volume bytes do not match the slice list.";
        else if (objc_getAssociatedObject(self, uploadedSlot) != volume || !renderer.isReady) {
            NSData *slices = volume.length == expected ? volume : [NSData dataWithBytesNoCopy:(void *)volume.bytes length:expected freeWhenDone:NO];
            NSError *failure = nil;
            BOOL uploaded = [snapshot[@"colourVolume"] boolValue]
                ? [renderer uploadColourVolume:slices width:w height:h depth:d transform:snapshot[@"transform"] error:&failure]
                : [renderer uploadVolume:slices width:w height:h depth:d transform:snapshot[@"transform"] error:&failure];
            if (uploaded) {
                objc_setAssociatedObject(self, uploadedSlot, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                objc_setAssociatedObject(self, uploadedSlot, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                reason = failure.localizedDescription ?: @"The volume could not be uploaded.";
            }
        }
    }
    NSData *bytes = nil;
    if (!reason) {
        NSError *failure = nil;
        bytes = [renderer renderWithCamera:snapshot[@"camera"] near:[snapshot[@"near"] doubleValue] far:[snapshot[@"far"] doubleValue]
                                     level:[snapshot[@"level"] doubleValue] width:[snapshot[@"width"] doubleValue] clut:snapshot[@"clut"]
                             opacityPoints:snapshot[@"opacity"] opacityTable:snapshot[@"opacityTable"]
                                      mode:[snapshot[@"mode"] integerValue] shading:snapshot[@"shading"]
                                      crop:@[] clippingPlanes:snapshot[@"clippingPlanes"] width:width height:height
                                sampleStep:[snapshot[@"sampleStep"] doubleValue]
                          scalarBackground:[snapshot[@"scalarBackground"] doubleValue]
                        anchoredProjection:[snapshot[@"anchoredProjection"] boolValue] imageRegion:imageRegion
                             geometryDepth:geometryDepth scalarOut:scalarOut error:&failure];
        // An RGB volume's projection comes back as three values a pixel; its
        // bytes are painted here with VTK's tables, for every caller.
        NSInteger pixels = width * height;
        if (bytes && [snapshot[@"colourVolume"] boolValue] && [snapshot[@"mode"] integerValue] != 0 &&
            scalarOut.length == (NSUInteger)pixels * 3 * sizeof(float)) {
            NSData *picture = [HorosMPRColourPlane pictureWithComponents:scalarOut count:pixels tables:snapshot[@"componentTables"]];
            NSMutableData *bgra = picture ? [NSMutableData dataWithLength:(NSUInteger)pixels * 4] : nil;
            const unsigned short *rgba = (const unsigned short *)picture.bytes;
            unsigned char *out = (unsigned char *)bgra.mutableBytes;
            for (NSInteger i = 0; bgra && i < pixels; ++i) {
                out[4 * i] = rgba[4 * i + 2] >> 7; out[4 * i + 1] = rgba[4 * i + 1] >> 7;
                out[4 * i + 2] = rgba[4 * i] >> 7; out[4 * i + 3] = 255;
            }
            bytes = bgra;
            if (!bytes) reason = @"The colour projection could not be painted.";
        }
        if (bytes) objc_setAssociatedObject(self, fused ? &fusedMillisecondsKey : &millisecondsKey, @(renderer.lastMilliseconds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        else reason = failure.localizedDescription ?: @"The render produced no image.";
    }
    objc_setAssociatedObject(self, fused ? &fusedReasonKey : &reasonKey, reason, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!bytes && error) *error = [NSError errorWithDomain:@"HorosVolumeMetal" code:1 userInfo:@{NSLocalizedDescriptionKey: reason ?: @""}];
    return bytes;
}

- (NSString *)horosVolumeMetalFallbackReason { return objc_getAssociatedObject(self, &reasonKey); }

- (NSString *)horosFusedVolumeMetalFallbackReason { return objc_getAssociatedObject(self, &fusedReasonKey); }

- (double)horosVolumeMetalLastMilliseconds {
    NSNumber *value = objc_getAssociatedObject(self, &millisecondsKey);
    return value ? value.doubleValue : -1;
}

- (double)horosFusedVolumeMetalLastMilliseconds {
    NSNumber *value = objc_getAssociatedObject(self, &fusedMillisecondsKey);
    return value ? value.doubleValue : -1;
}

- (NSInteger)horosVolumeMetalBytes {
    HorosVolumeRenderer *renderer = objc_getAssociatedObject(self, &rendererKey);
    HorosVolumeRenderer *fused = objc_getAssociatedObject(self, &fusedRendererKey);
    return renderer.volumeBytes + fused.volumeBytes;
}

- (void)horosVolumeMetalRelease {
    HorosVolumeRenderer *renderer = objc_getAssociatedObject(self, &rendererKey);
    [renderer releaseVolume];
    objc_setAssociatedObject(self, &uploadedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &millisecondsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self horosFusedVolumeMetalRelease];
}

/// Drops the fused series' renderer and its volume; a later fusion makes a
/// new one.
- (void)horosFusedVolumeMetalRelease {
    HorosVolumeRenderer *renderer = objc_getAssociatedObject(self, &fusedRendererKey);
    if (!renderer) return;
    [renderer releaseVolume];
    objc_setAssociatedObject(self, &fusedRendererKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &fusedUploadedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &fusedMillisecondsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &fusedReasonKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

/// Sent by -[VRController windowWillClose:]. The renderers are not dropped
/// from an observer of the window's NSWindowWillCloseNotification: the
/// controller is the window's delegate, and removing its registration for that
/// notification also removed the one AppKit made for -windowWillClose:, which
/// then never ran and never released the controller and its volume.
- (void)horosVolumeMetalDropRenderers {
    [self horosVolumeMetalRelease];
    objc_setAssociatedObject(self, &rendererKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &fusedRendererKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
