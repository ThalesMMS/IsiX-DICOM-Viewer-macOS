#import "ViewerVolumeSession.h"
#import "PlanarHostBridge.h"
#import "Horos-Swift.h"
#import "DicomImage.h"
#import "DicomSeries.h"
#import "DCMPix.h"
#import <objc/runtime.h>

static char planarRendererKey, planarFallbackKey, engineNoticeKey, performanceTraceKey, slabKeyKey, slabDataKey,
    compositeKeyKey, compositeTablesKey, compositeDataKey;

@interface DCMPix (HorosPlanarPresentation)
- (BOOL)horosPlanarHasPresentationFilter;
- (BOOL)horosPlanarUsesFixedWindow;
- (ThickSlabController *)horosPlanarThickSlab;
@end
@implementation DCMPix (HorosPlanarPresentation)
- (BOOL)horosPlanarHasPresentationFilter { return convolution; }
- (BOOL)horosPlanarUsesFixedWindow { return fixed8bitsWLWW; }
- (ThickSlabController *)horosPlanarThickSlab { return thickSlab; }
@end

@implementation ViewerController (HorosPlanarHost)
- (BOOL)horosPlanarMetalEnabled { return YES; }
@end

/// The volume session of the view's viewer, when it has one: the 2D viewer's.
/// The MPR, orthogonal, endoscopy and preview views draw without one.
static HorosVolumeSession *HorosPlanarSession(DCMView *view) {
    id controller = [view windowController];
    return [controller respondsToSelector:@selector(horosVolumeSession)] ? [(ViewerController *)controller horosVolumeSession] : nil;
}

