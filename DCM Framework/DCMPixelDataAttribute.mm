/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/


#import "DCMPixelDataAttribute.h"
#import "DCM.h"
#import "DCMHostServices.h"
#import "Accelerate/Accelerate.h"

// The framework decodes and encodes nothing itself (#742). Native pixel data is
// sliced into frames, swapped and colour-converted here; anything encapsulated,
// and every change of transfer syntax, goes through the host's DCMTK
// (HorosDICOMWriter), which returns the converted pixel data and pixel module.
static Class DCMPixelHostWriter(void)
{
    Class writer = NSClassFromString(@"HorosDICOMWriter");
    if (writer && [writer respondsToSelector: @selector(objectByConvertingObject:toTransferSyntax:quality:)])
        return writer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ NSLog(@"DCM.framework: no DICOM codec in this process; pixel data converts through the host's DCMTK"); });
    return nil;
}

@implementation DCMPixelDataAttribute

@synthesize rows = _rows;
@synthesize columns = _columns;
@synthesize numberOfFrames = _numberOfFrames;
@synthesize transferSyntax;
@synthesize samplesPerPixel = _samplesPerPixel;
@synthesize bytesPerSample = _bytesPerSample;
@synthesize pixelDepth = _pixelDepth;
@synthesize isShort = _isShort;
@synthesize compression = _compression;
@synthesize isDecoded = _isDecoded;

- (void)dealloc
{
    [singleThread release];
    [transferSyntax release];
    [_framesDecoded release];
    [super dealloc];
}

- (id)initWithAttributeTag:(DCMAttributeTag *)tag{
    if ((self = [super initWithAttributeTag:(DCMAttributeTag *)tag]))
        singleThread = [[NSRecursiveLock alloc] init];
    return self;
}

- (id)copyWithZone:(NSZone *)zone{
    DCMPixelDataAttribute *pixelAttr = [super copyWithZone:zone];
    return pixelAttr;
}


- (void)addFrame:(NSMutableData *)data{
    
    [_values addObject:data];
}

- (void)replaceFrameAtIndex:(int)index withFrame:(NSMutableData *)data{
    [_values replaceObjectAtIndex:index withObject:data];
}

- (NSString *)description{
    return  [NSString stringWithFormat:@"%@\t %@\t vl:%d\t vm:%d", _tag.description, _vr, (int) self.valueLength, self.valueMultiplicity];
}

- (BOOL)convertToTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality
{
    if (ts == nil)
        return NO;
    if ([transferSyntax isEqualToTransferSyntax: ts])
        return YES;
    // Native little endian either way: the samples are the same bytes.
    if (transferSyntax && transferSyntax.isEncapsulated == NO && ts.isEncapsulated == NO &&
        transferSyntax.isLittleEndian && ts.isLittleEndian)
    {
        self.transferSyntax = ts;
        return YES;
    }
    if (_dcmObject == nil)
        return NO;

    [singleThread lock];
    BOOL status = NO;
    @try
    {
        DCMObject *converted = [DCMPixelHostWriter() objectByConvertingObject: _dcmObject toTransferSyntax: ts.transferSyntax quality: quality];
        DCMAttribute *pixels = [converted attributeWithName: @"PixelData"];
        if (pixels)
        {
            // The values are copied out of the converted object's DCMTK memory.
            NSMutableArray *values = [NSMutableArray array];
            for (NSData *value in pixels.values)
                [values addObject: [NSMutableData dataWithData: value]];

            // The pixel module (and the lossy compression it now records) is the converted one.
            NSMutableDictionary *attributes = [_dcmObject attributes];
            NSMutableArray *module = [NSMutableArray array];
            for (NSString *key in attributes)
                if ([(DCMAttribute *) [attributes objectForKey: key] group] == 0x0028)
                    [module addObject: key];
            [attributes removeObjectsForKeys: module];
            for (NSString *key in converted.attributes)
            {
                DCMAttribute *attribute = [converted.attributes objectForKey: key];
                if (attribute.group == 0x0028)
                    [attributes setObject: attribute forKey: key];
            }

            [_values release];
            _values = [values retain];
            [_vr release];
            _vr = [pixels.vr retain];
            self.transferSyntax = ts;
            _framesCreated = NO;
            _isDecoded = NO;
            [_framesDecoded release];
            _framesDecoded = nil;
            _rows = [[_dcmObject attributeValueWithName: @"Rows"] intValue];
            _columns = [[_dcmObject attributeValueWithName: @"Columns"] intValue];
            _samplesPerPixel = [[_dcmObject attributeValueWithName: @"SamplesperPixel"] intValue];
            _pixelDepth = [[_dcmObject attributeValueWithName: @"BitsStored"] intValue];
            _bitsAllocated = [[_dcmObject attributeValueWithName: @"BitsAllocated"] intValue];
            status = YES;
        }
    }
    @catch (NSException *e)
    {
        NSLog(@"DCM Framework: converting pixel data to %@ failed: %@", ts.transferSyntax, e);
    }
    [singleThread unlock];
    return status;
}


//Pixel Decoding
- (NSData *)convertDataFromLittleEndianToHost:(NSMutableData *)data
{
    void *ptr = malloc([data length]);
    if( ptr)
    {
        memcpy( ptr, [data bytes], [data length]);
        
        if (NSHostByteOrder() == NS_BigEndian)
        {
            if (_pixelDepth <= 16 && _pixelDepth > 8)
            {
                unsigned short *shortsToSwap = (unsigned short *) ptr;
                int length = (int)[data length]/2;
                while( length-- > 0)
                    shortsToSwap[ length] = NSSwapShort( shortsToSwap[ length]);
            }
            else if (_pixelDepth > 16)
            {
                unsigned long *longsToSwap = (unsigned long *) ptr;
                int length = (int)[data length]/4;
                while( length-- > 0)
                    longsToSwap[ length] = NSSwapLong(longsToSwap[ length]);
            }
        }
        [data replaceBytesInRange:NSMakeRange(0, [data length]) withBytes: ptr];
        free( ptr);
    }
    else
        NSLog( @"****** NOT ENOUGH MEMORY ! UPGRADE TO OSIRIX 64-BIT");
    
    return data;
}

//  Big Endian to host will need
- (NSData *)convertDataFromBigEndianToHost:(NSMutableData *)data
{
    void *ptr = malloc([data length]);
    if( ptr)
    {
        memcpy( ptr, [data bytes], [data length]);
        
        if (NSHostByteOrder() == NS_LittleEndian)
        {
            if (_pixelDepth <= 16 && _pixelDepth > 8)
            {
                unsigned short *shortsToSwap = (unsigned short *) ptr;
                int length = (int)[data length]/2;
                while( length-- > 0)
                    shortsToSwap[ length] = NSSwapShort(shortsToSwap[ length]);
            }
            else if (_pixelDepth > 16)
            {
                unsigned long *longsToSwap = (unsigned long *) ptr;
                int length = (int)[data length]/4;
                while( length-- > 0)
                    longsToSwap[ length] = NSSwapLong(longsToSwap[ length]);
            }
        }
        [data replaceBytesInRange:NSMakeRange(0, [data length]) withBytes: ptr];
        free( ptr);
    }
    else
        NSLog( @"****** NOT ENOUGH MEMORY ! UPGRADE TO OSIRIX 64-BIT");
    
    return data;
}
- (void)convertBigEndianToHost{
}
- (void)convertHostToBigEndian{
    if (NSHostByteOrder() == NS_LittleEndian){
        for ( NSMutableData *data in _values ) {
            if (_pixelDepth <= 16) {
                unsigned short *shortsToSwap = (unsigned short *) [data mutableBytes];
                //signed short *signedShort = [data mutableBytes];
                unsigned int length = (unsigned int)[data length]/2;
                for ( unsigned i = 0; i < length; i++) {
                    shortsToSwap[i] = NSSwapShort(shortsToSwap[i]);
                }
            }
            else {
                unsigned long *longsToSwap = (unsigned long *) [data mutableBytes];
                //signed short *signedShort = [data mutableBytes];
                unsigned int length = (unsigned int)[data length]/4;
                for ( unsigned int i = 0; i < length; i++) {
                    longsToSwap[i] = NSSwapLong(longsToSwap[i]);
                }
            }
        }
    }
    self.transferSyntax = [DCMTransferSyntax ExplicitVRBigEndianTransferSyntax];
}

