//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import <Foundation/Foundation.h>

// The storage of the instance variables of the former Horos and OsiriX plugin
// SDK that were C arrays inside the object. A plugin built for that SDK reads
// and writes such an array at the offset its class exported for it, so the
// array stays inside the instance, as one field: Swift has no fixed-size array
// to declare it with, and takes each of these structs as an opaque value of
// the same size and alignment. Objects kept in them are not retained by the
// struct: who stores one keeps the ownership the SDK's class had.

/// -[ViewerController pixList]: one list of images per time point of a 4D
/// series. The SDK declared NSMutableArray *pixList[MAX4D] with MAX4D 500
/// (older copies of its headers, 200, which this covers). The slots are
/// untyped pointers: Swift would import an array of __unsafe_unretained object
/// pointers as strong references and release the slots still set when the
/// object dies.
typedef struct { void * _Nullable v[500]; } IsiXViewerPixListStorage;
_Static_assert(sizeof(IsiXViewerPixListStorage) == 500 * sizeof(void *), "pixList keeps 500 slots");

// DCMPix

/// The row and column directions of an image and their normal: orientation,
/// declared double[9].
typedef struct { double v[9]; } IsiXDCMPixOrientation;
_Static_assert(sizeof(IsiXDCMPixOrientation) == 9 * sizeof(double), "an orientation keeps nine doubles");

/// The convolution kernel of an image, up to five by five: kernel, declared
/// float[25].
typedef struct { float v[25]; } IsiXDCMPixKernel;
_Static_assert(sizeof(IsiXDCMPixKernel) == 25 * sizeof(float), "a kernel keeps 25 floats");

/// referenceCoordinates, declared float[4].
typedef struct { float v[4]; } IsiXDCMPixReferenceCoordinates;
_Static_assert(sizeof(IsiXDCMPixReferenceCoordinates) == 4 * sizeof(float), "the reference coordinates keep four floats");

/// One number for each of the 16 overlays of an image: oRows, oColumns,
/// oType, oBits and oBitPosition, each declared int[16].
typedef struct { int v[16]; } IsiXDCMPixOverlayNumbers;
_Static_assert(sizeof(IsiXDCMPixOverlayNumbers) == 16 * sizeof(int), "the overlays keep 16 numbers");

/// The origin of each overlay, x then y: oOrigin, declared int[16][2].
typedef struct { int v[16][2]; } IsiXDCMPixOverlayOrigins;
_Static_assert(sizeof(IsiXDCMPixOverlayOrigins) == 32 * sizeof(int), "the overlays keep 16 origins of two numbers");

/// The bitmap of each overlay, which the image frees: oData, declared
/// unsigned char *[16].
typedef struct { unsigned char * _Nullable v[16]; } IsiXDCMPixOverlayBitmaps;
_Static_assert(sizeof(IsiXDCMPixOverlayBitmaps) == 16 * sizeof(unsigned char *), "the overlays keep 16 bitmaps");

/// Whether each overlay is shown: overlaysChannelON, declared BOOL[16].
typedef struct { BOOL v[16]; } IsiXDCMPixOverlayFlags;
_Static_assert(sizeof(IsiXDCMPixOverlayFlags) == 16 * sizeof(BOOL), "the overlays keep 16 flags");

// DICOMExport

/// The row and column directions of the image to write: orientation, declared
/// float[6]. Its position, float[3], is a triple.
typedef struct { float v[6]; } IsiXDICOMExportOrientation;
_Static_assert(sizeof(IsiXDICOMExportOrientation) == 6 * sizeof(float), "an orientation keeps six floats");

// DCMView

/// A table of 256 bytes: alphaTable, opaqueTable, redTable, greenTable and
/// blueTable, each declared unsigned char[256]. -[DCMView getCLUT:::] and its
/// siblings hand out the address of the array inside the view.
typedef struct { unsigned char v[256]; } IsiXDCMViewByteTable;
_Static_assert(sizeof(IsiXDCMViewByteTable) == 256, "a table keeps 256 bytes");

/// The two ends of a reference line: sliceFromTo, sliceFromToS, sliceFromToE
/// and sliceFromTo2, each declared float[2][3].
typedef struct { float v[2][3]; } IsiXDCMViewLineEnds;
_Static_assert(sizeof(IsiXDCMViewLineEnds) == 6 * sizeof(float), "a line keeps two points of three floats");

