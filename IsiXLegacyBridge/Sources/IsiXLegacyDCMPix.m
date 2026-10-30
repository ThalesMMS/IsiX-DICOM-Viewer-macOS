//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.
//
// An image of a viewer reads its geometry and attributes when it is made and
// its pixels from the session on first use; a copy keeps the values and the
// pixel pointer of its source, as the legacy class did, and remembers which
// image of which viewer it came from, so a new viewer can be opened on it.

#import "IsiXLegacyBridgeInternal.h"

@implementation IsiXLegacyDCMPix
{
    IsiXLegacyViewerSession *session, *sourceSession;
    long sourceSlice, sourcePhase;
    IsiXLegacyImageInfo *info;
    float *ownPixels;
    BOOL hasOwnPixels, ownIsRGB;
    double orientation[9], origin[3];
    float localWW, localWL;
}

@synthesize pwidth, pheight, pixelSpacingX, pixelSpacingY, sliceLocation, sliceThickness, sliceInterval;
@synthesize slope, offset, savedWW, savedWL, minValueOfSeries, maxValueOfSeries, frameNo, ID, Tot;
@synthesize repetitiontime, echotime, modalityString;

- (instancetype) initWithIsiXSession: (IsiXLegacyViewerSession*) s slice: (long) slice phase: (long) phase
{
    if (!(self = [super init])) return nil;
    session = s;
    sourceSession = s;
    sourceSlice = slice;
    sourcePhase = phase;
    frameNo = slice;
    ID = slice;
    Tot = s.sliceCount;
    info = [s infoWithSlice: slice phase: phase];
    if (info)
    {
        pwidth = info.columns;
        pheight = info.rows;
        pixelSpacingX = info.spacingX;
        pixelSpacingY = info.spacingY;
        origin[0] = info.originX; origin[1] = info.originY; origin[2] = info.originZ;
        for (int i = 0; i < 9 && i < (int) info.orientation.count; i++) orientation[i] = [info.orientation[i] doubleValue];
        sliceLocation = info.sliceLocation;
        sliceThickness = info.sliceThickness;
        sliceInterval = info.sliceInterval;
        slope = info.slope;
        offset = info.intercept;
        echotime = info.echoTime;
        repetitiontime = info.repetitionTime;
        modalityString = info.modality;
    }
    localWW = s.windowWidth;
    localWL = s.windowCenter;
    savedWW = localWW;
    savedWL = localWL;
    return self;
}

- (id) copyWithZone: (NSZone*) zone
{
    IsiXLegacyDCMPix *copy = [[[self class] allocWithZone: zone] init];
    copy->sourceSession = sourceSession;
    copy->sourceSlice = sourceSlice;
    copy->sourcePhase = sourcePhase;
    copy->info = info;
    copy->ownPixels = self.fImage;
    copy->hasOwnPixels = YES;
    copy->ownIsRGB = self.isRGB;
    memcpy(copy->orientation, orientation, sizeof orientation);
    memcpy(copy->origin, origin, sizeof origin);
    copy->localWW = self.ww;
    copy->localWL = self.wl;
    copy.pwidth = pwidth;
    copy.pheight = pheight;
    copy.pixelSpacingX = pixelSpacingX;
    copy.pixelSpacingY = pixelSpacingY;
    copy.sliceLocation = sliceLocation;
    copy.sliceThickness = sliceThickness;
    copy.sliceInterval = sliceInterval;
    copy.slope = slope;
    copy.offset = offset;
    copy.savedWW = savedWW;
    copy.savedWL = savedWL;
    copy.frameNo = frameNo;
    copy.ID = ID;
    copy.Tot = Tot;
    copy.echotime = echotime;
    copy.repetitiontime = repetitiontime;
    copy.modalityString = modalityString;
    return copy;
}

- (IsiXLegacyViewerSession*) isixSourceSession { return sourceSession; }
- (long) isixSourceSlice { return sourceSlice; }
- (long) isixSourcePhase { return sourcePhase; }

#pragma mark Pixels

- (float*) fImage
{
    if (hasOwnPixels || !session) return ownPixels;
    return (float*) [session pixelsWithSlice: sourceSlice phase: sourcePhase];
}

- (void) setfImage: (float*) pixels
{
    ownPixels = pixels;
    ownIsRGB = self.isRGB;
    hasOwnPixels = YES;
}

- (BOOL) isRGB
{
    if (hasOwnPixels || !session) return ownIsRGB;
    return [session isColorWithSlice: sourceSlice phase: sourcePhase];
}