- (void)convertLittleEndianToHost{
    if (NSHostByteOrder() == NS_BigEndian){
        for ( NSMutableData *data in _values ) {
            if (_pixelDepth <= 16) {
                //				#if __ppc__
                //				if ( DCMHasAltiVec()) {
                //					 SwapShorts( (vector unsigned short *)[data mutableBytes], [data length]/2);
                //				}
                //				else
                //				#endif
                {
                    unsigned short *shortsToSwap = (unsigned short *) [data mutableBytes];
                    //signed short *signedShort = [data mutableBytes];
                    unsigned int length = (unsigned int)[data length]/2;
                    for ( unsigned int i = 0; i < length; i++ ) {
                        shortsToSwap[i] = NSSwapShort(shortsToSwap[i]);
                    }
                }
            }
            else {
                //				#if __ppc__
                //				if ( DCMHasAltiVec()) {
                //					 SwapLongs( (vector unsigned int *) [data mutableBytes], [data length]/4);
                //				}
                //				else
                //				#endif
                {
                    unsigned long *longsToSwap = (unsigned long *) [data mutableBytes];
                    //signed short *signedShort = [data mutableBytes];
                    unsigned int length = (unsigned int)[data length]/4;
                    for ( unsigned int i = 0; i < length; i++) {
                        longsToSwap[i] = NSSwapLong(longsToSwap[i]);
                    }
                }
            }
        }
        self.transferSyntax = [DCMTransferSyntax ExplicitVRBigEndianTransferSyntax];
    }
    
    else
        self.transferSyntax = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
}

- (void)convertHostToLittleEndian{
    if (NSHostByteOrder() == NS_BigEndian){
        for ( NSMutableData *data in _values ) {
            if (_pixelDepth <= 16) {
                //				#if __ppc__
                //				if ( DCMHasAltiVec())
                //					 SwapShorts( (vector unsigned short *) [data mutableBytes], [data length]/2);
                //				else
                //				#endif
                {
                    unsigned short *shortsToSwap = (unsigned short *) [data mutableBytes];
                    unsigned int length = (unsigned int)[data length]/2;
                    while (length--) {
                        *shortsToSwap = NSSwapShort(*shortsToSwap);
                        shortsToSwap++;
                    }
                }
            }
            else {
                //				#if __ppc__
                //				if ( DCMHasAltiVec()) {
                //					 SwapLongs( (vector unsigned int *) [data mutableBytes], [data length]/4);
                //				}
                //				else
                //				#endif
                {
                    unsigned long *longsToSwap = (unsigned long *) [data mutableBytes];
                    //signed short *signedShort = [data mutableBytes];
                    unsigned int length = (unsigned int)[data length]/4;
                    for ( unsigned int i = 0; i < length; i++ ) {
                        longsToSwap[i] = NSSwapLong(longsToSwap[i]);
                    }
                }
            }
        }
    }
    self.transferSyntax = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];
}

- (void)decodeData
{
    if (_isDecoded)
        return;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableArray *frames = [NSMutableArray array];
    for (int i = 0; i < _numberOfFrames; i++)
    {
        NSData *frame = [self decodeFrameAtIndex: i];
        if (frame == nil)
        {
            NSLog(@"DCM Framework: frame %d of %d cannot be decoded", i, _numberOfFrames);
            [pool release];
            return;
        }
        [frames addObject: [[frame mutableCopy] autorelease]];
    }
    [_values release];
    _values = [frames retain];
    _framesCreated = YES;
    _isDecoded = YES;
    self.transferSyntax = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax];

    // The frames are interleaved, and YBR and palette colour is RGB now.
    if (_samplesPerPixel > 1 && [_dcmObject attributeWithName: @"PlanarConfiguration"])
        [_dcmObject setAttributeValues: [NSMutableArray arrayWithObject: [NSNumber numberWithInt: 0]] forName: @"PlanarConfiguration"];
    NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
    if ([colorspace hasPrefix:@"YBR"] || [colorspace hasPrefix:@"PALETTE"])
    {
        //remove Palette stuff
        NSMutableDictionary *attributes = [_dcmObject attributes];
        NSMutableArray *keysToRemove = [NSMutableArray array];
        for ( NSString *key in attributes ) {
            DCMAttribute *attr = [attributes objectForKey:key];
            if ([(DCMAttributeTag *)[attr attrTag] group] == 0x0028 && ([(DCMAttributeTag *)[attr attrTag] element] > 0x1100 && [(DCMAttributeTag *)[attr attrTag] element] <= 0x1223))
                [keysToRemove addObject:key];
        }
        [attributes removeObjectsForKeys:keysToRemove];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"RGB"] forName:@"PhotometricInterpretation"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"3"] forName:@"SamplesperPixel"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:8]] forName:@"BitsStored"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:8]] forName:@"BitsAllocated"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:7]] forName:@"HighBit"];
        
        _samplesPerPixel = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"SamplesperPixel"]] value] intValue];
    }
    [pool release];
}


-(void)createOffsetTable{
    /*
     offset should be item tag 4 bytes length 4 bytes last item length
     */
    if (DCMDEBUG)
        NSLog(@"create Offset table");
    NSMutableData *offsetTable = [NSMutableData data];
    unsigned long offset = 0;
    [offsetTable appendBytes:&offset length:4];
    int i;
    int count = (int)[_values count];
    for (i = 1; i < count; i++) {
        offset += NSSwapHostLongToLittle([(NSData *)[_values objectAtIndex:i -1] length] + 8);
        [offsetTable appendBytes:&offset length:4];
    }
    [_values insertObject:offsetTable atIndex:0];
}

- (NSData *)interleavePlanesInData:(NSData *)planarData{
    DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"PlanarConfiguration"];
    DCMAttribute *attr = [_dcmObject attributeForTag:(DCMAttributeTag *)tag];
    int numberofPlanes = [[attr value] intValue];
    int i,j, k;
    int bytes = 1;
    if (_pixelDepth <= 8)
        bytes = 1;
    else if (_pixelDepth <= 16)
        bytes = 2;
    else
        bytes = 4;
    int planeLength = _rows * _columns;
    NSMutableData *interleavedData = nil;
    if (numberofPlanes > 0 && numberofPlanes <= 4) {
        interleavedData = [NSMutableData dataWithLength:[planarData length]];
        if (bytes == 1) {
            
            unsigned char *planarBuffer = (unsigned char *)[planarData  bytes];
            unsigned char *bitmapData = (unsigned char *)[interleavedData  mutableBytes];
            for(i=0; i< _rows; i++){
                
                for(j=0; j< _columns; j++){
                    for (k = 0; k < _samplesPerPixel; k++)
                        *bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];
                    
                }
            }
        }
        else if (bytes == 2) {
            unsigned short *planarBuffer = (unsigned short *)[planarData  bytes];
            unsigned short *bitmapData = (unsigned short *)[interleavedData  mutableBytes];
            for(i=0; i< _rows; i++){
                for(j=0; j< _columns; j++){
                    for (k = 0; k < _samplesPerPixel; k++)
                        *bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];
                    
                }
            }
        }
        else {
            unsigned long *planarBuffer = (unsigned long *)[planarData  bytes];
            unsigned long *bitmapData = (unsigned long *)[interleavedData  mutableBytes];
            for(i=0; i< _rows; i++){
                for(j=0; j< _columns; j++){
                    for (k = 0; k < _samplesPerPixel; k++)
                        *bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];
                    
                }
            }
        }
    }
    //already interleaved
    else
        return planarData;
    return interleavedData;
}