/// A direction or a point of the patient's space: sliceVector, slicePoint3D,
/// mprVector and mprPoint, each declared float[3].
typedef struct { float v[3]; } IsiXDCMViewTriple;
_Static_assert(sizeof(IsiXDCMViewTriple) == 3 * sizeof(float), "a triple keeps three floats");

/// The glyph widths of an OpenGL font's display lists: fontListGLSize and
/// labelFontListGLSize, each declared long[256]. Nothing draws with them now.
typedef struct { long v[256]; } IsiXDCMViewGlyphWidths;
_Static_assert(sizeof(IsiXDCMViewGlyphWidths) == 256 * sizeof(long), "the widths keep 256 longs");

// ThickSlabVR

/// A table of the thick slab's composite, one value per level: tableFloatR,
/// tableFloatG, tableFloatB, their three tableBlendingFloat siblings and
/// opacityTable, each declared float[256].
typedef struct { float v[256]; } IsiXThickSlabTable;
_Static_assert(sizeof(IsiXThickSlabTable) == 256 * sizeof(float), "a table keeps 256 floats");

// VRController

/// One object per time point of a 4D series: pixList and roiVolumes, declared
/// NSMutableArray *[MAX4D], and volumeData, NSData *[MAX4D], with MAX4D 500
/// (older copies of the SDK's headers, 100, which this covers). The slots are
/// untyped pointers, as those of the 2D viewer's lists are and for the same
/// reason; the window retains what it stores in one and releases it.
typedef struct { void * _Nullable v[500]; } IsiXVRControllerFrameObjects;
_Static_assert(sizeof(IsiXVRControllerFrameObjects) == 500 * sizeof(void *), "the window keeps 500 slots");

/// The copy of each time point's volume that Undo puts back, which the window
/// frees: undodata, declared float *[MAX4D].
typedef struct { float * _Nullable v[500]; } IsiXVRControllerUndoVolumes;
_Static_assert(sizeof(IsiXVRControllerUndoVolumes) == 500 * sizeof(float *), "the window keeps 500 undo volumes");

// VRView

/// A point or a direction in floats: flyToDestination and Oval2DPosition,
/// each declared float[3].
typedef struct { float v[3]; } IsiXVRViewFloatTriple;
_Static_assert(sizeof(IsiXVRViewFloatTriple) == 3 * sizeof(float), "a triple keeps three floats");

/// The row and column directions of a volume and their normal: cosines,
/// blendingcosines and Oval2DCos, each declared float[9].
typedef struct { float v[9]; } IsiXVRViewCosines;
_Static_assert(sizeof(IsiXVRViewCosines) == 9 * sizeof(float), "the cosines keep nine floats");

/// The red, green and blue of each level of a volume, and one level more:
/// table and blendingtable, each declared double[257][3].
typedef struct { double v[257][3]; } IsiXVRViewColourTable;
_Static_assert(sizeof(IsiXVRViewColourTable) == 257 * 3 * sizeof(double), "a colour table keeps 257 colours");

/// The opacity of each level, and one level more: alpha, declared double[257].
typedef struct { double v[257]; } IsiXVRViewOpacityTable;
_Static_assert(sizeof(IsiXVRViewOpacityTable) == 257 * sizeof(double), "an opacity table keeps 257 values");

/// The text of the window level and width: WLWWString, declared char[200].
typedef struct { char v[200]; } IsiXVRViewWindowText;
_Static_assert(sizeof(IsiXVRViewWindowText) == 200, "the window text keeps 200 bytes");

/// A point or a direction of the scene: camPosition, camFocal and
/// lineMeasurementDirection, each declared double[3].
typedef struct { double v[3]; } IsiXVRViewPoint;
_Static_assert(sizeof(IsiXVRViewPoint) == 3 * sizeof(double), "a point keeps three doubles");

/// The two ends of a measured line: lineMeasurementWorld, declared
/// double[2][3].
typedef struct { double v[2][3]; } IsiXVRViewLineEnds;
_Static_assert(sizeof(IsiXVRViewLineEnds) == 6 * sizeof(double), "a line keeps two points");