@implementation DCMView (HorosPlanarHost)
- (HorosPlanarPerformanceTrace *)horosPlanarPerformanceTrace {
    if (!HorosPlanarPerformanceTrace.enabled) return nil;
    HorosPlanarPerformanceTrace *trace = objc_getAssociatedObject(self, &performanceTraceKey);
    if (!trace) {
        trace = [[[HorosPlanarPerformanceTrace alloc] init] autorelease];
        objc_setAssociatedObject(self, &performanceTraceKey, trace, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return trace;
}
- (double)horosPlanarLastCommandMilliseconds {
    HorosPlanarHostRenderer *renderer = objc_getAssociatedObject(self, &planarRendererKey);
    return renderer.encodedGPUCommand && renderer.gpuMilliseconds > 0 ? renderer.gpuMilliseconds : -1;
}
- (void)horosInvalidatePlanar {
    [objc_getAssociatedObject(self, &planarRendererKey) invalidate];
    objc_setAssociatedObject(self, &planarRendererKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &planarFallbackKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSString *)horosPlanarFallbackReason {
    return objc_getAssociatedObject(self, &planarFallbackKey) ?: objc_getAssociatedObject(self, &engineNoticeKey);
}
- (NSString *)horosEngineNotice { return objc_getAssociatedObject(self, &engineNoticeKey); }
- (NSString *)horosPlanarBackendName {
    HorosPlanarHostRenderer *renderer = objc_getAssociatedObject(self, &planarRendererKey);
    return renderer.backendName ?: @"";
}
- (double)horosPlanarGPUMilliseconds {
    HorosPlanarHostRenderer *renderer = objc_getAssociatedObject(self, &planarRendererKey);
    return renderer ? renderer.gpuMilliseconds : 0;
}
- (void)horosSetPlanarFallbackReason:(NSString *)reason {
    // The MPR engine's notice: its plane came from the original renderer. It
    // stays until the MPR clears it, whatever the picture's own draw does.
    objc_setAssociatedObject(self, &engineNoticeKey, reason, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (HorosPlanarHostRenderer *)horosPlanarRenderer {
    HorosPlanarHostRenderer *renderer = objc_getAssociatedObject(self, &planarRendererKey);
    if (!renderer) {
        renderer = [[[HorosPlanarHostRenderer alloc] init] autorelease];
        objc_setAssociatedObject(self, &planarRendererKey, renderer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return renderer;
}
/// A snapshot that can be drawn, or nil with the reason recorded.
- (NSDictionary *)horosDrawableSnapshot:(NSDictionary *)snapshot {
    if (snapshot[@"error"]) {
        [self horosInvalidatePlanar];
        objc_setAssociatedObject(self, &planarFallbackKey, NSLocalizedString(@"This image cannot be displayed.", nil), OBJC_ASSOCIATION_COPY_NONATOMIC);
        return nil;
    }
    return snapshot;
}
- (BOOL)horosDrawPlanarInLayer:(CAMetalLayer *)layer inverted:(BOOL)inverted {
    NSAssert([NSThread isMainThread], @"Planar rendering requires the main thread");
    NSDictionary *snapshot = [self horosDrawableSnapshot:[self horosPlanarSnapshot]];
    if (!snapshot) return NO;
    BOOL drawn = [[self horosPlanarRenderer] drawSnapshot:snapshot session:HorosPlanarSession(self) layer:layer inverted:inverted];
    objc_setAssociatedObject(self, &planarFallbackKey, drawn ? nil :
        NSLocalizedString(@"This image cannot be displayed.", nil), OBJC_ASSOCIATION_COPY_NONATOMIC);
    return drawn;
}
- (void)horosClearLayer:(CAMetalLayer *)layer white:(BOOL)white inverted:(BOOL)inverted {
    [[self horosPlanarRenderer] clearLayer:layer white:white inverted:inverted];
}
- (NSData *)horosPlanarPixelsWidth:(NSInteger)width height:(NSInteger)height inverted:(BOOL)inverted {
    NSAssert([NSThread isMainThread], @"Planar rendering requires the main thread");
    NSDictionary *snapshot = [self horosDrawableSnapshot:[self horosPlanarSnapshot]];
    return snapshot ? [[self horosPlanarRenderer] renderSnapshot:snapshot session:HorosPlanarSession(self)
                                                           width:width height:height inverted:inverted] : nil;
}
- (NSData *)horosPlanarPixelsSide:(NSInteger)side topLeft:(NSPoint)topLeft topRight:(NSPoint)topRight
    bottomLeft:(NSPoint)bottomLeft inverted:(BOOL)inverted {
    NSAssert([NSThread isMainThread], @"Planar rendering requires the main thread");
    NSDictionary *snapshot = [self horosPlanarSnapshot];
    if (snapshot[@"error"] || side <= 0) return nil;
    // The view's own mapping, onto a square: the image pixels its three
    // corners show, as horosPlanarSnapshotDrawnIn: works them out for the bounds.
    NSPoint a = [self horosPixelAt:topLeft drawnIn:self], b = [self horosPixelAt:topRight drawnIn:self],
        c = [self horosPixelAt:bottomLeft drawnIn:self];
    NSMutableDictionary *lens = [NSMutableDictionary dictionaryWithDictionary:snapshot];
    lens[@"screenToPixel"] = @[@(a.x), @(a.y), @(b.x), @(b.y), @(c.x), @(c.y)];
    lens[@"viewSize"] = @[@(side), @(side)];
    [lens removeObjectForKey:@"fusion"];
    NSDictionary *fusion = snapshot[@"fusion"];
    if (fusion) {
        NSPoint fa = [self.blendingView horosPixelAt:topLeft drawnIn:self], fb = [self.blendingView horosPixelAt:topRight drawnIn:self],
            fc = [self.blendingView horosPixelAt:bottomLeft drawnIn:self];
        NSMutableDictionary *layer = [NSMutableDictionary dictionaryWithDictionary:fusion];
        layer[@"screenToPixel"] = @[@(fa.x), @(fa.y), @(fb.x), @(fb.y), @(fc.x), @(fc.y)];
        layer[@"viewSize"] = @[@(side), @(side)];
        lens[@"fusion"] = layer;
    }
    // A renderer of its own: the view's keeps the frame it shows.
    HorosPlanarHostRenderer *renderer = [[[HorosPlanarHostRenderer alloc] init] autorelease];
    return [renderer renderSnapshot:lens session:nil width:side height:side inverted:inverted];
}
- (NSDictionary *)horosPlanarSnapshot {
    return [self horosPlanarSnapshotDrawnIn:self];
}

/// The pixel of this view's image under `point` of `host`'s bounds, as `host`
/// draws it. For the view's own image that is `ConvertFromNSView2GL:`. A series
/// fused over `host` is drawn by drawRectIn: with this view's origin, scale,
/// rotation, flips and pixel ratio in the frame it is handed, `host`'s drawing
/// frame (#658): the same conversion, `ConvertFromUpLeftView2GL:` statement for
/// statement, with that frame for this view's own.
- (NSPoint)horosPixelAt:(NSPoint)point drawnIn:(DCMView *)host {
    if (host == self) return [self ConvertFromNSView2GL:point];
    static double deg2rad = M_PI / 180.0;
    NSRect size = host.drawingFrameRect;
    NSPoint a = [host convertPointToBacking:point];
    a.y = size.size.height - a.y;
    if( xFlipped) a.x = size.size.width - a.x;
    if( yFlipped) a.y = size.size.height - a.y;
    a.x -= size.size.width/2;
    a.x /= scaleValue;
    a.y -= size.size.height/2;
    a.y /= scaleValue;
    float xx = a.x*cos(rotation*deg2rad) + a.y*sin(rotation*deg2rad);
    float yy = -a.x*sin(rotation*deg2rad) + a.y*cos(rotation*deg2rad);
    a.y = yy;
    a.x = xx;
    a.x -= (origin.x)/scaleValue;
    a.y += (origin.y)/scaleValue;
    if( self.curDCM)
    {
        a.x += self.curDCM.pwidth * 0.5f;
        a.y += self.curDCM.pheight * self.curDCM.pixelRatio * 0.5f;
        a.y /= self.curDCM.pixelRatio;
    }
    return a;
}

/// What this view's image contributes when `host` draws: its own image when
/// `host` is this view, or the series this view fuses over `host` (#658).
- (NSDictionary *)horosPlanarSnapshotDrawnIn:(DCMView *)host {
    NSAssert([NSThread isMainThread], @"Planar snapshots require the main thread");
    DCMView *view = self;
    DCMPix *pix = view.curDCM;
    BOOL fused = host != view;
    NSString *unsupported = NSLocalizedString(@"This image cannot be displayed.", nil);
    // A thick slab in mean, maximum or minimum is a reduction the Metal path
    // runs itself (#659); the volume-rendering slab (modes 4 and 5) is
    // ThickSlabVR's composite, which it runs too (#723). A colour slab is
    // reduced by computeThickSlabRGB inside the 8-bit representation, before
    // the window, so the host's bytes handed over below already carry it, as
    // the original renderer draws them (#723).
    // Channel factors and a colour image's enlargement are the host's own
    // tables and vImage calls, reproduced below (#660). A fused series is drawn
    // through the host's scalar CLUT program; a colour one as the host loads it
    // with blending on: its bytes through the fusion's alpha table and the
    // colour tables, blended source-alpha over the image (#723).
    // The 12-bit LUT mode draws a buffer that a display vendor's plugin packs
    // (LUT12baseAddr, four bytes a pixel), on only with the automatic12BitTotoku
    // preference and +[AppController canDisplay12Bit], which only that plugin
    // sets. loadTextureIn: takes it as colour bytes and lays no table over it,
    // enlarged or not; Metal draws those bytes as they are (#723). Fused, the
    // host blends them source-alpha with their fourth byte as the alpha, no
    // table over them either, and so does Metal.
    // What is refused is what the host cannot draw either: a stack mode
    // computeThickSlab does not have, and, below, pixels that are missing or
    // do not match the image.
    BOOL packed = pix.isLUT12Bit;
    if (!pix || pix.stackMode < 0 || pix.stackMode > 5)
        return @{@"error": unsupported};
    long width = pix.pwidth, height = pix.pheight;
    NSUInteger count = [HorosVolumeAllocation byteCountForWidth:width height:height slices:1 bytesPerVoxel:4];
    // An image larger than any texture is read from a buffer (#723). The copy
    // below is made on every draw, so it stays within 2 GiB; DICOM's rows and
    // columns stop at 65535.
    if (width <= 0 || height <= 0 || width > 65535 || height > 65535 || count > 2048UL*1024*1024)
        return @{@"error": unsupported};
    float *pixels = pix.fImage;
    if (!pixels) return @{@"error": unsupported};
    NSRect bounds = host.bounds;
    NSPoint topLeft = [view horosPixelAt:NSMakePoint(NSMinX(bounds), NSMaxY(bounds)) drawnIn:host];
    NSPoint topRight = [view horosPixelAt:NSMakePoint(NSMaxX(bounds), NSMaxY(bounds)) drawnIn:host];
    NSPoint bottomLeft = [view horosPixelAt:NSMakePoint(NSMinX(bounds), NSMinY(bounds)) drawnIn:host];
    unsigned char *r, *g, *b, *alpha = NULL, rgba[1024];
    if (fused) {
        // The fused series' colours: those the PET CLUT mode gives (the PET
        // blending CLUT under B/W Inverse, the series' own otherwise), and its
        // alpha table, which the fusion factor and mode set (#658).
        unsigned char *unused;
        [host blendingColorTables:&unused :&r :&g :&b];
        [view colorTables:&alpha :&unused :&unused :&unused];
    } else {
        [view getCLUT:&r :&g :&b];
    }
    // The table loadTextureIn: gives the scalar CLUT program: the colours times
    // this view's channel factors (#660), and the alpha table, opaque for the
    // view's own image.
    for (NSUInteger i = 0; i < 256; ++i) {
        rgba[4*i] = fminf(255, fmaxf(0, r[i] * redFactor));
        rgba[4*i+1] = fminf(255, fmaxf(0, g[i] * greenFactor));
        rgba[4*i+2] = fminf(255, fmaxf(0, b[i] * blueFactor));
        rgba[4*i+3] = alpha ? alpha[i] : 255;
    }
    DicomImage *image = view.curImage >= 0 && view.curImage < view.dcmFilesList.count ? view.dcmFilesList[view.curImage] : nil;
    NSString *identifier = [NSString stringWithFormat:@"%@/%@/%ld", image.sopInstanceUID ?: image.objectID.URIRepresentation.absoluteString,
        image.frameID ?: @0, (long)view.curImage];
    // Subtraction and the DICOM shutter (#662) are presentations of the host's
    // own bytes: the subtraction through vImage's half-precision gamma, the
    // window through vImage's conversion, the polarity, and the shutter's
    // rectangle, circle and polygon masked over them with the CLUT's black
    // index. So is every colour image (#660): the host windows its ARGB bytes
    // through its conversion table, opacity table and filter included, and
    // interpolates those. The original renderer draws those bytes; so does
    // Metal, with the same interpolation. The accessor brings the 8-bit
    // representation up to date first, as DCMView does before drawing.
    // An image as wide or tall as the largest texture (16384 on these GPUs)
    // turns the host's 32-bit pipeline off in loadTextureIn: - it tiles and
    // interpolates the 8-bit representation instead - so its bytes are what
    // Metal draws too (#723).
    BOOL hostEightBit = width >= 16384 || height >= 16384;
    NSData *hostBytes = nil;
    BOOL colourBytes = pix.isRGB || packed;
    // The volume-rendering slab: where computefImage hands the slices to
    // ThickSlabVR, whose composite then stands for the whole 8-bit
    // representation - compute8bitRepresentation returns before its window,
    // table, polarity and shutter - and loadTextureIn: draws it as colour
    // bytes, untabled (#723). The composite's colours are its own tables, set
    // from the viewer's CLUT when the mode is chosen and when the CLUT changes.
    // Metal composes it (HorosPlanarThickSlab), and the image keeps it until
    // its slices, window or tables change, as the host keeps its composite in
    // baseAddr: scrolling back through a series does not compose it again.
    NSArray *series = pix.pixArray;
    BOOL volumeSlab = !colourBytes && (pix.stackMode == 4 || pix.stackMode == 5) && pix.stack >= 1 && series.count > 1;
    if (volumeSlab) {
        NSData *tables = [pix horosPlanarThickSlab].compositeTables;
        NSArray *order = [HorosPlanarThickSlab volumeSliceIndicesWithPosition:pix.pixPos stack:pix.stack direction:pix.stackDirection
                                                                        count:series.count memoryOrder:[pix horosPlanarThickSlab].composesInMemoryOrder];
        if (!tables || !order.count) return @{@"error": unsupported};
        // setWLWW:: gets the image's own window, inverted by its sign.
        BOOL fixedWindow = [pix horosPlanarUsesFixedWindow];
        float level = fixedWindow ? 127 : pix.wl, windowWidth = (pix.displayInverted ? -1 : 1) * (fixedWindow ? 256 : pix.ww);
        HorosVolumeSession *session = [[view windowController] respondsToSelector:@selector(horosVolumeSession)] ?
            [(ViewerController *)[view windowController] horosVolumeSession] : nil;
        NSMutableString *key = [NSMutableString stringWithFormat:@"%ld/%ld/%ld/%ld/%a/%a", (long)session.sessionID,
            (long)session.identity.generation, width, height, level, windowWidth];
        for (NSNumber *index in order) {
            DCMPix *slice = series[index.integerValue];
            if (!slice.fImage || slice.pwidth != width || slice.pheight != height) return @{@"error": unsupported};
            [key appendFormat:@"/%p:%p", slice, slice.fImage];
        }
        if ([objc_getAssociatedObject(pix, &compositeKeyKey) isEqualToString:key] &&
            [objc_getAssociatedObject(pix, &compositeTablesKey) isEqualToData:tables])
            hostBytes = objc_getAssociatedObject(pix, &compositeDataKey);
        if (!hostBytes) {
            NSMutableData *slices = [NSMutableData dataWithCapacity:order.count * count];
            for (NSNumber *index in order) [slices appendBytes:[series[index.integerValue] fImage] length:count];
            hostBytes = [HorosPlanarThickSlab volumeCompositeWithSlices:slices count:order.count width:width height:height
                                                                  level:level windowWidth:windowWidth tables:tables];
            if (!hostBytes) return @{@"error": unsupported};
            objc_setAssociatedObject(pix, &compositeKeyKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(pix, &compositeTablesKey, tables, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(pix, &compositeDataKey, hostBytes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (colourBytes || pix.subtractedfImage || pix.shutterEnabled || hostEightBit) {
        char *bytes = packed ? (char *)pix.LUT12baseAddr : pix.baseAddr;
        if (!bytes) return @{@"error": unsupported};
        hostBytes = [NSData dataWithBytes:bytes length:(NSUInteger)width * height * (colourBytes ? 4 : 1)];
    }
    // The MPR's cubic display plane stands in for the samples where the host
    // drew its textures from computefImageForDisplay (#702): not under a stack
    // slab, which is its own reduction.
    NSData *samples = nil;
    NSData *displayPlane = pix.horosMPRDisplayPixels;
    if (!colourBytes && !volumeSlab && displayPlane.length == count && !(pix.stackMode >= 1 && pix.stack > 1))
        samples = displayPlane;
    // A colour frame is drawn from its bytes alone; they stand in for the
    // samples, the same size, rather than a second copy of them.
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithDictionary:@{@"width": @(width), @"height": @(height), @"isColor": @(colourBytes || volumeSlab),
        @"pixels": colourBytes || volumeSlab ? hostBytes : (samples ?: [NSData dataWithBytes:pixels length:count]), @"clut": [NSData dataWithBytes:rgba length:sizeof(rgba)],
        @"frameIdentity": identifier, @"level": @(noScale || [pix horosPlanarUsesFixedWindow] ? 127 : view.curWL),
        @"widthWindow": @((pix.displayInverted ? -1 : 1) * (noScale || [pix horosPlanarUsesFixedWindow] ? 256 : view.curWW)),
        @"background": @(view.whiteBackground ? 1 : 0),
        @"softwareScale": @([view softwareInterpolation] ? (width <= 256 ? 3 : 2) : 1),
        @"screenToPixel": @[@(topLeft.x), @(topLeft.y), @(topRight.x), @(topRight.y), @(bottomLeft.x), @(bottomLeft.y)],
        @"viewSize": @[@(NSWidth(bounds)), @(NSHeight(bounds))],
        @"nearest": @([[NSUserDefaults standardUserDefaults] boolForKey:@"NOINTERPOLATION"])}];
    if (hostBytes) {
        snapshot[@"hostBytes"] = hostBytes;
        // Bytes whose fourth byte is their own alpha, fused or not.
        if (packed || volumeSlab) snapshot[@"bytesCarryAlpha"] = @YES;
        if (pix.isRGB && !packed && (fused || colorTransfer || redFactor != 1.0 || greenFactor != 1.0 || blueFactor != 1.0)) {
            // loadTextureIn: tables a colour image's bytes before they are
            // interpolated: vImageTableLookUp_ARGB8888 with the opaque alpha
            // table and the CLUT, or the CLUT times the channel factors converted
            // to bytes as C converts them, unclamped. Alpha, red, green, blue.
            // A fused colour series is always tabled (blending:YES), with the
            // fusion's alpha table and the colours blendingColorTables gives:
            // the PET tables under B/W Inverse, the series' own otherwise.
            unsigned char table[1024];
            for (NSUInteger i = 0; i < 256; ++i) {
                table[i] = fused ? alpha[i] : opaqueTable[i];
                if (redFactor != 1.0 || greenFactor != 1.0 || blueFactor != 1.0) {
                    table[256 + i] = r[i] * redFactor;
                    table[512 + i] = g[i] * greenFactor;
                    table[768 + i] = b[i] * blueFactor;
                } else {
                    table[256 + i] = r[i]; table[512 + i] = g[i]; table[768 + i] = b[i];
                }
            }
            snapshot[@"colourTable"] = [NSData dataWithBytes:table length:sizeof(table)];
        }
    }
    if (!volumeSlab && [pix horosPlanarHasPresentationFilter]) {
        // The menu's convolution filter runs before the window, on these source
        // values, as the host runs it (#661): the kernel as the host holds it and
        // its normalisation. PlanarConvolution does the arithmetic.
        snapshot[@"convolutionSize"] = @(pix.kernelsize);
        snapshot[@"convolutionKernel"] = [NSData dataWithBytes:pix.kernel length:25 * sizeof(float)];
        snapshot[@"convolutionNormalization"] = @(pix.normalization);
    }
    if (!volumeSlab && pix.transferFunctionPtr) {
        // The opacity table and what the host reads with it (#657): the image's
        // own WL/WW, not the view's, which noScale has set to 127/256 before the
        // host computes, and the polarity it applies afterwards. PlanarFrame
        // reproduces the arithmetic; nothing is computed here.
        snapshot[@"transferFunction"] = pix.transferFunction;
        snapshot[@"transferLevel"] = @(noScale ? 127 : pix.wl);
        snapshot[@"transferWidth"] = @(noScale ? 256 : pix.ww);
        snapshot[@"transferInverted"] = @(pix.displayInverted);
    }
    NSData *slab = nil;
    NSString *slabKey = nil;
    // A colour slab is already in the host's bytes; only a scalar one is reduced here.
    if (!colourBytes && !hostEightBit && pix.stackMode >= 1 && pix.stackMode <= 3 && pix.stack > 1 && series.count > 1) {
        // The slices computeThickSlab reduces with this one, in its order; a
        // slice with no pixels is skipped there and here.
        NSMutableArray *slices = [NSMutableArray array];
        NSMutableString *key = [NSMutableString string];
        HorosVolumeSession *session = [[view windowController] respondsToSelector:@selector(horosVolumeSession)] ?
            [(ViewerController *)[view windowController] horosVolumeSession] : nil;
        [key appendFormat:@"%ld/%ld/%ld/%ld", (long)session.sessionID, (long)session.identity.generation, width, height];
        for (NSNumber *index in [HorosPlanarThickSlab sliceIndicesWithPosition:pix.pixPos stack:pix.stack
                                                                     direction:pix.stackDirection count:series.count]) {
            DCMPix *slice = series[index.integerValue];
            float *samples = slice.fImage;
            if (!samples) continue;
            if (slice.pwidth != width || slice.pheight != height) return @{@"error": unsupported};
            [slices addObject:slice];
            [key appendFormat:@"/%p:%p", slice, samples];
        }
        if (slices.count) {
            // Every redraw builds a snapshot; the other slices are copied only
            // when they, or the volume's generation, change. The same NSData on
            // every draw compares equal without reading it.
            slabKey = key;
            slab = [objc_getAssociatedObject(view, &slabKeyKey) isEqualToString:key] ? objc_getAssociatedObject(view, &slabDataKey) : nil;
            if (!slab) {
                NSMutableData *others = [NSMutableData dataWithCapacity:slices.count * count];
                for (DCMPix *slice in slices) [others appendBytes:slice.fImage length:count];
                slab = others;
            }
            snapshot[@"slabMode"] = @(pix.stackMode);
            snapshot[@"slabSlices"] = slab;
            snapshot[@"slabCount"] = @(slices.count + 1);
        }
    }
    objc_setAssociatedObject(view, &slabKeyKey, slabKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(view, &slabDataKey, slab, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Under a fusion drawRect: adds the image to the clear colour (GL_ONE,
    // GL_ONE), white under the B/W Inverse CLUT: every entry then draws white,
    // and only the fused series shows (#658).
    if (!fused && view.blendingView && !syncOnLocationImpossible && view.whiteBackground) {
        memset(rgba, 255, sizeof(rgba));
        snapshot[@"clut"] = [NSData dataWithBytes:rgba length:sizeof(rgba)];
    }
    // The series fused over the image, where drawRect: draws it: in the key
    // view of a 2D viewer, and in every orthogonal view, while the two series'
    // locations are in sync.
    if (!fused && view.blendingView && !syncOnLocationImpossible && (view.isKeyView || ![view is2DViewer])) {
        NSDictionary *layer = [view.blendingView horosPlanarSnapshotDrawnIn:view];
        if (layer[@"error"]) return layer;
        snapshot[@"fusion"] = layer;
    }
    return snapshot;
}
@end
