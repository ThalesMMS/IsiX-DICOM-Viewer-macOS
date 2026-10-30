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

#ifndef DCMPIX_H_INCLUDED
#define DCMPIX_H_INCLUDED

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>

#include "options.h"

#define ORIENTATION_SENSIBILITY 0.001

/** Starts the patient's name in a line of -annotationsDictionary. The viewer
    shows the name only at the Full annotation level and leaves it out at the
    others; the prefix tells the name apart from the other fields of the line. */
FOUNDATION_EXPORT NSString * const DCMPixAnnotationPatientNamePrefix;

typedef struct {
    double x,y,z;
} XYZ;


#ifdef __cplusplus
extern "C"
{
#endif /*cplusplus*/
    extern XYZ ArbitraryRotate(XYZ p,double theta,XYZ r);
#ifdef __cplusplus
}
#endif /*cplusplus*/


@class ROI;
@class ThickSlabController;
@class Point3D;
@class DicomImage;
@class DicomSeries;
@class DicomStudy;
@class DCMTKFileFormat;

/** \brief Represents an image for display

 The class is implemented in Swift: DCMPix.swift is its implementation
 (@objc @implementation) and holds its state, its initializers and its
 accessors; each responsibility is in its own file (DCMPix+Loading.swift,
 DCMPix+FrameLoading.swift, DCMPix+ImageAttributes.swift,
 DCMPix+Subtraction.swift, DCMPix+SUV.swift, DCMPixSettings.swift, and the
 extensions declared by the category headers imported at the end). This
 interface declares it to Objective-C, which can still subclass it; it has no
 instance variables: key-value coding still answers their former names. */

@interface DCMPix: NSObject <NSCopying>

@property long frameNo;
@property(setter=setID:) long ID;
@property (readonly) NSRecursiveLock *checking;
@property (nonatomic) float minValueOfSeries, maxValueOfSeries, factorPET2SUV;

@property(retain) NSString* imageType, *modalityString, *referencedSOPInstanceUID, *yearOld, *yearOldAcquisition;

// Dimensions in pixels
@property (nonatomic) long pwidth, pheight;

/** Is it an RGB image (ARGB) or float image?
 Note setter is different to not break existing usage. :-( */
@property(nonatomic, setter=setRGB:) BOOL isRGB;
/** Pointer to image data */
@property(setter=setfImage:) float* fImage;

/** WW & WL */
@property(readonly) float ww, wl, fullww, fullwl;
@property(nonatomic) float slope, offset, savedWW, savedWL, *subtractedfImage;

@property(readonly) BOOL notAbleToLoadImage, VOILUTApplied;
@property(readonly) NSPoint *shutterPolygonal;

/**  X/Y ratio - non-square pixels */
@property(nonatomic) double pixelRatio;

/**  pixel size */
@property double pixelSpacingX, pixelSpacingY;

/** Slice location */
@property(readonly) double originX, originY, originZ;
@property(readonly) BOOL isOriginDefined;
@property(retain) NSString *frameofReferenceUID;

- (void)setOrigin :(float*) o;
- (void)setOriginDouble :(double*) o;
- (void)origin: (float*)o;
- (void)originDouble: (double*)o;

/**  Axial Location */
@property double sliceLocation;
/**  Slice Thickness */
@property double sliceThickness;
/**  Slice Interval */
@property double sliceInterval;
/**  Gap between slices */
@property(readonly) double spacingBetweenSlices;

/**  8-bit TransferFunction */

@property(nonatomic) NSPoint subPixOffset;

@property(nonatomic) BOOL shutterEnabled;
@property(nonatomic) NSRect shutterRect;

@property(retain) NSString *repetitiontime, *echotime;
@property(readonly) NSString *flipAngle;

@property(readonly) NSString *laterality, *viewPosition, *patientPosition;

@property(readonly) long serieNo;
@property(readonly) float *transferFunctionPtr;
@property NSInteger pixPos;
@property short stackDirection;
@property float countstackMean;

@property(getter=Tot, setter=setTot:) long Tot;

@property(readonly) short stack, stackMode;
@property(readonly) BOOL generated;
@property(retain) NSString *generatedName;

@property(strong) NSString *srcFile;
- (NSString *)sourceFile __deprecated;
- (void)setSourceFile:(NSString *)sf __deprecated;

@property(readonly) unsigned int* VOILUT_table;

/** Database links */
@property(retain) NSManagedObjectID *imageObjectID;
@property(retain) NSString *SOPClassUID;

// Properties (aka accessors) needed for SUV calculations
@property(readonly) float philipsFactor;
@property float patientsWeight, halflife, radionuclideTotalDose, radionuclideTotalDoseCorrected;
@property(retain) NSDate *acquisitionTime;
@property(copy) NSString *acquisitionDate, *rescaleType;
// Why this frame has no picture in it, in one sentence, or nil when it has
// one. An empty frame used to be indistinguishable from a dark one.
@property(copy) NSString *missingPixelsReason;
@property(retain) NSDate *radiopharmaceuticalStartTime;
@property BOOL SUVConverted, needToCompute8bitRepresentation;