/// The three points of a measured angle, a point a row:
/// angleMeasurementPatient, declared double[3][3].
typedef struct { double v[3][3]; } IsiXVRViewAnglePoints;
_Static_assert(sizeof(IsiXVRViewAnglePoints) == 9 * sizeof(double), "an angle keeps three points");

/// Oval2DPixZBufferOrigin, declared int[2].
typedef struct { int v[2]; } IsiXVRViewPixelOrigin;
_Static_assert(sizeof(IsiXVRViewPixelOrigin) == 2 * sizeof(int), "an origin keeps two numbers");

/// The four orientation labels of the view and one more: oText, declared as
/// five pointers to C++ objects, which the view does not make any more.
typedef struct { void * _Nullable v[5]; } IsiXVRViewTextActors;
_Static_assert(sizeof(IsiXVRViewTextActors) == 5 * sizeof(void *), "the labels keep five pointers");

// Surfaces and 3D: FlyAssistant and SRView

/// The two transforms of the fly-through assistant between the image and the
/// world: im2wordTransformMatrix and word2imTransformMatirx.
typedef struct { float v[4][4]; } IsiXFlyAssistantTransform;
_Static_assert(sizeof(IsiXFlyAssistantTransform) == 16 * sizeof(float), "a transform keeps four rows of four floats");

/// The plane of the assistant's cross section, two vectors: sampleMetric.
typedef struct { float v[2][3]; } IsiXFlyAssistantSampleMetric;
_Static_assert(sizeof(IsiXFlyAssistantSampleMetric) == 6 * sizeof(float), "the plane keeps two vectors of three floats");

/// The four orientation labels of the surface view: oText, declared as four
/// pointers to C++ objects, which the view does not make any more.
typedef struct { void * _Nullable v[4]; } IsiXSRViewTextActors;
_Static_assert(sizeof(IsiXSRViewTextActors) == 4 * sizeof(void *), "the labels keep four pointers");

/// The orientation of the series and of the fused series in the surface view:
/// cosines and blendingcosines.
typedef struct { float v[9]; } IsiXSRViewCosines;
_Static_assert(sizeof(IsiXSRViewCosines) == 9 * sizeof(float), "the cosines keep nine floats");

/// The position and the focal point of the camera the surface view keeps for
/// its exports: camPosition and camFocal.
typedef struct { double v[3]; } IsiXSRViewPoint;
_Static_assert(sizeof(IsiXSRViewPoint) == 3 * sizeof(double), "a point keeps three doubles");

/// One object of the pipeline of each of the two surfaces of a series: the
/// iso and Biso arrays, declared as two pointers to C++ objects, which the
/// view does not make any more.
typedef struct { void * _Nullable v[2]; } IsiXSRViewSurfacePair;
_Static_assert(sizeof(IsiXSRViewSurfacePair) == 2 * sizeof(void *), "a pair keeps two pointers");

/// What each of the two surfaces of a series was built with: isoGeometry and
/// BisoGeometry.
typedef struct { float v[2][6]; } IsiXSRViewSurfaceGeometry;
_Static_assert(sizeof(IsiXSRViewSurfaceGeometry) == 12 * sizeof(float), "the geometry keeps six floats for each surface");

/// How long each of the two surfaces took to build: isoBuildSeconds.
typedef struct { NSTimeInterval v[2]; } IsiXSRViewBuildSeconds;
_Static_assert(sizeof(IsiXSRViewBuildSeconds) == 2 * sizeof(NSTimeInterval), "the times keep two intervals");

// End of surfaces and 3D

// Older headers: 3D

/// The shadows of the four orientation labels of the volume view: oTextS,
/// which older copies of the SDK's headers declared after oText as four of
/// what they named a pointer to a C++ object. The view makes none.
typedef struct { void * _Nullable v[4]; } IsiXVRViewLabelShadows;
_Static_assert(sizeof(IsiXVRViewLabelShadows) == 4 * sizeof(void *), "the shadows keep four pointers");

/// The bounds the cropping box of the volume view started with:
/// initialCroppingBoxBounds, declared double[6] by older copies of the SDK's
/// headers. Nothing computes them now.
typedef struct { double v[6]; } IsiXVRViewBoxBounds;
_Static_assert(sizeof(IsiXVRViewBoxBounds) == 6 * sizeof(double), "the bounds keep six doubles");

