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
// The legacy exporter keeps what the plugin sets, as the application's did,
// and at each -writeDCMFile: turns the pixels into what the plugin API
// writes: grayscale values in modality units (the samples times the slope,
// plus the offset of unsigned 16-bit samples, as the application wrote
// them), or RGBA colour. The images an exporter writes are one series.

#import "IsiXLegacyBridgeInternal.h"

static IsiXLegacyDatabaseBridge *Bridge(void) { return [IsiXLegacyDatabaseBridge shared]; }

@implementation IsiXLegacyDICOMExport
{
    NSString *sourcePath;
    unsigned char *pixels;
    NSMutableData *ownPixels;
    long width, height;
    int samplesPerPixel, bitsPerSample;
    BOOL isSigned, positionSet, slicePositionSet, geometrySet;
    int offset;
    float slope, spacingX, spacingY, slicePosition;
    double sliceThickness;
    float orientation[6], position[3];
    long windowWidth, windowLevel;
    NSString *seriesDescription, *seriesUID;
    NSNumber *seriesNumber;
    long instanceNumber;
}

@synthesize metaDataDict, rotateRawDataBy90degrees;

/// The images of the database behind the files the kit handed out, by path.
static NSMutableDictionary<NSString*, NSDictionary*> *KnownFiles(void)
{
    static NSMutableDictionary *files;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ files = [NSMutableDictionary dictionary]; });
    return files;
}

+ (void) isixRememberFile: (NSString*) path image: (IsiXLegacyDicomImage*) image
{
    if (!path || !image.sopInstanceUID || !image.isixStudyInstanceUID) return;
    @synchronized (KnownFiles())
    {
        KnownFiles()[path] = @{@"sop": image.sopInstanceUID, @"study": image.isixStudyInstanceUID};
    }
}

/// The SOP Instance and Study Instance UIDs of a source file: one the kit
/// handed out, else read from the file.
+ (NSDictionary*) isixIdentityOfFile: (NSString*) path
{
    @synchronized (KnownFiles())
    {
        if (KnownFiles()[path]) return KnownFiles()[path];
    }
    IsiXLegacyDCMObject *object = [IsiXLegacyDCMObject objectWithContentsOfFile: path decodingPixelData: NO];
    NSString *sop = [object attributeValueWithName: @"SOPInstanceUID"], *study = [object attributeValueWithName: @"StudyInstanceUID"];
    if (![sop isKindOfClass: [NSString class]] || ![study isKindOfClass: [NSString class]]) return nil;
    return @{@"sop": sop, @"study": study};
}

- (instancetype) init
{
    if (!(self = [super init])) return nil;
    metaDataDict = [NSMutableDictionary dictionary];
    slope = 1;
    windowWidth = -1;
    windowLevel = -1;
    seriesDescription = @"IsiX SC";
    seriesUID = [IsiXLegacyDatabaseBridge freshUID];
    instanceNumber = 1;
    return self;
}

- (void) setSourceFile: (NSString*) isource { sourcePath = [isource copy]; }

- (long) setPixelData: (unsigned char*) idata samplesPerPixel: (int) ispp bitsPerSample: (int) ibps width: (long) iwidth height: (long) iheight
{
    pixels = idata;
    ownPixels = nil;
    // As the application's exporter did: new pixels are unsigned, offset -1024,
    // until -setSigned: and -setOffset: say otherwise.
    isSigned = NO;
    offset = -1024;
    samplesPerPixel = ispp;
    bitsPerSample = ibps;
    width = iwidth;
    height = iheight;
    return 0;
}

- (long) setPixelData: (unsigned char*) idata samplePerPixel: (long) spp bitsPerPixel: (long) bpp width: (long) iwidth height: (long) iheight
{
    // The former form names the bits of a pixel but, as the legacy header says
    // ("INCORRECT - backward compatibility"), the application took them as the
    // bits of a sample: plugins pass 8 for RGB with three samples.
    return [self setPixelData: idata samplesPerPixel: (int) spp bitsPerSample: (int) bpp width: iwidth height: iheight];
}

- (long) setPixelNSImage: (NSImage*) iimage
{
    NSBitmapImageRep *source = [NSBitmapImageRep imageRepWithData: iimage.TIFFRepresentation];
    if (!source) return -1;
    NSBitmapImageRep *rgba = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: source.pixelsWide pixelsHigh: source.pixelsHigh
                                                                  bitsPerSample: 8 samplesPerPixel: 4 hasAlpha: YES isPlanar: NO
                                                                 colorSpaceName: NSCalibratedRGBColorSpace bytesPerRow: source.pixelsWide * 4 bitsPerPixel: 32];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext: [NSGraphicsContext graphicsContextWithBitmapImageRep: rgba]];
    [source drawInRect: NSMakeRect(0, 0, source.pixelsWide, source.pixelsHigh)];
    [NSGraphicsContext restoreGraphicsState];
    ownPixels = [NSMutableData dataWithBytes: rgba.bitmapData length: (NSUInteger) (source.pixelsWide * source.pixelsHigh * 4)];
    pixels = ownPixels.mutableBytes;
    samplesPerPixel = 4;
    bitsPerSample = 8;
    width = source.pixelsWide;
    height = source.pixelsHigh;
    return 0;
}