@property(retain) DCMTKFileFormat *dcmtkDcmFileFormat;

@property(readonly) BOOL hasSUV;
@property float decayFactor;
@property(retain) NSString *units, *decayCorrection;
@property BOOL displaySUVValue;
@property BOOL isLUT12Bit;

// Waveform
@property(readonly,strong) id waveform; // nil: no decoder fills it

// US Regions
@property(readonly) NSMutableArray *usRegions;
-(BOOL) hasUSRegions;

- (float) appliedFactorPET2SUV;
- (void) copySUVfrom: (DCMPix*) from;  /**< Copy the SUV from another DCMPic */

- (void) checkSUV; /**< Makes sure all the necessary values for SUV calculation are present */

+ (void) checkUserDefaults: (BOOL) update;  /**< Check User Default for needed setting */
+ (void) resetUserDefaults;  /**< Reset the defaults */
- (void) computePixMinPixMax;  /**< Compute the min and max values in the image */



- (void) setPixelX: (int) x Y:(int) y value:(float) v;
- (float) cineRate;  /**< Returns the Cine rate */
+ (int) maxProcessors;
// drag-drop subtraction-multiplication between series
- (void) imageArithmeticMultiplication:(DCMPix*) sub;
- (float*) multiplyImages :(float*) input :(float*) subfImage;
- (void) imageArithmeticSubtraction:(DCMPix*) sub;
- (void) imageArithmeticSubtraction:(DCMPix*) sub absolute:(BOOL) abs;
- (float*) arithmeticSubtractImages :(float*) input :(float*) subfImage;
-(float*) arithmeticSubtractImages :(float*) input :(float*) subfImage absolute:(BOOL) abs;
//DSA
- (void) setSubSlidersPercent: (float) p gamma: (float) g zero: (float) z;
- (void) setSubSlidersPercent: (float) p;
- (NSPoint) subMinMax:(float*)input :(float*)subfImage;
- (void) setSubtractedfImage:(float*)mask :(NSPoint)smm;
- (float*) subtractImages:(float*)input :(float*)subfImage;
- (void) fImageTime:(float)newTime;
- (float) fImageTime;
- (void) freefImageWhenDone:(BOOL) b;
- (void) maskID:(long)newID;
- (long) maskID;
- (void) maskTime:(float)newMaskTime;
- (float) maskTime;

- (void) positionerPrimaryAngle:(NSNumber *)newPositionerPrimaryAngle;
- (NSNumber*) positionerPrimaryAngle;
- (void) positionerSecondaryAngle:(NSNumber*)newPositionerSecondaryAngle;
- (NSNumber*) positionerSecondaryAngle;


- (void) computeTotalDoseCorrected;
- (void) setRGB : (BOOL) val;
- (BOOL) updateToApply;
- (id) myinitEmpty;  /**< Returns an Empty object */
/**  calls
 * myinit:(NSString*) s :(long) pos :(long) tot :(float*) ptr :(long) f :(long) ss isBonjour:(BOOL) hello imageObj: (NSManagedObject*) iO
 * with hello = NO and iO = nil
 */
- (id) myinit:(NSString*) s :(long) pos :(long) tot :(float*) ptr :(long) f :(long) ss;
- (id) initWithPath:(NSString*) s :(long) pos :(long) tot :(float*) ptr :(long) f :(long) ss;

/**  Initialize
 * doesn't load pix data, only initializes instance variables
 * @param s  filename
 * @param pos  imageID  Position in array.
 * @param tot  imTot  Total number of images.
 * @param ptr  pointer to volume
 * @param f  frame number
 * @param ss  series number
 * @param hello  flag to indicate remote bonjour file
 * @param iO  coreData image Entity for image
 */
- (id) myinit:(NSString*) s :(long) pos :(long) tot :(float*) ptr :(long) f :(long) ss isBonjour:(BOOL) hello imageObj: (NSManagedObject*) iO;
- (id) initWithPath:(NSString*) s :(long) pos :(long) tot :(float*) ptr :(long) f :(long) ss isBonjour:(BOOL) hello imageObj: (NSManagedObject*) iO;

/** init with data pointer
 * @param im  pointer to image data
 * @param pixelSize  pixelDepth in bits
 * @param xDim  image width
 * @param yDim =image height
 * @param xSpace  pixel width
 * @param ySpace  pxiel height
 * @param oX x position of origin
 * @param oY y position of origin
 * @param oZ z position of origin
 */
- (id) initwithdata :(float*) im :(short) pixelSize :(long) xDim :(long) yDim :(float) xSpace :(float) ySpace :(float) oX :(float) oY :(float) oZ;
- (id) initWithData :(float*) im :(short) pixelSize :(long) xDim :(long) yDim :(float) xSpace :(float) ySpace :(float) oX :(float) oY :(float) oZ;