// End of older headers: 3D

// The tables of a DCMView as it starts

/// The table a view starts its colours with: each level drawn as itself.
static inline IsiXDCMViewByteTable IsiXDCMViewIdentityTable(void) {
    IsiXDCMViewByteTable table;
    for (int i = 0; i < 256; i++) table.v[i] = (unsigned char)i;
    return table;
}

/// The table a view starts its opacities with: every level opaque.
static inline IsiXDCMViewByteTable IsiXDCMViewOpaqueTable(void) {
    IsiXDCMViewByteTable table;
    memset(table.v, 0xFF, sizeof(table.v));
    return table;
}

// QueryController (BrowserController declared no array)

/// The seconds left before each automatic query of the window runs again:
/// autoQueryRemainingSecs, declared int[MAXINSTANCE] with MAXINSTANCE 40.
typedef struct { int v[40]; } IsiXQueryControllerCountdowns;
_Static_assert(sizeof(IsiXQueryControllerCountdowns) == 40 * sizeof(int), "the countdowns keep forty numbers");

// DicomDatabase

/// A folder of the database as the file system writes it, which the threads of
/// the DICOM listener read: baseDirPathC, incomingDirPathC and tempDirPathC,
/// each declared char[4096].
typedef struct { char v[4096]; } IsiXDicomDatabaseDirectoryPath;
_Static_assert(sizeof(IsiXDicomDatabaseDirectoryPath) == 4096, "a path of the database keeps 4096 bytes");

// Older headers: network, portal and database

/// The request the list of sources was sending to a shared database:
/// messageToRemoteService of BonjourBrowser, declared char[256].
typedef struct { char v[256]; } IsiXBonjourBrowserMessage;
_Static_assert(sizeof(IsiXBonjourBrowserMessage) == 256, "a request keeps 256 bytes");

/// One transfer of the DICOM listener as its log was told of it, which
/// logFiles of OsiriXSCPDataHandler pointed to, one for each file of a move.
/// The handler makes none; the type is here for the pointer to have its own.
typedef struct {
    char logPatientName[1024];
    char logStudyDescription[1024];
    char logCallingAET[1024];
    time_t logStartTime;
    char logMessage[1024];
    char logUID[1024];
    long logNumberReceived;
    long logNumberTotal;
    time_t logEndTime;
    char logType[1024];
    char logEncoding[1024];
} logStruct;

// End of older headers: network, portal and database

// Older headers: viewer, ROI, DCMPix and dataset

/// A line of a ROI's label as C text: line1 to line6, each declared
/// char[1024] by the later of the older copies of the SDK's header that have
/// them (the earlier ones, char[256], which this covers). Nothing writes them
/// now: the lines of a label are strings.
typedef struct { char v[1024]; } IsiXROILabelLineText;
_Static_assert(sizeof(IsiXROILabelLineText) == 1024, "a line of a label keeps 1024 bytes");

// End of older headers: viewer, ROI, DCMPix and dataset

// Older headers: database window and utilities

/// A folder of the local database as the file system writes it, inside the
/// database window: cfixedDocumentsDirectory, cfixedIncomingDirectory,
/// cfixedTempNoIndexDirectory and cfixedIncomingNoIndexDirectory of
/// BrowserController, each declared char[4096] by the later of the older
/// copies of the SDK's header (the earlier ones, char[1024], which this
/// covers). The window writes them from the paths of the database.
typedef struct { char v[4096]; } IsiXBrowserDirectoryPath;
_Static_assert(sizeof(IsiXBrowserDirectoryPath) == 4096, "a path of the window keeps 4096 bytes");

/// The visible frame of each screen as the database window once kept them:
/// visibleScreenRect of BrowserController, declared NSRect[40]. Nothing
/// writes it now: a frame is asked of the screen when a window is placed.
typedef struct { NSRect v[40]; } IsiXBrowserScreenRects;
_Static_assert(sizeof(IsiXBrowserScreenRects) == 40 * sizeof(NSRect), "the screens keep forty frames");

// End of older headers: database window and utilities