- (void)interleavePlanes{
    DCMAttributeTag *tag = [DCMAttributeTag tagWithName:@"PlanarConfiguration"];
    DCMAttribute *attr = [_dcmObject attributeForTag:(DCMAttributeTag *)tag];
    int numberofPlanes = [[attr value] intValue];
    NSMutableArray *dataArray = [NSMutableArray array];
    int bytes = 1;
    if (_pixelDepth <= 8)
        bytes = 1;
    else if (_pixelDepth <= 16)
        bytes = 2;
    else
        bytes = 4;
    int planeLength = _rows * _columns;
    if (numberofPlanes > 0 && numberofPlanes <= 4) {
        
        for ( NSMutableData *planarData in _values ) {
            NSMutableData *interleavedData = [NSMutableData dataWithLength:[planarData length]];
            if (bytes == 1) {
                
                unsigned char *planarBuffer = (unsigned char *)[planarData  bytes];
                unsigned char *bitmapData = (unsigned char *)[interleavedData  mutableBytes];
                for( unsigned int i=0; i < _rows; i++ ) {
                    for( unsigned int j=0; j< _columns; j++ ) {
                        for ( unsigned int k = 0; k < _samplesPerPixel; k++ )
                            *bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];
                        
                    }
                }
            }
            else if (bytes == 2) {
                unsigned short *planarBuffer = (unsigned short *)[planarData  bytes];
                unsigned short *bitmapData = (unsigned short *)[interleavedData  mutableBytes];
                for ( unsigned int i=0; i< _rows; i++ ) {
                    for ( unsigned int j=0; j< _columns; j++ ) {
                        for ( unsigned int k = 0; k < _samplesPerPixel; k++ )
                            *bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];
                        
                    }
                }
            }
            else {
                unsigned long *planarBuffer = (unsigned long *)[planarData  bytes];
                unsigned long *bitmapData = (unsigned long *)[interleavedData  mutableBytes];
                for ( unsigned int i=0; i< _rows; i++ ) {
                    for ( unsigned int j=0; j< _columns; j++ ) {
                        for ( unsigned int k = 0; k < _samplesPerPixel; k++ )
                            *bitmapData++ = planarBuffer[planeLength*k + i*_columns + j ];
                        
                    }
                }
            }
            [dataArray addObject:interleavedData];
        }
        for ( unsigned int i = 0; i< [dataArray count]; i++)
            [_values replaceObjectAtIndex:i withObject:[dataArray objectAtIndex:i]];
    }
}

- (void)setLossyImageCompressionRatio:(NSMutableData *)data quality: (int) quality
{
    int numBytes = 1;
    if (_pixelDepth > 8)
        numBytes = 2;
    float uncompressedSize = _rows * _columns * _samplesPerPixel * numBytes;
    float compression = uncompressedSize/(float)[data length];
    
    NSString *ratio = [NSString stringWithFormat:@"%f", compression];
    DCMAttributeTag *ratioTag = [DCMAttributeTag tagWithName:@"LossyImageCompressionRatio"];
    DCMAttribute *ratioAttr = [DCMAttribute attributeWithAttributeTag:ratioTag vr:[ratioTag vr] values:[NSMutableArray arrayWithObject:ratio]];
    
    DCMAttributeTag *compressionTag = [DCMAttributeTag tagWithName:@"LossyImageCompression"];
    DCMAttribute *compressionAttr;
    if( quality != DCMLosslessQuality)
        compressionAttr = [DCMAttribute attributeWithAttributeTag:compressionTag vr:[compressionTag vr] values:[NSMutableArray arrayWithObject:@"01"]];
    else
        compressionAttr = [DCMAttribute attributeWithAttributeTag:compressionTag vr:[compressionTag vr] values:[NSMutableArray arrayWithObject:@"00"]];
    
    [[_dcmObject attributes] setObject:ratioAttr  forKey:[ratioTag stringValue]];
    [[_dcmObject attributes] setObject:compressionAttr  forKey:[compressionTag stringValue]];
    //LossyImageCompression
}

- (void)findMinAndMax:(NSMutableData *)data
{
    int length;
    DCMAttributeTag *signedTag = [DCMAttributeTag tagWithName:@"PixelRepresentation"];
    DCMAttribute *signedAttr = [[_dcmObject attributes] objectForKey:[signedTag stringValue]];
    BOOL isSigned = [[signedAttr value] boolValue];
    float max,  min;
    
    if (_bitsAllocated <= 8)
        length = (int)[data length];
    else if (_bitsAllocated <= 16)
        length = (int)[data length]/2;
    else
        length = (int)[data length]/4;
    
    float *fBuffer = (float*) malloc(length * 4);
    if( fBuffer)
    {
        vImage_Buffer src, dstf;
        dstf.height = src.height = _rows;
        dstf.width = src.width = _columns;
        dstf.rowBytes = _columns*sizeof(float);
        dstf.data = fBuffer;
        src.data = (void*) [data bytes];
        
        if (_bitsAllocated <= 8)
        {
            src.rowBytes = _columns;
            vImageConvert_Planar8toPlanarF( &src, &dstf, 0, 256, 0);
        }
        else if (_bitsAllocated <= 16)
        {
            src.rowBytes = _columns * 2;
            
            if( isSigned)
                vImageConvert_16SToF( &src, &dstf, 0, 1, 0);
            else
                vImageConvert_16UToF( &src, &dstf, 0, 1, 0);
        }
        
        vDSP_minv( fBuffer, 1, &min, length);
        vDSP_maxv( fBuffer, 1, &max, length);
        
        _min = min;
        _max = max;
        
        //		// The goal of this 'trick' is to avoid the problem that some annotations can generate, if they are 'incrusted' in the image
        //		// the jp2k algorithm doesn't like them at all...
        //
        //		if( isSigned == NO && _max == 65535)
        //		{
        //			long i = _columns * _rows;
        //			// Compute the new max
        //			while( i-->0)
        //			{
        //				if( fBuffer[ i] == 0xFFFF)
        //					fBuffer[ i] = _min;
        //			}
        //
        //			vDSP_minv( fBuffer, 1, &min, length);
        //			vDSP_maxv( fBuffer, 1, &max, length);
        //
        //			_min = min;
        //			_max = max;
        //
        //			// Modify the original data
        //
        //			unsigned short *ptr = (unsigned short*) [data bytes];
        //
        //			i = _columns * _rows;
        //			while( i-->0)
        //			{
        //				if( ptr[ i] == 0xFFFF)
        //					ptr[ i] = _max;
        //			}
        //		}
        
        free(fBuffer);
    }
    else
        NSLog( @"****** NOT ENOUGH MEMORY ! UPGRADE TO OSIRIX 64-BIT");
}

// Expands one segmented palette lookup table (PS 3.3 C.7.9.2): a stream of
// segments, each a type and a length, then whatever that type needs. Nothing in
// the stream is trusted - not the length to stay inside the stream, not the
// total to stay inside the table.
static long expandSegmentedPalette( NSData *segmented, unsigned short *table, long entries)
{
    if( segmented == nil || table == NULL || entries <= 0)
        return 0;
    
    const unsigned short *stream = (const unsigned short*) [segmented bytes];
    long count = (long) ([segmented length] / 2);
    long filled = 0;
    
    if( stream == NULL)
        return 0;
    
    for( long at = 0; at + 1 < count && filled < entries; )
    {
        int type = NSSwapLittleShortToHost( stream[ at]);
        long length = NSSwapLittleShortToHost( stream[ at + 1]);
        at += 2;
        
        if( type == 0)          // Discrete: one value per entry
        {
            if( at + length > count)
                length = count - at;
            
            for( long i = 0; i < length && filled < entries; i++)
                table[ filled++] = NSSwapLittleShortToHost( stream[ at + i]);
            
            at += length;
        }
        else if( type == 1)     // Linear: interpolate from the last entry to one value
        {
            if( at >= count)
                break;
            
            long from = filled > 0 ? table[ filled - 1] : 0;
            long to = NSSwapLittleShortToHost( stream[ at]);
            
            for( long i = 1; i <= length && filled < entries; i++)
                table[ filled++] = (unsigned short) (from + ((to - from) * i) / (length > 0 ? length : 1));
            
            at += 1;
        }
        else                    // Indirect, and anything else
        {
            // Expanding it is not implemented, and carrying on would put every
            // following segment at the wrong index.
            NSLog( @"Palette segment type %d is not expanded; %ld entries were read", type, filled);
            break;
        }
    }
    return filled;
}