- (void) setSigned: (BOOL) s { isSigned = s; }
- (void) setOffset: (int) o { offset = o; }
- (void) setSlope: (float) s { slope = s; }
- (void) setModalityAsSource: (BOOL) v {}
- (NSString*) seriesDescription { return seriesDescription; }
- (void) setSeriesDescription: (NSString*) desc { seriesDescription = [desc copy]; }

- (void) setSeriesNumber: (long) no
{
    if (seriesNumber.longValue != no) seriesUID = [IsiXLegacyDatabaseBridge freshUID];
    seriesNumber = @(no);
}

- (void) beginSeriesWithNumber: (long) no
{
    seriesNumber = @(no);
    seriesUID = [IsiXLegacyDatabaseBridge freshUID];
    instanceNumber = 1;
}

- (void) setDefaultWWWL: (long) ww :(long) wl { windowWidth = ww; windowLevel = wl; }
- (void) setPixelSpacing: (float) x :(float) y { spacingX = x; spacingY = y; geometrySet = YES; }
- (void) setSliceThickness: (double) t { sliceThickness = t; geometrySet = YES; }
- (void) setOrientation: (float*) o { if (o) { memcpy(orientation, o, sizeof orientation); geometrySet = YES; } }
- (void) setPosition: (float*) p { if (p) { memcpy(position, p, sizeof position); positionSet = YES; geometrySet = YES; } }
- (void) setSlicePosition: (float) p { slicePosition = p; slicePositionSet = YES; geometrySet = YES; }

/// The pixels as the plugin API takes them: Float32 values or RGBA bytes.
- (NSData*) isixSamplesColor: (BOOL*) color
{
    long count = width * height;
    if (!pixels || count <= 0) return nil;
    if (samplesPerPixel == 3 || samplesPerPixel == 4)
    {
        if (bitsPerSample != 8) return nil;
        *color = YES;
        NSMutableData *rgba = [NSMutableData dataWithLength: (NSUInteger) count * 4];
        unsigned char *out = rgba.mutableBytes;
        for (long i = 0; i < count; i++)
        {
            out[i * 4] = pixels[i * samplesPerPixel];
            out[i * 4 + 1] = pixels[i * samplesPerPixel + 1];
            out[i * 4 + 2] = pixels[i * samplesPerPixel + 2];
            out[i * 4 + 3] = samplesPerPixel == 4 ? pixels[i * 4 + 3] : 255;
        }
        return rgba;
    }
    if (samplesPerPixel != 1) return nil;
    *color = NO;
    NSMutableData *values = [NSMutableData dataWithLength: (NSUInteger) count * sizeof(float)];
    float *out = values.mutableBytes;
    float intercept = isSigned ? 0 : offset;
    for (long i = 0; i < count; i++)
    {
        switch (bitsPerSample)
        {
            case 8: out[i] = (isSigned ? ((signed char*) pixels)[i] : pixels[i]) * slope; break;
            case 16: out[i] = (isSigned ? ((short*) pixels)[i] : ((unsigned short*) pixels)[i]) * slope + intercept; break;
            case 32: out[i] = ((float*) pixels)[i]; break;
            default: return nil;
        }
    }
    return values;
}

- (NSString*) writeDCMFile: (NSString*) dstPath
{
    BOOL color = NO;
    NSData *samples = [self isixSamplesColor: &color];
    if (!samples)
    {
        [Bridge() fail: [NSString stringWithFormat: @"DICOMExport: %d samples of %d bits per pixel cannot be written.", samplesPerPixel, bitsPerSample]];
        return nil;
    }
    NSDictionary *source = sourcePath ? [IsiXLegacyDICOMExport isixIdentityOfFile: sourcePath] : nil;
    if (!source)
    {
        [Bridge() fail: @"DICOMExport needs a source file of the database for the patient and the study (-setSourceFile:)."];
        return nil;
    }
    NSDictionary *geometry = nil;
    if (geometrySet)
    {
        NSMutableDictionary *values = [@{@"spacingX": @(spacingX ?: 1), @"spacingY": @(spacingY ?: 1), @"sliceThickness": @(sliceThickness),
                                         @"orientation": @[@(orientation[0]), @(orientation[1]), @(orientation[2]),
                                                           @(orientation[3]), @(orientation[4]), @(orientation[5])]} mutableCopy];
        if (orientation[0] == 0 && orientation[1] == 0 && orientation[2] == 0) values[@"orientation"] = @[@1, @0, @0, @0, @1, @0];
        if (positionSet) values[@"position"] = @[@(position[0]), @(position[1]), @(position[2])];
        if (slicePositionSet) values[@"sliceLocation"] = @(slicePosition);
        geometry = values;
    }
    NSArray *level = windowWidth != -1 ? @[@(windowWidth), @(windowLevel)] : nil;
    NSString *written = [Bridge() writeDerivedImageWithStudy: source[@"study"] source: source[@"sop"] seriesUID: seriesUID
                                                seriesNumber: seriesNumber seriesDescription: seriesDescription ?: @""
                                              instanceNumber: instanceNumber samples: samples width: width height: height
                                                       color: color geometry: geometry windowLevel: level path: dstPath];
    if (written) instanceNumber++;
    return written;
}

@end
