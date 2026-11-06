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
// The values of the pixels inside a ROI, read from the plugin's copy of the
// image: the pixels whose centre lies inside the ROI's outline (even-odd
// rule), or set in a brush ROI's mask. The application's statistics
// (computeROI) stay the application's; these are for what the legacy plugin
// computed itself, as a median.

#import "IsiXLegacyBridgeInternal.h"

@implementation IsiXLegacyDCMPix (IsiXLegacyROIValues)

static BOOL IsiXInside(NSArray<IsiXLegacyMyPoint*> *outline, double x, double y)
{
    BOOL inside = NO;
    NSUInteger count = outline.count;
    for (NSUInteger i = 0, j = count - 1; i < count; j = i++)
    {
        NSPoint a = outline[i].point, b = outline[j].point;
        if ((a.y > y) != (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) inside = !inside;
    }
    return inside;
}

- (float) isixValueAtColumn: (long) column row: (long) row
{
    if (column < 0 || row < 0 || column >= self.pwidth || row >= self.pheight || !self.fImage) return 0;
    long index = row * self.pwidth + column;
    if (!self.isRGB) return self.fImage[index];
    const unsigned char *argb = (const unsigned char*) self.fImage + index * 4;
    return (argb[1] + argb[2] + argb[3]) / 3.f;
}

- (float*) getROIValue: (long*) numberOfValues :(IsiXLegacyROI*) roi :(float**) locations
{
    NSMutableData *values = [NSMutableData data], *where = [NSMutableData data];
    void (^take)(long, long) = ^(long column, long row) {
        float value = [self isixValueAtColumn: column row: row], location[2] = { column, row };
        [values appendBytes: &value length: sizeof value];
        [where appendBytes: location length: sizeof location];
    };
    if (roi.type == tPlain && roi.textureBuffer)
    {
        for (long r = 0; r < roi.textureHeight; r++)
            for (long c = 0; c < roi.textureWidth; c++)
            {
                long column = roi.textureUpLeftCornerX + c, row = roi.textureUpLeftCornerY + r;
                if (roi.textureBuffer[r * roi.textureWidth + c] && column >= 0 && row >= 0 && column < self.pwidth && row < self.pheight)
                    take(column, row);
            }
    }
    else
    {
        NSArray<IsiXLegacyMyPoint*> *outline = roi.points;
        if (outline.count >= 3)
        {
            double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
            for (IsiXLegacyMyPoint *p in outline)
            {
                minX = MIN(minX, p.x); maxX = MAX(maxX, p.x);
                minY = MIN(minY, p.y); maxY = MAX(maxY, p.y);
            }
            long firstRow = MAX(0, (long) floor(minY)), lastRow = MIN(self.pheight - 1, (long) ceil(maxY));
            long firstColumn = MAX(0, (long) floor(minX)), lastColumn = MIN(self.pwidth - 1, (long) ceil(maxX));
            // Pixel centres are at half coordinates, as ROI points are.
            for (long row = firstRow; row <= lastRow; row++)
                for (long column = firstColumn; column <= lastColumn; column++)
                    if (IsiXInside(outline, column + 0.5, row + 0.5)) take(column, row);
        }
    }
    long count = (long) (values.length / sizeof(float));
    if (numberOfValues) *numberOfValues = count;
    // Allocated with malloc, as the legacy application did: the caller frees them.
    float *result = calloc(MAX(count, 1), sizeof(float));
    memcpy(result, values.bytes, values.length);
    if (locations)
    {
        *locations = calloc(MAX(count, 1) * 2, sizeof(float));
        memcpy(*locations, where.bytes, where.length);
    }
    return result;
}

@end