// A pixel value below the first one the table maps takes the first entry, one
// above the last takes the last: PS 3.3 C.7.6.3.1.5.
#define ENTRY_FOR( value, first, entries) \
    ((entries) <= 0 ? 0 : \
     ((value) - (first) < 0 ? 0 : \
      ((value) - (first) >= (entries) ? (entries) - 1 : (value) - (first))))

- (NSData *)convertPaletteToRGB:(NSData *)data
{
    BOOL			fSetClut = NO, fSetClut16 = NO;
    unsigned char   *clutRed = nil, *clutGreen = nil, *clutBlue = nil;
    int		clutEntryR = 0, clutEntryG = 0, clutEntryB = 0;
    // The second value of each descriptor is the pixel value the first entry
    // stands for. Ignoring it reads every palette from the wrong end.
    int   clutFirstR = 0, clutFirstG = 0, clutFirstB = 0;
    unsigned short		clutDepthR, clutDepthG, clutDepthB;
    unsigned short	*shortRed = nil, *shortGreen = nil, *shortBlue = nil;
    long height = _rows;
    long width = _columns;
    long realwidth = width;
    long depth = _pixelDepth;
    NSMutableData *rgbData = nil;
    @try {
        //PhotoInterpret
        if ([[_dcmObject attributeValueWithName:@"PhotometricInterpretation"] rangeOfString:@"PALETTE"].location != NSNotFound)
        {
            BOOL found = NO, found16 = NO;
            clutRed = (unsigned char*) calloc( 65536, 1);
            clutGreen = (unsigned char*) calloc( 65536, 1);
            clutBlue = (unsigned char*) calloc( 65536, 1);
            
            // initialisation
            clutEntryR = clutEntryG = clutEntryB = 0;
            clutFirstR = clutFirstG = clutFirstB = 0;
            clutDepthR = clutDepthG = clutDepthB = 0;
            
            NSArray *redLUTDescriptor = [_dcmObject attributeArrayWithName:@"RedPaletteColorLookupTableDescriptor"];
            clutEntryR = (unsigned short)[[redLUTDescriptor objectAtIndex:0] intValue];
            clutFirstR = [[redLUTDescriptor objectAtIndex:1] intValue];
            clutDepthR = (unsigned short)[[redLUTDescriptor objectAtIndex:2] intValue];
            NSArray *greenLUTDescriptor = [_dcmObject attributeArrayWithName:@"GreenPaletteColorLookupTableDescriptor"];
            clutEntryG = (unsigned short)[[greenLUTDescriptor objectAtIndex:0] intValue];
            clutFirstG = [[greenLUTDescriptor objectAtIndex:1] intValue];
            clutDepthG = (unsigned short)[[greenLUTDescriptor objectAtIndex:2] intValue];
            NSArray *blueLUTDescriptor = [_dcmObject attributeArrayWithName:@"BluePaletteColorLookupTableDescriptor"];
            clutEntryB = (unsigned short)[[blueLUTDescriptor objectAtIndex:0] intValue];
            clutFirstB = [[blueLUTDescriptor objectAtIndex:1] intValue];
            clutDepthB = (unsigned short)[[blueLUTDescriptor objectAtIndex:2] intValue];
            
            if( clutEntryR > 256) NSLog(@"R-Palette > 256");
            if( clutEntryG > 256) NSLog(@"G-Palette > 256");
            if( clutEntryB > 256) NSLog(@"B-Palette > 256");
            
            //NSLog(@"%d red entries with depth: %d", clutEntryR , clutDepthR);
            //NSLog(@"%d green entries with depth: %d", clutEntryG , clutDepthG);
            //NSLog(@"%d blue entries with depth: %d", clutEntryB , clutDepthB);
            
            NSMutableData *segmentedRedData = [_dcmObject attributeValueWithName:@"SegmentedRedPaletteColorLookupTableData"];
            if (segmentedRedData)	// SEGMENTED PALETTE - 16 BIT !
            {
                //NSLog(@"Segmented LUT");
                if (clutDepthR == 16  && clutDepthG == 16  && clutDepthB == 16)
                {
                    // A 16-bit pixel can be 65535, which is one past the end of
                    // 65535 entries. And a segmented table fills only as far as its
                    // segments go, so the rest has to be something rather than
                    // whatever malloc handed back.
                    shortRed = (unsigned short*) calloc( 65536L, sizeof( unsigned short));
                    shortGreen = (unsigned short*) calloc( 65536L, sizeof( unsigned short));
                    shortBlue = (unsigned short*) calloc( 65536L, sizeof( unsigned short));
                    
                    // The three streams are expanded by one piece of code that
                    // trusts neither a segment's length to stay inside the stream
                    // nor the total to stay inside the table. What was here was
                    // written out three times; it read a length and then that many
                    // values without looking at how long the stream was, and wrote
                    // them wherever the running index had reached.
                    long filled = expandSegmentedPalette( segmentedRedData, shortRed, 65536L);
                    expandSegmentedPalette( [_dcmObject attributeValueWithName:@"SegmentedGreenPaletteColorLookupTableData"], shortGreen, 65536L);
                    expandSegmentedPalette( [_dcmObject attributeValueWithName:@"SegmentedBluePaletteColorLookupTableData"], shortBlue, 65536L);
                    
                    if( filled > 0)
                        found16 = YES;
                    /*
                     for( jj = 0; jj < 65535; jj++)
                     {
                     shortRed[jj] =shortRed[jj]>>8;
                     shortGreen[jj] =shortGreen[jj]>>8;
                     shortBlue[jj] =shortBlue[jj]>>8;
                     }
                     */
                }  //end 16 bit
                else if (clutDepthR == 8  && clutDepthG == 8  && clutDepthB == 8)
                {
                    NSLog(@"Segmented palettes for 8 bits ??");
                }
                else
                {
                    NSLog(@"Dont know this kind of DICOM CLUT...");
                }
            } //end segmented
            // NOT SEGMENTED
            //
            // Three tables, read the same way, because they are the same thing in
            // three colours. What was here read the blue table out of the green
            // attribute - so every image came back with blue equal to green, and an
            // object with a blue table and no green one dereferenced a null pointer
            // - and it turned a 16-bit entry into 8 bits by dividing by 256, which
            // is only right when the entries really use all sixteen. A nuclear
            // medicine palette that stores 0-255 in 16-bit words, which is common,
            // came out entirely black.
            else if( (clutDepthR == 16 && clutDepthG == 16 && clutDepthB == 16) ||
                     (clutDepthR == 8 && clutDepthG == 8 && clutDepthB == 8))
            {
                NSString *names[ 3] = { @"RedPaletteColorLookupTableData",
                                        @"GreenPaletteColorLookupTableData",
                                        @"BluePaletteColorLookupTableData"};
                unsigned char *tables[ 3] = { clutRed, clutGreen, clutBlue};
                int *counts[ 3] = { &clutEntryR, &clutEntryG, &clutEntryB};
                unsigned short depths[ 3] = { clutDepthR, clutDepthG, clutDepthB};
                unsigned short raw[ 3][ 65536];
                int read[ 3] = { 0, 0, 0};
                unsigned short largest = 0;
                
                for( int c = 0; c < 3; c++)
                {
                    DCMAttribute *table = [_dcmObject attributeWithName: names[ c]];
                    if( table == nil)
                        continue;
                    
                    if( [table valueMultiplicity] > 1)
                    {
                        // Some objects arrive parsed into numbers rather than bytes.
                        NSArray *values = [table values];
                        int wanted = *counts[ c] > 0 ? *counts[ c] : (int) values.count;
                        if( wanted > (int) values.count) wanted = (int) values.count;
                        if( wanted > 65536) wanted = 65536;
                        
                        for( int j = 0; j < wanted; j++)
                            raw[ c][ j] = (unsigned short) [[values objectAtIndex: j] intValue];
                        read[ c] = wanted;
                    }
                    else
                    {
                        NSData *data = [table value];
                        if( data == nil)
                            continue;
                        
                        if( depths[ c] == 16)
                        {
                            int available = (int) ([data length] / 2);
                            int wanted = *counts[ c] > 0 ? *counts[ c] : available;
                            if( wanted > available) wanted = available;
                            if( wanted > 65536) wanted = 65536;
                            
                            const unsigned short *entries = (const unsigned short*) [data bytes];
                            for( int j = 0; j < wanted; j++)
                                raw[ c][ j] = NSSwapLittleShortToHost( entries[ j]);
                            read[ c] = wanted;
                        }
                        else
                        {
                            int available = (int) [data length];
                            int wanted = *counts[ c] > 0 ? *counts[ c] : available;
                            if( wanted > available) wanted = available;
                            if( wanted > 65536) wanted = 65536;
                            
                            const unsigned char *entries = (const unsigned char*) [data bytes];
                            for( int j = 0; j < wanted; j++)
                                raw[ c][ j] = entries[ j];
                            read[ c] = wanted;
                        }
                    }
                    
                    for( int j = 0; j < read[ c]; j++)
                        if( raw[ c][ j] > largest) largest = raw[ c][ j];
                }
                
                // The descriptor says how wide an entry is, not how much of it is
                // used. What the tables actually contain does.
                BOOL eightBitValues = (largest <= 255);
                
                for( int c = 0; c < 3; c++)
                {
                    for( int j = 0; j < read[ c]; j++)
                        tables[ c][ j] = eightBitValues ? (unsigned char) raw[ c][ j]
                                                        : (unsigned char) (raw[ c][ j] >> 8);
                    
                    if( read[ c] > 0)
                    {
                        *counts[ c] = read[ c];
                        found = YES;
                    }
                }
            }
            else
            {
                NSLog( @"Palette color lookup tables of %d/%d/%d bits are not read",
                      (int) clutDepthR, (int) clutDepthG, (int) clutDepthB);
            }
            if (found) fSetClut = YES;
            if (found16) fSetClut16 = YES;
            
        } // endif ...extraction of the color palette
        
        // This image has a palette -> Convert it to a RGB image !
        if( fSetClut)
        {
            if( clutRed != nil && clutGreen != nil && clutBlue != nil)
            {
                unsigned char   *bufPtr = (unsigned char*) [data bytes];
                unsigned short	*bufPtr16 = (unsigned short*) [data bytes];
                unsigned char   *tmpImage;
                long      totSize, pixelR, pixelG, pixelB;
                long i = 0;
                totSize = (long) ((long) height * (long) realwidth * 3L);
                //tmpImage = malloc( totSize);
                rgbData = [NSMutableData dataWithLength:totSize];
                tmpImage = (unsigned char*) [rgbData mutableBytes];
                
                // An object can declare a picture larger than the pixels it
                // carries. Under AddressSanitizer, a frame half the length of its
                // own Rows x Columns read past the end of the buffer.
                long available = (long) ([data length] / (_pixelDepth == 16 ? 2 : 1));
                long pixels = (long) height * (long) realwidth;
                if( available < pixels)
                {
                    NSLog( @"Palette pixel data holds %ld of the %ld pixels the object declares",
                          available, pixels);
                    pixels = available;
                }
                
                //if( _pixelDepth != 8) NSLog(@"Palette with a non-8 bit image??? : %d ", _pixelDepth);
                //NSLog(@"height; %d  width %d totSize: %d, length: %d", height, realwidth, totSize, [data length]);
                switch(_pixelDepth)
                {
                    case 8:
                        
                        for( i = 0; i < pixels; i++)
                        {
                            {
                                long value = bufPtr[ i];
                                
                                pixelR = ENTRY_FOR( value, clutFirstR, clutEntryR);
                                pixelG = ENTRY_FOR( value, clutFirstG, clutEntryG);
                                pixelB = ENTRY_FOR( value, clutFirstB, clutEntryB);
                                
                                tmpImage[i*3 + 0] = clutRed[ pixelR];
                                tmpImage[i*3 + 1] = clutGreen[ pixelG];
                                tmpImage[i*3 + 2] = clutBlue[ pixelB];
                            }
                        }
                        
                        break;
                        
                    case 16:
                        for( i = 0; i < pixels; i++)
                        {
                            {
                                // The pixels arrive in host order, like every other
                                // image here. Swapping them asked for entry 256 when
                                // the pixel was 1, which is past the end of a
                                // 256-entry palette: the whole picture came back
                                // black. Neither was the value clamped to the table.
                                long value = bufPtr16[i];
                                
                                pixelR = ENTRY_FOR( value, clutFirstR, clutEntryR);
                                pixelG = ENTRY_FOR( value, clutFirstG, clutEntryG);
                                pixelB = ENTRY_FOR( value, clutFirstB, clutEntryB);
                                
                                tmpImage[i*3 + 0] = clutRed[ pixelR];
                                tmpImage[i*3 + 1] = clutGreen[ pixelG];
                                tmpImage[i*3 + 2] = clutBlue[ pixelB];
                            }
                        }
                        break;
                }
                
            }
        }
        
        if( fSetClut16){
            unsigned short  *bufPtr = (unsigned short*) [data bytes];
            unsigned char   *tmpImage;
            long      totSize;
            
            long pixel;
            
            // Three bytes per pixel, like the other palette. Nothing downstream can
            // tell which of the two ran, and the display path reads eight bits per
            // sample, so both have to produce the same thing.
            totSize = (long) ((long) _rows * (long) _columns * 3L);
            rgbData = [NSMutableData dataWithLength:totSize];
            tmpImage = (unsigned char *)[rgbData mutableBytes];
            
            if( depth != 16) NSLog(@"Segmented Palette with a non-16 bit image???");
            
            long available = (long) ([data length] / 2);
            long pixels = (long) height * (long) realwidth;
            if( available < pixels)
            {
                NSLog( @"Segmented palette pixel data holds %ld of the %ld pixels the object declares",
                      available, pixels);
                pixels = available;
            }
            
            unsigned short largest = 0;
            for( long entry = 0; entry < 65536; entry++)
            {
                if( shortRed[ entry] > largest) largest = shortRed[ entry];
                if( shortGreen[ entry] > largest) largest = shortGreen[ entry];
                if( shortBlue[ entry] > largest) largest = shortBlue[ entry];
            }
            BOOL eightBitValues = (largest <= 255);
            
            for( long index = 0; index < pixels; index++)
            {
                long value = bufPtr[ index];
                
                pixel = ENTRY_FOR( value, clutFirstR, clutEntryR);
                tmpImage[index*3 + 0] = eightBitValues ? (unsigned char) shortRed[ pixel] : (unsigned char) (shortRed[ pixel] >> 8);
                pixel = ENTRY_FOR( value, clutFirstG, clutEntryG);
                tmpImage[index*3 + 1] = eightBitValues ? (unsigned char) shortGreen[ pixel] : (unsigned char) (shortGreen[ pixel] >> 8);
                pixel = ENTRY_FOR( value, clutFirstB, clutEntryB);
                tmpImage[index*3 + 2] = eightBitValues ? (unsigned char) shortBlue[ pixel] : (unsigned char) (shortBlue[ pixel] >> 8);
            }
        } //done converting Palette
    } @catch( NSException *localException) {
        rgbData = nil;
        NSLog(@"Exception converting Palette to RGB: %@", localException.name);
    }
    if( clutRed != nil)
        free(clutRed);
    if ( clutGreen != nil)
        free(clutGreen);
    if (clutBlue != nil)
        free(clutBlue);
    
    if (shortRed != nil)
        free(shortRed);
    if (shortGreen != nil)
        free(shortGreen);
    if (shortBlue != nil)
        free(shortBlue);
    //NSLog(@"end palette conversion end length: %d", [rgbData length]);

    return rgbData;
    
}