- (float) getPixelValueX: (long) x Y: (long) y
{
    float *pixels = self.fImage;
    if (!pixels || x < 0 || y < 0 || x >= pwidth || y >= pheight) return 0;
    if (self.isRGB)
    {
        unsigned char *argb = (unsigned char*) pixels + (y * pwidth + x) * 4;
        return (argb[1] + argb[2] + argb[3]) / 3.0f;
    }
    return pixels[y * pwidth + x];
}

/// The lowest and highest value of the image.
- (BOOL) isixRange: (float*) lowest :(float*) highest
{
    float *pixels = self.fImage;
    long count = pwidth * pheight;
    if (!pixels || count <= 0) return NO;
    if (self.isRGB) { *lowest = 0; *highest = 255; return YES; }
    float low = pixels[0], high = pixels[0];
    for (long i = 1; i < count; i++)
    {
        if (pixels[i] < low) low = pixels[i];
        if (pixels[i] > high) high = pixels[i];
    }
    *lowest = low;
    *highest = high;
    return YES;
}

- (float) fullww
{
    float low, high;
    return [self isixRange: &low :&high] ? high - low : 0;
}

- (float) fullwl
{
    float low, high;
    return [self isixRange: &low :&high] ? (high + low) / 2 : 0;
}

- (void) computePixMinPixMax {}
- (void) CheckLoad { (void) self.fImage; }
- (void) compute8bitRepresentation {}

#pragma mark Window level

/// The image shown by its viewer takes the viewer's window level.
- (BOOL) isixShown
{
    return session && !hasOwnPixels && session.currentSlice == sourceSlice && session.currentPhase == sourcePhase;
}

- (float) ww { return [self isixShown] ? (float) session.windowWidth : localWW; }
- (float) wl { return [self isixShown] ? (float) session.windowCenter : localWL; }

- (void) changeWLWW: (float) newWL :(float) newWW
{
    localWL = newWL;
    localWW = newWW;
    if ([self isixShown]) [session setWindowWithCenter: newWL width: newWW];
}

#pragma mark Geometry

- (double) pixelRatio
{
    return pixelSpacingX != 0 ? pixelSpacingY / pixelSpacingX : 1;
}

- (double) originX { return origin[0]; }
- (double) originY { return origin[1]; }
- (double) originZ { return origin[2]; }

- (void) orientation: (float*) c { for (int i = 0; i < 9; i++) c[i] = orientation[i]; }
- (void) orientationDouble: (double*) c { for (int i = 0; i < 9; i++) c[i] = orientation[i]; }
- (void) origin: (float*) o { for (int i = 0; i < 3; i++) o[i] = origin[i]; }
- (void) originDouble: (double*) o { for (int i = 0; i < 3; i++) o[i] = origin[i]; }

- (BOOL) SUVConverted { return info.isSUV; }

- (void) convertPixDoubleX: (double) x pixY: (double) y toDICOMCoords: (double*) d pixelCenter: (BOOL) pixelCenter
{
    if (pixelCenter) { x -= 0.5; y -= 0.5; }
    for (int i = 0; i < 3; i++)
        d[i] = origin[i] + orientation[i] * x * pixelSpacingX + orientation[3 + i] * y * pixelSpacingY;
}

- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter
{
    double p[3];
    [self convertPixDoubleX: x pixY: y toDICOMCoords: p pixelCenter: pixelCenter];
    for (int i = 0; i < 3; i++) d[i] = p[i];
}

- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d
{
    [self convertPixX: x pixY: y toDICOMCoords: d pixelCenter: YES];
}

+ (NSPoint) originCorrectedAccordingToOrientation: (IsiXLegacyDCMPix*) pix
{
    double o[3], c[9];
    [pix originDouble: o];
    [pix orientationDouble: c];
    return NSMakePoint(o[0] * c[0] + o[1] * c[1] + o[2] * c[2], o[0] * c[3] + o[1] * c[4] + o[2] * c[5]);
}

#pragma mark ROIs

- (void) computeROI: (IsiXLegacyROI*) roi :(float *) mean :(float *) total :(float *) dev :(float *) min :(float *) max
{
    IsiXLegacyROIStatistics *statistics = nil;
    if (sourceSession && roi.isixHostState)
        statistics = [sourceSession statisticsOf: roi.isixHostState slice: sourceSlice phase: sourcePhase];
    if (mean) *mean = statistics.mean;
    if (total) *total = statistics.total;
    if (dev) *dev = statistics.deviation;
    if (min) *min = statistics.minimum;
    if (max) *max = statistics.maximum;
}

@end