/** init with data pointer
 * @param im = pointer to image data
 * @param pixelSize = pixelDepth in bits
 * @param xDim  image width
 * @param yDim  image height
 * @param xSpace  pixel width
 * @param ySpace  pxiel height
 * @param oX x position of origin
 * @param oY y position of origin
 * @param oZ z position of origin
 * @param volSize ?
 */
- (id) initwithdata :(float*) im :(short) pixelSize :(long) xDim :(long) yDim :(float) xSpace :(float) ySpace :(float) oX :(float) oY :(float) oZ :(BOOL) volSize;
- (id) initWithData :(float*) im :(short) pixelSize :(long) xDim :(long) yDim :(float) xSpace :(float) ySpace :(float) oX :(float) oY :(float) oZ :(BOOL) volSize;

+ (id) dcmPixWithImageObj: (DicomImage*) image;
- (id) initWithImageObj: (DicomImage *) image;

- (id) initWithContentsOfFile: (NSString *)file;
/** Compute slicelocation according to pixelSpacing values, slice origin and slice orientation: the location is the center of the slice */
- (void) computeSliceLocation;

/** Load the DICOM image. There should be no reason to call this. The class will call it when needed. */
#ifndef OSIRIX_LIGHT
/** Reads the file through DCMTK (+[DCMObject objectWithContentsOfFile:]) and fills the pixels and geometry. */
- (BOOL)loadDICOMWithDCMTK;
/** The former name of -loadDICOMWithDCMTK, kept for plugins; the DCM Framework parser is no longer behind it. */
#endif

/** Papyrus is no longer part of Horos: always returns NO. Kept for plugins. */
- (BOOL) loadDICOMPapyrus;



/** Parses the file. Extracts necessary data. Load image data.
 * This class will be called by the class when necessay.
 * There should be no need to call it externally
 */
- (void) CheckLoadIn;

/** Calls CheckLoadIn when needed */
- (void) CheckLoad;
- (BOOL) isLoaded;
/** The cache key for the parsed source file: its path and its file revision, so a
    replaced or reused path never serves the previous file. Falls back to the path. */
- (NSString*) parsedFileCacheKey;
/** HorosFileRevision of the source file at the time fImage was decoded, or nil. */
- (id) loadedFileRevision;
/** NO when the source file changed on disk (rewritten, replaced or removed) since fImage was decoded. */
- (BOOL) loadedFileMatchesDisk;

/** How many frames this process has actually decoded, over every DCMPix.
    Instrumentation only: it counts the body of CheckLoadIn that reads pixels,
    so a caller can prove that showing a frame and computing its window share
    one decode. */
+ (unsigned long long) decodedFrameCount;
+ (void) resetDecodedFrameCount;

-(void) CheckLoadFromThread:(NSThread*) loadingThread;

/** Sets fusion paramaters
 * @param m  stack mode
 * @param s stack
 * @param direction stack direction
 */
- (void) setFusion:(short) m :(short) s :(short) direction;

/** Sets updateToBeApplied to YES. It is called whenver a setting has been changed.
 * Should be called by the class automatically when needed */
- (void) setUpdateToApply;


/** Releases the fImage and sets all values to nil. */
- (void) revert;
- (void) revert:(BOOL) reloadAnnotations;

/** Sets flag for when OsiriX is running in protected mode */
+ (void) setRunOsiriXInProtectedMode:(BOOL) v;

/** Returns flag for protected mode */
+ (BOOL) isRunOsiriXInProtectedModeActivated;

/** Releases this image's share of the parsed-file cache */
- (void) releaseParsedFile;

+ (void) purgeCachedDictionaries;




@end

/** The objects these hand in and out are the objects themselves, never copies,
 so they are Objective-C (DCMPix+CAPI.m): Swift would take and give the [Any]
 or Data it bridges an NSArray or NSData to. The series the image is in is kept
 without being retained, since the list holds the image, and a copy of a
 mutable list would be released at once; the transfer function's table is
 told apart from another by the object. */
@interface DCMPix (Unbridged)
@property(nonatomic, retain) NSData *transferFunction;
@property(readonly) NSArray *pixArray;
- (void) setArrayPix :(NSArray*) array :(NSInteger) i;
@end

// The ROI rasterization, measures, masks and fills, implemented in Swift.
#import "DCMPix+ROI.h"

// The reading of the formats that are not DICOM, implemented in Swift.
#import "DCMPix+NonDICOM.h"

// The database links, the custom annotations, the ROIs of an RT STRUCT and the
// geometry, implemented in Swift.
#import "DCMPix+Database.h"
#import "DCMPix+Annotations.h"
#import "DCMPix+RTStruct.h"
#import "DCMPix+Geometry.h"

// The display image: the 8-bit picture, the thick slab, the shutter and the
// thumbnail, implemented in Swift.
#import "DCMPix+Display.h"

#endif