// One place where a luminance and two chrominance samples become a colour.
// PS 3.3 C.7.6.3.1.2: YBR_FULL uses the whole 0-255 range for luminance, and
// YBR_PARTIAL reserves 16-235 for it, which is the same matrix with the range
// scaled. Fixed point, fifteen fractional bits.
static inline void ybrToRGB( int luminance, int blueDifference, int redDifference,
                             BOOL partialRange,
                             unsigned char *red, unsigned char *green, unsigned char *blue)
{
    int r, g, b;
    
    blueDifference -= 128;
    redDifference -= 128;
    
    if( partialRange)
    {
        luminance -= 16;
        r = 38142 * luminance + 52298 * redDifference;
        g = 38142 * luminance - 26640 * redDifference - 12845 * blueDifference;
        b = 38142 * luminance + 66093 * blueDifference;
    }
    else
    {
        r = 32768 * luminance + 45941 * redDifference;
        g = 32768 * luminance - 23401 * redDifference - 11277 * blueDifference;
        b = 32768 * luminance + 58065 * blueDifference;
    }
    
    r = (r + 16384) >> 15;
    g = (g + 16384) >> 15;
    b = (b + 16384) >> 15;
    
    *red   = (unsigned char) (r < 0 ? 0 : (r > 255 ? 255 : r));
    *green = (unsigned char) (g < 0 ? 0 : (g > 255 ? 255 : g));
    *blue  = (unsigned char) (b < 0 ? 0 : (b > 255 ? 255 : b));
}

- (NSData *) convertYBrToRGB:(NSData *)ybrData kind:(NSString *)theKind isPlanar:(BOOL)isPlanar
{
    long      loop, size;
    unsigned char   *pRGB;
    unsigned char   *theRGB;
    NSMutableData *rgbData;
    
    //  NSLog(@"convertYBrToRGB:%@ isPlanar:%d", theKind, isPlanar);
    // the planar configuration should be set to 0 whenever
    // YBR_FULL_422 or YBR_PARTIAL_422 is used
    if (![theKind isEqualToString:@"YBR_FULL"] && isPlanar == 1)
        return nil;
    
    if( ybrData == nil)
        return nil;
    
    // allocate room for the RGB image
    int length = ( _rows *  _columns * 3);
    rgbData = [NSMutableData dataWithLength:length];
    theRGB = (unsigned char*) [rgbData mutableBytes];
    if (theRGB == nil) return nil;
    pRGB = theRGB;
    size = (long) _rows * (long) _columns;
    const BOOL partialRange = [theKind hasPrefix: @"YBR_PARTIAL"];
    const BOOL subsampled = [theKind hasSuffix: @"_422"] || [theKind hasSuffix: @"_420"];
    
    if( isPlanar)
    {
        // Three planes, one after the other, and only for the full-sampled kinds.
        const unsigned char *luminance = (const unsigned char*) [ybrData bytes];
        const unsigned char *blueDifference = luminance + size;
        const unsigned char *redDifference = blueDifference + size;
        
        if( (long) [ybrData length] < size * 3)
        {
            NSLog( @"YBR planar data holds %ld of the %ld bytes the object declares",
                  (long) [ybrData length], (long) (size * 3));
            return nil;
        }
        
        for( loop = 0; loop < size; loop++)
            ybrToRGB( luminance[ loop], blueDifference[ loop], redDifference[ loop],
                     partialRange, pRGB + loop*3, pRGB + loop*3 + 1, pRGB + loop*3 + 2);
    }
    else if( subsampled)
    {
        // Y for each of two pixels, then one Cb and one Cr they share.
        const unsigned char *ybr = (const unsigned char*) [ybrData bytes];
        long pairs = size / 2;
        
        if( (long) [ybrData length] < pairs * 4)
        {
            pairs = (long) [ybrData length] / 4;
            NSLog( @"YBR_422 data holds %ld of the %ld pixel pairs the object declares",
                  pairs, (long) (size / 2));
        }
        
        for( loop = 0; loop < pairs; loop++)
        {
            int first = ybr[ loop*4 + 0], second = ybr[ loop*4 + 1];
            int blueDifference = ybr[ loop*4 + 2], redDifference = ybr[ loop*4 + 3];
            
            ybrToRGB( first, blueDifference, redDifference, partialRange,
                     pRGB + loop*6, pRGB + loop*6 + 1, pRGB + loop*6 + 2);
            ybrToRGB( second, blueDifference, redDifference, partialRange,
                     pRGB + loop*6 + 3, pRGB + loop*6 + 4, pRGB + loop*6 + 5);
        }
    }
    else
    {
        const unsigned char *ybr = (const unsigned char*) [ybrData bytes];
        long count = size;
        
        if( (long) [ybrData length] < size * 3)
        {
            count = (long) [ybrData length] / 3;
            NSLog( @"YBR data holds %ld of the %ld pixels the object declares", count, size);
        }
        
        for( loop = 0; loop < count; loop++)
            ybrToRGB( ybr[ loop*3], ybr[ loop*3 + 1], ybr[ loop*3 + 2], partialRange,
                     pRGB + loop*3, pRGB + loop*3 + 1, pRGB + loop*3 + 2);
    }
    
    return rgbData;
    
}

- (NSData *)convertToFloat:(NSData *)data{
    NSMutableData *floatData = nil;
    float rescaleIntercept = 0.0;
    float rescaleSlope = 1.0;
    vImage_Buffer src16, dstf, src8;
    dstf.height = src16.height = src8.height = _rows;
    dstf.width = src16.width = src8.width = _columns;
    dstf.rowBytes = _columns * sizeof(float);
    
    if ([_dcmObject attributeValueWithName:@"RescaleIntercept" ]  != nil)
        rescaleIntercept = (float)([[_dcmObject attributeValueWithName:@"RescaleIntercept" ] floatValue]);
    if ([_dcmObject attributeValueWithName:@"RescaleSlope" ] != nil)
        rescaleSlope = [[_dcmObject attributeValueWithName:@"RescaleSlope" ] floatValue];
    
    // 8 bit grayscale
    if (_samplesPerPixel == 1 && _pixelDepth <= 8){
        src8.rowBytes = _columns * sizeof(char);
        src8.data = (unsigned char *)[data bytes];
        floatData = [NSMutableData dataWithLength:[data length] * sizeof(float)/sizeof(char)];
        dstf.data = (float *)[floatData mutableBytes];
        vImageConvert_Planar8toPlanarF (&src8, &dstf, 0, 256,0);
    }
    // 16 bit signed
    else if (_samplesPerPixel == 1 && _pixelDepth <= 16 && _isSigned){
        src16.rowBytes = _columns * sizeof(short);
        src16.data = (short *)[data bytes];
        floatData = [NSMutableData dataWithLength:[data length]  * sizeof(float)/sizeof(short)];
        dstf.data = (float *)[floatData mutableBytes];
        vImageConvert_16SToF ( &src16, &dstf, rescaleIntercept, rescaleSlope, 0);
    }
    //16 bit unsigned
    else if (_samplesPerPixel == 1 && _pixelDepth <= 16 && !(_isSigned)){
        
        src16.rowBytes = _columns * sizeof(short);
        src16.data = (unsigned short *)[data bytes];
        floatData = [NSMutableData dataWithLength:[data length] * sizeof(float)/sizeof(unsigned short)];
        dstf.data = (float *)[floatData mutableBytes];
        vImageConvert_16UToF ( &src16, &dstf, rescaleIntercept, rescaleSlope, 0);
    }
    //rgb 8 bit interleaved
    else if (_samplesPerPixel > 1 && _pixelDepth <= 8){
        //convert to ARGB first
        src8.rowBytes = _columns * sizeof(char) * 3;
        src8.data = (unsigned char *)[data bytes];
        vImage_Buffer argb;
        argb.height = _rows;
        argb.width = _columns;
        argb.rowBytes = _columns * sizeof(char) * 4;
        NSMutableData *argbData = [NSMutableData dataWithLength:_rows * _columns * 4];
        argb.data = (unsigned char *)[argbData mutableBytes];
        vImageConvert_RGB888toARGB8888 (&src8,  //src
                                        NULL,	//alpha src
                                        0,	//alpha
                                        &argb,	//dst
                                        0, 0);		//flags need a extra arg for some reason
        
        
        floatData = [NSMutableData dataWithLength:[argbData length]  * sizeof(float)/sizeof(char)];
        dstf.data = (float *)[floatData mutableBytes];
        vImageConvert_Planar8toPlanarF (&argb, &dstf, 0, 256, 0);
    }
    else if( _pixelDepth == 32)
    {
        unsigned int *uslong = (unsigned int*) [data bytes];
        int	 *slong = (int*) [data bytes];
        floatData = [NSMutableData dataWithLength:[data length]];
        float *tDestF = (float *)[floatData mutableBytes];
        
        if(_isSigned)
        {
            long x = _rows * _columns;
            while( x-->0)
            {
                *tDestF++ = ((float) (*slong++)) * rescaleSlope + rescaleIntercept;
            }
        }
        else
        {
            long x = _rows * _columns;
            while( x-->0)
            {
                *tDestF++ = ((float) (*uslong++)) * rescaleSlope + rescaleIntercept;
            }
        }
        
    }
    
    
    
    return floatData;
}
- (NSData *)convertDataToRGBColorSpace:(NSData *)data
{
    NSData *rgbData = nil;
    NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
    BOOL isPlanar = [[_dcmObject attributeValueWithName:@"PlanarConfiguration"] intValue];
    if ([colorspace hasPrefix:@"YBR"])
        rgbData = [self convertYBrToRGB:data kind:colorspace isPlanar:isPlanar];
    else if ([colorspace hasPrefix:@"PALETTE"])
        rgbData = [self  convertPaletteToRGB:data];
    else
        rgbData = data;
    
    return rgbData;
}

- (void)convertToRGBColorspace{
    //NSLog(@"convert tp RGB colorspace");
    NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
    BOOL isPlanar = [[_dcmObject attributeValueWithName:@"PlanarConfiguration"] intValue];
    NSMutableArray *newValues = [NSMutableArray array];
    if ([colorspace hasPrefix:@"YBR"]){
        for ( NSMutableData *data in _values ) {
            [newValues addObject:[self convertYBrToRGB:data kind:colorspace isPlanar:isPlanar]];
        }
        [_values release];
        _values = [newValues retain];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"RGB"] forName:@"PhotometricInterpretation"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"3"] forName:@"SamplesperPixel"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:8]] forName:@"BitsStored"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:8]] forName:@"BitsAllocated"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:7]] forName:@"HighBit"];
        
        _samplesPerPixel = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"SamplesperPixel"]] value] intValue];
    }
    else if ([colorspace hasPrefix:@"PALETTE"]){
        
        for ( NSMutableData *data in _values ) {
            [newValues addObject:[self convertPaletteToRGB:data]];
        }
        [_values release];
        _values = [newValues retain];
        //remove PAlette stuff
        NSMutableDictionary *attributes = [_dcmObject attributes];
        NSMutableArray *keysToRemove = [NSMutableArray array];
        for ( NSString *key in attributes ) {
            DCMAttribute *attr = [attributes objectForKey:key];
            if ([(DCMAttributeTag *)[attr attrTag] group] == 0x0028 && ([(DCMAttributeTag *)[attr attrTag] element] > 0x1100 && [(DCMAttributeTag *)[attr attrTag] element] <= 0x1223))
                [keysToRemove addObject:key];
        }
        [attributes removeObjectsForKeys:keysToRemove];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"RGB"] forName:@"PhotometricInterpretation"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:@"3"] forName:@"SamplesperPixel"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:8]] forName:@"BitsStored"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:8]] forName:@"BitsAllocated"];
        [_dcmObject setAttributeValues:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:7]] forName:@"HighBit"];
        
        _samplesPerPixel = [[[_dcmObject attributeForTag:[DCMAttributeTag tagWithName:@"SamplesperPixel"]] value] intValue];
    }
    
}

- (NSMutableData *)createFrameAtIndex:(int)index{
    
    //NSDate *timestamp = [NSDate date];
    NSMutableData *subData = nil;
    if (!_framesCreated){	
        //NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        if ( transferSyntax.isEncapsulated )
        {
            //NSLog(@"encapsulated");
            NSMutableArray *offsetTable = [NSMutableArray array];
            /*offset table will be first fragment
             if single image value = 0;
             each offset is an unsigned long to the first byte of the Item tag. We have already removed the tags.
             The 0 frame starts on 0
             the 1 frame starts of offset - 8  ( Two Item tag and lengths)
             The 2 frame starts at offset - 16   ( three Item tag and lengths)
             So will use 0 for first frame, and then  subtract (n-1) * 8
             */
            unsigned  long offset;
            if ([_values count] > 1  && [(NSData *)[_values objectAtIndex:0] length] > 0) {
                int i;
                NSData *offsetData = [_values objectAtIndex:0];
                unsigned long *offsets = (unsigned long *)[offsetData bytes];
                int numberOfOffsets = (int)[offsetData length]/4;
                for ( i = 0; i < numberOfOffsets; i++)
                {
                    if ( transferSyntax.isLittleEndian ) 
                        offset = NSSwapLittleLongToHost(offsets[i]);
                    else
                        offset = offsets[i];
                    [offsetTable addObject:[NSNumber numberWithLong:offset]];
                }
            }
            else 
                [offsetTable addObject:[NSNumber numberWithLong:0]];
            
            
            //most likely way to have data with one frame per data object.
            NSMutableArray *values = [NSMutableArray arrayWithArray:_values];
            //remove offset table
            [values removeObjectAtIndex:0];
            if ([values count] == _numberOfFrames)
            {
                subData = [values objectAtIndex:index];
                //need to figure out where the data starts and ends
            }
            else
            {
                int currentOffset = (int)[[offsetTable objectAtIndex:index] longValue];
                int currentLength = 0;
                if (index < _numberOfFrames - 1 && index < [offsetTable count] - 1)
                    currentLength = (int)[[offsetTable objectAtIndex:index + 1] longValue] - currentOffset;
                else{
                    //last offset - currentLength =  total length of items 
                    int itemsLength = 0;
                    for ( NSData *aData in values )
                        itemsLength += [aData length];
                    currentLength = itemsLength - currentOffset;
                }
                /*now we need to find the item that == the start of the offset
                 find which items contain the data.
                 need to add for item tag and length 8 bytes * (n - 1) items
                 */
                int combinedLength = 0;
                int startingItem = 0;
                int dataLength = 0;
                int endItem = 0;
                while (combinedLength < currentOffset && startingItem < [values count]) {
                    combinedLength += ([(NSData *)[values objectAtIndex:startingItem] length] + 8);
                    startingItem++;
                }
                endItem = startingItem;
                dataLength = (int)([(NSData *)[values objectAtIndex:endItem] length] + 8);
                while ((dataLength < currentLength) && (endItem < [values count])) {
                    endItem++;
                    dataLength += ([(NSData *)[values objectAtIndex:endItem] length] + 8);
                }
                int j;
                subData = [NSMutableData data];
                for (j = startingItem; j <= endItem ; j++) 
                    [subData appendData:[values objectAtIndex:j]];	
            } //appending fragments
            
        } //end encapsulated
        //multiple frames
        else if (_numberOfFrames > 1)
        {
            int depth = 1;
            if (_bitsAllocated <= 8) 
                depth = 1;
            else if (_bitsAllocated  <= 16)
                depth = 2;
            else
                depth = 4;
            int frameLength = _rows * _columns * _samplesPerPixel * depth;
            NSRange range = NSMakeRange(index * frameLength, frameLength);
            
            void *ptr = malloc( frameLength);
            if( ptr)
            {
                if( [[_values objectAtIndex:0] length] < range.location + range.length)
                    subData = nil;
                else
                {
                    memcpy( ptr, (unsigned char*) [[_values objectAtIndex:0] bytes] + range.location,  range.length);
                    subData = [NSMutableData dataWithBytesNoCopy: ptr length: frameLength freeWhenDone: YES];
                }
                
                if( subData == nil)
                    free( ptr);
            }
            else
                NSLog( @"****** NOT ENOUGH MEMORY ! UPGRADE TO OSIRIX 64-BIT");
        }
        //only one fame
        else {
            
            subData =[_values objectAtIndex:0];
        }
    }		
    return subData;
}

- (void)createFrames{
    
    if (!_framesCreated){
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        if (DCMDEBUG)
            NSLog(@"Decode Data");
        // if encapsulated we need to use offset table to create frames
        if ( transferSyntax.isEncapsulated ) {
            if (DCMDEBUG)
                NSLog(@"Data is encapsulated");
            NSMutableArray *offsetTable = [NSMutableArray array];
            /*offset table will be first fragment
             if single image value = 0;
             each offset is an unsigned long to the first byte of the Item tag. We have already removed the tags.
             The 0 frame starts on 0
             the 1 frame starts of offset - 8  ( Two Item tag and lengths)
             The 2 frame starts at offset - 16   ( three Item tag and lengths)
             So will use 0 for first frame, and then  subtract (n-1) * 8
             */
            unsigned  long offset;
            
            if ([_values count] > 1  && [(NSData *)[_values objectAtIndex:0] length] > 0) {
                int i;
                NSData *offsetData = [_values objectAtIndex:0];
                unsigned long *offsets = (unsigned long *)[offsetData bytes];
                int numberOfOffsets = (int)[offsetData length]/4;
                for ( i = 0; i < numberOfOffsets; i++) {
                    if ( transferSyntax.isLittleEndian ) 
                        offset = NSSwapLittleLongToHost(offsets[i]);
                    else
                        offset = offsets[i];
                    [offsetTable addObject:[NSNumber numberWithLong:offset]];
                }
            }
            else 
                [offsetTable addObject:[NSNumber numberWithLong:0]];
            
            
            
            //most likely way to have data with one frame per data object.
            NSMutableArray *values = [NSMutableArray arrayWithArray:_values];
            //remove offset table
            [values removeObjectAtIndex:0];
            
            [_values removeAllObjects];
            int i;
            NSMutableData *subData;
            if (DCMDEBUG)
                NSLog(@"number of Frames: %d", _numberOfFrames);
            for (i = 0; i < _numberOfFrames; i++) {	
                if (DCMDEBUG)
                    NSLog(@"Frame %d", i);
                //one to one match between frames and items
                
                if ([values count] == _numberOfFrames) {
                    subData = [values objectAtIndex:i];
                }
                
                //need to figure out where the data starts and ends
                else{
                    
                    int currentOffset = (int)[[offsetTable objectAtIndex:i] longValue];
                    int currentLength = 0;
                    if (i < _numberOfFrames - 1)
                        currentLength =  (int)[[offsetTable objectAtIndex:i + 1] longValue] - currentOffset;
                    else{
                        //last offset - currentLength =  total length of items 
                        int itemsLength = 0;
                        for ( NSData *aData in values )
                            itemsLength += [aData length];
                        currentLength = itemsLength - currentOffset;
                    }
                    /*now we need to find the item that == the start of the offset
                     find which items contain the data.
                     need to add for item tag and length 8 bytes * (n - 1) items
                     */
                    int combinedLength = 0;
                    int startingItem = 0;
                    int dataLength = 0;
                    int endItem = 0;
                    while (combinedLength < currentOffset && startingItem < [values count]) {
                        combinedLength += ([(NSData *)[values objectAtIndex:startingItem] length] + 8);
                        startingItem++;
                    }
                    endItem = startingItem;
                    dataLength = (int)([(NSData *)[values objectAtIndex:endItem] length] + 8);
                    while ((dataLength < currentLength) && (endItem < [values count])) {
                        endItem++;
                        dataLength += ([(NSData *)[values objectAtIndex:endItem] length] + 8);
                    }
                    subData = [NSMutableData data];
                    for ( int j = startingItem; j <= endItem ; j++ ) 
                        [subData appendData:[values objectAtIndex:j]];	
                }
                //subdata is new frame;
                [self addFrame:subData];
            }
        }
        else
        {
            if (_numberOfFrames > 0)
            {
                int depth = 1;
                if (_bitsAllocated <= 8) 
                    depth = 1;
                else if (_bitsAllocated  <= 16)
                    depth = 2;
                else
                    depth = 4;
                int frameLength = _rows * _columns * _samplesPerPixel * depth;
                NSMutableData *rawData = [[[_values objectAtIndex:0] retain] autorelease];
                [_values removeAllObjects];
                for ( unsigned int i = 0; i < _numberOfFrames; i++ )
                {
                    NSAutoreleasePool *subPool = [[NSAutoreleasePool alloc] init];
                    
                    @try
                    {
                        NSRange range = NSMakeRange(i * frameLength, frameLength);
                        
                        void *ptr = malloc( range.length);
                        if( ptr)
                        {
                            if( [rawData length] < range.location + range.length)
                                free( ptr);
                            else
                            {
                                memcpy( ptr, (unsigned char*) [rawData bytes] + range.location, range.length);
                                [self addFrame: [NSMutableData dataWithBytesNoCopy: ptr length: range.length freeWhenDone: YES]];
                            }
                        }
                        else
                            NSLog( @"****** NOT ENOUGH MEMORY ! UPGRADE TO OSIRIX 64-BIT");
                    }
                    @catch (NSException *exception) {
                        NSLog( @"%@", exception);
                    }
                    @finally {
                        [subPool release];
                    }
                    
                }
            }
        }
        
        _framesCreated = YES;
        [pool release];
    }
}

- (NSData *)encapsulatedStream
{
    if( transferSyntax.isEncapsulated == NO || _framesCreated || [_values count] < 2)
        return nil;

    NSMutableData *stream = [NSMutableData data];

    // The first item is the basic offset table, which is not part of the
    // stream; the rest are the stream, in order, split wherever the writer
    // chose to split it.
    for( NSUInteger i = 1; i < [_values count]; i++)
    {
        NSData *fragment = [_values objectAtIndex: i];
        if( [fragment isKindOfClass: [NSData class]])
            [stream appendData: fragment];
    }

    return [stream length] ? stream : nil;
}

// A frame in host byte order, samples interleaved, YBR and palette colour as RGB.
- (NSData *)decodeFrameAtIndex:(int)index
{
    if (index < 0 || index >= _numberOfFrames)
        return nil;
    if (_isDecoded)
        return index < (int) [_values count] ? [_values objectAtIndex: index] : nil;
    // Encapsulated: the host's DCMTK decodes the whole value once.
    if (transferSyntax.isEncapsulated &&
        [self convertToTransferSyntax: [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] quality: DCMLosslessQuality] == NO)
        return nil;

    NSData *data = nil;
    [singleThread lock];
    @try
    {
        if ([_values count] > 0)
            data = _framesCreated ? [_values objectAtIndex: index] : [self createFrameAtIndex: index];
    }
    @catch (NSException *e)
    {
        NSLog( @"exception decodeFrameAtIndex: %@", e);
        data = nil;
    }
    [singleThread unlock];
    if (data == nil)
        return nil;

    if (_bitsAllocated > 8 && [transferSyntax isEqualToTransferSyntax: [DCMTransferSyntax ExplicitVRBigEndianTransferSyntax]])
        data = [self convertDataFromBigEndianToHost: [[data mutableCopy] autorelease]];

    NSString *colorspace = [_dcmObject attributeValueWithName:@"PhotometricInterpretation"];
    if ([colorspace hasPrefix:@"YBR"] || [colorspace hasPrefix:@"PALETTE"])
        return [self convertDataToRGBColorSpace:data];
    int numberofPlanes = [[_dcmObject attributeValueWithName:@"PlanarConfiguration"] intValue];
    if (numberofPlanes > 0 && numberofPlanes <= 4)
        return [self interleavePlanesInData:data];
    return data;
}

@end
