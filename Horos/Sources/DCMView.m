#include <limits.h>
/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import "DCMAbstractSyntaxUID.h"
#import "DCMView.h"
#import "Horos-Swift.h"
#import "PlanarHostBridge.h"
#import "ScrollPositionPreview.h"
#import "PatientCrosshairBridge.h"
#import "DCMPix.h"
#import "ROI.h"
#import "DCMCursor.h"
#import "DICOMExport.h"
#import "SeriesView.h"
#import "ViewerController.h"
#import "ThickSlabController.h"
#import "BrowserController.h"
#import "AppController.h"
#import "OrthogonalMPRController.h"
#import "OrthogonalMPRView.h"
#import "OrthogonalMPRPETCTView.h"
#import "ROIWindow.h"
#import "ToolbarPanel.h"
#import "ThumbnailsListPanel.h"
#import "NSUserDefaultsController+OsiriX.h"
#import "DicomStudy.h"
#import "DicomSeries.h"
#import "DicomImage.h"
#import "ROICanvasGL.h"
#import <CoreVideo/CoreVideo.h>
#import "DefaultsOsiriX.h"
#import "Notifications.h"
#import "PluginManager.h"
#import "N2Debug.h"
#import "OSIEnvironment.h"
#import "OSIEnvironment+Private.h"
#import "DCMWaveform.h"
#import "DicomDatabase.h"
#import "NSFileManager+N2.h"
#import <QuartzCore/QuartzCore.h>

// kvImageHighQualityResampling
#define QUALITY kvImageNoFlags

#define BS 10.
//#define new_loupe

short						syncro = syncroLOC;
static		double						deg2rad = M_PI / 180.0;
static		unsigned char				*PETredTable = nil, *PETgreenTable = nil, *PETblueTable = nil;
static		BOOL						NOINTERPOLATION = NO, SOFTWAREINTERPOLATION = NO, IndependentCRWLWW, pluginOverridesMouse = NO;  // Allows plugins to override mouse click actions.
BOOL						FULL32BITPIPELINE = NO, gDontListenToSyncMessage = NO;
BOOL                        OVERFLOWLINES = NO;
int							CLUTBARS, MAXNUMBEROF32BITVIEWERS = 4, SOFTWAREINTERPOLATION_MAX, DISPLAYCROSSREFERENCELINES = YES;
static		BOOL						gClickCountSet = NO, avoidSetWLWWRentry = NO, gInvertColors = NO;
static		NSDictionary				*_hotKeyDictionary = nil, *_hotKeyModifiersDictionary = nil;
static		NSRecursiveLock				*drawLock = nil;

__attribute__((used)) NSString * const HorosPasteboardType = @"com.opensource.horos";
__attribute__((used)) NSString * const HorosPasteboardTypePlugin = @"com.opensource.horos.plugin";

NSString * const pasteBoardOsiriX = @"OsiriX pasteboard"; // deprecated
NSString * const pasteBoardOsiriXPlugin = @"OsiriXPluginDataType"; // deprecated
NSString * const OsirixPluginPboardUTI = @"com.opensource.osirix.plugin.uti"; // deprecated
NSString * const pasteBoardHoros = @"Horos pasteboard"; // deprecated
NSString * const HorosPboardUTI = @"com.opensource.horos.uti"; // deprecated
NSString * const pasteBoardHorosPlugin = @"HorosPluginDataType"; // deprecated
NSString * const HorosPluginPboardUTI = @"com.opensource.horos.plugin.uti"; // deprecated

// intersect3D_SegmentPlane(): intersect a segment and a plane
//    Input:  S = a segment, and Pn = a plane = {Point V0; Vector n;}
//    Output: *I0 = the intersect point (when it exists)
//    Return: 0 = disjoint (no intersection)
//            1 = intersection in the unique point *I0
//            2 = the segment lies in the plane

#define SMALL_NUM  0.00000001 // anything that avoids division overflow
#define DOT(v1,v2) (v1[0]*v2[0]+v1[1]*v2[1]+v1[2]*v2[2])

int intersect3D_SegmentPlane( float *P0, float *P1, float *Pnormal, float *Ppoint, float* resultPt )
{
    float    u[ 3];
    float    w[ 3];
    
    u[ 0]  = P1[ 0] - P0[ 0];
    u[ 1]  = P1[ 1] - P0[ 1];
    u[ 2]  = P1[ 2] - P0[ 2];
    
    w[ 0] =  P0[ 0] - Ppoint[ 0];
    w[ 1] =  P0[ 1] - Ppoint[ 1];
    w[ 2] =  P0[ 2] - Ppoint[ 2];
    
    float     D = DOT(Pnormal, u);
    float     N = -DOT(Pnormal, w);
    
    if (fabs(D) < SMALL_NUM) {          // segment is parallel to plane
        if (N == 0)                     // segment lies in plane
            return 0;
        else
            return 0;                   // no intersection
    }
    
    // they are not parallel
    // compute intersect param
    
    float sI = N / D;
    if (sI < 0 || sI > 1)
        return 0;						// no intersection
    
    resultPt[ 0] = P0[ 0] + sI * u[ 0];		// compute segment intersect point
    resultPt[ 1] = P0[ 1] + sI * u[ 1];
    resultPt[ 2] = P0[ 2] + sI * u[ 2];
    
    if( D > 0) return 1;
    else return 2;
}


#define CROSS(dest,v1,v2) \
dest[0]=v1[1]*v2[2]-v1[2]*v2[1]; \
dest[1]=v1[2]*v2[0]-v1[0]*v2[2]; \
dest[2]=v1[0]*v2[1]-v1[1]*v2[0];

#define DOT(v1,v2) (v1[0]*v2[0]+v1[1]*v2[1]+v1[2]*v2[2])

#define SUB(dest,v1,v2) dest[0]=v1[0]-v2[0]; \
dest[1]=v1[1]-v2[1]; \
dest[2]=v1[2]-v2[2];

void Normalise(XYZ *p)
{
    double length;
    
    length = sqrt(p->x * p->x + p->y * p->y + p->z * p->z);
    if (length != 0) {
        p->x /= length;
        p->y /= length;
        p->z /= length;
    } else {
        p->x = 0;
        p->y = 0;
        p->z = 0;
    }
}

XYZ ArbitraryRotate(XYZ p,double theta,XYZ r)
{
    XYZ q = {0.0,0.0,0.0};
    double costheta,sintheta;
    
    Normalise(&r);
    
    costheta = cos(theta);
    sintheta = sin(theta);
    
    q.x += (costheta + (1.0 - costheta) * r.x * r.x) * p.x;
    q.x += ((1.0 - costheta) * r.x * r.y - r.z * sintheta) * p.y;
    q.x += ((1.0 - costheta) * r.x * r.z + r.y * sintheta) * p.z;
    
    q.y += ((1.0 - costheta) * r.x * r.y + r.z * sintheta) * p.x;
    q.y += (costheta + (1.0 - costheta) * r.y * r.y) * p.y;
    q.y += ((1.0 - costheta) * r.y * r.z - r.x * sintheta) * p.z;
    
    q.z += ((1.0 - costheta) * r.x * r.z - r.y * sintheta) * p.x;
    q.z += ((1.0 - costheta) * r.y * r.z + r.x * sintheta) * p.y;
    q.z += (costheta + (1.0 - costheta) * r.z * r.z) * p.z;
    
    return(q);
}

short intersect3D_2Planes( float *Pn1, float *Pv1, float *Pn2, float *Pv2, float *u, float *iP)
{
    CROSS(u, Pn1, Pn2);         // cross product -> perpendicular vector
    
    float    ax = (u[0] >= 0 ? u[0] : -u[0]);
    float    ay = (u[1] >= 0 ? u[1] : -u[1]);
    float    az = (u[2] >= 0 ? u[2] : -u[2]);
    
    
    if( [DCMView angleBetweenVector: Pn1 andVector:Pn2] < [[NSUserDefaults standardUserDefaults] floatForKey: @"PARALLELPLANETOLERANCE"])
        return -1;
    
    // Pn1 and Pn2 intersect in a line
    // first determine max abs coordinate of cross product
    int maxc;                      // max coordinate
    if (ax > ay)
    {
        if (ax > az)
            maxc = 1;
        else
            maxc = 3;
    }
    else
    {
        if (ay > az)
            maxc = 2;
        else
            maxc = 3;
    }
    
    // next, to get a point on the intersect line
    // zero the max coord, and solve for the other two
    
    float    d1, d2;            // the constants in the 2 plane equations
    d1 = -DOT(Pn1, Pv1); 		// note: could be pre-stored with plane
    d2 = -DOT(Pn2, Pv2); 		// ditto
    
    switch (maxc)
    {            // select max coordinate
        case 1:                    // intersect with x=0
            iP[0] = 0;
            iP[1] = (d2*Pn1[2] - d1*Pn2[2]) / u[0];
            iP[2] = (d1*Pn2[1] - d2*Pn1[1]) / u[0];
            break;
        case 2:                    // intersect with y=0
            iP[0] = (d1*Pn2[2] - d2*Pn1[2]) / u[1];
            iP[1] = 0;
            iP[2] = (d2*Pn1[0] - d1*Pn2[0]) / u[1];
            break;
        case 3:                    // intersect with z=0
            iP[0] = (d2*Pn1[1] - d1*Pn2[1]) / u[2];
            iP[1] = (d1*Pn2[0] - d2*Pn1[0]) / u[2];
            iP[2] = 0;
    }
    return noErr;
}


// ---------------------------------
/*
 */

static long GetNextTextureSize (long textureDimension, long maxTextureSize, Boolean textureRectangle)
{
    long targetTextureSize = maxTextureSize; // start at max texture size
    if (textureRectangle)
    {
        if (textureDimension >= targetTextureSize) // the texture dimension is greater than the target texture size (i.e., it fits)
            return targetTextureSize; // return corresponding texture size
        else
            return textureDimension; // jusr return the dimension
    }
    else
    {
        do // while we have txture sizes check for texture value being equal or greater
        {
            if (textureDimension >= targetTextureSize) // the texture dimension is greater than the target texture size (i.e., it fits)
                return targetTextureSize; // return corresponding texture size
        }
        while (targetTextureSize >>= 1); // step down to next texture size smaller
    }
    return 0; // no textures fit so return zero
}

static long GetTextureNumFromTextureDim (long textureDimension, long maxTextureSize, Boolean texturesOverlap, Boolean textureRectangle)
{
    // start at max texture size
    // loop through each texture size, removing textures in turn which are less than the remaining texture dimension
    // each texture has 2 pixels of overlap (one on each side) thus effective texture removed is 2 less than texture size
    
    long i = 0; // initially no textures
    long bitValue = maxTextureSize; // start at max texture size
    long texOverlapx2 = texturesOverlap ? 2 : 0;
    textureDimension -= texOverlapx2; // ignore texture border since we are using effective texure size (by subtracting 2 from the initial size)
    if (textureRectangle)
    {
        // count number of full textures
        while (textureDimension > (bitValue - texOverlapx2)) // while our texture dimension is greater than effective texture size (i.e., minus the border)
        {
            i++; // count a texture
            textureDimension -= bitValue - texOverlapx2; // remove effective texture size
        }
        // add one partial texture
        i++;
    }
    else
    {
        do
        {
            while (textureDimension >= (bitValue - texOverlapx2)) // while our texture dimension is greater than effective texture size (i.e., minus the border)
            {
                i++; // count a texture
                textureDimension -= bitValue - texOverlapx2; // remove effective texture size
            }
        }
        while ((bitValue >>= 1) > texOverlapx2); // step down to next texture while we are greater than two (less than 4 can't be used due to 2 pixel overlap)
        if (textureDimension > 0x0) // if any textureDimension is left there is an error, because we can't texture these small segments and in anycase should not have image pixels left
            NSLog (@"GetTextureNumFromTextureDim error: Texture to small to draw, should not ever get here, texture size remaining");
    }
    return i; // return textures counted
}

float min(float a, float b)
{
    if(a < b) return a;
    else return b;
}

float distanceNSPoint(NSPoint p1, NSPoint p2)
{
    float dx = p1.x - p2.x;
    float dy = p1.y - p2.y;
    return sqrt(dx*dx+dy*dy);
}

BOOL lineIntersectsRect(NSPoint lineStarts, NSPoint lineEnds, NSRect rect)
{
    if(NSPointInRect(lineStarts, rect) || NSPointInRect(lineEnds, rect)) return YES;
    
    if( rect.size.width == 0 || rect.size.height == 0) return NO;
    
    CGFloat width = fabs(lineStarts.x - lineEnds.x);
    CGFloat height = fabs(lineStarts.y - lineEnds.y);
    NSRect lineBoundingBox = NSMakeRect(min(lineStarts.x, lineEnds.x), min(lineStarts.y, lineEnds.y), width, height);
    
    if(NSIsEmptyRect(lineBoundingBox))
    {
        if(distanceNSPoint(lineStarts, lineEnds)<=1) // really small rect
            return NO;
        else // the line is vertical or horizontal
        {
            NSPoint midPoint;
            midPoint.x = (lineStarts.x+lineEnds.x)/2.0;
            midPoint.y = (lineStarts.y+lineEnds.y)/2.0;
            return lineIntersectsRect(lineStarts, midPoint, rect) || lineIntersectsRect(midPoint, lineEnds, rect);
        }
    }
    else if(NSIntersectsRect(lineBoundingBox, rect))
    {
        NSPoint midPoint = NSMakePoint(NSMidX(lineBoundingBox), NSMidY(lineBoundingBox));
        return lineIntersectsRect(lineStarts, midPoint, rect) || lineIntersectsRect(midPoint, lineEnds, rect);
    }
    else return NO;
}

NSInteger studyCompare(ViewerController *v1, ViewerController *v2, void *context)
{
    NSDate *d1 = [[v1 currentStudy] valueForKey:@"date"];
    NSDate *d2 = [[v2 currentStudy] valueForKey:@"date"];
    
    if( d1 == nil || d2 == nil)
    {
        NSLog( @"d1 == nil || d2 == nil : studyCompare");
        
        return NSOrderedSame;
    }
    
    return [d2 compare: d1];
}

@implementation DCMExportPlugin
- (void) finalize:(DCMObject*) dcmDst withSourceObject:(DCMObject*) dcmObject
{
    
}

- (NSString*) seriesName
{
    return nil;
}
@end

@interface DCMView (Dummy)

- (void)setFontColor:(id)dummy;

@end

@interface DCMView ()

@property(strong) DCMPix *curDCM;

@end

@implementation DCMView

@synthesize showDescriptionInLarge, curRoiList;
@synthesize drawingFrameRect;
@synthesize rectArray, studyColorR, studyColorG, studyColorB, studyDateIndex;
@synthesize flippedData, whiteBackground, timeIntervalForDrag;
@synthesize dcmPixList;
@synthesize dcmFilesList;
@synthesize dcmRoiList;
@synthesize syncSeriesIndex;
@synthesize syncRelativeDiff;
@synthesize blendingMode, blendingView, blendingFactor;
@synthesize xFlipped, yFlipped;
@synthesize stringID;
@synthesize currentTool, currentToolRight;
@synthesize curImage;
@synthesize theMatrix = matrix;
@synthesize suppressLabels = suppress_labels;
@synthesize scaleValue, rotation;
@synthesize origin;
@synthesize curDCM = _curDCM;
@synthesize dcmExportPlugin;
@synthesize mouseXPos, mouseYPos;
@synthesize contextualMenuInWindowPosX, contextualMenuInWindowPosY;
@synthesize fontGL;
@synthesize tag = _tag;
@synthesize curWW, curWL;
@synthesize rows = _imageRows, columns = _imageColumns;
@synthesize cursor;
@synthesize eraserFlag;
@synthesize drawing;
@synthesize volumicSeries;
@synthesize isKeyView, mouseDragging;
@synthesize annotationType;
@synthesize referenceLineAbsenceReason;

- (BOOL) eventToPlugins: (NSEvent*) event
{
    BOOL used = NO;
    
    for (id key in [PluginManager plugins])
    {
        if ([[[PluginManager plugins] objectForKey:key] respondsToSelector:@selector(handleEvent:forViewer:)])
            if ([[[PluginManager plugins] objectForKey:key] handleEvent:event forViewer:[self windowController]])
                used = YES;
    }
    
    return used;
}

+ (void) setDontListenToSyncMessage: (BOOL) v
{
    gDontListenToSyncMessage = v;
    
    if( gDontListenToSyncMessage == NO)
        [[[ViewerController frontMostDisplayed2DViewer] imageView] sendSyncMessage: 0];
}

+ (BOOL) intersectionBetweenTwoLinesA1:(NSPoint) a1 A2:(NSPoint) a2 B1:(NSPoint) b1 B2:(NSPoint) b2 result:(NSPoint*) r
{
    float x1 = a1.x,	y1 = a1.y;
    float x2 = a2.x,	y2 = a2.y;
    float x3 = b1.x,	y3 = b1.y;
    float x4 = b2.x,	y4 = b2.y;
    
    float d = (x1-x2)*(y3-y4) - (y1-y2)*(x3-x4);
    
    if (d == 0) return NO;
    
    float xi = ((x3-x4)*(x1*y2-y1*x2)-(x1-x2)*(x3*y4-y3*x4))/d;
    float yi = ((y3-y4)*(x1*y2-y1*x2)-(y1-y2)*(x3*y4-y3*x4))/d;
    
    float mag1 = [DCMView Magnitude: a1 : a2];
    float U1 =	(	( ( xi - x1 ) * ( x2 - x1 ) ) +
                 ( ( yi - y1 ) * ( y2 - y1 ) ) );
    U1 /= (mag1*mag1);
    
    float mag2 = [DCMView Magnitude: b1 : b2];
    float U2 =	(	( ( xi - x3 ) * ( x4 - x3 ) ) +
                 ( ( yi - y3 ) * ( y4 - y3 ) ) );
    U2 /= (mag2 * mag2);
    
    if( U1 >= 0 && U1 <= 1 && U2 >= 0 && U2 <= 1)
    {
        if( r)
        {
            r->x = xi;
            r->y = yi;
        }
        
        return YES;
    }
    
    return NO;
}

+ (float) Magnitude:( NSPoint) Point1 :(NSPoint) Point2
{
    NSPoint Vector;
    
    Vector.x = Point2.x - Point1.x;
    Vector.y = Point2.y - Point1.y;
    
    return (float)sqrt( Vector.x * Vector.x + Vector.y * Vector.y);
}

+ (int) DistancePointLine: (NSPoint) Point :(NSPoint) startPoint :(NSPoint) endPoint :(float*) Distance
{
    float   LineMag;
    float   U;
    NSPoint Intersection;
    
    LineMag = [DCMView Magnitude: endPoint : startPoint];
    
    U = ( ( ( Point.x - startPoint.x ) * ( endPoint.x - startPoint.x ) ) +
         ( ( Point.y - startPoint.y ) * ( endPoint.y - startPoint.y ) ) );
    
    U /= ( LineMag * LineMag );
    
    //    if( U < 0.0f || U > 1.0f )
    //	{
    //		NSLog(@"Distance Err");
    //		return 0;   // closest point does not fall within the line segment
    //	}
    
    Intersection.x = startPoint.x + U * ( endPoint.x - startPoint.x );
    Intersection.y = startPoint.y + U * ( endPoint.y - startPoint.y );
    
    //    Intersection.Z = LineStart->Z + U * ( endPoint->Z - LineStart->Z );
    
    *Distance = [DCMView Magnitude: Point :Intersection];
    
    return 1;
}

+ (NSString*) findWLWWPreset: (float) wl :(float) ww :(DCMPix*) pix
{
    NSDictionary *wlwwPresets = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"WLWW3"];
    
    for( NSString *key in [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"WLWW3"])
    {
        NSArray *value = [wlwwPresets objectForKey: key];
        
        if( [[value objectAtIndex: 0] floatValue] == wl && [[value objectAtIndex: 1] floatValue] == ww)
            return key;
    }
    
    if( pix)
    {
        if( wl == pix.fullwl && ww == pix.fullww) return NSLocalizedString( @"Full dynamic", nil);
        if( wl == pix.savedWL && ww == pix.savedWW) return NSLocalizedString(@"Default WL & WW", nil);
    }
    
    return NSLocalizedString( @"Other", nil);
}

+ (long) lengthOfString:( char *) cstr forFont:(long *)fontSizeArray
{
    long i = 0, temp = 0;
    
    while( cstr[ i] != 0)
    {
        temp += fontSizeArray[ cstr[ i]];
        i++;
    }
    
    return temp;
}

+(void) setDefaults
{
    
    //	[_hotKeyModifiersDictionary release];
    //	_hotKeyModifiersDictionary = [[[NSUserDefaults standardUserDefaults] objectForKey:@"HOTKEYSMODIFIERS"] retain];
    
    [_hotKeyDictionary release];
    _hotKeyDictionary = [[[NSUserDefaults standardUserDefaults] objectForKey:@"HOTKEYS"] retain];
    
    NOINTERPOLATION = [[NSUserDefaults standardUserDefaults] boolForKey:@"NOINTERPOLATION"];
    FULL32BITPIPELINE = [[NSUserDefaults standardUserDefaults] boolForKey:@"FULL32BITPIPELINE"];
    MAXNUMBEROF32BITVIEWERS = [[NSUserDefaults standardUserDefaults] integerForKey: @"MAXNUMBEROF32BITVIEWERS"];
    OVERFLOWLINES = [[NSUserDefaults standardUserDefaults] boolForKey:@"OVERFLOWLINES"];
    
    SOFTWAREINTERPOLATION = [[NSUserDefaults standardUserDefaults] boolForKey:@"SOFTWAREINTERPOLATION"];
    SOFTWAREINTERPOLATION_MAX = [[NSUserDefaults standardUserDefaults] integerForKey:@"SOFTWAREINTERPOLATION_MAX"];
    DISPLAYCROSSREFERENCELINES = [[NSUserDefaults standardUserDefaults] boolForKey:@"DisplayCrossReferenceLines"];
    
    IndependentCRWLWW = [[NSUserDefaults standardUserDefaults] boolForKey:@"IndependentCRWLWW"];
    CLUTBARS = [[NSUserDefaults standardUserDefaults] integerForKey: @"CLUTBARS"];
    
    //	int previousANNOTATIONS = ANNOTATIONS;
    //	ANNOTATIONS = [[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"];
    //
    //	BOOL reload = NO;
    //
    //	if( previousANNOTATIONS != ANNOTATIONS)
    //	{
    //		for( ViewerController *v in [ViewerController getDisplayed2DViewers])
    //		{
    //			[v refresh];
    //
    //			NSArray	*relatedViewers = [[AppController sharedAppController] FindRelatedViewers: [v pixList]];
    //			for( NSWindowController *r in relatedViewers)
    //				[[r window] display];
    //		}
    //
    //		if( reload) [[BrowserController currentBrowser] refreshMatrix: self];		// This will refresh the DCMView of the BrowserController
    //	}
    //	else
    //	{
    //		for( ViewerController *v in [ViewerController getDisplayed2DViewers])
    //		{
    //			[[[v window] contentView] setNeedsDisplay: YES];
    //		}
    //	}
}

+(void) setCLUTBARS:(int) c ANNOTATIONS:(int) a
{
    CLUTBARS = c;
    
    NSArray *viewers = [ViewerController getDisplayed2DViewers];
    
    for( ViewerController *v in viewers)
    {
        for( DCMView *vi in v.imageViews)
            vi.annotationType = a;
        
        [v refresh];
    }
}

+ (BOOL) noPropagateSettingsInSeriesForModality: (NSString*) m
{
    if( IndependentCRWLWW &&
       [[NSUserDefaults standardUserDefaults] boolForKey: [NSString stringWithFormat: @"noPropagateInSeriesFor%@", m]])
        return YES;
    else
        return NO;
}

+ (NSSize) sizeOfString:(NSString *)string forFont:(NSFont *)font
{
    if( string == nil) string = @"";
    
    NSDictionary *attr = [NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName];
    NSAttributedString *attrString = [[[NSAttributedString alloc] initWithString:string attributes:attr] autorelease];
    return [attrString size];
}

//+ (void) hideOverlayWindows
//{
//	[overlayWindows removeAllObjects];
//}
//
//+ (void) showOverlayWindows
//{
//	if( overlayWindows == nil) overlayWindows = [[NSMutableArray array] retain];
//
//	if( [overlayWindows count] == 0)
//	{
//		NSMutableArray *screens = [NSMutableArray array];
//
//		for( ViewerController *v in [ViewerController getDisplayed2DViewers])
//		{
//			if( [screens containsObject: [[v window] screen]] == NO)
//				[screens addObject: [[v window] screen]];
//		}
//
//		for( NSScreen *s in screens)
//		{
//			NSWindow *newWindow = [[[NSWindow alloc] initWithContentRect: [s visibleFrame]
//															  styleMask: NSBorderlessWindowMask
//																backing: NSBackingStoreBuffered
//																  defer: NO
//																 screen: s] autorelease];
//			// Define new window
//			[newWindow setBackgroundColor:[NSColor blackColor]];
//			[newWindow setAlphaValue:0.2];
//			[newWindow setLevel:NSScreenSaverWindowLevel-2];
//			[newWindow makeKeyAndOrderFront:nil];
//
//			[overlayWindows addObject: newWindow];
//		}
//	}
//}

- (void) computeColor
{
    if( [self is2DViewer] == NO)
        return;
    
    @try
    {
        NSArray *viewers = [[ViewerController getDisplayed2DViewers] sortedArrayUsingFunction: studyCompare context: nil];
        
        NSMutableArray *studiesArray = [NSMutableArray array];
        NSMutableDictionary *colorsStudy = [NSMutableDictionary dictionary];
        
        for( ViewerController *v in viewers)
        {
            if( [v currentStudy] && [v currentSeries])
                [studiesArray addObject: [v currentStudy]];
            
            for( DCMView *view in v.imageViews)
            {
                view.studyColorR = view.studyColorG = view.studyColorB = 0;
                view.studyDateIndex = NSNotFound;
                [view setNeedsDisplay: YES];
            }
        }
        
        if( studiesArray.count)
        {
            DicomStudy *study = [self studyObj];
            NSArray *allStudiesArray = nil;
            
            // Use the 'history' array of the browser controller, if available (with the distant studies)
            if( [[[BrowserController currentBrowser] comparativePatientUID] compare: [study patientUID] options: NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch] == NSOrderedSame && [[BrowserController currentBrowser] comparativeStudies] != nil)
                allStudiesArray = [BrowserController currentBrowser].comparativeStudies;
            else
            {
                DicomDatabase *db = [[BrowserController currentBrowser] database];
                NSPredicate *predicate = nil;
                
                // FIND ALL STUDIES of this patient
                NSString *searchString = [study valueForKey:@"patientUID"];
                
                if( [searchString length] == 0 || [searchString isEqualToString:@"0"])
                {
                    searchString = [study valueForKey:@"name"];
                    predicate = [NSPredicate predicateWithFormat: @"(name == %@)", searchString];
                }
                else predicate = [NSPredicate predicateWithFormat: @"(patientUID BEGINSWITH[cd] %@)", searchString];
                
                allStudiesArray = [db objectsForEntity:db.studyEntity predicate:predicate];
                allStudiesArray = [allStudiesArray sortedArrayUsingDescriptors: [NSArray arrayWithObject: [NSSortDescriptor sortDescriptorWithKey: @"date" ascending: NO]]];
            }
            
            allStudiesArray = [allStudiesArray valueForKey: @"studyInstanceUID"];
            NSArray *colors = ViewerController.studyColors;
            // Give a different color for each study/patient
            
            for( id study in studiesArray)
            {
                NSString *studyUID = [study valueForKey:@"studyInstanceUID"];
                
                if( [colorsStudy objectForKey: studyUID] == nil)
                {
                    NSUInteger color = [allStudiesArray indexOfObject: studyUID];
                    
                    if( color != NSNotFound)
                    {
                        if( color >= colors.count) color = colors.count-1;
                        [colorsStudy setObject: [colors objectAtIndex: color] forKey: studyUID];
                    }
                }
                
            }
            
            if( allStudiesArray.count > 1)
            {
                for( ViewerController *v in viewers)
                {
                    NSColor *boxColor = [colorsStudy objectForKey: [v studyInstanceUID]];
                    
                    for( DCMView *view in v.imageViews)
                    {
                        view.studyColorR = [boxColor redComponent];
                        view.studyColorG = [boxColor greenComponent];
                        view.studyColorB = [boxColor blueComponent];
                        view.studyDateIndex = [allStudiesArray indexOfObject: [v studyInstanceUID]];
                        [view setNeedsDisplay: YES];
                    }
                }
            }
        }
    }
    
    @catch (NSException *e)
    {
        NSLog( @"**** computeColor exception: %@", e);
    }
}

- (void) reapplyWindowLevel
{
    if( curWL != 0 && curWW != 0 && curWLWWSUVConverted != self.curDCM.SUVConverted)
    {
        if( curWLWWSUVFactor > 0)
        {
            if( curWLWWSUVConverted)
            {
                curWL /= curWLWWSUVFactor;
                curWW /= curWLWWSUVFactor;
            }
            else
            {
                curWLWWSUVFactor = 1.0;
                if( curWLWWSUVConverted && [self is2DViewer])
                    curWLWWSUVFactor = [[self windowController] factorPET2SUV];
                
                curWL *= curWLWWSUVFactor;
                curWW *= curWLWWSUVFactor;
            }
        }
        
        curWLWWSUVConverted = self.curDCM.SUVConverted;
        curWLWWSUVFactor = 1.0;
        if( curWLWWSUVConverted && [self is2DViewer])
            curWLWWSUVFactor = [[self windowController] factorPET2SUV];
    }
    
    [self.curDCM changeWLWW :curWL :curWW];
}

- (BOOL) isKeyImage
{
    BOOL result = NO;
    
    if( [[self windowController] isMemberOfClass:[ViewerController class]])
        result = [[self windowController] isKeyImage:curImage];
    
    return result;
}

- (void) updateTilingViews
{
    if( [self is2DViewer] && [[self window] isVisible])
    {
        if( [[self windowController] updateTilingViewsValue] == NO)
        {
            [[self windowController] setUpdateTilingViewsValue: YES];
            
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:curImage]  forKey:@"curImage"];
            [[NSNotificationCenter defaultCenter]  postNotificationName: OsirixDCMUpdateCurrentImageNotification object: self userInfo: userInfo];
            
            [[self windowController] setUpdateTilingViewsValue : NO];
        }
    }
}

- (DCMPix*) mergeFused
{
    float oScale = 1.0; // The back image is at full resolution
    float scaleRatio = 1.0 / [self scaleValue];
    float blendingScale = [blendingView scaleValue] * scaleRatio;
    
    DCMPix *fusedPix = [blendingView.curDCM renderWithRotation: [blendingView rotation] scale: blendingScale xFlipped: [blendingView xFlipped] yFlipped: [blendingView yFlipped]];
    DCMPix *originalPix = [self.curDCM renderWithRotation: [self rotation] scale: oScale xFlipped: [self xFlipped] yFlipped: [self yFlipped]];
    
    NSPoint oo = [blendingView origin];
    oo.x *= scaleRatio;
    oo.y *= scaleRatio;
    
    if( [blendingView xFlipped]) oo.x = - oo.x;
    if( [blendingView yFlipped]) oo.y = - oo.y;
    oo = [DCMPix rotatePoint: oo aroundPoint:NSMakePoint( 0, 0) angle: -[blendingView rotation]*deg2rad];
    
    NSPoint cc = [self origin];
    cc.x *= scaleRatio;
    cc.y *= scaleRatio;
    
    if( [self xFlipped]) cc.x = - cc.x;
    if( [self yFlipped]) cc.y = - cc.y;
    cc = [DCMPix rotatePoint: cc aroundPoint:NSMakePoint( 0, 0) angle: -[self rotation]*deg2rad];
    
    oo.x -= cc.x;
    oo.y -= cc.y;
    oo.y = -oo.y;
    
    DCMPix *newPix = [originalPix mergeWithDCMPix: fusedPix offset: oo];
    
    return newPix;
}

- (IBAction) mergeFusedImages:(id)sender
{
    BOOL applyToEntireSeries = NO;
    
    if( [blendingView volumicSeries] && [self volumicSeries]) applyToEntireSeries = YES;
    
    NSMutableArray *pixA = [NSMutableArray array];
    NSMutableArray *objA = [NSMutableArray array];
    
    NSMutableData	*newData = nil;
    
    if( applyToEntireSeries)
    {
        newData = [NSMutableData data];
        
        for( int i = 0 ; i < [dcmPixList count]; i++)
        {
            [self setIndex: i];
            [self sendSyncMessage: 1];
            [[self windowController] propagateSettings];
            
            [pixA addObject:  [self mergeFused]];
            [objA addObject: [[pixA lastObject] imageObj]];
            
            [newData appendBytes: [[pixA lastObject] fImage] length: [[pixA lastObject] pheight] * [[pixA lastObject] pwidth]*sizeof(float)];
        }
        
        for( int i = 0 ; i < [dcmPixList count]; i++)
        {
            [[pixA objectAtIndex: i] setfImage: (float*) ([newData bytes] + [[pixA lastObject] pheight] * [[pixA lastObject] pwidth]*sizeof(float) * i)];
            [[pixA objectAtIndex: i] freefImageWhenDone: NO];
        }
    }
    else
    {
        [pixA addObject:  [self mergeFused]];
        [objA addObject: [[pixA lastObject] imageObj]];
        
        newData = [NSMutableData dataWithBytes: [[pixA lastObject] fImage] length: [[pixA lastObject] pheight] * [[pixA lastObject] pwidth]*sizeof(float)];
        
        [[pixA lastObject] setfImage: (float*) [newData bytes]];
        [[pixA lastObject] freefImageWhenDone: NO];
    }
    
    [[self windowController] close];
    
    [ViewerController newWindow
     : pixA
     : objA
     : newData];
}

- (IBAction) print:(id)sender
{
    if ([self is2DViewer] == YES)
    {
        [[self windowController] print: self];
    }
    else
    {
        NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
        
        NSLog(@"Orientation %d", (int) [printInfo orientation]);
        
        NSImage *im = [self nsimage: NO];
        
        NSLog( @"w:%f, h:%f", [im size].width, [im size].height);
        
        if ([im size].height < [im size].width)
            [printInfo setOrientation: NSPaperOrientationLandscape];
        else
            [printInfo setOrientation: NSPaperOrientationPortrait];
        
        //NSRect	r = NSMakeRect( 0, 0, [printInfo paperSize].width, [printInfo paperSize].height);
        
        NSRect	r = NSMakeRect( 0, 0, [im size].width/2, [im size].height/2);
        
        NSImageView *imageView = [[NSImageView alloc] initWithFrame: r];
        
        //	r = NSMakeRect( 0, 0, [im size].width, [im size].height);
        
        //	NSWindow	*pwindow = [[NSWindow alloc]  initWithContentRect: r styleMask: NSBorderlessWindowMask backing: NSBackingStoreNonretained defer: NO];
        
        //	[pwindow setContentView: imageView];
        
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [im setScalesWhenResized:YES];
#pragma clang diagnostic pop

        [imageView setImage: im];
        [imageView setImageScaling: NSScaleProportionally];
        [imageView setImageAlignment: NSImageAlignCenter];
        
        [printInfo setVerticallyCentered:YES];
        [printInfo setHorizontallyCentered:YES];
        
        //	[printInfo setTopMargin: 0.0f];
        //	[printInfo setBottomMargin: 0.0f];
        //	[printInfo setRightMargin: 0.0f];
        //	[printInfo setLeftMargin: 0.0f];
        
        
        // print imageView
        
        [printInfo setHorizontalPagination:NSFitPagination];
        [printInfo setVerticalPagination:NSFitPagination];
        
        NSPrintOperation * printOperation = [NSPrintOperation printOperationWithView: imageView];
        
        [printOperation runOperation];
        
        //	[pwindow release];
        [imageView release];
    }
}

- (void) erase2DPointMarker
{
    display2DPoint = NSMakePoint(0,0);
}

- (void) draw2DPointMarker
{
    if( display2DPoint.x != 0 || display2DPoint.y != 0)
    {
        if( display2DPointIndex == curImage)
        {
            
            roiColor3f (0.0f, 0.5f, 1.0f);
            roiLineWidth(2.0 * self.window.backingScaleFactor);
            roiBegin(GL_LINES);
            
            float crossx, crossy;
            
            crossx = display2DPoint.x - self.curDCM.pwidth/2.;
            crossy = display2DPoint.y - self.curDCM.pheight/2.;
            
            roiVertex2f( scaleValue * (crossx - 40), scaleValue*(crossy));
            roiVertex2f( scaleValue * (crossx - 5), scaleValue*(crossy));
            roiVertex2f( scaleValue * (crossx + 40), scaleValue*(crossy));
            roiVertex2f( scaleValue * (crossx + 5), scaleValue*(crossy));
            
            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy-40));
            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy-5));
            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy+5));
            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy+40));
            roiEnd();
        }
        else
        {
            display2DPoint.x = 0;
            display2DPoint.y = 0;
        }
    }
}

- (void)drawRepulsorToolArea;
{
    
    roiEnable(GL_BLEND);
    roiDisable(GL_POLYGON_SMOOTH);
    roiDisable(GL_POINT_SMOOTH);
    roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    long i;
    
    int circleRes = 20;
    circleRes = (repulsorRadius>5) ? 30 : circleRes;
    circleRes = (repulsorRadius>10) ? 40 : circleRes;
    circleRes = (repulsorRadius>50) ? 60 : circleRes;
    circleRes = (repulsorRadius>70) ? 80 : circleRes;
    
    roiColor4f(1.0,1.0,0.0,repulsorAlpha);
    
    NSPoint pt = repulsorPosition;
    pt = [self convertPointToBacking: pt];
    
    pt.y = [self drawingFrameRect].size.height - pt.y;		// inverse Y scaling system
    
    roiBegin(GL_POLYGON);
    for(i = 0; i < circleRes ; i++)
    {
        // M_PI defined in cmath.h
        float alpha = i * 2 * M_PI /circleRes;
        roiVertex2f( pt.x + repulsorRadius*cos(alpha)*scaleValue, pt.y + repulsorRadius*sin(alpha)*scaleValue);//*self.curDCM.pixelSpacingY/self.curDCM.pixelSpacingX
    }
    roiEnd();
    roiDisable(GL_BLEND);
}

- (void)setAlphaRepulsor:(NSTimer*)theTimer
{
    if (repulsorAlpha >= 0.4) repulsorAlphaSign = -1.0;
    else if (repulsorAlpha <= 0.1) repulsorAlphaSign = 1.0;
    
    repulsorAlpha += repulsorAlphaSign*0.02;
    
    [self setNeedsDisplay:YES];
}


- (void)drawROISelectorRegion;
{
    
    roiEnable(GL_BLEND);
    roiDisable(GL_POLYGON_SMOOTH);
    roiDisable(GL_POINT_SMOOTH);
    roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    roiLineWidth( 1 * self.window.backingScaleFactor);
    
#define ROISELECTORREGION_R 0.8
#define ROISELECTORREGION_G 0.8
#define ROISELECTORREGION_B 1.0
    
    NSPoint startPt = ROISelectorStartPoint, endPt = ROISelectorEndPoint;
    
    startPt = [self convertPointToBacking: startPt];
    endPt = [self convertPointToBacking: endPt];
    
    // inside: fill
    roiColor4f(ROISELECTORREGION_R, ROISELECTORREGION_G, ROISELECTORREGION_B, 0.3);
    roiBegin(GL_POLYGON);
    roiVertex2f(startPt.x, startPt.y);
    roiVertex2f(startPt.x, endPt.y);
    roiVertex2f(endPt.x, endPt.y);
    roiVertex2f(endPt.x, startPt.y);
    roiEnd();
    
    // border
    roiColor4f(ROISELECTORREGION_R, ROISELECTORREGION_G, ROISELECTORREGION_B, 0.75);
    roiBegin(GL_LINE_LOOP);
    roiVertex2f(startPt.x, startPt.y);
    roiVertex2f(startPt.x, endPt.y);
    roiVertex2f(endPt.x, endPt.y);
    roiVertex2f(endPt.x, startPt.y);
    roiEnd();
    
    roiDisable(GL_BLEND);
}

- (void) Display3DPoint:(NSNotification*) note
{
    if( stringID == nil)
    {
        NSMutableArray	*v = [note object];
        
        if( v == dcmPixList)
        {
            display2DPoint.x = [[[note userInfo] valueForKey:@"x"] intValue];
            display2DPoint.y = [[[note userInfo] valueForKey:@"y"] intValue];
            display2DPointIndex = [[[note userInfo] valueForKey:@"z"] intValue];
            
            [self setIndex: [[[note userInfo] valueForKey:@"z"] intValue]];
            
            [self sendSyncMessage: 0];
            [self setNeedsDisplay: YES];
        }
    }
}

-(OrthogonalMPRController*) controller
{
    return nil;	// Only defined in herited classes
}

- (void) stopROIEditingForce:(BOOL) force
{
    long no;
    
    drawingROI = NO;
    for( ROI *r in curRoiList)
    {
        if( curROI != r )
        {
            if( [r ROImode] == ROI_selectedModify || [r ROImode] == ROI_drawing)
                [r setROIMode: ROI_selected];
        }
    }
    
    if( curROI )
    {
        if( [curROI ROImode] == ROI_selectedModify || [curROI ROImode] == ROI_drawing)
        {
            no = 0;
            
            // Does this ROI have alias in other views?
            for( NSArray *r in dcmRoiList)
            {
                if( [r containsObject: curROI]) no++;
            }
            
            if( no <= 1 || force == YES)
            {
                curROI.ROImode = ROI_selected;
                
                if( [curROI valid] == NO)
                {
                    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object: curROI userInfo: nil];
                    
                    @try
                    {
                        [curRoiList removeObject: curROI];
                    }
                    @catch (NSException * e) {}
                    
                    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixROIRemovedFromArrayNotification object:NULL userInfo:NULL];
                }
                
                [curROI autorelease];
                curROI = nil;
            }
        }
        else
        {
            curROI.ROImode = ROI_selected;
            [curROI autorelease];
            curROI = nil;
        }
    }
    
    if( showDescriptionInLarge)
    {
        showDescriptionInLarge = NO;
        [self switchShowDescriptionInLarge];
    }
}

- (void) stopROIEditing
{
    [self stopROIEditingForce: NO];
}

- (void) blendingPropagate
{
    if( blendingView)
    {
        blendingView.scaleValue = scaleValue;
        
        blendingView.rotation = rotation;
        [blendingView setOrigin: origin];
    }
}

- (void) roiLoadFromFilesArray: (NSArray*) filenames
{
    // Unselect all ROIs
    for( ROI *r in curRoiList) [r setROIMode: ROI_sleep];
    
    for( NSString *path in filenames)
    {
        NSArray*    roiArray = [HorosRestrictedUnarchiver unarchiveROIsWithFile: path];
        
        for( id loopItem1 in roiArray)
        {
            [loopItem1 setOriginAndSpacing:self.curDCM.pixelSpacingX :self.curDCM.pixelSpacingY :[DCMPix originCorrectedAccordingToOrientation:self.curDCM]];
            [loopItem1 setROIMode:ROI_selected];
            [loopItem1 setCurView:self];
            
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROISelectedNotification object: loopItem1 userInfo: nil];
        }
        
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"markROIImageAsKeyImage"])
        {
            if( [self is2DViewer] == YES && [self isKeyImage] == NO && [[self windowController] isPostprocessed] == NO)
                [[self windowController] setKeyImage: self];
        }
        
        [curRoiList addObjectsFromArray: roiArray];
    }
    
    [self setNeedsDisplay:YES];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    BOOL valid = NO;
    
    if ([item action] == @selector(roiSaveSelected:) || [item action] == @selector(increaseThickness:) || [item action] == @selector(decreaseThickness:))
    {
        for( ROI *r in curRoiList)
        {
            if( [r ROImode] == ROI_selected) valid = YES;
        }
    }
    else if( [item action] == @selector(copy:) && [item tag] == 1) // copy all viewers
    {
        if( [ViewerController numberOf2DViewer] > 1)
            valid = YES;
    }
    else if( [item action] == @selector(switchCopySettingsInSeries:))
    {
        valid = YES;
        [item setState: COPYSETTINGSINSERIES];
    }
    else if( [item action] == @selector(flipHorizontal:))
    {
        valid = YES;
        [item setState: xFlipped];
    }
    else if( [item action] == @selector(flipVertical:))
    {
        valid = YES;
        [item setState: yFlipped];
    }
    else if( [item action] == @selector(syncronize:))
    {
        valid = YES;
        if( [item tag] == syncro) [item setState: NSOnState];
        else [item setState: NSOffState];
    }
    else if( [item action] == @selector(mergeFusedImages:))
    {
        if( blendingView) valid = YES;
    }
    else if( [item action] == @selector(annotMenu:))
    {
        valid = YES;
        if( [item tag] == [[NSUserDefaults standardUserDefaults] integerForKey:@"ANNOTATIONS"]) [item setState: NSOnState];
        else [item setState: NSOffState];
    }
    else if( [item action] == @selector(barMenu:))
    {
        valid = YES;
        if( [item tag] == [[NSUserDefaults standardUserDefaults] integerForKey:@"CLUTBARS"]) [item setState: NSOnState];
        else [item setState: NSOffState];
    }
    else if( [item action] == @selector(increaseFontSize:) || [item action] == @selector(decreaseFontSize:))
    {
        valid = [DCMView labelFontSizeMenuItemIsEnabled: item];
    }
    else valid = YES;
    
    if( showDescriptionInLarge)
    {
        showDescriptionInLarge = NO;
        [self switchShowDescriptionInLarge];
    }
    
    return valid;
}

- (IBAction) roiSaveSelected: (id) sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    
    NSMutableArray *selectedROIs = [NSMutableArray  array];
    
    for (ROI *r in curRoiList)
    {
        if ([r ROImode] == ROI_selected)
            [selectedROIs addObject:r];
    }
    
    if ([selectedROIs count] > 0)
    {
        [panel setCanSelectHiddenExtension:NO];
        panel.allowedFileTypes = @[@"roi"];
        panel.nameFieldStringValue = [[selectedROIs objectAtIndex:0] name];
        
        [panel beginWithCompletionHandler:^(NSInteger result) {
            if (result != NSFileHandlingPanelOKButton)
                return;
            
            [NSArchiver archiveRootObject:selectedROIs toFile:panel.URL.path];
        }];
    }
    else
        NSRunCriticalAlertPanel(NSLocalizedString(@"ROIs Save Error",nil), NSLocalizedString(@"No ROI(s) selected to save!",nil) , NSLocalizedString(@"OK",nil), nil, nil);
}

- (void) roiLoadFromXML: (NSDictionary *) xml
{
    // Single ROI
    
    if( [xml valueForKey: @"Slice"])
    {
        [self setIndex: [[xml valueForKey: @"Slice"] intValue] - 1];
        
        if( [self is2DViewer] == YES)
            [[self windowController] adjustSlider];
        
        // SYNCRO
        [self sendSyncMessage: 0];
        
        [self setNeedsDisplay:YES];
    }
    
    NSArray *pointsStringArray = [xml objectForKey: @"ROIPoints"];
    
    ToolMode type = tCPolygon;
    if( [pointsStringArray count] == 2) type = tMesure;
    if( [pointsStringArray count] == 1) type = t2DPoint;
    
    ROI *roi = [[[ROI alloc] initWithType: type :self.curDCM.pixelSpacingX :self.curDCM.pixelSpacingY :[DCMPix originCorrectedAccordingToOrientation:self.curDCM]] autorelease];
    roi.name = [xml objectForKey: @"Name"];
    roi.comments = [xml objectForKey: @"Comments"];
    
    NSMutableArray *pointsArray = [NSMutableArray array];
    
    if( type == t2DPoint)
    {
        NSRect irect;
        irect.origin.x = NSPointFromString( [pointsStringArray objectAtIndex: 0] ).x;
        irect.origin.y = NSPointFromString( [pointsStringArray objectAtIndex: 0] ).y;
        [roi setROIRect:irect];
    }
    
    if( [pointsStringArray count] > 0 )
    {
        for ( int j = 0; j < [pointsStringArray count]; j++ )
        {
            MyPoint *pt = [MyPoint point: NSPointFromString( [pointsStringArray objectAtIndex: j] )];
            [pointsArray addObject: pt];
        }
        
        roi.points = pointsArray;
        roi.ROImode = ROI_selected;
        [roi setCurView:self];
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"markROIImageAsKeyImage"])
        {
            if( [self is2DViewer] == YES && [self isKeyImage] == NO && [[self windowController] isPostprocessed] == NO)
                [[self windowController] setKeyImage: self];
        }
        
        [curRoiList addObject: roi];
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROISelectedNotification object: roi userInfo: nil];
    }
}

- (IBAction) roiLoadFromXMLFiles: (NSArray*) filenames
{
    int	i;
    
    if ([[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"] == annotNone)
    {
        [[NSUserDefaults standardUserDefaults] setInteger: annotGraphics forKey: @"ANNOTATIONS"];
        [DCMView setDefaults];
    }
    
    // Unselect all ROIs
    for( ROI *r in curRoiList) [r setROIMode: ROI_sleep];
    
    for( i = 0; i < [filenames count]; i++)
    {
        NSDictionary *xml = [NSDictionary dictionaryWithContentsOfFile: [filenames objectAtIndex:i]];
        NSArray* roiArray = [xml objectForKey: @"ROI array"];
        
        if( roiArray)
        {
            for( NSDictionary *x in roiArray)
                [self roiLoadFromXML: x];
        }
        else
            [self roiLoadFromXML: xml];
    }
    
    [self setNeedsDisplay:YES];
}

- (void) undo:(id) sender
{
    [[self windowController] undo: sender];
}

- (void) redo:(id) sender
{
    [[self windowController] redo: sender];
}

#ifndef OSIRIX_LIGHT
- (void)paste:(id)sender
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSData *archived_data = [pb dataForType:@"ROIObject"];
    
    if( archived_data)
    {
        [[self windowController] addToUndoQueue:@"roi"];
        
        NSArray*	roiArray = [HorosRestrictedUnarchiver unarchiveROIsWithData: archived_data];
        
        // Unselect all ROIs
        for( ROI *r in curRoiList) [r setROIMode: ROI_sleep];
        
        NSMutableArray *planarROIs = [NSMutableArray array];
        for( ROI *r in roiArray)
        {
            if ([r isKindOfClass:HorosVolumeLengthROI.class])
            {
                NSDictionary *endpoint = [self lengthEndpointAt:NSZeroPoint];
                HorosVolumeLengthROI *physical = (HorosVolumeLengthROI*)r;
                if (![physical.volumeLength[@"series"] isEqual:endpoint[@"series"]] ||
                    ![physical.volumeLength[@"frameOfReference"] isEqual:endpoint[@"frameOfReference"]]) { NSBeep(); continue; }
                NSMutableDictionary *payload = [[physical.volumeLength mutableCopy] autorelease];
                payload[@"id"] = NSUUID.UUID.UUIDString;
                payload[@"temporalIndex"] = endpoint[@"temporalIndex"];
                physical.volumeLength = payload;
                [[self windowController] addVolumeLengthROI:physical];
                [physical setROIMode:ROI_selected];
                continue;
            }
            [planarROIs addObject:r];
            r.isAliased = NO;
            
            //Correct the origin only if the orientation is the same
            r.pix = self.curDCM;
            [r setOriginAndSpacing :self.curDCM.pixelSpacingX :self.curDCM.pixelSpacingY :[DCMPix originCorrectedAccordingToOrientation:self.curDCM]];
            
            [r setROIMode: ROI_selected];
            [r setCurView:self];
        }
        
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"markROIImageAsKeyImage"])
        {
            if( [self is2DViewer] == YES && [self isKeyImage] == NO && [[self windowController] isPostprocessed] == NO)
                [[self windowController] setKeyImage: self];
        }
        
        [curRoiList addObjectsFromArray:planarROIs];
        
        for( long i = 0 ; i < [roiArray count] ; i++) {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:[roiArray objectAtIndex: i], @"ROI",
                                      [NSNumber numberWithInt:curImage],	@"sliceNumber",
                                      //xx, @"x", yy, @"y", zz, @"z",
                                      nil];
            
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixAddROINotification object: self userInfo:userInfo];
        }
        
        
        for( long i = 0 ; i < [roiArray count] ; i++)
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROISelectedNotification object: [roiArray objectAtIndex: i] userInfo: nil];
        
        [self setNeedsDisplay:YES];
    }
    
    id winCtrl = self.windowController;
    if ([winCtrl respondsToSelector:@selector(paste:)])
        [winCtrl paste: sender];
}
#endif

-(IBAction) copy:(id) sender
{
    NSPasteboard	*pb = [NSPasteboard generalPasteboard];
    BOOL			roiSelected = NO;
    NSMutableArray  *roiSelectedArray = [NSMutableArray array];
    
    for( ROI *r in curRoiList)
    {
        if( [r ROImode] == ROI_selected)
        {
            roiSelected = YES;
            
            [roiSelectedArray addObject: r];
        }
    }
    
    if( roiSelected == NO || [sender tag])
    {
        NSImage *im;
        
        [pb declareTypes:[NSArray arrayWithObject:NSPasteboardTypeTIFF] owner:self];
        
        im = [self nsimage: NO allViewers: [sender tag]];
        
        [pb setData: [[NSBitmapImageRep imageRepWithData: [im TIFFRepresentation]] representationUsingType:NSJPEGFileType properties:[NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:0.9] forKey:NSImageCompressionFactor]] forType:NSPasteboardTypeTIFF];
    }
    else
    {
        [pb declareTypes:[NSArray arrayWithObjects:@"ROIObject", NSPasteboardTypeString, nil] owner:nil];
        [pb setData: [NSArchiver archivedDataWithRootObject: roiSelectedArray] forType:@"ROIObject"];
        
        NSMutableString *r = [NSMutableString string];
        
        for( long i = 0 ; i < [roiSelectedArray count] ; i++ )
        {
            [r appendString: [[roiSelectedArray objectAtIndex: i] description]];
            
            if( i != (long)[roiSelectedArray count]-1)
                [r appendString:@"\r"];
        }
        
        [pb setString: r  forType:NSPasteboardTypeString];
    }
}

-(IBAction) cut:(id) sender
{
    [self copy:sender];
    
    long	i;
    NSTimeInterval groupID;
    
    [[self windowController] addToUndoQueue:@"roi"];
    
    [drawLock lock];
    
    NSMutableArray *rArray = curRoiList;
    
    [rArray retain];
    
    @try
    {
        for( i = 0; i < [rArray count]; i++)
        {
            ROI *r = [rArray objectAtIndex:i];
            if( [r ROImode] == ROI_selected && r.locked == NO)
            {
                groupID = [r groupID];
                [r retain]; // the notification can release it: a mirrored 2D point's owner removes it
                [[NSNotificationCenter defaultCenter] postNotificationName:OsirixRemoveROINotification object:r userInfo: nil];
                [self removeROIFromSliceOrVolume:r];
                [r release];
                i--;
                if(groupID!=0.0)
                    [self deleteROIGroupID:groupID];
            }
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIRemovedFromArrayNotification object: nil userInfo: nil];
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [rArray autorelease];
    
    [drawLock unlock];
    
    [self setNeedsDisplay:YES];
}

- (void) setYFlipped:(BOOL) v
{
    yFlipped = v;
    
    if( [self is2DViewer] && [[self windowController] isPostprocessed] == NO)
    {
        @try {
            // Series Level
            [self.seriesObj  setValue:[NSNumber numberWithBool:yFlipped] forKey:@"yFlipped"];
            
            // Image Level
            if( (curImage >= 0 && dcmFilesList.count > curImage) && COPYSETTINGSINSERIES == NO)
                [self.imageObj setValue:[NSNumber numberWithBool:yFlipped] forKey:@"yFlipped"];
            else
                [self.imageObj setValue: nil forKey:@"yFlipped"];
        }
        @catch ( NSException *e) {
            N2LogException( e);
        }
    }
    
    [self updateTilingViews];
    
    [self setNeedsDisplay:YES];
}

- (void) setXFlipped:(BOOL) v
{
    xFlipped = v;
    
    if( [self is2DViewer] && [[self windowController] isPostprocessed] == NO)
    {
        @try {
            [self.seriesObj setValue:[NSNumber numberWithBool:xFlipped] forKey:@"xFlipped"];
            
            // Image Level
            if( (curImage >= 0 && dcmFilesList.count > curImage) && COPYSETTINGSINSERIES == NO)
                [self.imageObj setValue:[NSNumber numberWithBool:xFlipped] forKey:@"xFlipped"];
            else
                [self.imageObj setValue: nil forKey:@"xFlipped"];
        }
        @catch ( NSException *e) {
            N2LogException( e);
        }
    }
    
    [self updateTilingViews];
    
    [self setNeedsDisplay:YES];
}

- (void)flipVertical: (id)sender
{
    self.yFlipped = !yFlipped;
}

- (void)flipHorizontal: (id)sender
{
    self.xFlipped = !xFlipped;
}

- (void) DrawNSStringGL:(NSString*)str :(DCMViewFontKind)fontL :(long)x :(long)y rightAlignment:(BOOL)right useStringTexture:(BOOL)stringTex
{
    if(right)
        [self DrawNSStringGL:str :fontL :x :y align:DCMViewTextAlignRight useStringTexture:stringTex];
    else
        [self DrawNSStringGL:str :fontL :x :y align:DCMViewTextAlignLeft useStringTexture:stringTex];
}

+ (void) purgeStringTextureCache
{
    [HorosAnnotationText purgeCache];
}

// Where the canvas's current transform puts a point, in backing pixels from the
// view's top left: the annotation overlay draws text where the graphics are (#728).
static BOOL HorosAnnotationPixel(double x, double y, NSPoint *pixel)
{
    HorosROICanvas *canvas = [HorosROICanvas current];
    if( canvas == nil) return NO;
    NSPoint window = [canvas devicePointX: x y: y];
    pixel->x = round( window.x * 1024) / 1024;
    pixel->y = round( window.y * 1024) / 1024;
    return YES;
}

- (BOOL) horosAnnotationRect:(NSRect) r pixels:(NSRect*) pixels
{
    NSPoint a, b;
    if( !HorosAnnotationPixel( NSMinX( r), NSMinY( r), &a) ||
        !HorosAnnotationPixel( NSMaxX( r), NSMaxY( r), &b))
        return NO;
    *pixels = NSMakeRect( MIN( a.x, b.x), MIN( a.y, b.y), fabs( b.x - a.x), fabs( b.y - a.y));
    return YES;
}

- (void) horosDrawAnnotationBox:(HorosAnnotationBox*) box bounds:(NSRect) r
{
    NSRect pixels;
    if( box && [self horosAnnotationRect: r pixels: &pixels])
        [[HorosAnnotationOverlay overlayForView: self] addBox: box rect: pixels];
}

- (HorosAnnotationText*) horosLabelText:(NSString*) label font:(NSFont*) font
{
    return [HorosAnnotationText textForString: label font: font scale: self.window.backingScaleFactor
        cacheToken: [HorosAnnotationPresentation textureCacheTokenForWindow: self.window]];
}

- (void) horosDrawLabel:(HorosAnnotationText*) text at:(NSPoint) origin textColor:(NSColor*) textColor shadowColor:(NSColor*) shadowColor
{
    NSRect pixels;
    if( text && [self horosAnnotationRect: NSMakeRect( origin.x, origin.y, text.pixelWidth, text.pixelHeight) pixels: &pixels])
        [[HorosAnnotationOverlay overlayForView: self] addText: text x: NSMinX( pixels) y: NSMinY( pixels) textColor: textColor shadowColor: shadowColor];
}

- (void)DrawNSStringGL:(NSString*)str :(DCMViewFontKind)fontL :(long)x :(long)y align:(DCMViewTextAlign)align useStringTexture:(BOOL)stringTex;
{
    if( str == nil)
        return;
    
    float sf = self.window.backingScaleFactor;
    NSFont *textureFont = fontL == DCMViewLabelFont ? labelFont : fontGL;
    HorosAnnotationText *text = [HorosAnnotationText textForString: str font: textureFont scale: sf
        cacheToken: [HorosAnnotationPresentation textureCacheTokenForWindow: self.window]];
    NSColor *light = [NSColor colorWithDeviceRed: 1 green: 1 blue: 1 alpha: 1], *dark = [NSColor colorWithDeviceRed: 0 green: 0 blue: 0 alpha: 1];
    NSColor *textColor = whiteBackground ? dark : light, *shadowColor = whiteBackground ? light : dark;
    double left, top;
    
    if( stringTex)
    {
        if(align==DCMViewTextAlignRight) x -= text.pixelWidth;
        else if(align==DCMViewTextAlignCenter) x -= text.pixelWidth/2.0;
        else x -= 5 * sf;
        
        long xc, yc;
        xc = x+2;
        yc = y+1-text.pixelHeight;
        if( recordAnnotationRects)
        {
            NSRect occupied = NSMakeRect(xc - drawingFrameRect.size.width/2,
                yc - drawingFrameRect.size.height/2, text.pixelWidth+1, text.pixelHeight+1);
            [rectArray addObject:[NSValue valueWithRect:occupied]];
        }
        left = xc;
        top = yc;
    }
    else
    {
        // These strings were glyph bitmaps whose line started at x and sat
        // on y; the picture's line lands there instead, aligned by its own
        // width.
        if(align==DCMViewTextAlignRight)
            x -= text.stringWidth + (fontL == DCMViewLabelFont ? 2*sf : 2);
        else if(align==DCMViewTextAlignCenter)
            x -= text.stringWidth/2.0 + 2*sf;
        
        if( fontColor) shadowColor = fontColor;
        left = x - 4 * sf;
        top = y + text.lineBottom - text.pixelHeight;
    }
    
    NSRect pixels;
    if( [self horosAnnotationRect: NSMakeRect( left, top, text.pixelWidth, text.pixelHeight) pixels: &pixels])
        [[HorosAnnotationOverlay overlayForView: self] addText: text x: NSMinX( pixels) y: NSMinY( pixels) textColor: textColor shadowColor: shadowColor];
}

- (void)DrawCStringGL:(char*)cstrOut :(DCMViewFontKind)fontL :(long)x :(long)y rightAlignment:(BOOL)right useStringTexture:(BOOL)stringTex
{
    if(right)
        [self DrawCStringGL:cstrOut :fontL :x :y align:DCMViewTextAlignRight useStringTexture:stringTex];
    else
        [self DrawCStringGL:cstrOut :fontL :x :y align:DCMViewTextAlignLeft useStringTexture:stringTex];
}

- (void)DrawCStringGL:(char*)cstrOut :(DCMViewFontKind)fontL :(long)x :(long)y align:(DCMViewTextAlign)align useStringTexture:(BOOL)stringTex;
{
    [self DrawNSStringGL:[NSString stringWithUTF8String:cstrOut] :fontL :x :y align:align useStringTexture:stringTex];
}

- (void) DrawCStringGL: (char *) cstrOut :(DCMViewFontKind) fontL :(long) x :(long) y
{
    [self DrawCStringGL: (char *) cstrOut :(DCMViewFontKind) fontL :(long) x :(long) y rightAlignment: NO useStringTexture: NO];
}

- (void) DrawNSStringGL: (NSString*) cstrOut :(DCMViewFontKind) fontL :(long) x :(long) y
{
    [self DrawNSStringGL: (NSString*) cstrOut :(DCMViewFontKind) fontL :(long) x :(long) y rightAlignment: NO useStringTexture: NO];
}

- (ToolMode) currentToolRight
{
    return currentToolRight;
}

-(void) setRightTool:(ToolMode) i
{
    currentToolRight = i;
    
    if( [self is2DViewer])
        [[NSUserDefaults standardUserDefaults] setInteger:currentToolRight forKey: @"DEFAULTRIGHTTOOL"];
}

-(void) setCurrentTool:(ToolMode) i
{
    if (i != currentTool) [self cancelLengthPlacement];
    BOOL keepROITool = (i == tROISelector || i == tRepulsor || currentTool == tROISelector || currentTool == tRepulsor);
    
    keepROITool = keepROITool || [self roiTool:currentTool] || [self roiTool:i];
    currentTool = i;
    
    if( [self is2DViewer])
        [[NSUserDefaults standardUserDefaults] setInteger:currentTool forKey: @"DEFAULTLEFTTOOL"];
    
    [self stopROIEditingForce: YES];
    
    mesureA.x = mesureA.y = mesureB.x = mesureB.y = 0;
    roiRect.origin.x = roiRect.origin.y = roiRect.size.width = roiRect.size.height = 0;
    
    if( keepROITool == NO)
    {
        // Unselect previous ROIs
        for( ROI *r in curRoiList) [r setROIMode : ROI_sleep];
    }
    
    NSEvent *event = [[NSApplication sharedApplication] currentEvent];
    
    int clickCount = 1;
    @try
    {
        if( [event type] ==	NSLeftMouseDown || [event type] ==	NSRightMouseDown || [event type] ==	NSLeftMouseUp || [event type] == NSRightMouseUp)
            clickCount = [event clickCount];
    }
    @catch (NSException * e)
    {
        clickCount = 1;
    }
    
    switch( currentTool)
    {
        case tPlain:
            if ([self is2DViewer] == YES)
            {
                [[self windowController] brushTool: self];
            }
            break;
            
        case tZoom:
            if( [event type] != NSKeyDown)
            {
                if( clickCount == 2)
                {
                    [self setOriginX: 0 Y: 0];
                    self.rotation = 0.0f;
                    [self scaleToFit];
                }
                
                if( clickCount == 3)
                {
                    [self setOriginX: 0 Y: 0];
                    self.rotation = 0.0f;
                    self.scaleValue = 1.0f;
                }
            }
            break;
            
        case tRotate:
            if( [event type] != NSKeyDown)
            {
                if( clickCount == 2 && gClickCountSet == NO && isKeyView == YES && [[self window] isKeyWindow] == YES)
                {
                    gClickCountSet = YES;
                    
                    float rot = [self rotation];
                    
                    if ([event modifierFlags] & NSAlternateKeyMask) rot -= 180;		// -> 180
                    else if ([event modifierFlags] & NSShiftKeyMask) rot -= 90;	// -> 90
                    else rot += 90;	// -> 90
                    
                    self.rotation = rot;
                    
                    if( [self is2DViewer] == YES)
                        [[self windowController] propagateSettings];
                }
            }
            break;
        default:;
    }
    
    [self setCursorForView : currentTool];
    [self checkCursor];
    [self setNeedsDisplay:YES];
}

- (void) gClickCountSetReset
{
    gClickCountSet = NO;
}

- (BOOL) isScaledFit
{
    float s = [self scaleToFitForDCMPix:self.curDCM];
    
    if( origin.x != 0 && origin.y != 0)
        return NO;
    
    if( fabs( s - self.scaleValue) < 0.1)
        return YES;
    else
        return NO;
}

- (float) scaleToFitForDCMPix: (DCMPix*) d
{
    NSRect  sizeView = [self convertRectToBacking: [self bounds]]; // Retina
    
    double w = d.pwidth;
    double h = d.pheight;
    
    if( d.shutterEnabled)
    {
        w = d.shutterRect.size.width;
        h = d.shutterRect.size.height;
    }
    
    h *= d.pixelRatio;
    double radians = self.rotation * M_PI / 180.0;
    double rotatedWidth = fabs(cos(radians)) * w + fabs(sin(radians)) * h;
    double rotatedHeight = fabs(sin(radians)) * w + fabs(cos(radians)) * h;
    if (!isfinite(rotatedWidth) || !isfinite(rotatedHeight) ||
        rotatedWidth <= 0 || rotatedHeight <= 0 ||
        sizeView.size.width <= 0 || sizeView.size.height <= 0)
        return self.scaleValue > 0 ? self.scaleValue : 1;
    return MIN(sizeView.size.width / rotatedWidth, sizeView.size.height / rotatedHeight);
}

- (void) scaleToFit
{
    if( scaleToFitNoReentry) return;
    scaleToFitNoReentry = YES;
    
    self.scaleValue = [self scaleToFitForDCMPix:self.curDCM];
    
    if (self.curDCM.shutterEnabled)
    {
        origin.x = ((self.curDCM.pwidth  * 0.5f ) - (self.curDCM.shutterRect.origin.x + (self.curDCM.shutterRect.size.width  * 0.5f ))) * scaleValue;
        origin.y = -((self.curDCM.pheight * 0.5f ) - (self.curDCM.shutterRect.origin.y + (self.curDCM.shutterRect.size.height * 0.5f ))) * scaleValue * self.curDCM.pixelRatio;
    }
    else
        origin.x = origin.y = 0;
    
    [self setNeedsDisplay:YES];
    
    scaleToFitNoReentry = NO;
}

- (void) prepareForWorkspacePresentation
{
    // First draw also restores presentation. Restore it now so it cannot
    // overwrite the fit; retain its rotation, flips and WL/WW.
    if (!firstTimeDisplay)
    {
        firstTimeDisplay = YES;
        [self updatePresentationStateFromSeries];
    }
}

- (void) applyOpeningScaleToFit: (NSRect) content
{
    [self prepareForWorkspacePresentation];
    DCMPix *pix = self.curDCM;
    // Pixel analysis belongs to the loading worker. An empty result means
    // pending/uncertain series content, so opening uses the complete matrix.
    if (pix.shutterEnabled || NSIsEmptyRect(content))
    { [self scaleToFit]; return; }
    NSRect viewport = [self convertRectToBacking:self.bounds];
    double radians = self.rotation * M_PI / 180.0;
    double w = content.size.width, h = content.size.height * pix.pixelRatio;
    double rw = fabs(cos(radians)) * w + fabs(sin(radians)) * h;
    double rh = fabs(sin(radians)) * w + fabs(cos(radians)) * h;
    double fullFit = [self scaleToFitForDCMPix:pix];
    double zoom = fmin(viewport.size.width / rw, viewport.size.height / rh);
    // Avoid extreme zoom on a tiny island and insignificant changes on images
    // already occupying their matrix. All margins above stay inside the image.
    zoom = fmin(zoom, fullFit * 3);
    if (!isfinite(zoom) || rw <= 0 || rh <= 0 || zoom <= fullFit * 1.05)
    { [self scaleToFit]; return; }
    self.scaleValue = zoom;
    origin.x = (pix.pwidth * .5 - NSMidX(content)) * scaleValue;
    origin.y = (NSMidY(content) - pix.pheight * .5) * scaleValue * pix.pixelRatio;
    [self setNeedsDisplay:YES];
}

- (void) cancelOpeningScaleToFitForInteraction
{
    if ([self is2DViewer])
        [[self windowController] cancelOpeningScaleToFit];
}

- (void) setIndexWithReset:(short) index :(BOOL) sizeToFit
{
    TextureComputed32bitPipeline = NO;
    
    if( dcmPixList && index >= 0)
    {
        [[self window] setAcceptsMouseMovedEvents: YES];
        
        [curROI autorelease];
        curROI = nil;
        
        curImage = index;
        if( curImage >= [dcmPixList count]) curImage = (long)[dcmPixList count] -1;
        if( curImage < 0) curImage = 0;
        
        self.curDCM = [dcmPixList objectAtIndex: curImage];
        
        [curRoiList autorelease];
        
        if( dcmRoiList) curRoiList = [[dcmRoiList objectAtIndex: curImage] retain];
        else 			curRoiList = [[NSMutableArray alloc] initWithCapacity:0];
        
        for( ROI *r in curRoiList)
        {
            [r setCurView:self];
            [r recompute];
            // Unselect previous ROIs
            [r setROIMode : ROI_sleep];
        }
        
        curWL = self.curDCM.wl;
        curWW = self.curDCM.ww;
        curWLWWSUVConverted = self.curDCM.SUVConverted;
        curWLWWSUVFactor = 1.0;
        if( curWLWWSUVConverted && [self is2DViewer])
            curWLWWSUVFactor = [[self windowController] factorPET2SUV];
        
        origin.x = origin.y = 0;
        scaleValue = 1;
        
        //get Presentation State info from series Object
        [self updatePresentationStateFromSeries];
        
        [self.curDCM checkImageAvailble :curWW :curWL];
        
        if( sizeToFit && [self is2DViewer] == NO)
        {
            [self scaleToFit];
        }
        
        [self loadTextures];
        [self setNeedsDisplay:YES];
        
        [yearOld release];
        
        
        if( [[[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOld"] isEqualToString: [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOldAcquisition"]])
            yearOld = [[[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOld"] retain];
        else
            yearOld = [[NSString stringWithFormat:@"%@ / %@", [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOld"], [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOldAcquisition"]] retain];
        
        
        if( self.is2DViewer)
        {
            [self.windowController willChangeValueForKey: @"thicknessInMm"];
            [self.windowController didChangeValueForKey: @"thicknessInMm"];
        }
    }
    else
    {
        self.curDCM = nil;
        curImage = -1;
        [curRoiList autorelease];
        curRoiList = nil;
        
        [curROI autorelease];
        curROI = nil;
        [self loadTextures];
    }
}

- (void) setPixels: (NSMutableArray*) pixels files: (NSArray*) files rois: (NSMutableArray*) rois firstImage: (short) firstImage level: (char) level reset: (BOOL) reset
{
    [self horosDiscardScrollPreview];
    [drawLock lock];
    
    @try
    {
        if( [self is2DViewer])
        {
            currentToolRight = [[NSUserDefaults standardUserDefaults] integerForKey: @"DEFAULTRIGHTTOOL"];
            
            if( [[NSUserDefaults standardUserDefaults] boolForKey: @"RestoreLeftMouseTool"])
                currentTool =  [[NSUserDefaults standardUserDefaults] integerForKey: @"DEFAULTLEFTTOOL"];
        }
        
        self.curDCM = nil;
        
        volumicData = -1;
        
        [cleanedOutDcmPixArray release];
        cleanedOutDcmPixArray = nil;
        
        if( dcmPixList != pixels)
        {
            [self cancelLengthPlacement];
            slabScrollRemainder = 0;
            slabScrollTimestamp = 0;
            [dcmPixList release];
            dcmPixList = [pixels retain];
            
            volumicSeries = YES;
            
            if( [files count] > 0)
            {
                id sopclassuid = [[files objectAtIndex: 0] valueForKeyPath:@"series.seriesSOPClassUID"];
                if ([DCMAbstractSyntaxUID isImageStorage: sopclassuid] || [DCMAbstractSyntaxUID isRadiotherapy: sopclassuid] || [DCMAbstractSyntaxUID isStructuredReport: sopclassuid] || sopclassuid == nil)
                {
                    
                }
                else NSLog( @"*** DCMView ! ****** It's not a DICOM image ? SOP Class UID: %@", sopclassuid);
            }
            
            if( [stringID isEqualToString:@"previewDatabase"] == NO)
            {
                if( [dcmPixList count] > 1)
                {
                    if( [(DCMPix*)[dcmPixList objectAtIndex: 0] sliceLocation] == [(DCMPix*)[dcmPixList lastObject] sliceLocation]) volumicSeries = NO;
                }
                else volumicSeries = NO;
            }
        }
        
        if( dcmFilesList != files)
        {
            [dcmFilesList release];
            dcmFilesList = [files retain];
        }
        
        flippedData = NO;
        
        if( dcmRoiList != rois)
        {
            [dcmRoiList autorelease];
            dcmRoiList = [rois retain];
        }
        
        listType = level;
        
        if( dcmPixList)
        {
            if( reset)
            {
                [self setIndexWithReset: firstImage :YES];
                [self updatePresentationStateFromSeries];
            }
        }
        
        [self setNeedsDisplay:true];
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [drawLock unlock];
}

- (void) setDCM:(NSMutableArray*) c :(NSArray*)d :(NSMutableArray*)e :(short) firstImage :(char) type :(BOOL) reset
{
    [self setPixels: c files: d rois: e firstImage: firstImage level: type reset: reset];
}

- (void) dealloc
{
    [self horosDiscardScrollPreview];
    [self cancelLengthPlacement];
    [self horosInvalidatePlanar];
    NSLog(@"DCMView released");
    
    
    @try
    {
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:@"ANNOTATIONS"];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:@"LabelFONTNAME"];
        [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:@"LabelFONTSIZE"];
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    
    [self prepareToRelease];
    
    [self deleteMouseDownTimer];
    
    [matrix release];
    matrix = nil;
    
    [cursorTracking release];
    cursorTracking = nil;
    
    [drawLock lock];
    [drawLock unlock];
    
    for( ROI*r in curRoiList)
        [r prepareForRelease]; // We need to unlink the links related to OpenGLContext
    
    [curRoiList autorelease];
    curRoiList = nil;
    
    [dcmRoiList release];
    dcmRoiList = nil;
    
    @synchronized( self)
    {
        [dcmFilesList release];
        dcmFilesList = nil;
        
        [dcmPixList release];
        dcmPixList = nil;
    }
    
    self.curDCM = nil;
    
    [dcmExportPlugin release];
    dcmExportPlugin = nil;
    
    [stringID release];
    stringID = nil;
    
    self.referenceLineAbsenceReason = nil;
    
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    @try
    {
        
        if( colorBuf) free( colorBuf);
        colorBuf = nil;
        
        if( blendingColorBuf) free( blendingColorBuf);
        blendingColorBuf = nil;
        
        [fontColor release]; fontColor = nil;
        [fontGL release]; fontGL = nil;
        [labelFont release]; labelFont = nil;
        [yearOld release]; yearOld = nil;
        
        [cursor release]; cursor = nil;
        
        [_mouseDownTimer invalidate];
        [_mouseDownTimer release];
        _mouseDownTimer = nil;
        
        [destinationImage release];
        destinationImage = nil;
        
        if(repulsorColorTimer)
        {
            [repulsorColorTimer invalidate];
            [repulsorColorTimer release];
            repulsorColorTimer = nil;
        }
        
        if( resampledBaseAddr) free( resampledBaseAddr);
        resampledBaseAddr = nil;
        
        if( blendingResampledBaseAddr) free( blendingResampledBaseAddr);
        blendingResampledBaseAddr = nil;
        
        [showDescriptionInLargeText release];
        showDescriptionInLargeText = nil;
        

        
        [blendingView release];
        blendingView = nil;
        
        [self deleteLens];
        
        [loupeImage release];
        loupeImage = nil;
        
        [loupeMaskImage release];
        loupeMaskImage = nil;
        
        [studyDateBox release];
        studyDateBox = nil;
        
        [cleanedOutDcmPixArray release];
        cleanedOutDcmPixArray = nil;
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [pool release];
    
    [super dealloc];
}

- (BOOL) COPYSETTINGSINSERIES
{
    return COPYSETTINGSINSERIES;
}

- (void) setCOPYSETTINGSINSERIESdirectly: (BOOL) b
{
    COPYSETTINGSINSERIES = b;
}

// Applies a change of the propagation flag to one series' images.
//
// Turning propagation on is a flattening, and is meant to be: every image loses
// its own settings and takes the one on screen. Turning it off used to be a
// flattening too - it wrote the current window, scale, rotation, flips and
// offset onto every image in the series - so the option that exists to give each
// image its own settings began by making them all identical, and an image's own
// window could not be recovered afterwards. A heterogeneous series, where every
// image carries a different WindowCenter, showed one window from beginning to
// end whichever way the option was set.
//
// Off now means off: only the image on screen keeps what is on screen, so
// nothing changes under the user at the moment they choose it, and every other
// image is left with whatever it already had - for an untouched image, its own
// window from the file.
- (void) writeCopySettingsInSeriesForPixels:(NSArray*) pixels
{
    for( DCMPix *pix in pixels)
    {
        DicomImage *im = pix.imageObj;
        
        if( COPYSETTINGSINSERIES)
        {
            if( pix.isLoaded)
                [pix changeWLWW :curWL :curWW];
            
            [im setValue: nil forKey:@"windowWidth"];
            [im setValue: nil forKey:@"windowLevel"];
            [im setValue: nil forKey:@"scale"];
            [im setValue: nil forKey:@"rotationAngle"];
            [im setValue: nil forKey:@"yFlipped"];
            [im setValue: nil forKey:@"xFlipped"];
            [im setValue: nil forKey:@"xOffset"];
            [im setValue: nil forKey:@"yOffset"];
        }
        else if( im == self.imageObj)
        {
            [im setValue:[NSNumber numberWithFloat:curWW] forKey:@"windowWidth"];
            [im setValue:@([pix storedWindowLevelForCalibratedLevel:curWL]) forKey:@"windowLevel"];
            if( [self isScaledFit] == NO)
                [im setValue:[NSNumber numberWithFloat:scaleValue] forKey:@"scale"];
            else
                [im setValue:nil forKey:@"scale"];
            [im setValue:[NSNumber numberWithFloat:rotation] forKey:@"rotationAngle"];
            [im setValue:[NSNumber numberWithBool:yFlipped] forKey:@"yFlipped"];
            // This wrote the vertical flip into the horizontal one.
            [im setValue:[NSNumber numberWithBool:xFlipped] forKey:@"xFlipped"];
            [im setValue:[NSNumber numberWithFloat:origin.x] forKey:@"xOffset"];
            [im setValue:[NSNumber numberWithFloat:origin.y] forKey:@"yOffset"];
        }
    }
}

- (void) setCOPYSETTINGSINSERIES: (BOOL) b
{
    ViewerController *v = [self windowController];
    
    COPYSETTINGSINSERIES = b;
    
    for( int i = 0 ; i < [v  maxMovieIndex]; i++)
        [self writeCopySettingsInSeriesForPixels: [v pixList: i]];
}

- (void) switchCopySettingsInSeries:(id) sender
{
    COPYSETTINGSINSERIES = !COPYSETTINGSINSERIES;
    
    @try
    {
        ViewerController *v = self.windowController;
        
        for( DCMView *imageView in [v imageViews])
        {
            if( [imageView seriesObj] == self.seriesObj)
            {
                imageView.COPYSETTINGSINSERIES = COPYSETTINGSINSERIES;
                
                for( int i = 0 ; i < [v  maxMovieIndex]; i++)
                    [imageView writeCopySettingsInSeriesForPixels: [v pixList: i]];
            }
        }
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
}

- (void) setIndex:(short) index
{
    [drawLock lock];
    
    @try
    {
        TextureComputed32bitPipeline = NO;
        
        BOOL	keepIt;
        
        [self stopROIEditing];
        
        [[self window] setAcceptsMouseMovedEvents: YES];
        
        if( dcmPixList && index > -1 && [dcmPixList count] > 0)
        {
            if( [[[[dcmFilesList objectAtIndex: 0] valueForKey:@"completePath"] lastPathComponent] isEqualToString:@"Empty.tif"])
                noScale = YES;
            else
                noScale = NO;
            
            curImage = index;
            if( curImage >= [dcmPixList count]) curImage = (long)[dcmPixList count] -1;
            if( curImage < 0) curImage = 0;
            
            DCMPix *pix2beReleased = [self.curDCM retain];
            self.curDCM = [dcmPixList objectAtIndex:curImage];
            
            [self.curDCM CheckLoad];
            
            [pix2beReleased release]; // This will allow us to keep the cached group for a multi frame image
            
            [curRoiList autorelease];
            
            if( dcmRoiList) curRoiList = [[dcmRoiList objectAtIndex: curImage] retain];
            else
                curRoiList = [[NSMutableArray alloc] initWithCapacity:0];
            
            keepIt = NO;
            for( ROI *r in curRoiList)
            {
                [r setCurView:self];
                [r recompute];
                if( curROI == r) keepIt = YES;
            }
            
            if( keepIt == NO)
            {
                [curROI autorelease];
                curROI = nil;
            }
            
            BOOL done = NO;
            
            if( [self is2DViewer] == YES)
            {
                if( curImage >= 0 && COPYSETTINGSINSERIES == NO)
                {
                    if( curWW != self.curDCM.ww || curWL != self.curDCM.wl || [self.curDCM updateToApply] == YES)
                    {
                        [self reapplyWindowLevel];
                    }
                    else [self.curDCM checkImageAvailble :curWW :curWL];
                    
                    [self updatePresentationStateFromSeriesOnlyImageLevel: YES];
                    
                    done = YES;
                }
                
                [self.windowController willChangeValueForKey: @"thicknessInMm"];
                [self.windowController didChangeValueForKey: @"thicknessInMm"];
            }
            
            if( done == NO)
            {
                if( curWW != self.curDCM.ww || curWL != self.curDCM.wl || [self.curDCM updateToApply] == YES)
                {
                    [self reapplyWindowLevel];
                }
                else [self.curDCM checkImageAvailble :curWW :curWL];
            }
            
            [self loadTextures];
            
            [yearOld release];
            
            if( [[[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOld"] isEqualToString: [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOldAcquisition"]])
                yearOld = [[[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOld"] retain];
            else
                yearOld = [[NSString stringWithFormat:@"%@ / %@", [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOld"], [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.yearOldAcquisition"]] retain];
            
            [[NSNotificationCenter defaultCenter] postNotificationName:OsirixDCMViewIndexChangedNotification object:self];
        }
        else
        {
            self.curDCM = nil;
            curImage = -1;
            [curRoiList autorelease];
            curRoiList = nil;
            
            [curROI autorelease];
            curROI = nil;
            [self loadTextures];
        }
        
        NSEvent *event = [[NSApplication sharedApplication] currentEvent];
        
        [self mouseMoved: event];
        [self setNeedsDisplay:YES];
        
        [self updateTilingViews];
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [drawLock unlock];
}

-(BOOL) acceptsFirstMouse:(NSEvent*) theEvent
{
    if (currentTool >= 5) return NO;  // A ROI TOOL !
    else return YES;
}

- (BOOL)acceptsFirstResponder
{
    if (self.curDCM == nil) return NO;
    
    return YES;
}

- (BOOL) containsScrollThroughModality
{
    for( NSString *m in [self.studyObj.modalities componentsSeparatedByString:@"\\"])
    {
        if( [[NSUserDefaults standardUserDefaults] boolForKey: [NSString stringWithFormat: @"scrollThroughSeriesFor%@", m]])
        {
            return YES;
        }
    }
    
    return NO;
}

- (BOOL) scrollThroughSeriesIfNecessary: (int) i
{
    BOOL switchSeries = NO;
    
    if( [self is2DViewer] && [[NSUserDefaults standardUserDefaults] boolForKey:@"scrollThroughSeries"] && [self containsScrollThroughModality])
    {
        int imIndex = curImage;
        
        if( flippedData)
            imIndex = (long)[dcmPixList count]-1-imIndex;
        
        if( imIndex < 0)
        {
            NSArray *seriesArray = [[BrowserController currentBrowser] childrenArray: [self.seriesObj valueForKey: @"study"]];
            NSInteger index = [seriesArray indexOfObject: self.seriesObj];
            
            if( index != NSNotFound)
            {
                if( index > 0)
                {
                    [NSObject cancelPreviousPerformRequestsWithTarget: [self windowController] selector: @selector(loadSeriesDown) object: nil];
                    [[self windowController] performSelector: @selector(loadSeriesDown) withObject: nil afterDelay: 0.01];
                    switchSeries = YES;
                }
            }
        }
        else if( imIndex >= [dcmPixList count])
        {
            NSArray *seriesArray = [[BrowserController currentBrowser] childrenArray: [self.seriesObj valueForKey: @"study"]];
            NSInteger index = [seriesArray indexOfObject: self.seriesObj];
            
            if( index != NSNotFound)
            {
                if( index + 1 < [seriesArray count])
                {
                    [NSObject cancelPreviousPerformRequestsWithTarget: [self windowController] selector: @selector(loadSeriesUp) object: nil];
                    [[self windowController] performSelector: @selector(loadSeriesUp) withObject: nil afterDelay: 0.01];
                    switchSeries = YES;
                }
            }
        }
        
        if( curImage < 0) curImage = 0;
        if( curImage >= [dcmPixList count]) curImage = (long)[dcmPixList count]-1;
    }
    
    return switchSeries;
}

- (void) keyDown:(NSEvent *)event
{
    if (event.keyCode == 53 && (lengthFirstEndpoint || lengthClickEvent))
    { [self cancelLengthPlacement]; return; }
    [self cancelOpeningScaleToFitForInteraction];
    if ([self eventToPlugins:event]) return;
    if( [[event characters] length] == 0) return;
    
    unichar		c = [[event characters] characterAtIndex:0];
    long		xMove = 0, yMove = 0, val;
    BOOL		Jog = NO;
    
    if( [self windowController]  == [BrowserController currentBrowser])
    {
        [super keyDown:event];
        return;
    }
    
    if( dcmPixList)
    {
        short   inc, previmage = curImage;
        
        if(lensActive)
        {
            if(c == 45 || c == 95) //  '-' (numeric keypad) or '_' (standard keyboard)
            {
                if(lensZoomFactor < 4.0f) {
                    lensZoomFactor += 0.2;
                }
                [self setNeedsDisplay:TRUE];
                return;
            }
            else if(c == 43) //  '+'
            {
                if(lensZoomFactor > 0.2f) {
                    lensZoomFactor -= 0.2;
                }
                [self setNeedsDisplay:TRUE];

                return;
            }
            else if(c == 63232) //  ARROW UP
            {
                lensSizeFactor *= 1.5f;
                [self computeMagnifyLens: NSMakePoint( mouseXPos, mouseYPos)];
                [self setNeedsDisplay:TRUE];
                return;
            }
            else if(c == 63233) //  ARROW DOWN
            {
                lensSizeFactor /= 1.5f;
                [self computeMagnifyLens: NSMakePoint( mouseXPos, mouseYPos)];
                [self setNeedsDisplay:TRUE];
                return;
            }
        }
        
        if( flippedData)
        {
            if (c == NSLeftArrowFunctionKey) c = NSRightArrowFunctionKey;
            else if (c == NSRightArrowFunctionKey) c = NSLeftArrowFunctionKey;
            else if( c == NSPageUpFunctionKey) c = NSPageDownFunctionKey;
            else if( c == NSPageDownFunctionKey) c = NSPageUpFunctionKey;
        }
        
        if( c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey)
        {
            [[self windowController] addToUndoQueue:@"roi"];
            
            // NE PAS OUBLIER DE CHANGER EGALEMENT LE CUT !
            long	i;
            NSTimeInterval groupID;
            
            [drawLock lock];
            
            
            NSMutableArray *rArray = curRoiList;
            
            [rArray retain];
            
            @try
            {
                for( i = 0; i < [rArray count]; i++)
                {
                    ROI *r = [rArray objectAtIndex:i];
                    
                    if( [r ROImode] == ROI_selectedModify || [r ROImode] == ROI_drawing)
                    {
                        if( [r deleteSelectedPoint] == NO && r.locked == NO)
                        {
                            if( curROI == r)
                            {
                                [curROI autorelease];
                                curROI = nil;
                                drawingROI = NO;
                            }
                            groupID = [r groupID];
                            [r retain]; // the notification can release it: a mirrored 2D point's owner removes it
                            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object:r userInfo: nil];
                            [self removeROIFromSliceOrVolume:r];
                            [r release];
                            i--;
                            if( groupID != 0.0)
                                [self deleteROIGroupID:groupID];
                        }
                    }
                }
                
                for( i = 0; i < [rArray count]; i++)
                {
                    ROI *r = [rArray objectAtIndex:i];
                    
                    if( [r ROImode] == ROI_selected  && r.locked == NO && r.hidden == NO)
                    {
                        groupID = [r groupID];
                        [r retain]; // the notification can release it: a mirrored 2D point's owner removes it
                        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object:r userInfo: nil];
                        [self removeROIFromSliceOrVolume:r];
                        [r release];
                        i--;
                        if( groupID != 0.0)
                            [self deleteROIGroupID:groupID];
                    }
                }
                
                [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROIRemovedFromArrayNotification object: nil userInfo: nil];
            }
            @catch (NSException * e)
            {
                N2LogExceptionWithStackTrace(e);
            }
            
            [rArray autorelease];
            
            [drawLock unlock];
            
            [self setNeedsDisplay: YES];
        }
        else if( (c == 13 || c == 3 || c == ' ') && [self is2DViewer] == YES)	// Return - Enter - Space
        {
            [[self windowController] PlayStop:[[self windowController] findPlayStopButton]];
        }
        else if( c == 27)			// Escape
        {
            if( [self is2DViewer] == YES)
                [[self windowController] offFullScreen];
        }
        else if (c == NSLeftArrowFunctionKey)
        {
            if (([event modifierFlags] & NSCommandKeyMask))
            {
                [super keyDown:event];
            }
            else
            {
                if( [event modifierFlags]  & NSControlKeyMask)
                {
                    inc = - self.curDCM.stack;
                    curImage += inc;
                    
                    [self scrollThroughSeriesIfNecessary: curImage];
                    
                    if( curImage < 0) curImage = 0;
                }
                else
                {
                    if( [event modifierFlags]  & NSAlternateKeyMask) [[self windowController] setKeyImage:self];
                    inc = -_imageRows * _imageColumns;
                    curImage -= _imageRows * _imageColumns;
                    
                    [self scrollThroughSeriesIfNecessary: curImage];
                    
                    if( curImage < 0) curImage = 0;
                }
            }
        }
        else if(c ==  NSRightArrowFunctionKey)
        {
            if (([event modifierFlags] & NSCommandKeyMask))
            {
                [super keyDown:event];
            }
            else
            {
                if( [event modifierFlags]  & NSControlKeyMask)
                {
                    inc = self.curDCM.stack;
                    curImage += inc;
                    
                    [self scrollThroughSeriesIfNecessary: curImage];
                    
                    if( curImage >= [dcmPixList count]) curImage = (long)[dcmPixList count]-1;
                }
                else
                {
                    if( [event modifierFlags]  & NSAlternateKeyMask) [[self windowController] setKeyImage:self];
                    inc = _imageRows * _imageColumns;
                    curImage += _imageRows * _imageColumns;
                    
                    [self scrollThroughSeriesIfNecessary: curImage];
                    
                    if( curImage >= [dcmPixList count]) curImage = (long)[dcmPixList count]-1;
                }
            }
        }
        else if (c == NSUpArrowFunctionKey)
        {
            if( [self is2DViewer] == YES && [[self windowController] maxMovieIndex] > 1) [super keyDown:event];
            else
            {
                [self setScaleValue:(scaleValue+1./50.)];
                
                [self setNeedsDisplay:YES];
            }
        }
        else if(c == NSDownArrowFunctionKey)
        {
            if( [[self windowController] maxMovieIndex] > 1 && [[self windowController] maxMovieIndex] > 1) [super keyDown:event];
            else
            {
                self.scaleValue = scaleValue -1.0f/50.0f;
                
                [self setNeedsDisplay:YES];
            }
        }
        else if (c == NSPageUpFunctionKey)
        {
            inc = -_imageRows * _imageColumns;
            curImage -= _imageRows * _imageColumns;
            if (curImage < 0) curImage = 0;
        }
        else if (c == NSPageDownFunctionKey)
        {
            inc = _imageRows * _imageColumns;
            curImage += _imageRows * _imageColumns;
            if( curImage >= [dcmPixList count]) curImage = (long)[dcmPixList count]-1;
        }
        else if (c == NSHomeFunctionKey)
            curImage = 0;
        else if (c == NSEndFunctionKey)
            curImage = (long)[dcmPixList count]-1;
        else if (c == 9)	// Tab key
        {
            int a = annotationType + 1;
            if( a > annotFull) a = 0;
            
            [[NSUserDefaults standardUserDefaults] setInteger: a forKey: @"ANNOTATIONS"];
            [DCMView setDefaults];
            annotationType = a;
            //            ANNOTATIONS = a;
            
            NSNotificationCenter *nc;
            nc = [NSNotificationCenter defaultCenter];
            [nc postNotificationName: OsirixUpdateViewNotification object: self userInfo: nil];
            
            for( ViewerController *v in [ViewerController getDisplayed2DViewers])
                [v setWindowTitle: self];
        }
        else
        {
            NSLog( @"Keydown: %d", c);
            
            if( [self actionForHotKey:[event characters]] == NO) [super keyDown:event];
        }
        
        if( Jog == YES)
        {
            if (currentTool == tZoom)
            {
                if( yMove) val = yMove;
                else val = xMove;
                
                self.scaleValue = scaleValue + val / 10.0f;
            }
            
            if (currentTool == tTranslate)
            {
                float xmove, ymove, xx, yy;
                //	GLfloat deg2rad = M_PI/180.0;
                
                xmove = xMove*10;
                ymove = yMove*10;
                
                if( xFlipped) xmove = -xmove;
                if( yFlipped) ymove = -ymove;
                
                xx = xmove*cos(rotation*deg2rad) + ymove*sin(rotation*deg2rad);
                yy = xmove*sin(rotation*deg2rad) - ymove*cos(rotation*deg2rad);
                
                [self setOriginX: origin.x + xx Y: origin.y + yy];
            }
            
            if (currentTool == tRotate)
            {
                if( yMove) val = yMove * 3;
                else val = xMove * 3;
                
                float rot = self.rotation;
                
                rot += val;
                
                if( rot < 0) rot += 360;
                if( rot > 360) rot -= 360;
                
                self.rotation =rot;
            }
            
            if (currentTool == tNext)
            {
                short   inc, previmage;
                
                if( yMove) val = yMove/labs(yMove);
                else val = xMove/labs(xMove);
                
                previmage = curImage;
                
                if( val < 0)
                {
                    inc = -1;
                    curImage--;
                    if( curImage < 0) curImage = (long)[dcmPixList count]-1;
                }
                else if(val> 0)
                {
                    inc = 1;
                    curImage++;
                    if( curImage >= [dcmPixList count]) curImage = 0;
                }
            }
            
            if( currentTool == tWL)
            {
                [self setWLWW:self.curDCM.wl +yMove*10 :self.curDCM.ww +xMove*10 ];
            }
            
            [self setNeedsDisplay:YES];
        }
        
        if( previmage != curImage)
        {
            if( listType == 'i') [self setIndex:curImage];
            else [self setIndexWithReset:curImage :YES];
            
            if( matrix ) {
                NSInteger rows, cols; [matrix getNumberOfRows:&rows columns:&cols];  if( cols < 1) cols = 1;
                [matrix selectCellAtRow:curImage/cols column:curImage%cols];
            }
            
            if( [self is2DViewer] == YES)
                [[self windowController] adjustSlider];
            
            // SYNCRO
            [self sendSyncMessage:inc];
            
            [self setNeedsDisplay:YES];
        }
        
        if( [self is2DViewer] == YES)
            [[self windowController] propagateSettings];
    }
}

- (BOOL) shouldPropagate
{
    //	if( curImage >= 0 && [DCMView noPropagateSettingsInSeriesForModality: [[dcmFilesList objectAtIndex:0] valueForKey:@"modality"]] || COPYSETTINGSINSERIES == NO)
    //		return NO;
    //	else
    return YES;
}

// A physical Length is one object shared by slice lists. Removing only the
// visible alias would resurrect it on the next slice and at the next save.
- (void)removeROIFromSliceOrVolume:(ROI*)roi
{
    [roi retain];
    if ([self is2DViewer] && [roi isKindOfClass:HorosVolumeLengthROI.class])
        for (NSMutableArray *slice in dcmRoiList) [slice removeObjectIdenticalTo:roi];
    else
        [curRoiList removeObjectIdenticalTo:roi];
    [roi release];
}

- (void)deleteROIGroupID:(NSTimeInterval)groupID
{
    [drawLock lock];
    
    NSMutableArray *rArray = curRoiList;
    
    [rArray retain];
    
    @try
    {
        for( int i=0; i<[rArray count]; i++ )
        {
            if([[rArray objectAtIndex:i] groupID] == groupID)
            {
                // The notification can change the array and release the ROI (a
                // mirrored 2D point's owner removes it): the ROI removed is the
                // one notified, kept until then.
                ROI *r = [[rArray objectAtIndex:i] retain];
                [[NSNotificationCenter defaultCenter] postNotificationName:OsirixRemoveROINotification object:r userInfo:nil];
                [self removeROIFromSliceOrVolume:r];
                [r release];
                i--;
                
                [[NSNotificationCenter defaultCenter] postNotificationName:OsirixROIRemovedFromArrayNotification object:NULL userInfo:NULL];
            }
        }
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [rArray autorelease];
    
    [drawLock unlock];
}

- (BOOL) allIdenticalValues:(NSString*) v inArray:(NSArray*) a
{
    if( [a count])
    {
        NSString *s = [[a objectAtIndex: 0] valueForKey: v];
        for( id i in a)
        {
            if( [s isEqualToString: [i valueForKey: v]] == NO) return NO;
        }
        
        return YES;
    }
    return NO;
}

- (void) computeDescriptionInLarge
{
    [drawLock lock];
    
    @try
    {
        id curSeries = self.seriesObj;
        id curStudy = [curSeries valueForKey:@"study"];
        
        NSArray *viewers = [[ViewerController getDisplayed2DViewers] sortedArrayUsingFunction: studyCompare context: nil];
        
        NSMutableArray *studiesArray = [NSMutableArray array];
        NSMutableArray *seriesArray = [NSMutableArray array];
        
        for( ViewerController *v in viewers)
        {
            if( [v currentStudy] && [v currentSeries])
            {
                [studiesArray addObject: [v currentStudy]];
                [seriesArray addObject: [v currentSeries]];
            }
        }
        
        NSMutableString *description = [NSMutableString stringWithString:@""];
        // same patients?
        if( [self allIdenticalValues: @"name" inArray: studiesArray] == NO)
        {
            if( [curStudy valueForKey: @"name"])
            {
                if( [description length]) [description appendString:@"\r"];
                if( [curStudy valueForKey: @"name"]) [description appendString: [curStudy valueForKey: @"name"]];
            }
        }
        
        if( [description length]) [description appendString:@"\r"];
        
        if( [NSUserDefaults formatDateTime: [curSeries valueForKey:@"date"]])
            [description appendString: [NSUserDefaults formatDateTime: [curSeries valueForKey:@"date"]]];
        
        if( [self allIdenticalValues: @"studyName" inArray: studiesArray] == NO)
        {
            if( [curStudy valueForKey: @"studyName"])
            {
                if( [description length]) [description appendString:@"\r"];
                if( [curStudy valueForKey: @"studyName"])
                    [description appendString: [curStudy valueForKey: @"studyName"]];
            }
        }
        
        if( [curSeries valueForKey:@"name"])
        {
            if( [description length]) [description appendString:@"\r"];
            if( [curSeries valueForKey:@"name"])
                [description appendString: [curSeries valueForKey:@"name"]];
        }
        
        NSMutableDictionary *stanStringAttrib = [NSMutableDictionary dictionary];
        [stanStringAttrib setObject: [NSFont fontWithName:@"Helvetica-Bold" size:30] forKey:NSFontAttributeName];
        
        if( description == nil)
            description = [NSMutableString stringWithString:@""];
        
        NSAttributedString *text = [[[NSAttributedString alloc] initWithString: description attributes: stanStringAttrib] autorelease];
        
        [self computeColor];
        
        NSColor *boxColor = [ViewerController.studyColors objectAtIndex: 0];
        if( studyColorR != 0 || studyColorG != 0 || studyColorB != 0)
            boxColor = [NSColor colorWithCalibratedRed: studyColorR green: studyColorG blue: studyColorB alpha: 0.7];
        NSColor *frameColor = [NSColor colorWithDeviceRed: [boxColor redComponent] green:[boxColor greenComponent] blue:[boxColor blueComponent] alpha:1];
        
        if( showDescriptionInLargeText == nil)
            showDescriptionInLargeText = [[HorosAnnotationBox alloc] initWithAttributedString: text boxColor: boxColor borderColor: frameColor];
        else
            [showDescriptionInLargeText setAttributedString: text boxColor: boxColor borderColor: frameColor];
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [drawLock unlock];
}

- (void) switchShowDescriptionInLarge
{
    for( ViewerController *v in [ViewerController getDisplayed2DViewers])
    {
        for( DCMView *m in [v imageViews])
        {
            m.showDescriptionInLarge = showDescriptionInLarge;
            
            if( showDescriptionInLarge)
                [m computeDescriptionInLarge];
            [m setNeedsDisplay: YES];
        }
    }
}

- (void)flagsChanged {
    NSEvent *e = nil;
    [self flagsChanged:e];
}

- (void) flagsChanged:(NSEvent *)event
{
    [self deleteLens];
    //	if(loupeController) [loupeController close];
    
    if( [self is2DViewer] == YES)
    {
        NSUInteger modifiers = [event modifierFlags];
        BOOL update = NO;
        
        if ((modifiers & (NSCommandKeyMask | NSShiftKeyMask)) == (NSCommandKeyMask | NSShiftKeyMask))
        {
            if (suppress_labels == NO) update = YES;
            suppress_labels = YES;
        }
        else
        {
            if (suppress_labels == YES) update = YES;
            suppress_labels = NO;
        }
        
        if (update == YES) [self setNeedsDisplay:YES];
        
        BOOL cLarge = showDescriptionInLarge;
        showDescriptionInLarge = NO;
        if( modifiers & NSControlKeyMask)
        {
            if(modifiers & NSCommandKeyMask) {}
            else if(modifiers & NSShiftKeyMask) {}
            else if(modifiers & NSAlternateKeyMask) {}
            else
                showDescriptionInLarge = YES;
        }
        
        if( showDescriptionInLarge != cLarge)
        {
            [self switchShowDescriptionInLarge];
            [[self windowController] showCurrentThumbnail: self];
        }
        
        //		if( (modifiers & NSControlKeyMask) && (modifiers & NSAlternateKeyMask) && (modifiers & NSCommandKeyMask))
        //		{
        //			for( ViewerController *v in [ViewerController get2DViewers])
        //			{
        //				for( DCMView *view in [v imageViews])
        //					[view setNeedsDisplay: YES];
        //			}
        //		}
    }
    
    BOOL roiHit = NO;
    
    if( [self roiTool: currentTool])
    {
        NSPoint tempPt = [self convertPoint: [event locationInWindow] fromView: nil];
        tempPt = [self ConvertFromNSView2GL:tempPt];
        if( [self clickInROI: tempPt])
            roiHit = YES;
    }
    else if( ( [event modifierFlags] & NSShiftKeyMask) && !([event modifierFlags] & NSAlternateKeyMask)  && !([event modifierFlags] & NSCommandKeyMask)  && !([event modifierFlags] & NSControlKeyMask) && mouseDragging == NO)
    {
        if( [event type] != NSLeftMouseDragged && [event type] != NSLeftMouseDown)
        {
            [self computeMagnifyLens: NSMakePoint( mouseXPos, mouseYPos)];
#ifdef new_loupe
            [self displayLoupeWithCenter:NSMakePoint([[self window] frame].origin.x+[event locationInWindow].x, [[self window] frame].origin.y+[event locationInWindow].y)];
#endif
        }
    }
    
    if( roiHit == NO)
        [self setCursorForView: [self getTool: event]];
    else
        [self setCursorForView: currentTool];
    
    if( cursorSet) [cursor set];
    
    [super flagsChanged:event];
}

// A hidden hardware cursor does not imply that input left this Mac: remote
// control can still deliver events to this viewer's window. Retain the legacy
// filtering only for hidden-cursor events without a matching local window.
- (BOOL) shouldIgnoreHiddenCursorEvent:(NSEvent*) event
{
    if( CGCursorIsVisible() || lensActive)
        return NO;
    NSWindow *targetWindow = self.window;
    return targetWindow == nil || event.window != targetWindow;
}

- (void)mouseUp:(NSEvent *)event
{
    if (lengthClickEvent) { [self finishLengthClick:event]; return; }
    if( [self shouldIgnoreHiddenCursorEvent:event]) return;
    if ([self eventToPlugins:event]) return;
    
    mouseDragging = NO;
        
    // get rid of timer
    [self deleteMouseDownTimer];
    
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:curImage], @"curImage", event, @"event", nil];
    
    if( [[self window] isVisible] == NO) return;
    
    if( [self is2DViewer] == YES)
    {
        if( [[self windowController] windowWillClose]) return;
    }
    
    // If caplock is on changes to scale, rotation, zoom, ww/wl will apply only to the current image
    BOOL modifyImageOnly = NO;
    if ([event modifierFlags] & NSAlphaShiftKeyMask)
        modifyImageOnly = YES;
    
    if( dcmPixList)
    {
        if ( pluginOverridesMouse && ( [event modifierFlags] & NSControlKeyMask ) )
        {  // Simulate Right Mouse Button action
            [nc postNotificationName: OsirixRightMouseUpNotification object: self userInfo: userInfo];
            return;
        }
        
        [drawLock lock];
        
        @try
        {
            [self mouseMoved: event];	// Update some variables...
            
            if( curImage != startImage && (matrix && [BrowserController currentBrowser]))
            {
                NSInteger rows, cols; [matrix getNumberOfRows:&rows columns:&cols];  if( cols < 1) cols = 1;
                NSButtonCell *cell = [matrix cellAtRow:curImage/cols column:curImage%cols];
                [cell performClick:nil];
                [matrix selectCellAtRow :curImage/cols column:curImage%cols];
            }
            
            ToolMode tool = currentMouseEventTool;
            
            if( crossMove >= 0) tool = tCross;
            
            if( tool == tWL || tool == tWLBlended)
            {
                if( [self is2DViewer] == YES)
                {
                    [[[self windowController] thickSlabController] setLowQuality: NO];
                    [self reapplyWindowLevel];
                    [self loadTextures];
                    [self setNeedsDisplay:YES];
                }
            }
            
            if( [self roiTool: tool] )
            {
                NSPoint     eventLocation = [event locationInWindow];
                NSPoint		tempPt = [self convertPoint:eventLocation fromView: nil];
                
                tempPt = [self ConvertFromNSView2GL:tempPt];
                
                for( ROI *r in curRoiList)
                {
                    [r mouseRoiUp: tempPt scaleValue: (float) scaleValue];
                    
                    if( [r ROImode] == ROI_selected)
                    {
                        [nc postNotificationName: OsirixROISelectedNotification object: r userInfo: nil];
                        break;
                    }
                }
                
                [self deleteInvalidROIs];
                
                [self setNeedsDisplay:YES];
            }
            
            if(repulsorROIEdition)
            {
                currentTool = tRepulsor;
                tool = tRepulsor;
                repulsorROIEdition = NO;
            }
            
            if(tool == tRepulsor)
            {
                repulsorRadius = 0;
                if(repulsorColorTimer)
                {
                    [repulsorColorTimer invalidate];
                    [repulsorColorTimer release];
                    repulsorColorTimer = nil;
                }
                [self setNeedsDisplay:YES];
            }
            
            if(selectorROIEdition)
            {
                currentTool = tROISelector;
                tool = tROISelector;
                selectorROIEdition = NO;
            }
            
            if(tool == tROISelector)
            {
                [ROISelectorSelectedROIList release];
                ROISelectorSelectedROIList = nil;
                
                NSRect rect = NSMakeRect(ROISelectorStartPoint.x-1, ROISelectorStartPoint.y-1, fabs(ROISelectorEndPoint.x-ROISelectorStartPoint.x)+2, fabs(ROISelectorEndPoint.y-ROISelectorStartPoint.y)+2);
                ROISelectorStartPoint = NSMakePoint(0.0, 0.0);
                ROISelectorEndPoint = NSMakePoint(0.0, 0.0);
                [self drawRect:rect];
            }
        }
        @catch (NSException * e)
        {
            N2LogExceptionWithStackTrace(e);
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateWLWWMenuNotification object: [DCMView findWLWWPreset: curWL :curWW :self.curDCM] userInfo: nil];
        
        [drawLock unlock];
    }
}

-(void) roiSet:(ROI*) aRoi
{
    [aRoi setCurView:self];
}

-(void) roiSet
{
    for( ROI *c in curRoiList)
        [c setCurView:self];
}

// checks to see if tool is a valid ID for ROIs
// A better name might be  - (BOOL)isToolforROIs:(long)tool;

-(BOOL) roiTool:(ToolMode) tool
{
    // The list used to live here as a switch with a silent default, so a tool
    // mode added to ToolMode fell through to NO without anyone deciding. A255
    // asks for the opposite: a mode that does not apply refused for a stated
    // reason. HorosToolModeCapability carries one row per mode, with that
    // reason, and a test compares it against the enum in DCMView.h.
    //
    // tRepulsor and tROISelector are deliberately not here: they work on ROIs
    // without drawing one, and each caller of this method names them.
    return [HorosToolModeCapability drawsROIsWithToolMode: tool];
}

- (IBAction) selectAll: (id) sender
{
    for( ROI *r in curRoiList)
    {
        [r setROIMode: ROI_selected];
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROISelectedNotification object: r userInfo: nil];
    }
    
    [self setNeedsDisplay:YES];
}

-(void) deleteLens
{
    if( lensActive)
    {
        lensActive = NO;
        [self setNeedsDisplay: YES];
        
        if( cursorhidden)
        {
            [NSCursor unhide];
            cursorhidden = NO;
        }
    }
}

-(void) computeMagnifyLens:(NSPoint) p
{
    if( p.x == 0 && p.y == 0)
        return;
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"magnifyingLens"] == NO)
        return;
    
    if( isKeyView == NO)
        [[self window] makeFirstResponder: self];
    
    lensSize = 100 / scaleValue;
    LENSRATIO = 1;
    
    [self deleteLens];
    
    int lensActualSize = (int)(lensSize*lensSizeFactor);
    
    // The lens is drawn with each frame, from the picture Metal draws (#728).
    if( lensActualSize > 0 && lensActualSize < [self.curDCM pwidth])
    {
        lensActive = YES;
        
        if( cursorhidden == NO)
        {
            cursorhidden = YES;
            [NSCursor hide];
        }
    }
    
    [self setNeedsDisplay: YES];
}

// An image's pixels as straight-alpha ARGB, `width` x `height`, rows from the top.
static NSMutableData *HorosImageARGB( NSImage *image, NSInteger width, NSInteger height)
{
    CGImageRef picture = [image CGImageForProposedRect: NULL context: nil hints: nil];
    if( picture == nil || width <= 0 || height <= 0)
        return nil;
    NSMutableData *data = [NSMutableData dataWithLength: width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate( data.mutableBytes, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease( space);
    if( context == nil)
        return nil;
    CGContextDrawImage( context, CGRectMake( 0, 0, width, height), picture);
    CGContextRelease( context);
    unsigned char *p = data.mutableBytes;
    for( NSInteger i = 0; i < width * height; i++, p += 4)
    {
        if( p[0] == 0 || p[0] == 255)
            continue;
        for( int k = 1; k < 4; k++)
            p[k] = MIN( 255, p[k] * 255 / p[0]);
    }
    return data;
}

// The magnifying lens: the picture under the cursor drawn again by Metal,
// magnified, masked to the lens's disc and ringed, on the canvas (#728).
- (void) drawMagnifyingLens
{
    HorosROICanvas *canvas = [HorosROICanvas current];
    if( canvas == nil || self.window == nil)
        return;
    
    NSBundle *bundle = [NSBundle bundleForClass:[DCMView class]];
    if( loupeImage == nil)
        loupeImage = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"loupe.png"]];
    if( loupeMaskImage == nil)
        loupeMaskImage = [[NSImage alloc] initWithContentsOfFile:[bundle pathForImageResource:@"loupeMask.png"]];
    
    float sf = self.window.backingScaleFactor;
    NSRect mlr = {[NSEvent mouseLocation], NSZeroSize};
    NSPoint cursor = [self convertPoint: [[self window] convertRectFromScreen: mlr].origin fromView: nil];
    
    // The lens is as wide as twice its crop at the view's scale, and shows the
    // crop lensZoomFactor chooses: at 4, the whole crop, twice the view's
    // magnification; below 2 the original drew nothing sensible.
    float actualLensSize = lensSize * lensSizeFactor;
    NSInteger side = (NSInteger) round( actualLensSize * 2 * scaleValue / LENSRATIO);
    if( side < 2 || side > 4096)
        return;
    float magnification = 4.0f / (MAX( lensZoomFactor, 2.2f) - 2.0f);
    float half = side / 2.0f / magnification / sf;
    NSData *bgra = [self horosPlanarPixelsSide: side
        topLeft: NSMakePoint( cursor.x - half, cursor.y + half)
        topRight: NSMakePoint( cursor.x + half, cursor.y + half)
        bottomLeft: NSMakePoint( cursor.x - half, cursor.y - half) inverted: NO];
    NSMutableData *mask = HorosImageARGB( loupeMaskImage, side, side);
    if( bgra == nil || mask == nil)
        return;
    
    // The picture's colours with the mask's alpha, as the multitexture combined them.
    unsigned char *lens = mask.mutableBytes;
    const unsigned char *picture = bgra.bytes;
    for( NSInteger i = 0; i < side * side; i++)
    {
        lens[4*i+1] = picture[4*i+2];
        lens[4*i+2] = picture[4*i+1];
        lens[4*i+3] = picture[4*i];
    }
    
    NSPoint centre = [self convertPointToBacking: cursor];
    centre.y = drawingFrameRect.size.height - centre.y;
    float x0 = centre.x - side / 2.0f, y0 = centre.y - side / 2.0f;
    
    roiLoadIdentity();
    roiScalef( 2.0f / drawingFrameRect.size.width, -2.0f / drawingFrameRect.size.height, 1.0f);
    roiTranslatef( -drawingFrameRect.size.width / 2.0f, -drawingFrameRect.size.height / 2.0f, 0.0f);
    [canvas drawARGB: lens width: side height: side rowBytes: side * 4
        x0: x0 y0: y0 x1: x0 + side y1: y0 x2: x0 y2: y0 + side interpolate: NO];
    
    NSInteger ringWidth = loupeImage.size.width, ringHeight = loupeImage.size.height;
    NSMutableData *ring = HorosImageARGB( loupeImage, ringWidth, ringHeight);
    if( ring)
        [canvas drawARGB: ring.mutableBytes width: ringWidth height: ringHeight rowBytes: ringWidth * 4
            x0: x0 y0: y0 x1: x0 + side y1: y0 x2: x0 y2: y0 + side interpolate: YES];
}

-(void) mouseMovedInView: (NSPoint) eventLocationInWindow
{
    [self horosMoveScrollPreviewAtWindowPoint:eventLocationInWindow];
    NSUInteger modifierFlags = [[[NSApplication sharedApplication] currentEvent] modifierFlags];
    NSPoint eventLocationInView = [self convertPoint: eventLocationInWindow fromView: nil];
    
    @try
    {
        [self deleteLens];
        
        [BrowserController updateActivity];
        
        float	cpixelMouseValueR = pixelMouseValueR;
        float	cpixelMouseValueG = pixelMouseValueG;
        float	cpixelMouseValueB = pixelMouseValueB;
        float	cmouseXPos = mouseXPos;
        float	cmouseYPos = mouseYPos;
        float	cpixelMouseValue = pixelMouseValue;
        
        pixelMouseValueR = 0;
        pixelMouseValueG = 0;
        pixelMouseValueB = 0;
        mouseXPos = 0;
        mouseYPos = 0;
        pixelMouseValue = 0;
        
        float	cblendingMouseXPos = blendingMouseXPos;
        float	cblendingMouseYPos = blendingMouseYPos;
        float	cblendingPixelMouseValue = blendingPixelMouseValue;
        float	cblendingPixelMouseValueR = blendingPixelMouseValueR;
        float	cblendingPixelMouseValueG = blendingPixelMouseValueG;
        float	cblendingPixelMouseValueB = blendingPixelMouseValueB;
        
        blendingMouseXPos = 0;
        blendingMouseYPos = 0;
        blendingPixelMouseValue = 0;
        blendingPixelMouseValueR = 0;
        blendingPixelMouseValueG = 0;
        blendingPixelMouseValueB = 0;
        
        BOOL needUpdate = NO;
        
        [drawLock lock];
        
        @try
        {
            BOOL mouseOnImage = NO;
            
            NSPoint imageLocation = [self ConvertFromNSView2GL: eventLocationInView];
            
            mouseXPos = imageLocation.x;
            mouseYPos = imageLocation.y;
            
            if( imageLocation.x >= 0 && imageLocation.x < self.curDCM.pwidth)	//&& NSPointInRect( eventLocation, size)) <- this doesn't work in MPR Ortho
            {
                if( imageLocation.y >= 0 && imageLocation.y < self.curDCM.pheight)
                {
                    mouseOnImage = YES;
                    
                    if( (modifierFlags & NSShiftKeyMask) && (modifierFlags & NSControlKeyMask) && mouseDragging == NO)
                    {
                        [self sync3DPosition];
                    }
                    else if( (modifierFlags & (NSShiftKeyMask|NSCommandKeyMask|NSControlKeyMask|NSAlternateKeyMask)) == NSShiftKeyMask && mouseDragging == NO)
                    {
                        if( [self roiTool: currentTool] == NO)
                        {
                            [self computeMagnifyLens: imageLocation];
#ifdef new_loupe
                            [self displayLoupeWithCenter:NSMakePoint([[self window] frame].origin.x+[theEvent locationInWindow].x, [[self window] frame].origin.y+[theEvent locationInWindow].y)];
#endif
                        }
                    }
                    
                    int
                    xPos = (int)mouseXPos,
                    yPos = (int)mouseYPos;
                    
                    if (self.curDCM.isRGB)
                    {
                        pixelMouseValueR = ((unsigned char*) self.curDCM.fImage)[ 4 * (xPos + yPos * self.curDCM.pwidth) +1];
                        pixelMouseValueG = ((unsigned char*) self.curDCM.fImage)[ 4 * (xPos + yPos * self.curDCM.pwidth) +2];
                        pixelMouseValueB = ((unsigned char*) self.curDCM.fImage)[ 4 * (xPos + yPos * self.curDCM.pwidth) +3];
                    }
                    else pixelMouseValue = [self.curDCM getPixelValueX: xPos Y:yPos];
                }
            }
            
            // Blended view
            if( blendingView)
            {
                NSPoint blendedLocation = [blendingView ConvertFromNSView2GL: eventLocationInView];
                
                if( blendedLocation.x >= 0 && blendedLocation.x < [blendingView.curDCM pwidth])
                {
                    if( blendedLocation.y >= 0 && blendedLocation.y < [blendingView.curDCM pheight])
                    {
                        blendingMouseXPos = blendedLocation.x;
                        blendingMouseYPos = blendedLocation.y;
                        
                        int xPos = (int)blendingMouseXPos,
                        yPos = (int)blendingMouseYPos;
                        
                        if( [blendingView.curDCM isRGB])
                        {
                            blendingPixelMouseValueR = ((unsigned char*) [blendingView.curDCM fImage])[ 4 * (xPos + yPos * [blendingView.curDCM pwidth]) +1];
                            blendingPixelMouseValueG = ((unsigned char*) [blendingView.curDCM fImage])[ 4 * (xPos + yPos * [blendingView.curDCM pwidth]) +2];
                            blendingPixelMouseValueB = ((unsigned char*) [blendingView.curDCM fImage])[ 4 * (xPos + yPos * [blendingView.curDCM pwidth]) +3];
                        }
                        else blendingPixelMouseValue = [blendingView.curDCM getPixelValueX: xPos Y:yPos];
                    }
                }
            }
            
            // Are we near a ROI point?
            if( [self roiTool: currentTool])
            {
                NSPoint pt = [self convertPoint: eventLocationInWindow fromView:nil];
                pt = [self ConvertFromNSView2GL: pt];
                
                for( ROI *r in curRoiList)
                    [r displayPointUnderMouse :pt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue];
                
                if( [[[NSApplication sharedApplication] currentEvent] type] == NSMouseMoved)
                {
                    // Should we change the mouse cursor?
                    if( (modifierFlags & NSDeviceIndependentModifierFlagsMask)) [self flagsChanged: [[NSApplication sharedApplication] currentEvent]];
                }
            }
            
            if( [NSUserDefaults.standardUserDefaults boolForKey: @"ROITextIfMouseIsOver"] && [NSUserDefaults.standardUserDefaults boolForKey:@"ROITEXTIFSELECTED"])
            {
                if( mouseDragging == NO)
                {
                    NSPoint pt = [self convertPoint: eventLocationInWindow fromView:nil];
                    pt = [self ConvertFromNSView2GL: pt];
                    
                    for( ROI *r in curRoiList)
                    {
                        BOOL c = r.clickInTextBox;
                        
                        if( [r clickInROI:pt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :NO])
                        {
                            if( !r.mouseOverROI)
                            {
                                r.mouseOverROI = YES;
                                [self setNeedsDisplay: YES];
                            }
                        }
                        else if( r.mouseOverROI)
                        {
                            r.mouseOverROI = NO;
                            [self setNeedsDisplay: YES];
                        }
                        r.clickInTextBox = c;
                    }
                }
            }
            
            if(!mouseOnImage)
            {
#ifdef new_loupe
                [self hideLoupe];
#endif
            }
        }
        @catch (NSException * e)
        {
            N2LogExceptionWithStackTrace(e);
        }
        
        [drawLock unlock];
        
        if(	cpixelMouseValueR != pixelMouseValueR)	needUpdate = YES;
        if(	cpixelMouseValueG != pixelMouseValueG)	needUpdate = YES;
        if(	cpixelMouseValueB != pixelMouseValueB)	needUpdate = YES;
        if(	cmouseXPos != mouseXPos)	needUpdate = YES;
        if(	cmouseYPos != mouseYPos)	needUpdate = YES;
        if(	cpixelMouseValue != pixelMouseValue)	needUpdate = YES;
        if( cblendingMouseXPos != blendingMouseXPos) needUpdate = YES;
        if( cblendingMouseYPos != blendingMouseYPos) needUpdate = YES;
        if( cblendingPixelMouseValue != blendingPixelMouseValue) needUpdate = YES;
        if( cblendingPixelMouseValueR != blendingPixelMouseValueR) needUpdate = YES;
        if( cblendingPixelMouseValueG != blendingPixelMouseValueG) needUpdate = YES;
        if( cblendingPixelMouseValueB != blendingPixelMouseValueB) needUpdate = YES;
        
        if( needUpdate)
        {
            [self setNeedsDisplay: YES];
            [[NSNotificationCenter defaultCenter] postNotificationName: @"DCMViewMouseMovedUpdated" object: self];
        }
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
}

- (void) DCMViewMouseMovedUpdated: (NSNotification*) n
{
    if( n.object != self)
    {
        float	cpixelMouseValueR = pixelMouseValueR, cpixelMouseValueG = pixelMouseValueG, cpixelMouseValueB = pixelMouseValueB;
        float	cmouseXPos = mouseXPos, cmouseYPos = mouseYPos;
        float	cpixelMouseValue = pixelMouseValue;
        
        pixelMouseValueR =  pixelMouseValueG =  pixelMouseValueB =  mouseXPos =  mouseYPos =  pixelMouseValue = 0;
        
        float	cblendingMouseXPos = blendingMouseXPos, cblendingMouseYPos = blendingMouseYPos;
        float	cblendingPixelMouseValue = blendingPixelMouseValue, cblendingPixelMouseValueR = blendingPixelMouseValueR, cblendingPixelMouseValueG = blendingPixelMouseValueG, cblendingPixelMouseValueB = blendingPixelMouseValueB;
        
        blendingMouseXPos =  blendingMouseYPos =  blendingPixelMouseValue =  blendingPixelMouseValueR =  blendingPixelMouseValueG =  blendingPixelMouseValueB = 0;
        
        BOOL needUpdate = NO;
        
        if(	cpixelMouseValueR != pixelMouseValueR) needUpdate = YES;
        if(	cpixelMouseValueG != pixelMouseValueG) needUpdate = YES;
        if(	cpixelMouseValueB != pixelMouseValueB) needUpdate = YES;
        if(	cmouseXPos != mouseXPos) needUpdate = YES;
        if(	cmouseYPos != mouseYPos) needUpdate = YES;
        if(	cpixelMouseValue != pixelMouseValue) needUpdate = YES;
        if( cblendingMouseXPos != blendingMouseXPos) needUpdate = YES;
        if( cblendingMouseYPos != blendingMouseYPos) needUpdate = YES;
        if( cblendingPixelMouseValue != blendingPixelMouseValue) needUpdate = YES;
        if( cblendingPixelMouseValueR != blendingPixelMouseValueR) needUpdate = YES;
        if( cblendingPixelMouseValueG != blendingPixelMouseValueG) needUpdate = YES;
        if( cblendingPixelMouseValueB != blendingPixelMouseValueB) needUpdate = YES;
        
        if( needUpdate)
            [self setNeedsDisplay: YES];
    }
}

-(void) mouseMoved: (NSEvent*) theEvent
{
    if( [self shouldIgnoreHiddenCursorEvent:theEvent]) return;
    if( ![[self window] isVisible])
    {
        if( [self is2DViewer] && [[self windowController] FullScreenON])
        {
            
        }
        else
            return;
    }
    
    if ([self eventToPlugins:theEvent]) return;
    
    if( !drawing) return;
    
    if( [self is2DViewer] == YES)
    {
        if( [[self windowController] windowWillClose]) return;
    }
    
    if (self.curDCM == nil) return;
    
    if( dcmPixList == nil) return;
    
    if( avoidMouseMovedRecursive)
        return;
    
    avoidMouseMovedRecursive = YES;
    
    NSPoint eventLocation = [[self window] mouseLocationOutsideOfEventStream];
    
    if( [[self window] isVisible])
    {
        id view = [self.window.contentView hitTest: eventLocation];
        
        if( [view isKindOfClass: [DCMView class]])
            [view mouseMovedInView: eventLocation];
        
        if ([self is2DViewer] == YES && [self.window isKeyWindow])
            [[self windowController] autoHideMatrix];
    }
    
    avoidMouseMovedRecursive = NO;
}

- (ToolMode) getTool: (NSEvent*) event
{
    ToolMode tool;
    
    if( [event type] == NSRightMouseDown || [event type] == NSRightMouseDragged) tool = currentToolRight;
    else if( [event type] == NSOtherMouseDown || [event type] == NSOtherMouseDragged) tool = tTranslate;
    else tool = currentTool;
    
    if (([event modifierFlags] & NSCommandKeyMask))  tool = tTranslate;
    if (([event modifierFlags] & (NSShiftKeyMask|NSAlternateKeyMask)) == NSAlternateKeyMask)  tool = tWL;
    if (([event modifierFlags] & NSControlKeyMask) && ([event modifierFlags] & NSAlternateKeyMask))
    {
        if( blendingView) tool = tWLBlended;
        else tool = tWL;
    }
    
    if( [self roiTool:currentTool] != YES && currentTool != tROISelector)   // Not a ROI TOOL !
    {
        if (([event modifierFlags] & NSCommandKeyMask) && ([event modifierFlags] & NSAlternateKeyMask))  tool = tRotate;
        if (([event modifierFlags] & NSShiftKeyMask))  tool = tZoom;
    }
    else
    {
        if (([event modifierFlags] & NSCommandKeyMask) && ([event modifierFlags] & NSAlternateKeyMask))  tool = tRotate;
        // 		if (([event modifierFlags] & NSCommandKeyMask) && ([event modifierFlags] & NSAlternateKeyMask)) tool = currentTool;
        //		if (([event modifierFlags] & NSCommandKeyMask)) tool = currentTool;
    }
    
    return tool;
}

- (void) setStartWLWW
{
    startWW = self.curDCM.ww;
    startWL = self.curDCM.wl;
    startMin = self.curDCM.wl - self.curDCM.ww/2;
    startMax = self.curDCM.wl + self.curDCM.ww/2;
    
    bdstartWW = [blendingView.curDCM ww];
    bdstartWL = [blendingView.curDCM wl];
    bdstartMin = [blendingView.curDCM wl] - [blendingView.curDCM ww]/2;
    bdstartMax = [blendingView.curDCM wl] + [blendingView.curDCM ww]/2;
}

- (ROI*) clickInROI: (NSPoint) tempPt
{
    for( ROI * r in curRoiList)
    {
        if([r clickInROI:tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :NO])
            return r;
    }
    
    return nil;
}

- (void) sync3DPosition
{
    if (!self.curDCM || curImage < 0 || curImage >= dcmPixList.count) return;
    float location[ 3];
    
    [self.curDCM convertPixX: mouseXPos pixY: mouseYPos toDICOMCoords: location pixelCenter: YES];
    
    // The shared controller moves native consumers once. Keep the established
    // OsirixSyncNotification payload below for plugins and reference lines.
    BOOL sharedPoint = [self is2DViewer] &&
        HorosPublishPatientCrosshair(location, [self windowController], [self windowController]);
    DCMPix	*thickDCM = nil;
    
    // This used to ignore flippedData, while -syncMessage: right below honoured
    // it: a reversed series sent the far end of the slab from the wrong side of
    // the current slice, and the receiver drew the band there.
    long farEnd = [HorosThickSlabRange farEndIndexForCurrentIndex: curImage
                                                           stack: self.curDCM.stack
                                                           count: [dcmPixList count]
                                                     flippedData: flippedData];
    if( farEnd >= 0)
        thickDCM = [dcmPixList objectAtIndex: farEnd];
    
    int pos = flippedData? (long)[dcmPixList count] -1 -curImage : curImage;
    
    NSMutableDictionary *instructions = [NSMutableDictionary dictionary];
    
    [instructions setObject: self forKey: @"view"];
    [instructions setObject: [NSNumber numberWithLong: pos] forKey: @"Pos"];
    [instructions setObject: [NSNumber numberWithFloat:[(DCMPix*)[dcmPixList objectAtIndex:curImage] sliceLocation]] forKey: @"Location"];
    
    if( [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.studyInstanceUID"])
        [instructions setObject: [[dcmFilesList objectAtIndex: curImage] valueForKeyPath:@"series.study.studyInstanceUID"] forKey: @"studyID"];
    
    if (self.curDCM)
        [instructions setObject:self.curDCM forKey: @"DCMPix"];
    
    if (self.curDCM.frameofReferenceUID)
        [instructions setObject:self.curDCM.frameofReferenceUID forKey:@"frameofReferenceUID"];
    
    [instructions setObject: [NSNumber numberWithFloat: syncRelativeDiff] forKey: @"offsetsync"];
    [instructions setObject: [NSNumber numberWithFloat: location[0]] forKey: @"point3DX"];
    [instructions setObject: [NSNumber numberWithFloat: location[1]] forKey: @"point3DY"];
    [instructions setObject: [NSNumber numberWithFloat: location[2]] forKey: @"point3DZ"];
    if (sharedPoint) [instructions setObject:@YES forKey:@"HorosPatientCrosshair"];
    
    if( thickDCM)
        [instructions setObject: thickDCM forKey: @"DCMPix2"];
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixSyncNotification object: self userInfo: instructions];
}

// TrackPad support

//- (void)touchesBeganWithEvent:(NSEvent *)event
//{
//    NSSet *touches = [event touchesMatchingPhase: NSTouchPhaseTouching inView: self];
//
//    if (touches.count == 2)
//	{
//		NSPoint initialPoint = [self convertPointFromBase: [event locationInWindow]];
//        NSArray *array = [touches allObjects];
//
//		NSLog( @"%@", array);
//    }
//	else if (touches.count == 3)
//	{
//
//    }
//}
//
//- (void)touchesMovedWithEvent:(NSEvent *)event
//{
//    self.modifiers = [event modifierFlags];
//    NSSet *touches = [event touchesMatchingPhase:NSTouchPhaseTouching inView: self];
//
//    if (touches.count == 2 && _initialTouches[0])
//	{
//        NSArray *array = [touches allObjects];
//
//        NSLog( @"%@", array);
//    }
//}
//
//- (void)touchesEndedWithEvent:(NSEvent *)event
//{
//
//}
//
//- (void)touchesCancelledWithEvent:(NSEvent *)event
//{
//
//}

-(void) magnifyWithEvent:(NSEvent *)anEvent
{
    [self cancelOpeningScaleToFitForInteraction];
    [self setScaleValue: scaleValue + anEvent.deltaZ / 60.];
    
    [self setNeedsDisplay:YES];
}

-(void) rotateWithEvent:(NSEvent *)anEvent
{
    [self cancelOpeningScaleToFitForInteraction];
    [self setRotation: rotation - anEvent.rotation * 1.5];
    
    [self setNeedsDisplay:YES];
}

-(void) swipeWithEvent:(NSEvent *)anEvent
{
    if( [self is2DViewer])
    {
        ViewerController *v = [self windowController];
        
        if( anEvent.deltaX < -0.5)
            [v loadSeriesUp];
        
        if( anEvent.deltaX > 0.5)
            [v loadSeriesDown];
        
        if( anEvent.deltaY < -0.5)
            [v loadSeriesUp];
        
        if( anEvent.deltaY > 0.5)
            [v loadSeriesDown];
    }
}

- (void) deleteInvalidROIsForArray: (NSMutableArray*) r
{
    [r retain]; //OsirixRemoveROINotification or OsirixROIRemovedFromArrayNotification can change/delete the NSArray !
    
    @try {
        for( int i = 0; i < [r count]; i++)
        {
            if( [[r objectAtIndex: i] valid] == NO)
            {
                if( curROI == [r objectAtIndex: i])
                {
                    [curROI autorelease];
                    curROI = nil;
                    drawingROI = NO;
                }
                
                [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object: [r objectAtIndex: i] userInfo: nil];
                [r removeObjectAtIndex: i];
                i--;
                
                [[NSNotificationCenter defaultCenter] postNotificationName:OsirixROIRemovedFromArrayNotification object:NULL userInfo:NULL];
            }
        }
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    
    [r autorelease];
}

- (void) deleteInvalidROIs
{
    if( dcmRoiList == nil) // For sub-classes, such as MPR, Curved-MPR, ... they don't have the dcmRoiList array
        [self deleteInvalidROIsForArray: curRoiList];
    else
    {
        for( NSMutableArray *r in dcmRoiList)
            [self deleteInvalidROIsForArray: r];
    }
}

- (void)cancelLengthPlacement
{
    [lengthClickEvent release]; lengthClickEvent = nil;
    [lengthFirstEndpoint release]; lengthFirstEndpoint = nil;
    [lengthPendingMarker release]; lengthPendingMarker = nil;
    [self setNeedsDisplay:YES];
}

- (BOOL)beginLengthClick:(NSEvent*)event
{
    if (replayingLengthDrag || ![self is2DViewer] || event.type != NSEventTypeLeftMouseDown ||
        drawingROI || [self getTool:event] != tMesure ||
        (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl))) return NO;
    NSPoint point = [self ConvertFromNSView2GL:[self convertPoint:event.locationInWindow fromView:nil]];
    // Existing ROI/handle selection keeps the established mouse-down path.
    for (ROI *roi in curRoiList)
    {
        roi.curView = self;
        if ([roi clickInROI:point :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :NO]) return NO;
    }
    [self deleteMouseDownTimer];
    [lengthClickEvent release]; lengthClickEvent = [event retain];
    currentMouseEventTool = tMesure;
    return YES;
}

- (NSDictionary*)lengthEndpointAt:(NSPoint)point
{
    NSArray *patient = [HorosVolumeLengthROI patientPoint:point pix:self.curDCM];
    if (!patient) return nil;
    id image = self.curDCM.imageObj;
    NSString *series = [image valueForKeyPath:@"series.seriesDICOMUID"];
    if (!series.length) return nil;
    NSDictionary *reference = [HorosVolumeLengthROI referenceForPix:self.curDCM];
    return @{@"point":patient, @"series":series, @"frameOfReference":self.curDCM.frameofReferenceUID,
             @"temporalIndex":@([[self windowController] curMovieIndex]), @"reference":reference};
}

- (void)finishLengthClick:(NSEvent*)event
{
    [lengthClickEvent release]; lengthClickEvent = nil;
    if (self.curDCM.stack > 1)
    {
        NSBeep(); [self setNeedsDisplay:YES]; return; // Keep A until thin slices return.
    }
    NSPoint point = [self ConvertFromNSView2GL:[self convertPoint:event.locationInWindow fromView:nil]];
    NSDictionary *endpoint = [self lengthEndpointAt:point];
    if (!endpoint)
    {
        NSRunInformationalAlertPanel(NSLocalizedString(@"Length", nil),
            NSLocalizedString(@"Measuring between slices requires valid patient geometry. Click and drag remains available for a 2D length.", nil), NSLocalizedString(@"OK", nil), nil, nil);
        return;
    }
    if (lengthFirstEndpoint)
    {
        if (![lengthFirstEndpoint[@"series"] isEqual:endpoint[@"series"]] ||
            ![lengthFirstEndpoint[@"frameOfReference"] isEqual:endpoint[@"frameOfReference"]] ||
            ![lengthFirstEndpoint[@"temporalIndex"] isEqual:endpoint[@"temporalIndex"]])
            [self cancelLengthPlacement];
    }
    if (!lengthFirstEndpoint)
    {
        lengthFirstEndpoint = [endpoint copy];
        lengthPendingMarker = [[ROI alloc] initWithType:t2DPoint :self.curDCM.pixelSpacingX :self.curDCM.pixelSpacingY :[DCMPix originCorrectedAccordingToOrientation:self.curDCM]];
    }
    else
    {
        NSDictionary *payload = @{@"version":@1, @"id":NSUUID.UUID.UUIDString,
            @"a":lengthFirstEndpoint[@"point"], @"b":endpoint[@"point"],
            @"referenceA":lengthFirstEndpoint[@"reference"], @"referenceB":endpoint[@"reference"],
            @"series":endpoint[@"series"], @"frameOfReference":endpoint[@"frameOfReference"],
            @"temporalIndex":endpoint[@"temporalIndex"]};
        if (![HorosVolumeLengthROI validPayload:payload]) { NSBeep(); return; }
        HorosVolumeLengthROI *roi = [[[HorosVolumeLengthROI alloc] initWithType:tMesure :self.curDCM.pixelSpacingX :self.curDCM.pixelSpacingY :[DCMPix originCorrectedAccordingToOrientation:self.curDCM]] autorelease];
        roi.volumeLength = payload;
        roi.name = NSLocalizedString(@"Length", nil);
        for (ROI *other in curRoiList) [other setROIMode:ROI_sleep];
        [[self windowController] addToUndoQueue:@"roi"];
        [[self windowController] addVolumeLengthROI:roi];
        [roi setROIMode:ROI_selected];
        [self cancelLengthPlacement];
    }
    [self setNeedsDisplay:YES];
}

- (void)drawPendingLength
{
    if (!lengthFirstEndpoint || ![HorosVolumeLengthROI validGeometry:self.curDCM]) return;
    NSPoint point = [HorosVolumeLengthROI projectPoint:lengthFirstEndpoint[@"point"] pix:self.curDCM depth:NULL];
    lengthPendingMarker.curView = self;
    lengthPendingMarker.pix = self.curDCM;
    [lengthPendingMarker setROIRect:NSMakeRect(point.x, point.y, 0, 0)];
    lengthPendingMarker.name = self.curDCM.stack > 1 ?
        NSLocalizedString(@"Length: return to thin slices to place the second point", nil) :
        NSLocalizedString(@"Length: select the second point (Esc to cancel)", nil);
    [lengthPendingMarker drawROI:scaleValue :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :self.curDCM.pixelSpacingX :self.curDCM.pixelSpacingY];
    lengthPendingMarker.textualBoxLine2 = lengthPendingMarker.textualBoxLine3 = lengthPendingMarker.textualBoxLine4 = lengthPendingMarker.textualBoxLine5 = lengthPendingMarker.textualBoxLine6 = nil;
}

- (void) mouseDown:(NSEvent *)event
{
    [self cancelOpeningScaleToFitForInteraction];
    if( [self shouldIgnoreHiddenCursorEvent:event]) return;
    if ([self eventToPlugins:event]) return;
    
    currentMouseEventTool = -1;
    
    if( !drawing) return;
    if( [[self window] isVisible] == NO) return;
    if( self.curDCM == nil) return;
    if( curImage < 0) return;
    if( [self is2DViewer] == YES)
    {
        if( [[self windowController] windowWillClose]) return;
    }
    
    if( [self is2DViewer] == YES && [event type] == NSLeftMouseDown)
    {
        if( ([event modifierFlags] & NSShiftKeyMask) == 0 && ([event modifierFlags] & NSControlKeyMask) == 0 && ([event modifierFlags] & NSAlternateKeyMask) == 0 && ([event modifierFlags] & NSCommandKeyMask) == 0)
        {
            NSPoint tempPt = [[[event window] contentView] convertPoint: [event locationInWindow] toView:self];
            tempPt = [self ConvertFromNSView2GL:tempPt];
            
            NSMutableDictionary	*dict = [NSMutableDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithFloat:tempPt.y], @"Y", [NSNumber numberWithLong:tempPt.x],@"X", [NSNumber numberWithBool: NO], @"stopMouseDown", nil];
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixMouseDownNotification object: [self windowController] userInfo: dict];
            
            if( [[dict valueForKey:@"stopMouseDown"] boolValue]) return;
        }
    }
    
    if ([self beginLengthClick:event]) return;

    if (_mouseDownTimer)
        [self deleteMouseDownTimer];
    
    if ([event type] == NSLeftMouseDown)
        _mouseDownTimer = [[NSTimer scheduledTimerWithTimeInterval: self.timeIntervalForDrag target:self selector:@selector(startDrag:) userInfo: event  repeats:NO] retain];
    
    if( dcmPixList)
    {
        [drawLock lock];
        
        @try
        {
            [self deleteLens];
            
            [self erase2DPointMarker];
            if( blendingView) [blendingView erase2DPointMarker];
            
            NSPoint     eventLocation = [event locationInWindow];
            NSRect      size = [self frame];
            ToolMode	tool;
            
            [self mouseMoved: event];	// Update some variables...
            
            start = previous = [self convertPoint:eventLocation fromView: nil];
            
            BOOL roiHit = NO;
            
            if( [self roiTool: currentTool] || currentTool == tRepulsor || currentTool == tROISelector)
            {
                NSPoint tempPt = [self convertPoint:eventLocation fromView: nil];
                tempPt = [self ConvertFromNSView2GL:tempPt];
                if( [self clickInROI: tempPt]) roiHit = YES;
            }
            
            if( roiHit == NO)
                tool = [self getTool: event];
            else
                tool = currentTool;
            
            startImage = curImage;
            [self setStartWLWW];
            startScaleValue = scaleValue;
            rotationStart = rotation;
            blendingFactorStart = blendingFactor;
            scrollMode = 0;
            resizeTotal = 1;
            
            originStart = origin;
            
            mesureB = mesureA = [self convertPoint:eventLocation fromView: nil];
            mesureB.y = mesureA.y = size.size.height - mesureA.y ;
            
            roiRect.origin = [self convertPoint:eventLocation fromView: nil];
            roiRect.origin.y = size.size.height - roiRect.origin.y;
            
            int clickCount = 1;
            @try
            {
                if( [event type] ==	NSLeftMouseDown || [event type] ==	NSRightMouseDown || [event type] ==	NSLeftMouseUp || [event type] == NSRightMouseUp)
                    clickCount = [event clickCount];
            }
            @catch (NSException * e)
            {
                clickCount = 1;
            }
            
            if( clickCount > 1 && _mouseDownTimer)
                [self deleteMouseDownTimer];
            
            if( clickCount == 2 && [self window] == [[BrowserController currentBrowser] window])
            {
                [[BrowserController currentBrowser] matrixDoublePressed:nil];
            }
            else if( clickCount == 2 && roiHit == NO && ([[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSCommandKeyMask) && [self actionForHotKey: @"dbl-click + cmd"])
            {
                return;
            }
            else if( clickCount == 2 && roiHit == NO && ([[[NSApplication sharedApplication] currentEvent] modifierFlags] & NSAlternateKeyMask) && [self actionForHotKey: @"dbl-click + alt"])
            {
                return;
            }
            else if( clickCount == 2 && roiHit == NO && stringID == nil && [self actionForHotKey: @"dbl-click"])
            {
                return;
            }
            
            crossMove = -1;
            if (tool == tCross && [self is2DViewer])
            {
                [self deleteMouseDownTimer];
                [self mouseDraggedCrosshair:event];
            }
            
            if( tool == tRotate)
            {
                NSPoint current = [self currentPointInView:event];
                
                current.x -= [self frame].size.width/2.;
                current.y -= [self frame].size.height/2.;
                
                float sign = 1;
                
                if( xFlipped) sign = -sign;
                if( yFlipped) sign = -sign;
                
                rotationStart -= sign*atan2( current.x, current.y) / deg2rad;
            }
            
            if(tool == tRepulsor)
            {
                [self deleteMouseDownTimer];
                
                [[self windowController] addToUndoQueue:@"roi"];
                
                NSPoint tempPt = [self convertPoint:eventLocation fromView: nil];
                tempPt = [self ConvertFromNSView2GL:tempPt];
                
                BOOL clickInROI = NO;
                for( ROI *r in curRoiList)
                {
                    if([r clickInROI:tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :YES])
                    {
                        clickInROI = YES;
                    }
                }
                
                if(!clickInROI)
                {
                    for( ROI *r in curRoiList)
                    {
                        if([r clickInROI:tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :NO])
                        {
                            clickInROI = YES;
                        }
                    }
                }
                
                if(clickInROI)
                {
                    currentTool = tPencil;
                    tool = tPencil;
                    repulsorROIEdition = YES;
                }
                else
                {
                    [self deleteMouseDownTimer];
                    repulsorColorTimer = [[NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(setAlphaRepulsor:) userInfo:event repeats:YES] retain];
                    repulsorAlpha = 0.1;
                    repulsorAlphaSign = 1.0;
                    repulsorRadius = 0;
                    
                    float pixSpacingRatio = 1.0;
                    if ( self.pixelSpacingY != 0 && self.pixelSpacingX != 0 )
                        pixSpacingRatio = self.pixelSpacingY / self.pixelSpacingX;
                    
                    NSArray *roiArray = [self selectedROIs];
                    if( [roiArray count] == 0) roiArray = curRoiList;
                    
                    float distance = 0;
                    if( [roiArray count]>0)
                    {
                        ROI *r = [roiArray objectAtIndex:0];
                        if( r.type != tPlain && r.type != tArrow && r.type != tAngle && r.type != tAxis && r.type != tDynAngle && r.type != tTAGT)
                        {
                            NSPoint pt = [[[[roiArray objectAtIndex:0] points] objectAtIndex:0] point];
                            float dx = (pt.x-tempPt.x);
                            float dx2 = dx * dx;
                            float dy = (pt.y-tempPt.y)*pixSpacingRatio;
                            float dy2 = dy * dy;
                            distance = sqrt(dx2 + dy2);
                        }
                    }
                    
                    NSMutableArray *points;
                    for( int i = 0; i < [roiArray count]; i++ )
                    {
                        ROI *r = [roiArray objectAtIndex: i];
                        if( r.type != tPlain && r.type != tArrow && r.type != tAngle && r.type != tAxis && r.type != tDynAngle && r.type != tTAGT)
                        {
                            points = [r points];
                            
                            for( int j = 0; j < [points count]; j++ )
                            {
                                NSPoint pt = [[points objectAtIndex:j] point];
                                float dx = (pt.x-tempPt.x);
                                float dx2 = dx * dx;
                                float dy = (pt.y-tempPt.y) *pixSpacingRatio;
                                float dy2 = dy * dy;
                                float d = sqrt(dx2 + dy2);
                                distance = (d < distance) ? d : distance ;
                            }
                        }
                    }
                    repulsorRadius = (int) ((distance + 0.5) * 0.8);
                    if(repulsorRadius < 2) repulsorRadius = 2;
                    if(repulsorRadius>self.curDCM.pwidth/2) repulsorRadius = self.curDCM.pwidth/2;
                    
                    if( [roiArray count] == 0 || distance == 0)
                    {
                        NSRunCriticalAlertPanel(NSLocalizedString(@"Repulsor",nil),NSLocalizedString(@"The Repulsor tool works only if ROIs (Length ROI, Opened and Closed Polygon ROI and Pencil ROI) are on the image.",nil), NSLocalizedString(@"OK",nil), nil,nil);
                    }
                }
            }
            
            if(tool == tROISelector)
            {
                ROISelectorSelectedROIList = [[NSMutableArray array] retain];
                
                // if shift key is pressed, we need to keep track of the ROIs that were selected before the click
                if([event modifierFlags] & NSShiftKeyMask)
                {
                    for( ROI *r in curRoiList)
                    {
                        if([r ROImode]==ROI_selected)
                            [ROISelectorSelectedROIList addObject: r];
                    }
                }
                
                NSPoint tempPt = [self convertPoint:eventLocation fromView: nil];
                
                ROISelectorStartPoint = tempPt;
                ROISelectorEndPoint = tempPt;
                
                ROISelectorStartPoint.y = [self frame].size.height - ROISelectorStartPoint.y;
                ROISelectorEndPoint.y = [self frame].size.height - ROISelectorEndPoint.y;
                
                [self deleteMouseDownTimer];
                
                tempPt = [self ConvertFromNSView2GL:tempPt];
                
                BOOL clickInROI = NO;
                for( ROI *r in curRoiList)
                {
                    if([r clickInROI:tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :YES])
                    {
                        clickInROI = YES;
                    }
                }
                
                if(!clickInROI)
                {
                    for( ROI *r in curRoiList)
                    {
                        if([r clickInROI:tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :NO])
                        {
                            clickInROI = YES;
                        }
                    }
                }
                
                if( clickInROI)
                {
                    currentTool = tPencil;
                    tool = tPencil;
                    selectorROIEdition = YES;
                }
            }
            
            // ROI TOOLS
            if( [self roiTool:tool] == YES && crossMove == -1 )
            {
                mouseDraggedForROIUndo = NO;
                
                if( !mouseDraggedForROIUndo) {
                    mouseDraggedForROIUndo = YES;
                    [[self windowController] addToUndoQueue:@"roi"];
                }
                
                @try
                {
                    [self deleteMouseDownTimer];
                    
                    BOOL		DoNothing = NO;
                    NSInteger	selected = -1;
                    NSPoint tempPt = [self convertPoint:eventLocation fromView: nil];
                    tempPt = [self ConvertFromNSView2GL:tempPt];
                    
                    if ([[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"] == annotNone)
                    {
                        [[NSUserDefaults standardUserDefaults] setInteger: annotGraphics forKey: @"ANNOTATIONS"];
                        [DCMView setDefaults];
                    }
                    
                    BOOL roiFound = NO;
                    
                    if (!(([event modifierFlags] & NSCommandKeyMask) && ([event modifierFlags] & NSShiftKeyMask)))
                    {
                        for( ROI *r in curRoiList)
                        {
                            if( [r clickInROI: tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :YES])
                            {
                                selected = [curRoiList indexOfObject: r];
                                roiFound = YES;
                                break;
                            }
                        }
                    }
                    
                    //		if (roiFound)
                    //			if (curROI == [curRoiList objectAtIndex: selected])
                    //				DoNothing = YES;
                    
                    if( roiFound == NO)
                    {
                        for( ROI *r in curRoiList)
                        {
                            if( [r clickInROI: tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :NO])
                            {
                                selected = [curRoiList indexOfObject: r];
                                break;
                            }
                        }
                    }
                    
                    if (([event modifierFlags] & NSShiftKeyMask) && !([event modifierFlags] & NSCommandKeyMask) )
                    {
                        if( selected != -1 )
                        {
                            if( [[curRoiList objectAtIndex: selected] ROImode] == ROI_selected)
                            {
                                [[curRoiList objectAtIndex: selected] setROIMode: ROI_sleep];
                                // unselect all ROIs in the same group
                                [[self windowController] setMode:ROI_sleep toROIGroupWithID:[[curRoiList objectAtIndex:selected] groupID]];
                                DoNothing = YES;
                            }
                        }
                    }
                    else
                    {
                        if( selected == -1 || ( [[curRoiList objectAtIndex: selected] ROImode] != ROI_selected &&  [[curRoiList objectAtIndex: selected] ROImode] != ROI_selectedModify))
                        {
                            // Unselect previous ROIs
                            for( ROI *r in curRoiList) [r setROIMode : ROI_sleep];
                        }
                    }
                    
                    if( DoNothing == NO)
                    {
                        if( selected >= 0 && drawingROI == NO)
                        {
                            [curROI autorelease];
                            curROI = nil;
                            
                            // Bring the selected ROI to the first position in array
                            ROI *roi = [curRoiList objectAtIndex: selected];
                            
                            [[self windowController] bringToFrontROI: roi];
                            
                            selected = [curRoiList indexOfObject: roi];
                            
                            long roiVal = [roi clickInROI: tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :YES];
                            if( roiVal == ROI_sleep)
                                roiVal = [roi clickInROI: tempPt :self.curDCM.pwidth/2. :self.curDCM.pheight/2. :scaleValue :NO];
                            
                            if( [self is2DViewer])
                                [[self windowController] setMode:roiVal toROIGroupWithID:[roi groupID]]; // change the mode to the whole group before the selected ROI!
                            
                            [roi setROIMode: roiVal];
                            
                            NSArray *winList = [[NSApplication sharedApplication] windows];
                            BOOL	found = NO;
                            
                            if( [self is2DViewer])
                            {
                                for( int i = 0; i < [winList count]; i++)
                                {
                                    id controller = [[winList objectAtIndex:i] windowController];
                                    
                                    // Not a ROI window that is closing: its -windowWillClose:
                                    // autoreleased it, and it goes with a window shown again.
                                    if( [[controller windowNibName] isEqualToString:@"ROI"] && !([controller respondsToSelector: @selector(windowWillClose)] && [controller windowWillClose]))
                                    {
                                        found = YES;
                                        
                                        [[[winList objectAtIndex:i] windowController] setROI: roi :[self windowController]];
                                        if( clickCount > 1)
                                            [[winList objectAtIndex:i] makeKeyAndOrderFront: self];
                                    }
                                }
                                
                                if( clickCount > 1)
                                {
                                    if( found == NO)
                                    {
                                        ROIWindow* roiWin = [[ROIWindow alloc] initWithROI: roi :[self windowController]];
                                        [roiWin showWindow:self];
                                    }
                                }
                            }
                        }
                        else // Start drawing a new ROI !
                        {
                            if( curROI)
                            {
                                drawingROI = [curROI mouseRoiDown:tempPt :scaleValue];
                                
                                if( drawingROI == NO)
                                {
                                    [curROI autorelease];
                                    curROI = nil;
                                }
                                
                                if( [curROI ROImode] == ROI_selected)
                                    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROISelectedNotification object: curROI userInfo: nil];
                            }
                            else
                            {
                                // Unselect previous ROIs
                                for( ROI *r in curRoiList) [r setROIMode : ROI_sleep];
                                
                                ROI*		aNewROI;
                                NSString	*roiName = nil, *finalName;
                                long		counter;
                                BOOL		existsAlready;
                                
                                drawingROI = NO;
                                
                                [curROI autorelease];
                                curROI = aNewROI = [[[ROI alloc] initWithType: tool : self.curDCM.pixelSpacingX :self.curDCM.pixelSpacingY : [DCMPix originCorrectedAccordingToOrientation: self.curDCM]] autorelease];	//NSMakePoint( self.curDCM.originX, self.curDCM.originY)];
                                [curROI retain];
                                
                                if ( [ROI defaultName] != nil )
                                {
                                    [aNewROI setName: [ROI defaultName]];
                                }
                                else
                                {
                                    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"EmptyNameForNewROIs"] == NO || tool == t2DPoint)
                                    {
                                        switch( tool)
                                        {
                                            case  tOval:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Oval ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tDynAngle:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Dynamic Angle ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tTAGT:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Perpendicular Distance ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tAxis:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Bone Axis ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tOPolygon:
                                            case tCPolygon:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Polygon ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tAngle:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Angle ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tArrow:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Arrow ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tPlain:
                                            case tPencil:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"ROI ", @"ROI = Region of Interest, keep the space at the end of the string")];
                                                break;
                                                
                                            case tMesure:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Measurement ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case tROI:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Rectangle ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            case t2DPoint:
                                                roiName = [NSString stringWithString: NSLocalizedString( @"Point ", @"keep the space at the end of the string")];
                                                break;
                                                
                                            default:;
                                        }
                                        
                                        if( roiName )
                                        {
                                            counter = 1;
                                            do
                                            {
                                                existsAlready = NO;
                                                
                                                finalName = [roiName stringByAppendingFormat:@"%d", (int) counter++];
                                                
                                                for( int i = 0; i < [dcmRoiList count]; i++)
                                                {
                                                    for( int x = 0; x < [[dcmRoiList objectAtIndex: i] count]; x++)
                                                    {
                                                        if( [[[[dcmRoiList objectAtIndex: i] objectAtIndex: x] name] isEqualToString: finalName])
                                                        {
                                                            existsAlready = YES;
                                                        }
                                                    }
                                                }
                                                
                                            } while (existsAlready != NO);
                                            
                                            [aNewROI setName: finalName];
                                        }
                                    }
                                }
                                
                                // Create aliases of current ROI to the entire series
                                if (([event modifierFlags] & NSShiftKeyMask) && !([event modifierFlags] & NSCommandKeyMask))
                                {
                                    for( int i = 0; i < [dcmRoiList count]; i++)
                                    {
                                        [[dcmRoiList objectAtIndex: i] addObject: aNewROI];
                                    }
                                    
                                    aNewROI.originalIndexForAlias = curImage;
                                    aNewROI.isAliased = YES;
                                }
                                else [curRoiList addObject: aNewROI];
                                
                                [aNewROI setCurView:self];
                                
                                if( [[NSUserDefaults standardUserDefaults] boolForKey: @"markROIImageAsKeyImage"])
                                {
                                    if( [self is2DViewer] == YES && [self isKeyImage] == NO && [[self windowController] isPostprocessed] == NO)
                                        [[self windowController] setKeyImage: self];
                                }
                                
                                [[self windowController] bringToFrontROI: aNewROI];
                                
                                drawingROI = [aNewROI mouseRoiDown: tempPt :scaleValue];
                                
                                if( drawingROI == NO)
                                {
                                    [curROI autorelease];
                                    curROI = nil;
                                }
                                
//								NSNumber *xx = nil, *yy = nil, *zz = nil;
//								if( [aNewROI type] == t2DPoint)
//								{
//									float location[ 3];
//
//									[self.curDCM convertPixX: [[[aNewROI points] objectAtIndex:0] x] pixY: [[[aNewROI points] objectAtIndex:0] y] toDICOMCoords: location pixelCenter: YES];
//
//									xx = [NSNumber numberWithFloat: location[ 0]];
//									yy = [NSNumber numberWithFloat: location[ 1]];
//									zz = [NSNumber numberWithFloat: location[ 2]];
//								}
                                
                                if( [aNewROI ROImode] == ROI_selected)
                                    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixROISelectedNotification object: aNewROI userInfo: nil];
                                
                                NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:	aNewROI,							@"ROI",
                                                          [NSNumber numberWithInt:curImage],	@"sliceNumber",
                                                          //xx, @"x", yy, @"y", zz, @"z",
                                                          nil];
                                
                                [[NSNotificationCenter defaultCenter] postNotificationName: OsirixAddROINotification object: self userInfo:userInfo];
                            }
                        }
                    }
                    
                    [self deleteInvalidROIs];
                }
                @catch (NSException * e)
                {
                    NSLog( @"**** mouseDown ROI : %@", e);
                }
            }
            
            currentMouseEventTool = tool;
            
            [self mouseDragged:event];
        }
        @catch (NSException * e)
        {
            N2LogExceptionWithStackTrace(e);
        }
        
        [drawLock unlock];
    }
    
    //	float pixPosition[ 3];
    //	float slicePosition[ 3];
    //	float dcmPosition[ 3];
    //
    //	pixPosition[ 0] = 256;
    //	pixPosition[ 1] = 256;
    //	pixPosition[ 2] = curImage;
    //
    //	NSLog( @"IN - Pixel coordinates in slice: %f %f slice index: %d", pixPosition[ 0], pixPosition[ 1], (int) pixPosition[ 2]);
    //
    //	[[dcmPixList objectAtIndex: curImage] convertPixX: pixPosition[ 0] pixY: pixPosition[ 1] toDICOMCoords: dcmPosition pixelCenter: YES];
    //
    //	NSLog( @"DICOM coordinates in mm : %f %f %f", dcmPosition[ 0], dcmPosition[ 1], dcmPosition[ 2]);
    //
    //	[[dcmPixList objectAtIndex: 0] convertDICOMCoords: dcmPosition toSliceCoords: slicePosition pixelCenter: YES];
    //
    //	slicePosition[ 0] /= [self.curDCM pixelSpacingX];
    //	slicePosition[ 1] /= [self.curDCM pixelSpacingY];
    //	slicePosition[ 2] /= [self.curDCM sliceInterval];
    //
    //	NSLog( @"OUT - Pixel coordinates in slice: %f %f slice index: %d", slicePosition[ 0], slicePosition[ 1], (int) slicePosition[ 2]);
}

static short HorosImageIndexByAddingScroll(short current, double change, short *increment)
{
    if (!isfinite(change)) { *increment = 0; return current; }
    // Keep truncation toward zero for ordinary wheel steps. Clamp before narrowing
    // so a large event cannot wrap the legacy index to the opposite end of a series.
    double next = fmax(SHRT_MIN, fmin(SHRT_MAX, (double)current + trunc(change)));
    *increment = (short)fmax(SHRT_MIN, fmin(SHRT_MAX, next - current));
    return (short)next;
}

static NSInteger HorosMovieIndexForScroll(NSInteger current, NSInteger count, double delta)
{
    if (count <= 0 || !isfinite(delta) || delta == 0) return current;
    double change = delta / -2.5;
    change = change >= 0 ? fmax(1, ceil(change)) : fmin(-1, floor(change));
    // Reduce before addition; repeated float subtraction can stall for large deltas.
    double result = fmod((double)current + fmod(change, (double)count), (double)count);
    if (result < 0) result += count;
    return (NSInteger)result;
}

- (void)scrollWheel:(NSEvent *)theEvent
{
    HorosPlanarPerformanceTrace *performanceTrace = self.horosPlanarPerformanceTrace;
    uint64_t inputSpan = [performanceTrace beginScroll:theEvent fromIndex:curImage];
    @try {
    float reverseScrollWheel;
    
    float deltaX = [theEvent deltaX];
    float deltaY = [theEvent deltaY];
    
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
    if (![theEvent hasPreciseScrollingDeltas])
    {
        deltaX = [theEvent scrollingDeltaX];
        deltaY = [theEvent scrollingDeltaY];
    }
#endif
    
    if (!isfinite(deltaX) || !isfinite(deltaY)) return;

    // macOS inverts these deltas when "natural" scrolling is on, while a
    // click-drag carries no such inversion. Undo it here so a system-wide
    // setting no longer decides whether the two gestures agree.
    double deviceSign = [HorosScrollDirection deviceOrientationSignInverted: theEvent.isDirectionInvertedFromDevice];
    deltaX *= deviceSign;
    deltaY *= deviceSign;

    if( [NSEvent pressedMouseButtons])
        return;
    
    
    if( curImage < 0) return;
    if( !drawing) return;
    if( [[self window] isVisible] == NO) return;
    if( [self is2DViewer] == YES)
    {
        if( [[self windowController] windowWillClose]) return;
    }
    
    if ([self is2DViewer] && dcmPixList && ![stringID isEqualToString:@"previewDatabase"])
    {
        NSEventPhase phase = theEvent.phase, momentum = theEvent.momentumPhase;
        NSEventModifierFlags flags = theEvent.modifierFlags;
        BOOL slabGesture = (flags & NSEventModifierFlagOption) &&
                           !(flags & (NSEventModifierFlagCommand | NSEventModifierFlagShift));
        if (phase & (NSEventPhaseBegan | NSEventPhaseMayBegin))
        {
            consumeSlabScrollTail = NO;
            slabScrollRemainder = 0;
        }
        if (consumeSlabScrollTail && !slabGesture)
        {
            // Releasing Option in the same gesture must not turn its remaining
            // finger or momentum events into slice, phase, zoom or blend input.
            if (momentum != NSEventPhaseNone || phase != NSEventPhaseNone)
                return;
            consumeSlabScrollTail = NO; // A fresh discrete wheel event.
        }
        if (slabGesture)
        {
            // The momentum of a trackpad or Magic Mouse gesture keeps changing
            // the thickness while Option is held, as it keeps scrolling slices
            // without it (#986).
            consumeSlabScrollTail = theEvent.hasPreciseScrollingDeltas || phase != NSEventPhaseNone;
            if (theEvent.timestamp - slabScrollTimestamp > 0.3)
                slabScrollRemainder = 0;
            slabScrollTimestamp = theEvent.timestamp;
            // The series' backing order has no bearing on slab thickness.
            double change = [HorosScrollDirection wheelSignForFlippedData:NO] * deltaY / 2.5;
            if (change == 0) return;
            change = fmax(-128, fmin(128, change));
            NSInteger steps;
            if (theEvent.hasPreciseScrollingDeltas)
            {
                slabScrollRemainder += change;
                steps = (NSInteger)trunc(slabScrollRemainder);
                slabScrollRemainder -= steps;
            }
            else
                steps = change > 0 ? (NSInteger)ceil(change) : (NSInteger)floor(change);
            if (steps)
                [[self windowController] adjustThickSlabBySteps:steps];
            return;
        }
        slabScrollRemainder = 0;
    }

    BOOL SelectWindowScrollWheel = [[NSUserDefaults standardUserDefaults] boolForKey: @"SelectWindowScrollWheel"];
    
    if( [theEvent modifierFlags] & NSAlphaShiftKeyMask) // Caps Lock
        SelectWindowScrollWheel = !SelectWindowScrollWheel;
    
    if( SelectWindowScrollWheel)
    {
        if( [self is2DViewer])
        {
            if( [ViewerController isFrontMost2DViewer: self.window] == NO)
            {
                [[self window] makeKeyAndOrderFront: self];
                [self.windowController windowDidBecomeMain:[NSNotification notificationWithName:NSWindowDidBecomeMainNotification object:self.window]]; //If the application is in background, it will not automatically called.
            }
        }
        else if( [[self window] isMainWindow] == NO)
            [[self window] makeKeyAndOrderFront: self];
    }
    
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"ZoomWithHorizonScroll"] == NO) deltaX = 0;
    
    reverseScrollWheel = [HorosScrollDirection wheelSignForFlippedData: flippedData];
    
    if( dcmPixList)
    {
        short inc = 0;
        
        if( [stringID isEqualToString:@"previewDatabase"])
        {
            [super scrollWheel: theEvent];
        }
        else
        {
            //NSLog(@"DeltaY = %f , DeltaX = %f",deltaY,deltaX);
            
            if( fabs(deltaY) * 2.0f >  fabs( deltaX) )
            {
                if( [theEvent modifierFlags]  & NSCommandKeyMask)
                {
                    if( [self is2DViewer] && blendingView)
                    {
                        float change = deltaY / -0.2f;
                        
                        blendingFactor += change;
                        [self setBlendingFactor: blendingFactor];
                    }
                }
                else if( ([theEvent modifierFlags] & (NSAlternateKeyMask | NSShiftKeyMask)) == (NSAlternateKeyMask | NSShiftKeyMask))
                {
                    if( [self is2DViewer] && [[self windowController] maxMovieIndex] > 1)
                    {
                        // 4D Direction scroll - Cardiac CT eg
                        NSInteger next = HorosMovieIndexForScroll([[self windowController] curMovieIndex],
                                                                 [[self windowController] maxMovieIndex], deltaY);
                        [[self windowController] setMovieIndex:next];
                    }
                }
                else if( [theEvent modifierFlags]  & NSShiftKeyMask)
                {
                    float change = reverseScrollWheel * deltaY / 2.5f;
                    
                    if( change >= 0)
                    {
                        change = ceil( change);
                        if( change < 1) change = 1;
                        
                        curImage = HorosImageIndexByAddingScroll(curImage, (double)self.curDCM.stack * change, &inc);
                    }
                    else
                    {
                        change = floor( change);
                        if( change > -1) change = -1;
                        
                        curImage = HorosImageIndexByAddingScroll(curImage, (double)self.curDCM.stack * change, &inc);
                    }
                }
                else
                {
                    float change = reverseScrollWheel * deltaY / 2.5f;
                    
                    if( change > 0)
                    {
                        if( [PluginManager isComPACS])
                            change = 1;
                        else if( change < 1)
                            change = 1;
                        
                        curImage = HorosImageIndexByAddingScroll(curImage, (double)_imageRows * _imageColumns * change, &inc);
                    }
                    else
                    {
                        if( [PluginManager isComPACS])
                            change = -1;
                        else if( change > -1)
                            change = -1;
                        
                        curImage = HorosImageIndexByAddingScroll(curImage, (double)_imageRows * _imageColumns * change, &inc);
                    }
                }
            }
            else if( fabs( deltaX) > 0.7 )
            {
                // Slice navigation must not cancel the pending series fit.
                // Only a gesture that actually changes the user's zoom wins
                // over the asynchronous opening result.
                [self cancelOpeningScaleToFitForInteraction];
                [self mouseMoved: theEvent];	// Update some variables...
                
                float sScaleValue = scaleValue;
                
                [self setScaleValue:sScaleValue + deltaX * scaleValue / 10];
                [self setOriginX: ((origin.x * scaleValue) / sScaleValue) Y: ((origin.y * scaleValue) / sScaleValue)];
                
                if( [self is2DViewer] == YES)
                    [[self windowController] propagateSettings];
                
                [self setNeedsDisplay:YES];
            }
            
            if( [self scrollThroughSeriesIfNecessary: curImage])
            {
            }
            else if( [dcmPixList count] > 3 && [[NSUserDefaults standardUserDefaults] boolForKey:@"loopScrollWheel"])
            {
                if( curImage < 0) curImage = (long)[dcmPixList count]-1;
                if( curImage >= [dcmPixList count]) curImage = 0;
            }
            else
            {
                if( curImage < 0) curImage = 0;
                if( curImage >= [dcmPixList count]) curImage = (long)[dcmPixList count]-1;
            }
            
            if( listType == 'i') [self setIndex:curImage];
            else [self setIndexWithReset:curImage :YES];
            
            if( matrix ) {
                NSInteger rows, cols; [matrix getNumberOfRows:&rows columns:&cols];  if( cols < 1) cols = 1;
                [matrix selectCellAtRow :curImage/cols column:curImage%cols];
            }
            
            if( [self is2DViewer] == YES)
                [[self windowController] adjustSlider];    //mouseDown:theEvent];
            
            // SYNCRO
            [self sendSyncMessage:inc];
            
            if( [self is2DViewer] == YES)
                [[self windowController] propagateSettings];
            
            //[self setNeedsDisplay:YES];
            if (fabs(deltaY) > 0 && fabs(deltaY)*2 > fabs(deltaX) &&
                !(theEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)))
                [self horosShowScrollPreviewAtWindowPoint:theEvent.locationInWindow];
            
            //[self displayIfNeeded];
        }
    }
    } @finally {
        [performanceTrace endScroll:inputSpan index:curImage];
    }
}

- (void) otherMouseDown:(NSEvent *)event
{
    [self cancelOpeningScaleToFitForInteraction];
    if ([self eventToPlugins:event]) return;
    
    if( curImage < 0) return;
    
    [[self window] makeKeyAndOrderFront: self];
    [[self window] makeFirstResponder: self];
    [self sendSyncMessage: 0];
    
    [self mouseDown: event];
}

- (void) rightMouseDown:(NSEvent *)event
{
    [self cancelOpeningScaleToFitForInteraction];
    if ([self eventToPlugins:event]) return;
    
    if( curImage < 0) return;
    
    [[self window] makeKeyAndOrderFront: self];
    [[self window] makeFirstResponder: self];
    [self sendSyncMessage: 0];
    
    if( pluginOverridesMouse)
    {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt: curImage], @"curImage", event, @"event", nil];
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRightMouseDownNotification object: self userInfo: userInfo];
        return;
    }
    
    [self mouseDown: event];
}


- (void) rightMouseUp:(NSEvent *)event
{
    if ([self eventToPlugins:event]) return;
    
    mouseDragging = NO;
    
    NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:  [NSNumber numberWithInt:curImage], @"curImage", event, @"event", nil];
    
    if( pluginOverridesMouse)
        [[NSNotificationCenter defaultCenter] postNotificationName: OsirixRightMouseUpNotification object: self userInfo: userInfo];
    else
    {
        int clickCount = 0;
        
        @try
        {
            if( [event type] ==	NSLeftMouseDown || [event type] ==	NSRightMouseDown || [event type] ==	NSLeftMouseUp || [event type] == NSRightMouseUp)
                clickCount = [event clickCount];
        }
        @catch (NSException * e)
        {
            clickCount = 1;
        }
        
        if (clickCount == 1)
        {
            if ([self is2DViewer])
            {
                ROI* roi = [self clickInROI:[self ConvertFromNSView2GL:[self convertPoint:[event locationInWindow] fromView:NULL]]];
                if (roi)
                    [[self windowController] computeContextualMenuForROI:roi];
                else [[self windowController] computeContextualMenu];
            }
            
            NSMenu *menu = [self menuForEvent:event];
            if( menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self];
        }
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateWLWWMenuNotification object: [DCMView findWLWWPreset: curWL :curWW :self.curDCM] userInfo: nil];
}

- (void)otherMouseDragged:(NSEvent *)event
{
    if ([self eventToPlugins:event]) return;
    [self mouseDragged:(NSEvent *)event];
}

-(void)otherMouseUp:(NSEvent*)event {
    [self eventToPlugins:event];
}

- (void)rightMouseDragged:(NSEvent *)event
{
    if ([self eventToPlugins:event]) return;
    
    if ( pluginOverridesMouse )
    {
        [self mouseMoved: event];	// Update some variables...
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                  [NSNumber numberWithInt:curImage], @"curImage", event, @"event", nil];
        [nc postNotificationName: OsirixRightMouseDraggedNotification object: self userInfo: userInfo];
        return;
    }
    
    [self mouseDragged:(NSEvent *)event];
}

-(NSMenu*) menuForEvent:(NSEvent *)theEvent
{
    if ( pluginOverridesMouse ) return nil;
    NSPoint contextualMenuWhere = [theEvent locationInWindow]; 	//JF20070103 WindowAnchored ctrl-clickPoint registered
    contextualMenuInWindowPosX = contextualMenuWhere.x;
    contextualMenuInWindowPosY = contextualMenuWhere.y;
    if (([theEvent modifierFlags] & NSControlKeyMask) && ([theEvent modifierFlags] & NSAlternateKeyMask)) return nil;
    NSMenu *menu = [[[self menu] copy] autorelease];
    if( curRoiList.count && menu)
    {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *labels = [menu addItemWithTitle:NSLocalizedString(@"ROI Labels...", nil)
            action:@selector(showCompleteROILabels:) keyEquivalent:@""];
        labels.target = self;
    }
    return menu;
}

- (IBAction) showCompleteROILabels:(id) sender
{
    if( self.window == nil) return;
    NSMutableArray *labels = [NSMutableArray array];
    // Snapshot complete fields, independently of compact or overflow rendering.
    for( ROI *roi in curRoiList)
        [labels addObject:@[roi.textualBoxLine1 ?: @"", roi.textualBoxLine2 ?: @"",
            roi.textualBoxLine3 ?: @"", roi.textualBoxLine4 ?: @"",
            roi.textualBoxLine5 ?: @"", roi.textualBoxLine6 ?: @""]];
    [HorosROILabelPresentation showLabels:labels inWindow:self.window];
}

- (IBAction) decreaseThickness: (id) sender
{
    for( ROI *r in curRoiList)
    {
        if( [r ROImode] == ROI_selected)
        {
            [r setThickness: [r thickness]-1];
        }
    }
    
    [self display];
}

- (IBAction) increaseThickness: (id) sender
{
    for( ROI *r in curRoiList)
    {
        if( [r ROImode] == ROI_selected)
        {
            [r setThickness: [r thickness]+1];
        }
    }
    
    [self display];
}

#pragma mark-
#pragma mark Mouse dragging methods

// Implemented in Swift since #834: DCMView+MouseDragging.swift.

#pragma mark-
#pragma mark ww/wl

// Implemented in Swift since #834: DCMView+WindowLevel.swift and
// DCMView+WindowLevel+Coordinates.swift. -initWithFrameInt: stays here, an
// initializer; -computeSliceIntersection:sliceFromTo:vector:origin:, whose
// float[2][3] parameter Swift cannot declare; and -setStudyDateIndex:, the
// setter of a property whose getter is synthesized.












- (id)initWithFrameInt:(NSRect)frameRect
{
    if( PETredTable == nil)
        [DCMView computePETBlendingCLUT];
    
    yearOld = nil;
    syncSeriesIndex = -1;
    mouseXPos = mouseYPos = 0;
    pixelMouseValue = 0;
    self.curDCM = nil;
    curRoiList = nil;
    blendingMode = 0;
    display2DPoint = NSMakePoint(0,0);
    colorBuf = nil;
    blendingColorBuf = nil;
    stringID = nil;
    mprVector[ 0] = 0;
    mprVector[ 1] = 0;
    crossMove = -1;
    
    cursor = [[NSCursor contrastCursor] retain];
    syncRelativeDiff = 0;
    volumicSeries = YES;
    
    currentToolRight = tZoom;
    
    thickSlabMode = 0;
    thickSlabStacks = 0;
    COPYSETTINGSINSERIES = YES;
    suppress_labels = NO;
    previousViewSize = frameRect.size;
    
    annotationType = [[NSUserDefaults standardUserDefaults] integerForKey:@"ANNOTATIONS"];
    [[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:@"ANNOTATIONS" options:NSKeyValueObservingOptionNew context:nil];
    [[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:@"LabelFONTNAME" options:NSKeyValueObservingOptionNew context:nil];
    [[NSUserDefaults standardUserDefaults] addObserver:self forKeyPath:@"LabelFONTSIZE" options:NSKeyValueObservingOptionNew context:nil];
    
    //	NSOpenGLPixelFormatAttribute attrs[] =
    //    {
    //			NSOpenGLPFAAccelerated,
    //			NSOpenGLPFANoRecovery,
    //            NSOpenGLPFADoubleBuffer,
    //			NSOpenGLPFADepthSize, (NSOpenGLPixelFormatAttribute)32,
    //			0
    //	};
    
    
    self = [super initWithFrame:frameRect];
    
    // The picture is drawn by Metal into the view's layer, and its graphics
    // and text into the layers of the annotation overlay above it (#728).
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    
    drawingFrameRect = [self convertRectToBacking: [self frame]]; //retina
    
    cursorTracking = [[NSTrackingArea alloc] initWithRect: [self visibleRect] options: (NSTrackingCursorUpdate | NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow) owner: self userInfo: nil];
    [self addTrackingArea: cursorTracking];
    
    blendingView = nil;
    
    NSNotificationCenter *nc;
    nc = [NSNotificationCenter defaultCenter];
    [nc addObserver: self
           selector: @selector(sync:)
               name: OsirixSyncNotification
             object: nil];
    
    [nc addObserver:self selector:@selector(patientCrosshairChanged:)
               name:HorosPatientCrosshairController.changeNotification object:nil];
    [nc	addObserver: self
           selector: @selector(Display3DPoint:)
               name: OsirixDisplay3dPointNotification
             object: nil];
    
    [nc addObserver: self
           selector: @selector(roiChange:)
               name: OsirixROIChangeNotification
             object: nil];
    
    [nc addObserver: self
           selector: @selector(roiRemoved:)
               name: OsirixRemoveROINotification
             object: nil];
    
    [nc addObserver: self
           selector: @selector(roiSelected:)
               name: OsirixROISelectedNotification
             object: nil];
    
    [nc addObserver: self
           selector: @selector(updateView:)
               name: OsirixUpdateViewNotification
             object: nil];
    
    [nc addObserver: self
           selector: @selector(setFontColor:)
               name:  @"DCMNewFontColor"
             object: nil];
			 
    [nc addObserver: self
           selector: @selector(changeGLFontNotification:)
               name:  OsirixGLFontChangeNotification
             object: nil];
    
    [nc addObserver: self
           selector: @selector(changeLabelGLFontNotification:)
               name:  OsirixLabelGLFontChangeNotification
             object: nil];
    
    [nc addObserver: self
           selector: @selector(screenParametersChanged:)
               name: NSApplicationDidChangeScreenParametersNotification
             object: nil];
    
    [nc	addObserver: self
           selector: @selector(changeWLWW:)
               name: OsirixChangeWLWWNotification
             object: nil];
    
    [nc addObserver: self selector: @selector( DCMViewMouseMovedUpdated:) name: @"DCMViewMouseMovedUpdated" object: nil];
    
    colorTransfer = NO;
    
    for ( unsigned int i = 0; i < 256; i++ )
    {
        alphaTable[i] = 0xFF;
        opaqueTable[i] = 0xFF;
        redTable[i] = i;
        greenTable[i] = i;
        blueTable[i] = i;
    }
    
    redFactor = 1.0;
    greenFactor = 1.0;
    blueFactor = 1.0;
    
    dcmPixList = nil;
    dcmFilesList = nil;
    
    blendingFactor = 0.5;
    fontColor = nil;
    
    //	[[NSNotificationCenter defaultCenter] postNotificationName:OsirixLabelGLFontChangeNotification object: self];
    //	[[NSNotificationCenter defaultCenter] postNotificationName:OsirixGLFontChangeNotification object: self];
    
    currentTool = tWL;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowWillClose:) name: NSWindowWillCloseNotification object: nil];
    
    //	_alternateContext = [[NSOpenGLContext alloc] initWithFormat:pixFmt shareContext:[self openGLContext]];
    
    repulsorRadius = 0;
    
    //    if( [[[[NSUserDefaults standardUserDefaults] persistentDomainForName: @"com.apple.CoreGraphics"] objectForKey: @"DisplayUseInvertedPolarity"] boolValue])
    //    {
    //        [self setWantsLayer: YES];
    //        CIFilter *CIColorInvert = [CIFilter filterWithName:@"CIColorInvert"];
    //        [CIColorInvert setDefaults];
    //        self.contentFilters = [NSArray arrayWithObject:CIColorInvert];
    //    }
    
    gInvertColors = [[[[NSUserDefaults standardUserDefaults] persistentDomainForName: @"com.apple.CoreGraphics"] objectForKey: @"DisplayUseInvertedPolarity"] boolValue];
    
    [HorosAnnotationOverlay overlayForView: self];
    
    return self;
}






- (void) computeSliceIntersection: (DCMPix*) oPix sliceFromTo: (float[2][3]) sft vector: (float*) vectorB origin: (float*) originB
{
    // Compute Slice From To Points
    
    float c1[ 3], c2[ 3], r[ 3], sc[ 3];
    int order[ 2];
    
    // originB is the physical DICOM plane origin, shared by all slice references.
    // Pixel-center offsets belong to the coordinate conversions below, not this plane.
    
    sft[ 0][ 0] = HUGE_VALF; sft[ 0][ 1] = HUGE_VALF; sft[ 0][ 2] = HUGE_VALF;
    sft[ 1][ 0] = HUGE_VALF; sft[ 1][ 1] = HUGE_VALF; sft[ 1][ 2] = HUGE_VALF;
    
    [oPix convertPixX: 0 pixY: 0 toDICOMCoords: c1 pixelCenter: YES];
    [oPix convertPixX: [oPix pwidth] pixY: 0 toDICOMCoords: c2 pixelCenter: YES];
    
    int x = 0, v;
    
    v = intersect3D_SegmentPlane( c1, c2, vectorB+6, originB, r);
    if( x < 2 && v != 0)
    {
        order[ x] = v;
        [self.curDCM convertDICOMCoords: r toSliceCoords: sc pixelCenter: YES];
        sft[ x][ 0] = sc[ 0]; sft[ x][ 1] = sc[ 1]; sft[ x][ 2] = sc[ 2];
        x++;
    }
    
    [oPix convertPixX: 0 pixY: [oPix pheight] toDICOMCoords: c1 pixelCenter: YES];
    [oPix convertPixX: 0 pixY: 0 toDICOMCoords: c2 pixelCenter: YES];
    
    v = intersect3D_SegmentPlane( c1, c2, vectorB+6, originB, r);
    if( x < 2 && v != 0)
    {
        order[ x] = v;
        [self.curDCM convertDICOMCoords: r toSliceCoords: sc pixelCenter: YES];
        sft[ x][ 0] = sc[ 0]; sft[ x][ 1] = sc[ 1]; sft[ x][ 2] = sc[ 2];
        x++;
    }
    
    [oPix convertPixX: [oPix pwidth] pixY: [oPix pheight] toDICOMCoords: c1 pixelCenter: YES];
    [oPix convertPixX: 0 pixY: [oPix pheight] toDICOMCoords: c2 pixelCenter: YES];
    
    v = intersect3D_SegmentPlane( c1, c2, vectorB+6, originB, r);
    if( x < 2 && v != 0)
    {
        order[ x] = v;
        [self.curDCM convertDICOMCoords: r toSliceCoords: sc pixelCenter: YES];
        sft[ x][ 0] = sc[ 0]; sft[ x][ 1] = sc[ 1]; sft[ x][ 2] = sc[ 2];
        x++;
    }
    
    [oPix convertPixX: [oPix pwidth] pixY: 0 toDICOMCoords: c1 pixelCenter: YES];
    [oPix convertPixX: [oPix pwidth] pixY: [oPix pheight] toDICOMCoords: c2 pixelCenter: YES];
    
    v = intersect3D_SegmentPlane( c1, c2, vectorB+6, originB, r);
    if( x < 2 && v != 0)
    {
        order[ x] = v;
        [self.curDCM convertDICOMCoords: r toSliceCoords: sc pixelCenter: YES];
        sft[ x][ 0] = sc[ 0]; sft[ x][ 1] = sc[ 1]; sft[ x][ 2] = sc[ 2];
        x++;
    }
    
    if( x != 2)
    {
        sft[ 0][ 0] = HUGE_VALF; sft[ 0][ 1] = HUGE_VALF; sft[ 0][ 2] = HUGE_VALF;
        sft[ 1][ 0] = HUGE_VALF; sft[ 1][ 1] = HUGE_VALF; sft[ 1][ 2] = HUGE_VALF;
    }
    else
    {
        if( order[ 0] == 1 && order[ 1] == 2)
        {
            sc[ 0] = sft[ 0][ 0];	sc[ 1] = sft[ 0][ 1];	sc[ 2] = sft[ 0][ 2];
            sft[ 0][ 0] = sft[ 1][ 0]; sft[ 0][ 1] = sft[ 1][ 1]; sft[ 0][ 2] = sft[ 1][ 2];
            sft[ 1][ 0] = sc[ 0]; sft[ 1][ 1] = sc[ 1]; sft[ 1][ 2] = sc[ 2];
        }
    }
}


- (void) setStudyDateIndex:(NSUInteger)s
{
    [studyDateBox release];
    studyDateBox = nil;
    
    studyDateIndex = s;
}



#pragma mark-
#pragma mark image transformation


- (void) applyImageTransformation
{
    
    roiLoadIdentity ();
    
    roiScalef (2.0f /(xFlipped ? -(drawingFrameRect.size.width) : drawingFrameRect.size.width), -2.0f / (yFlipped ? -(drawingFrameRect.size.height) : drawingFrameRect.size.height), 1.0f);
    roiRotatef (rotation, 0.0f, 0.0f, 1.0f);
    roiTranslatef( origin.x, -origin.y, 0.0f);
    roiScalef( 1.f, self.curDCM.pixelRatio, 1.f);
}

- (void) drawRect:(NSRect) r
{
    if( drawing == NO) return;
    
    @synchronized (self)
    {
        NSRect backingBounds = [self convertRectToBacking: [self frame]]; // Retina
        
        if( previousScalingFactor != self.window.backingScaleFactor && self.window.backingScaleFactor != 0)
        {
            if( previousScalingFactor)
            {
                scaleValue *= self.window.backingScaleFactor / previousScalingFactor;
                origin.x *= self.window.backingScaleFactor / previousScalingFactor;
                origin.y *= self.window.backingScaleFactor / previousScalingFactor;
            }
            previousScalingFactor = self.window.backingScaleFactor;
            

            [DCMView purgeStringTextureCache];
            
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixLabelGLFontChangeNotification object: self];
            [[NSNotificationCenter defaultCenter] postNotificationName: OsirixGLFontChangeNotification object: self];
            
            for( ROI *r in curRoiList)
                [r setCurView:self];
        }
        
        [self horosUpdateDrawableSize];
        [self drawFrame: backingBounds];
    }
}

// The picture is drawn by Metal into a layer of its own, the first of the
// view's layer: the annotation overlay's graphics and text are above it (#728).
- (CAMetalLayer *) horosPictureLayer
{
    CALayer *host = self.layer;
    CAMetalLayer *picture = (CAMetalLayer *) host.sublayers.firstObject;
    if( [picture isKindOfClass: [CAMetalLayer class]] == NO)
    {
        for( CALayer *sublayer in host.sublayers)
        {
            if( [sublayer isKindOfClass: [CAMetalLayer class]])
            {
                picture = (CAMetalLayer *) sublayer;
                [picture removeFromSuperlayer];
                break;
            }
        }
        if( [picture isKindOfClass: [CAMetalLayer class]] == NO)
        {
            picture = [CAMetalLayer layer];
            picture.device = [HorosPlanarHostRenderer device];
            picture.pixelFormat = MTLPixelFormatBGRA8Unorm;
            picture.framebufferOnly = YES;
            // The picture is shown with the transaction that shows its graphics
            // and text, so the three never show different frames.
            picture.presentsWithTransaction = YES;
            picture.opaque = YES;
            picture.anchorPoint = CGPointZero;
            picture.actions = @{ @"bounds": [NSNull null], @"position": [NSNull null], @"contents": [NSNull null] };
        }
        [host insertSublayer: picture atIndex: 0];
    }
    return picture;
}

- (BOOL) wantsUpdateLayer
{
    return YES;
}

- (BOOL) isOpaque
{
    return YES;
}

- (void) updateLayer
{
    [self drawRect: self.bounds];
}

- (void) horosUpdateDrawableSize
{
    if( self.layer == nil)
        return;
    CAMetalLayer *picture = [self horosPictureLayer];
    CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1;
    [CATransaction begin];
    [CATransaction setDisableActions: YES];
    picture.contentsScale = scale;
    picture.frame = self.bounds;
    // OpenGL put its bytes on the screen untouched, which is what a layer in the
    // screen's own colour space does, as the overlay's are.
    CGColorSpaceRef space = self.window.colorSpace.CGColorSpace;
    if( space && picture.colorspace != space)
        picture.colorspace = space;
    [CATransaction commit];
    NSSize size = [self convertSizeToBacking: self.bounds.size];
    CGSize drawable = CGSizeMake( MAX( 1, round( size.width)), MAX( 1, round( size.height)));
    if( CGSizeEqualToSize( picture.drawableSize, drawable) == NO)
        picture.drawableSize = drawable;
}

// What NSOpenGLView's reshape was called for: a new size.
- (void) setFrameSize:(NSSize) newSize
{
    [super setFrameSize: newSize];
    [self horosUpdateDrawableSize];
    [self reshape];
}

- (void) viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self horosUpdateDrawableSize];
    [self setNeedsDisplay: YES];
}

- (void) drawCrossLines:(float[2][3]) sft
{
    return [self drawCrossLines: sft perpendicular: NO withShift: 0];
}

- (void) drawCrossLines:(float[2][3]) sft withShift: (double) shift
{
    return [self drawCrossLines: sft perpendicular: NO withShift: shift];
}

- (void) drawCrossLines:(float[2][3]) sft withShift: (double) shift showPoint: (BOOL) showPoint
{
    return [self drawCrossLines: sft perpendicular: NO withShift: shift half: NO showPoint: showPoint];
}

- (void) drawCrossLines:(float[2][3]) sft perpendicular: (BOOL) perpendicular
{
    return [self drawCrossLines: sft perpendicular: perpendicular withShift: 0];
}

- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular withShift:(double) shift
{
    return [self drawCrossLines: sft perpendicular: perpendicular withShift: shift half: NO];
}

- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular withShift:(double) shift half:(BOOL) half
{
    return [self drawCrossLines: sft perpendicular: perpendicular withShift: shift half: half showPoint: NO];
}

- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular withShift:(double) shift half:(BOOL) half showPoint:(BOOL) showPoint
{
    float a[ 2] = {0, 0};	// perpendicular vector
    float c[2][3];
    
    for( int i = 0; i < 2; i++)
        for( int x = 0; x < 3; x++)
            c[i][x] = sft[i][x];
    
    if( perpendicular || shift != 0)
    {
        a[ 1] = c[ 0][ 0] - c[ 1][ 0];
        a[ 0] = c[ 0][ 1] - c[ 1][ 1];
        
        double t = a[ 1]*a[ 1] + a[ 0]*a[ 0];
        t = sqrt(t);
        a[0] = a[0]/t;
        a[1] = a[1]/t;
        
        c[ 0][ 0] += a[0]*shift;	c[ 0][ 1] -= a[1]*shift;
        c[ 1][ 0] += a[0]*shift;	c[ 1][ 1] -= a[1]*shift;
    }
    
    NSPoint (^viewPoint)(float, float) = ^(float sx, float sy) {
        return [HorosViewerReferenceLines renderedPointSliceX: sx
                                                       sliceY: sy
                                                pixelSpacingX: self.curDCM.pixelSpacingX
                                                pixelSpacingY: self.curDCM.pixelSpacingY
                                                        width: self.curDCM.pwidth
                                                       height: self.curDCM.pheight
                                                        scale: scaleValue];
    };
    
    if( showPoint)
    {
        roiEnable(GL_POINT_SMOOTH);
        roiPointSize( 12 * self.window.backingScaleFactor);
        
        roiBegin( GL_POINTS);
        float mx = (c[ 0][ 0] + c[ 1][ 0]) / 2.;
        float my = (c[ 0][ 1] + c[ 1][ 1]) / 2.;
        NSPoint mid = viewPoint(mx, my);
        roiVertex2f( mid.x, mid.y);
        roiEnd();
    }
    else
    {
        roiEnable(GL_LINE_SMOOTH);
        roiBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA );
        roiEnable(GL_BLEND);
        roiBegin(GL_LINES);
        NSPoint start = viewPoint(c[ 0][ 0], c[ 0][ 1]);
        roiVertex2f( start.x, start.y);
        
        if( half)
            roiVertex2f( 0, 0);
        else
        {
            NSPoint end = viewPoint(c[ 1][ 0], c[ 1][ 1]);
            roiVertex2f( end.x, end.y);
        }
        roiEnd();
    }
    
    
    if( perpendicular)
    {
        roiLineWidth(1.0 * self.window.backingScaleFactor);
        NSPoint plus0 = viewPoint(c[ 0][ 0]+a[0]*sliceFromToThickness/2., c[ 0][ 1]-a[1]*sliceFromToThickness/2.);
        NSPoint plus1 = viewPoint(c[ 1][ 0]+a[0]*sliceFromToThickness/2., c[ 1][ 1]-a[1]*sliceFromToThickness/2.);
        roiBegin(GL_LINES);
        roiVertex2f( plus0.x, plus0.y);
        roiVertex2f( plus1.x, plus1.y);
        roiEnd();
        
        NSPoint minus0 = viewPoint(c[ 0][ 0]-a[0]*sliceFromToThickness/2., c[ 0][ 1]+a[1]*sliceFromToThickness/2.);
        NSPoint minus1 = viewPoint(c[ 1][ 0]-a[0]*sliceFromToThickness/2., c[ 1][ 1]+a[1]*sliceFromToThickness/2.);
        roiBegin(GL_LINES);
        roiVertex2f( minus0.x, minus0.y);
        roiVertex2f( minus1.x, minus1.y);
        roiEnd();
    }
}

//- (NSOpenGLContext*) offscreenDisplay: (NSRect) r
//{
//	NSOpenGLPixelFormatAttribute attrs[] = { NSOpenGLPFAOffScreen, NSOpenGLPFADoubleBuffer, NSOpenGLPFADepthSize, (NSOpenGLPixelFormatAttribute)32, 0};
//    NSOpenGLPixelFormat* pixFmt = [[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] autorelease];
//
//	NSOpenGLContext * c = [[[NSOpenGLContext alloc] initWithFormat: pixFmt shareContext: nil] autorelease];
//
//	void* memBuffer = (void *) malloc (drawingFrameRect.size.width * drawingFrameRect.size.height * 4);
//	[c setOffScreen: memBuffer width: drawingFrameRect.size.width height: drawingFrameRect.size.height rowbytes: drawingFrameRect.size.width*4];
//
////	NSOpenGLContext * c = [self openGLContext];
//
//	[c makeCurrentContext];
////	CGLContextObj cgl_ctx = [[NSOpenGLContext currentContext] CGLContextObj];
//
////	GLuint framebuffer, renderbuffer;
////	GLenum status;
////	// Set the width and height appropriately for you image
////	GLuint texWidth = r.size.width,
////		   texHeight = r.size.height;
////
////	//Set up a FBO with one renderbuffer attachment
////	glGenFramebuffersEXT(1, &framebuffer);
////	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, framebuffer);
////	glGenRenderbuffersEXT(1, &renderbuffer);
////	glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, renderbuffer);
////	glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, texWidth, texHeight);
////	glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
////					 GL_RENDERBUFFER_EXT, renderbuffer);
////	status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
//////	if (status != GL_FRAMEBUFFER_COMPLETE_EXT)
////					// Handle errors
//
//	[self drawRect: r withContext: c];
//
//	// Make the window the target
////	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
//	//Your code to use the contents
//	// ...
//	// Delete the renderbuffer attachment
////	glDeleteRenderbuffersEXT(1, &renderbuffer);
//
//
//
//	return c;
//}

- (void) drawFrame:(NSRect)aRect
{
    HorosPlanarPerformanceTrace *performanceTrace = self.horosPlanarPerformanceTrace;
    uint64_t drawSpan = 0;
    long clutBars = CLUTBARS, annotations = annotationType;
    BOOL preparedROILabels = NO;
    BOOL frontMost = NO, is2DViewer = [self is2DViewer];
    float sf = self.window.backingScaleFactor;
    
    //	#ifndef OSIRIX_LIGHT
    //    iChatRunning = NO;
    //    if( is2DViewer)
    //        iChatRunning = [[IChatTheatreDelegate sharedDelegate] isIChatTheatreRunning];
    //	#else
    //    iChatRunning = NO;
    //	#endif
    
    if( is2DViewer)
        frontMost = self.window.isKeyWindow;    //[ViewerController isFrontMost2DViewer: [self window]];
    
    if( firstTimeDisplay == NO && is2DViewer)
    {
        firstTimeDisplay = YES;
        [self updatePresentationStateFromSeries];
    }
    
    //	if( iChatRunning)
    //	{
    //		if( drawLock == nil) drawLock = [[NSRecursiveLock alloc] init];
    //		[drawLock lock];
    //	}
    //	else
    {
        [drawLock release];
        drawLock = nil;
    }
    
    HorosAnnotationOverlay *annotationOverlay = [HorosAnnotationOverlay overlayForView: self];
    [annotationOverlay beginFrameWidth: aRect.size.width height: aRect.size.height];
    // Every graphic of the view is drawn by the canvas, from this transform: the
    // viewport in backing pixels and the identity, as glViewport and a reset
    // model-view matrix left OpenGL (#728).
    [annotationOverlay.canvas setModelview: CGAffineTransformIdentity viewport: NSMakeRect( 0, 0, aRect.size.width, aRect.size.height)];
    
    @try
    {
        
        if( noScale)
        {
            self.scaleValue = 1.0f;
            [self setOriginX: 0 Y: 0];
        }
        
        NSPoint offset = { 0.0f, 0.0f };
        
        //		if( ctx == _alternateContext)
        //			savedDrawingFrameRect = drawingFrameRect;
        
        drawingFrameRect = aRect;
        
        
        drawSpan = [performanceTrace beginDrawForIndex:curImage];
        
        // The picture, drawn by Metal into the layer and presented with this
        // frame's graphics and text; inverted there when the colours are.
        BOOL invertColors = gInvertColors && [stringID isEqualToString: @"export"] == NO;
        BOOL planarDrawn = dcmPixList && curImage > -1 &&
            [self horosDrawPlanarInLayer: [self horosPictureLayer] inverted: invertColors];
        if( planarDrawn == NO)
            [self horosClearLayer: [self horosPictureLayer] white: whiteBackground && dcmPixList && curImage > -1 inverted: invertColors];
        if (performanceTrace) [performanceTrace prepared:drawSpan metal:planarDrawn loadedLegacyTexture:NO
            gpuMilliseconds:planarDrawn ? self.horosPlanarLastCommandMilliseconds : -1];

        if( dcmPixList && curImage > -1)
        {
            BOOL noBlending = NO;
            
            if( is2DViewer == YES)
            {
                if( isKeyView == NO) noBlending = YES;
            }
            
            [performanceTrace imageDrawn:drawSpan];
            // The graphics start from the blending the image left, as they did
            // in OpenGL: off, with the fusion's function when one was drawn.
            roiDisable( GL_BLEND);
            if( blendingView != nil && syncOnLocationImpossible == NO && noBlending == NO)
                roiBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            else
                roiBlendFunc( GL_ONE, GL_ONE);
            if( is2DViewer)
            {
                if( [[self windowController] highLighted] > 0)
                {
                    roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
                    roiScalef (2.0f / drawingFrameRect.size.width, -2.0f /  drawingFrameRect.size.height, 1.0f); // scale to port per pixel scale
                    roiTranslatef (-(drawingFrameRect.size.width) / 2.0f, -(drawingFrameRect.size.height) / 2.0f, 0.0f); // translate center to upper left
                    
                    roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                    roiEnable(GL_BLEND);
                    
                    if( gInvertColors)
                        roiColor4f ( 0, 0, 0, [[self windowController] highLighted]);
                    else
                        roiColor4f (249./255., 240./255., 140./255., [[self windowController] highLighted]);
                    roiLineWidth(1.0 * sf);
                    roiBegin(GL_QUADS);
                    roiVertex2f(0.0, 0.0);
                    roiVertex2f(0.0, drawingFrameRect.size.height);
                    roiVertex2f(drawingFrameRect.size.width, drawingFrameRect.size.height);
                    roiVertex2f(drawingFrameRect.size.width, 0);
                    roiEnd();
                    roiDisable(GL_BLEND);
                }
            }
            
            // highlight the visible part of the view (the part visible through iChat)
            //			#ifndef OSIRIX_LIGHT
            //			if( iChatRunning && ctx!=_alternateContext && [[self window] isMainWindow] && isKeyView && iChatWidth>0 && iChatHeight>0)
            //			{
            //				roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
            //				roiScalef (2.0f / drawingFrameRect.size.width, -2.0f /  drawingFrameRect.size.height, 1.0f); // scale to port per pixel scale
            //				roiTranslatef (-(drawingFrameRect.size.width) / 2.0f, -(drawingFrameRect.size.height) / 2.0f, 0.0f); // translate center to upper left
            //				NSPoint topLeft;
            //				topLeft.x = drawingFrameRect.size.width/2 - iChatWidth/2.0;
            //				topLeft.y = drawingFrameRect.size.height/2 - iChatHeight/2.0;
            //
            //				roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            //				roiEnable(GL_BLEND);
            //
            //				roiColor4f (0.0f, 0.0f, 0.0f, 0.7f);
            //				roiLineWidth(1.0 * sf);
            //				roiBegin(GL_QUADS);
            //					roiVertex2f(0.0, 0.0);
            //					roiVertex2f(0.0, topLeft.y);
            //					roiVertex2f(drawingFrameRect.size.width, topLeft.y);
            //					roiVertex2f(drawingFrameRect.size.width, 0.0);
            //				roiEnd();
            //
            //				roiBegin(GL_QUADS);
            //					roiVertex2f(0.0, topLeft.y);
            //					roiVertex2f(topLeft.x, topLeft.y);
            //					roiVertex2f(topLeft.x, topLeft.y+iChatHeight);
            //					roiVertex2f(0.0, topLeft.y+iChatHeight);
            //				roiEnd();
            //
            //				roiBegin(GL_QUADS);
            //					roiVertex2f(topLeft.x+iChatWidth, topLeft.y);
            //					roiVertex2f(drawingFrameRect.size.width, topLeft.y);
            //					roiVertex2f(drawingFrameRect.size.width, topLeft.y+iChatHeight);
            //					roiVertex2f(topLeft.x+iChatWidth, topLeft.y+iChatHeight);
            //				roiEnd();
            //
            //				roiBegin(GL_QUADS);
            //					roiVertex2f(0.0, topLeft.y+iChatHeight);
            //					roiVertex2f(drawingFrameRect.size.width, topLeft.y+iChatHeight);
            //					roiVertex2f(drawingFrameRect.size.width, drawingFrameRect.size.height);
            //					roiVertex2f(0.0, drawingFrameRect.size.height);
            //				roiEnd();
            //
            //				roiColor4f (1.0f, 1.0f, 1.0f, 0.8f);
            //				roiBegin(GL_LINE_LOOP);
            //					roiVertex2f(topLeft.x, topLeft.y);
            //					roiVertex2f(topLeft.x, topLeft.y+iChatHeight);
            //					roiVertex2f(topLeft.x+iChatWidth, topLeft.y+iChatHeight);
            //					roiVertex2f(topLeft.x+iChatWidth, topLeft.y);
            //				roiEnd();
            //
            //				roiLineWidth(1.0 * sf);
            //				roiDisable(GL_BLEND);
            //
            //				// label
            //				NSPoint iChatTheatreSharedViewLabelPosition;
            //				iChatTheatreSharedViewLabelPosition.x = drawingFrameRect.size.width/2.0;
            //				iChatTheatreSharedViewLabelPosition.y = topLeft.y;
            //
            //				[self DrawNSStringGL:NSLocalizedString(@"iChat Theatre shared view", nil) : DCMViewMainFont :iChatTheatreSharedViewLabelPosition.x :iChatTheatreSharedViewLabelPosition.y align:DCMViewTextAlignCenter useStringTexture:YES];
            //			}
            //			#endif
            // ***********************
            // DRAW CLUT BARS ********
            
            if( is2DViewer == YES && annotations != annotNone) // && ctx!=_alternateContext)
            {
                roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
                roiScalef (2.0f /(drawingFrameRect.size.width), -2.0f / (drawingFrameRect.size.height), 1.0f); // scale to port per pixel scale
                
                if( clutBars == barOrigin || clutBars == barBoth)
                {
                    float			heighthalf = drawingFrameRect.size.height/2 - 1;
                    float			widthhalf = drawingFrameRect.size.width/2 - 1;
                    NSString		*tempString = nil;
                    
                    //#define BARPOSX1 50.f
                    //#define BARPOSX2 20.f
                    
#define BARPOSX1 62.f
#define BARPOSX2 32.f
                    
                    heighthalf = 0;
                    
                    //					roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
                    //					roiScalef (2.0f /(xFlipped ? -(drawingFrameRect.size.width) : drawingFrameRect.size.width), -2.0f / (yFlipped ? -(drawingFrameRect.size.height) : drawingFrameRect.size.height), 1.0f);
                    
                    roiLineWidth(1.0 * sf);
                    roiBegin(GL_LINES);
                    for( int i = 0; i < 256; i++ )
                    {
                        roiColor3ub ( redTable[ i], greenTable[ i], blueTable[ i]);
                        
                        roiVertex2f(  widthhalf - BARPOSX1*sf, heighthalf - (-128.f*sf + i*sf));
                        roiVertex2f(  widthhalf - BARPOSX2*sf, heighthalf - (-128.f*sf + i*sf));
                    }
                    roiColor3ub ( 128, 128, 128);
                    roiVertex2f(  widthhalf - BARPOSX1*sf, heighthalf - -128.f*sf);		roiVertex2f(  widthhalf - BARPOSX2*sf , heighthalf - -128.f*sf);
                    roiVertex2f(  widthhalf - BARPOSX1*sf, heighthalf - 127.f*sf);			roiVertex2f(  widthhalf - BARPOSX2*sf , heighthalf - 127.f*sf);
                    roiVertex2f(  widthhalf - BARPOSX1*sf, heighthalf - -128.f*sf);		roiVertex2f(  widthhalf - BARPOSX1*sf, heighthalf - 127.f*sf);
                    roiVertex2f(  widthhalf - BARPOSX2*sf ,heighthalf -  -128.f*sf);		roiVertex2f(  widthhalf - BARPOSX2*sf, heighthalf - 127.f*sf);
                    roiEnd();
                    
                    float barWW = self.curDCM.displayInverted ? -curWW : curWW;
                    if( curWW < 50 )
                    {
                        tempString = [NSString stringWithFormat: @"%0.4f", curWL - barWW/2];
                        [self DrawNSStringGL: tempString : DCMViewMainFont :widthhalf - BARPOSX1*sf: heighthalf - -133*sf rightAlignment: YES useStringTexture: NO];
                        
                        tempString = [NSString stringWithFormat: @"%0.4f", curWL];
                        [self DrawNSStringGL: tempString : DCMViewMainFont :widthhalf - BARPOSX1*sf: heighthalf - 0 rightAlignment: YES useStringTexture: NO];
                        
                        tempString = [NSString stringWithFormat: @"%0.4f", curWL + barWW/2];
                        [self DrawNSStringGL: tempString : DCMViewMainFont :widthhalf - BARPOSX1*sf: heighthalf - 120*sf rightAlignment: YES useStringTexture: NO];
                    }
                    else
                    {
                        tempString = [NSString stringWithFormat: @"%0.0f", curWL - barWW/2];
                        [self DrawNSStringGL: tempString : DCMViewMainFont :widthhalf - BARPOSX1*sf: heighthalf - -133*sf rightAlignment: YES useStringTexture: NO];
                        
                        tempString = [NSString stringWithFormat: @"%0.0f", curWL];
                        [self DrawNSStringGL: tempString : DCMViewMainFont :widthhalf - BARPOSX1*sf: heighthalf - 0 rightAlignment: YES useStringTexture: NO];
                        
                        tempString = [NSString stringWithFormat: @"%0.0f", curWL + barWW/2];
                        [self DrawNSStringGL: tempString : DCMViewMainFont :widthhalf - BARPOSX1*sf: heighthalf - 120*sf rightAlignment: YES useStringTexture: NO];
                    }
                } //clutBars == barOrigin || clutBars == barBoth
                
                if( blendingView )
                {
                    if( clutBars == barFused || clutBars == barBoth)
                    {
                        unsigned char	*bred = nil, *bgreen = nil, *bblue = nil;
                        float			heighthalf = drawingFrameRect.size.height/2 - 1;
                        float			widthhalf = drawingFrameRect.size.width/2 - 1;
                        float			bwl, bww;
                        NSString		*tempString = nil;
                        
                        if( [[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] isEqualToString: @"B/W Inverse"])
                        {
                            if( PETredTable == nil)
                                [DCMView computePETBlendingCLUT];
                            
                            bred = PETredTable;
                            bgreen = PETgreenTable;
                            bblue = PETblueTable;
                        }
                        else [blendingView getCLUT:&bred :&bgreen :&bblue];
                        
#define BBARPOSX1 55.f
#define BBARPOSX2 25.f
                        
                        heighthalf = 0;
                        
                        roiLineWidth(1.0 * sf);
                        roiBegin(GL_LINES);
                        
                        if( bred)
                        {
                            for( int i = 0; i < 256; i++ )
                            {
                                roiColor3ub ( bred[ i], bgreen[ i], bblue[ i]);
                                
                                roiVertex2f(  -widthhalf + BBARPOSX1*sf, heighthalf - (-128.f*sf + i*sf));
                                roiVertex2f(  -widthhalf + BBARPOSX2*sf, heighthalf - (-128.f*sf + i*sf));
                            }
                        }
                        else
                            NSLog( @"bred == nil");
                        
                        roiColor3ub ( 128, 128, 128);
                        roiVertex2f(  -widthhalf + BBARPOSX1*sf, heighthalf - -128.f*sf);		roiVertex2f(  -widthhalf + BBARPOSX2*sf , heighthalf - -128.f*sf);
                        roiVertex2f(  -widthhalf + BBARPOSX1*sf, heighthalf - 127.f*sf);         roiVertex2f(  -widthhalf + BBARPOSX2*sf , heighthalf - 127.f*sf);
                        roiVertex2f(  -widthhalf + BBARPOSX1*sf, heighthalf - -128.f*sf);		roiVertex2f(  -widthhalf + BBARPOSX1*sf, heighthalf - 127.f*sf);
                        roiVertex2f(  -widthhalf + BBARPOSX2*sf ,heighthalf -  -128.f*sf);		roiVertex2f(  -widthhalf + BBARPOSX2*sf, heighthalf - 127.f*sf);
                        roiEnd();
                        
                        [blendingView getWLWW: &bwl :&bww];
                        if( blendingView.curDCM.displayInverted) bww = -bww;
                        
                        if( curWW < 50)
                        {
                            tempString = [NSString stringWithFormat: @"%0.4f", bwl - bww/2];
                            [self DrawNSStringGL: tempString : DCMViewMainFont :-widthhalf + BBARPOSX1*sf + 4*sf: heighthalf - -133*sf];
                            
                            tempString = [NSString stringWithFormat: @"%0.4f", bwl];
                            [self DrawNSStringGL: tempString : DCMViewMainFont :-widthhalf + BBARPOSX1*sf + 4*sf: heighthalf - 0];
                            
                            tempString = [NSString stringWithFormat: @"%0.4f", bwl + bww/2];
                            [self DrawNSStringGL: tempString : DCMViewMainFont :-widthhalf + BBARPOSX1*sf + 4*sf: heighthalf - 120*sf];
                        }
                        else
                        {
                            tempString = [NSString stringWithFormat: @"%0.0f", bwl - bww/2];
                            [self DrawNSStringGL: tempString : DCMViewMainFont :-widthhalf + BBARPOSX1*sf + 4*sf: heighthalf - -133*sf];
                            
                            tempString = [NSString stringWithFormat: @"%0.0f", bwl];
                            [self DrawNSStringGL: tempString : DCMViewMainFont :-widthhalf + BBARPOSX1*sf + 4*sf: heighthalf - 0];
                            
                            tempString = [NSString stringWithFormat: @"%0.0f", bwl + bww/2];
                            [self DrawNSStringGL: tempString : DCMViewMainFont :-widthhalf + BBARPOSX1*sf + 4*sf: heighthalf - 120*sf];
                        }
                    }
                } //blendingView
            } //is2DViewer == YES
            
            if (annotations != annotNone)
            {
                roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
                roiScalef (2.0f /(xFlipped ? -(drawingFrameRect.size.width) : drawingFrameRect.size.width), -2.0f / (yFlipped ? -(drawingFrameRect.size.height) : drawingFrameRect.size.height), 1.0f); // scale to port per pixel scale
                
                //FRAME RECT IF MORE THAN 1 WINDOW and IF THIS WINDOW IS THE FRONTMOST : BORDER AROUND THE IMAGE
                
                if( [ViewerController numberOf2DViewer] > 1 && is2DViewer == YES && stringID == nil)
                {
                    // draw line around key View - RED BOX
                    
                    if( isKeyView && (frontMost || [ViewerController frontMostDisplayed2DViewerForScreen: self.window.screen] == self.windowController))
                    {
                        if( [[self windowController] FullScreenON] == FALSE)
                        {
                            float heighthalf = drawingFrameRect.size.height/2;
                            float widthhalf = drawingFrameRect.size.width/2;
                            
                            // red square
                            
                            //					roiEnable(GL_BLEND);
                            roiColor4f (1.0f, 0.0f, 0.0f, 0.8f);
                            roiLineWidth(8.0 * sf);
                            roiBegin(GL_LINE_LOOP);
                            roiVertex2f(  -widthhalf, -heighthalf);
                            roiVertex2f(  -widthhalf, heighthalf);
                            roiVertex2f(  widthhalf, heighthalf);
                            roiVertex2f(  widthhalf, -heighthalf);
                            roiEnd();
                            roiLineWidth(1.0 * sf);
                            //					roiDisable(GL_BLEND);
                        }
                    }
                }  //drawLines for ImageView Frames
                
                // Draw a dot line if the raw data overflows the displayed view
                if( OVERFLOWLINES && is2DViewer && stringID == nil)
                {
                    float heighthalf = drawingFrameRect.size.height/2;
                    float widthhalf = drawingFrameRect.size.width/2;
                    float offset = 4 * sf;
                    
                    NSRect dstRect = [self.curDCM usefulRectWithRotation: rotation scale: scaleValue xFlipped: xFlipped yFlipped: yFlipped];
                    NSPoint oo = [DCMPix rotatePoint: [self origin] aroundPoint:NSMakePoint( 0, 0) angle: -rotation*deg2rad];
                    dstRect.origin = NSMakePoint( drawingFrameRect.size.width/2 + oo.x - dstRect.size.width/2, drawingFrameRect.size.height/2 - oo.y - dstRect.size.height/2);
                    
                    roiColor4f (0, 1, 0.0f, 0.8f);
                    roiLineWidth( 3.0 * sf);
                    
                    roiPushAttrib( GL_ENABLE_BIT);
                    roiLineStipple( 4 * sf, 0xAAAA);
                    roiEnable(GL_LINE_STIPPLE);
                    
                    // Left
                    if( dstRect.origin.x <= -5)
                    {
                        roiBegin(GL_LINES);
                        roiVertex2f( -widthhalf +offset, dstRect.origin.y -heighthalf);
                        roiVertex2f( -widthhalf +offset, dstRect.origin.y +dstRect.size.height -heighthalf);
                        roiEnd();
                    }
                    
                    // Top
                    if( dstRect.origin.y <= -5)
                    {
                        roiBegin(GL_LINES);
                        roiVertex2f( dstRect.origin.x -widthhalf, -heighthalf +offset);
                        roiVertex2f( dstRect.origin.x +dstRect.size.width -widthhalf, -heighthalf +offset);
                        roiEnd();
                    }
                    
                    // Right
                    if( dstRect.origin.x + dstRect.size.width >= drawingFrameRect.size.width+5)
                    {
                        roiBegin(GL_LINES);
                        roiVertex2f( widthhalf -offset, dstRect.origin.y -heighthalf);
                        roiVertex2f( widthhalf -offset, dstRect.origin.y +dstRect.size.height -heighthalf);
                        roiEnd();
                    }
                    
                    // Bottom
                    if( dstRect.origin.y + dstRect.size.height >= drawingFrameRect.size.height+5)
                    {
                        roiBegin(GL_LINES);
                        roiVertex2f( dstRect.origin.x -widthhalf, heighthalf -offset);
                        roiVertex2f( dstRect.origin.x +dstRect.size.width -widthhalf, heighthalf -offset);
                        roiEnd();
                    }
                    
                    roiLineWidth(1.0 * sf);
                    roiPopAttrib();
                }
                
                if ((_imageColumns > 1 || _imageRows > 1) && is2DViewer == YES && stringID == nil )
                {
                    float heighthalf = drawingFrameRect.size.height/2 - 1;
                    float widthhalf = drawingFrameRect.size.width/2 - 1;
                    
                    roiColor3f (0.5f, 0.5f, 0.5f);
                    roiLineWidth(1.0 * sf);
                    roiBegin(GL_LINE_LOOP);
                    roiVertex2f(  -widthhalf, -heighthalf);
                    roiVertex2f(  -widthhalf, heighthalf);
                    roiVertex2f(  widthhalf, heighthalf);
                    roiVertex2f(  widthhalf, -heighthalf);
                    roiEnd();
                    roiLineWidth(1.0 * sf);
                    
                    // KEY VIEW - RED BOX
                    
                    if( isKeyView && (frontMost || [ViewerController frontMostDisplayed2DViewerForScreen: self.window.screen] == self.windowController))
                    {
                        float heighthalf = drawingFrameRect.size.height/2 - 1;
                        float widthhalf = drawingFrameRect.size.width/2 - 1;
                        
                        roiColor3f (1.0f, 0.0f, 0.0f);
                        roiLineWidth(2.0 * sf);
                        roiBegin(GL_LINE_LOOP);
                        roiVertex2f(  -widthhalf, -heighthalf);
                        roiVertex2f(  -widthhalf, heighthalf);
                        roiVertex2f(  widthhalf, heighthalf);
                        roiVertex2f(  widthhalf, -heighthalf);
                        roiEnd();
                        roiLineWidth(1.0 * sf);
                    }
                }
                
                roiRotatef (rotation, 0.0f, 0.0f, 1.0f); // rotate matrix for image rotation
                roiTranslatef( origin.x, -origin.y, 0.0f);
                roiScalef( 1.f, self.curDCM.pixelRatio, 1.f);
                
                // Draw ROIs
                BOOL drawROI = NO;
                
                if( is2DViewer == YES) drawROI = [[[self windowController] roiLock] tryLock];
                else drawROI = YES;
                
                if( drawROI )
                {
                    BOOL resetData = NO;
                    if(_imageColumns > 1 || _imageRows > 1) resetData = YES;	//For alias ROIs
                    
                    
                    rectArray = [[NSMutableArray alloc] initWithCapacity: [curRoiList count]];
                    
                    // The ROIs are drawn by the canvas, from this state (#727).
                    [[HorosROICanvas current] resetFrameState];
                    
                    for( int i = (long)[curRoiList count]-1; i >= 0; i--)
                    {
                        ROI *r = [[curRoiList objectAtIndex:i] retain];	// If we are not in the main thread (iChat), we want to be sure to keep our ROIs
                        
                        if( resetData) [r recompute];
                        [r setCurView:self];
                        [r drawROI: scaleValue : self.curDCM.pwidth / 2. : self.curDCM.pheight / 2. : self.curDCM.pixelSpacingX : self.curDCM.pixelSpacingY];
                        
                        [r release];
                    }
                    
                    [self drawPendingLength];

                    // let the pluginSDK draw anything it needs to draw, we use a notification for now, but that is nasty style, we really should be calling a method
#ifndef OSIRIX_LIGHT
                    [[OSIEnvironment sharedEnvironment] drawDCMView:self];
#endif
                    
                    // Place text after this frame's fixed annotation bounds are known.
                    preparedROILabels = YES;
                }
                
                if( drawROI && is2DViewer == YES) [[[self windowController] roiLock] unlock];
                
                // Draw 2D point cross (used when double-click in 3D panel)
                // BLUE CROSS
                if( is2DViewer)
                {
                    [self draw2DPointMarker];
                    if( blendingView) [blendingView draw2DPointMarker];
                }
                // Draw any Plugin objects
                
                NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:	[NSNumber numberWithFloat: scaleValue], @"scaleValue",
                                          [NSNumber numberWithFloat: self.curDCM.pwidth /2. ], @"offsetx",
                                          [NSNumber numberWithFloat: self.curDCM.pheight /2.], @"offsety",
                                          [NSNumber numberWithFloat: self.curDCM.pixelSpacingX], @"spacingX",
                                          [NSNumber numberWithFloat: self.curDCM.pixelSpacingY], @"spacingY",
                                          nil];
                
                // OsirixDrawObjectsNotification handed plugins the OpenGL context; there
                // is none since #728, and only the canvas notification is posted.
                HorosROICanvas *objectsCanvas = [HorosROICanvas current];
                if( objectsCanvas)
                {
                    NSMutableDictionary *canvasInfo = [NSMutableDictionary dictionaryWithDictionary: userInfo];
                    [canvasInfo setObject: objectsCanvas forKey: @"canvas"];
                    [[NSNotificationCenter defaultCenter] postNotificationName: HorosDrawObjectsCanvasNotification object: self userInfo: canvasInfo];
                }
                
                [self subDrawRect: aRect];
                self.scaleValue = scaleValue;
                
                // Patient-space marker in both active and inactive viewers. The
                // surrounding host transform already accounts for pan/zoom/flip/rotation.
                float patientCross[3];
                if (stringID == nil && [self getPatientCrosshairSliceCoordinates:patientCross])
                {
                    float x = scaleValue * (patientCross[0] / self.curDCM.pixelSpacingX - self.curDCM.pwidth * 0.5);
                    float y = scaleValue * (patientCross[1] / self.curDCM.pixelSpacingY - self.curDCM.pheight * 0.5);
                    float ratio = self.curDCM.pixelRatio;
                    if (ratio > 0)
                    {
                        roiPushAttrib(GL_ENABLE_BIT | GL_LINE_BIT | GL_CURRENT_BIT | GL_COLOR_BUFFER_BIT);
                        roiEnable(GL_BLEND);
                        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                        roiColor3f(0.0f, 0.8f, 0.2f);
                        roiLineWidth(2.0 * sf);
                        roiBegin(GL_LINES);
                        roiVertex2f(x - 12*sf, y); roiVertex2f(x - 4*sf, y);
                        roiVertex2f(x + 4*sf, y); roiVertex2f(x + 12*sf, y);
                        roiVertex2f(x, y - 12*sf/ratio); roiVertex2f(x, y - 4*sf/ratio);
                        roiVertex2f(x, y + 4*sf/ratio); roiVertex2f(x, y + 12*sf/ratio);
                        roiEnd();
                        roiPopAttrib();
                    }
                }

                //** SLICE CUT BETWEEN SERIES - CROSS REFERENCES LINES
                
                if( is2DViewer && (stringID == nil || [stringID isEqualToString:@"export"]) && frontMost == NO)
                {
                    roiBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA );
                    roiEnable(GL_BLEND);
                    roiEnable(GL_POINT_SMOOTH);
                    roiEnable(GL_LINE_SMOOTH);
                    roiEnable(GL_POLYGON_SMOOTH);
                    
                    if( DISPLAYCROSSREFERENCELINES)
                    {
                        //						NSUInteger modifiers = [NSEvent modifierFlags];
                        //						if( (modifiers & NSControlKeyMask) && (modifiers & NSAlternateKeyMask) && (modifiers & NSCommandKeyMask)) // Display all references lines for all images
                        //						{
                        //							for( DCMPix *o in [[ViewerController frontMostDisplayed2DViewer] pixList])
                        //							{
                        //								[self computeSlice: o :self.curDCM];
                        //
                        //								if( sliceFromTo[ 0][ 0] != HUGE_VALF)
                        //								{
                        //									roiColor3f (0.0f, 0.6f, 0.0f);
                        //									roiLineWidth(2.0 * sf);
                        //									[self drawCrossLines: sliceFromTo perpendicular: YES];
                        //
                        //									if( sliceFromTo2[ 0][ 0] != HUGE_VALF)
                        //									{
                        //										roiLineWidth(2.0 * sf);
                        //										[self drawCrossLines: sliceFromTo2 perpendicular: YES];
                        //									}
                        //								}
                        //							}
                        //						}
                        //						else
                        {
                            if( sliceFromTo[ 0][ 0] != HUGE_VALF)
                            {
                                if( sliceFromToS[ 0][ 0] != HUGE_VALF)
                                {
                                    roiColor3f (1.0f, 0.6f, 0.0f);
                                    
                                    roiLineWidth(2.0 * sf);
                                    [self drawCrossLines: sliceFromToS perpendicular: NO];
                                    
                                    roiLineWidth(2.0 * sf);
                                    [self drawCrossLines: sliceFromToE perpendicular: NO];
                                }
                                
                                roiColor3f (0.0f, 0.6f, 0.0f);
                                roiLineWidth(2.0 * sf);
                                [self drawCrossLines: sliceFromTo perpendicular: YES];
                                
                                if( sliceFromTo2[ 0][ 0] != HUGE_VALF)
                                {
                                    roiLineWidth(2.0 * sf);
                                    [self drawCrossLines: sliceFromTo2 perpendicular: YES];
                                }
                            }
                        }
                    }
                    
                    if( slicePoint3D[ 0] != HUGE_VALF)
                    {
                        float tempPoint3D[ 2];
                        
                        roiLineWidth(2.0 * sf);
                        
                        tempPoint3D[0] = slicePoint3D[ 0] / self.curDCM.pixelSpacingX;
                        tempPoint3D[1] = slicePoint3D[ 1] / self.curDCM.pixelSpacingY;
                        
                        tempPoint3D[0] -= self.curDCM.pwidth * 0.5f;
                        tempPoint3D[1] -= self.curDCM.pheight * 0.5f;
                        
                        roiColor3f (0.0f, 0.6f, 0.0f);
                        roiLineWidth(2.0 * sf);
                        
                        if( sliceFromTo[ 0][ 0] != HUGE_VALF && (sliceVector[ 0] != 0 || sliceVector[ 1] != 0  || sliceVector[ 2] != 0))
                        {
                            float a[ 2];
                            // perpendicular vector
                            
                            a[ 1] = sliceFromTo[ 0][ 0] - sliceFromTo[ 1][ 0];
                            a[ 0] = sliceFromTo[ 0][ 1] - sliceFromTo[ 1][ 1];
                            
                            // normalize
                            double t = a[ 1]*a[ 1] + a[ 0]*a[ 0];
                            t = sqrt(t);
                            a[0] = a[0]/t;
                            a[1] = a[1]/t;
                            
#define LINELENGTH 15
                            
                            roiBegin(GL_LINES);
                            roiVertex2f( scaleValue*(tempPoint3D[ 0]-LINELENGTH/self.curDCM.pixelSpacingX * a[ 0]), scaleValue*(tempPoint3D[ 1]+LINELENGTH/self.curDCM.pixelSpacingY*(a[ 1])));
                            roiVertex2f( scaleValue*(tempPoint3D[ 0]+LINELENGTH/self.curDCM.pixelSpacingX * a[ 0]), scaleValue*(tempPoint3D[ 1]-LINELENGTH/self.curDCM.pixelSpacingY*(a[ 1])));
                            roiEnd();
                        }
                        else
                        {
                            roiBegin(GL_LINES);
                            
                            float crossx = tempPoint3D[0], crossy = tempPoint3D[1];
                            
                            roiVertex2f( scaleValue * (crossx - LINELENGTH/self.curDCM.pixelSpacingX), scaleValue*(crossy));
                            roiVertex2f( scaleValue * (crossx - 5/self.curDCM.pixelSpacingX), scaleValue*(crossy));
                            roiVertex2f( scaleValue * (crossx + LINELENGTH/self.curDCM.pixelSpacingX), scaleValue*(crossy));
                            roiVertex2f( scaleValue * (crossx + 5/self.curDCM.pixelSpacingX), scaleValue*(crossy));
                            
                            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy-LINELENGTH/self.curDCM.pixelSpacingX));
                            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy-5/self.curDCM.pixelSpacingX));
                            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy+5/self.curDCM.pixelSpacingX));
                            roiVertex2f( scaleValue * (crossx), scaleValue*(crossy+LINELENGTH/self.curDCM.pixelSpacingX));
                            
                            roiEnd();
                        }
                        roiLineWidth(1.0 * sf);
                    }
                    
                    roiDisable(GL_LINE_SMOOTH);
                    roiDisable(GL_POLYGON_SMOOTH);
                    roiDisable(GL_POINT_SMOOTH);
                    roiDisable(GL_BLEND);
                }
                
                roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
                roiScalef (2.0f / drawingFrameRect.size.width, -2.0f /  drawingFrameRect.size.height, 1.0f); // scale to port per pixel scale
                
                roiColor3f (0.0f, 1.0f, 0.0f);
                
                if( annotations >= annotBase)
                {
                    //** PIXELSPACING LINES - RULER
                    float yOffset = 24*sf;
                    float xOffset = 32*sf;
                    roiLineWidth( 1.0 * sf);
                    roiBegin(GL_LINES);
                    
                    NSRect rr = drawingFrameRect;
                    
                    if( NSIsEmptyRect( screenCaptureRect) == NO)
                    {
                        rr = screenCaptureRect;
                        
                        // We didn't used glTranslate, after glScalef...
                        rr.origin.x -= drawingFrameRect.size.width/2.;
                        rr.origin.y -= drawingFrameRect.size.height/2.;
                        
                        rr.origin.x += rr.size.width/2.;
                        rr.origin.y += rr.size.height/2.;
                    }
                    else
                        rr.origin = NSMakePoint( 0, 0);
                    
                    if( self.curDCM.pixelSpacingX != 0 && self.curDCM.pixelSpacingX * 1000.0 < 1)
                    {
                        roiVertex2f( rr.origin.x + scaleValue  * (-0.02/self.curDCM.pixelSpacingX), rr.origin.y + rr.size.height/2 - yOffset);
                        roiVertex2f( rr.origin.x + scaleValue  * (0.02/self.curDCM.pixelSpacingX), rr.origin.y + rr.size.height/2 - yOffset);
                        
                        roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset , rr.origin.y + scaleValue  * (-0.02/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio));
                        roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset , rr.origin.y + scaleValue  * (0.02/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio));
                        
                        for ( short i = -20; i<=20; i++ )
                        {
                            short length = ( i % 10 == 0 )? 10 : 5;
                            
                            length *= sf;
                            
                            roiVertex2f( rr.origin.x + i*scaleValue *0.001/self.curDCM.pixelSpacingX, rr.origin.y + rr.size.height/2 - yOffset);
                            roiVertex2f( rr.origin.x + i*scaleValue *0.001/self.curDCM.pixelSpacingX, rr.origin.y + rr.size.height/2 - yOffset - length);
                            
                            roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset + length, rr.origin.y + i* scaleValue *0.001/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio);
                            roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset, rr.origin.y + i* scaleValue * 0.001/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio);
                        }
                    }
                    else if( self.curDCM.pixelSpacingX != 0 && self.curDCM.pixelSpacingY != 0)
                    {
                        roiVertex2f( rr.origin.x + scaleValue  * (-50/self.curDCM.pixelSpacingX), rr.origin.y + rr.size.height/2 - yOffset);
                        roiVertex2f( rr.origin.x + scaleValue  * (50/self.curDCM.pixelSpacingX), rr.origin.y + rr.size.height/2 - yOffset);
                        
                        roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset , rr.origin.y + scaleValue  * (-50/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio));
                        roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset , rr.origin.y + scaleValue  * (50/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio));
                        
                        for ( short i = -5; i<=5; i++ )
                        {
                            short length = (i % 5 == 0) ? 10 : 5;
                            
                            length *= sf;
                            
                            roiVertex2f( rr.origin.x + i*scaleValue *10/self.curDCM.pixelSpacingX, rr.origin.y + rr.size.height/2 - yOffset);
                            roiVertex2f( rr.origin.x + i*scaleValue *10/self.curDCM.pixelSpacingX, rr.origin.y + rr.size.height/2 - yOffset - length);
                            
                            roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset + length,  rr.origin.y + i* scaleValue *10/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio);
                            roiVertex2f( rr.origin.x + -rr.size.width/2 + xOffset,  rr.origin.y + i* scaleValue * 10/self.curDCM.pixelSpacingY*self.curDCM.pixelRatio);
                        }
                    }
                    roiEnd();
                }
                
            } //Annotation  != None
            
            @try
            {
                recordAnnotationRects = preparedROILabels;
                [self drawTextualData: drawingFrameRect :annotations];
            }
            
            @catch (NSException * e)
            {
                NSLog( @"drawTextualData Annotations Exception : %@", e);
            }
            
            recordAnnotationRects = NO;
            if( preparedROILabels)
            {
                BOOL labelLock = !is2DViewer || [[[self windowController] roiLock] tryLock];
                if( labelLock)
                {
                    NSSortDescriptor *roiSorting = [NSSortDescriptor sortDescriptorWithKey:@"uniqueID" ascending:NO];
                    if ( !suppress_labels)
                    {
                        NSMutableArray *labelROIs = [NSMutableArray arrayWithArray:curRoiList];
                        if (lengthPendingMarker) [labelROIs addObject:lengthPendingMarker];
                        NSArray *sortedROIs = [labelROIs sortedArrayUsingDescriptors:@[roiSorting]];

                        BOOL drawingRoiMode = NO;
                        for( ROI *r in sortedROIs)
                        {
                            if( r.ROImode == ROI_drawing)
                                drawingRoiMode = YES;
                        }

                        if( drawingRoiMode == NO)
                        {
                            for( int i = (long)[sortedROIs count]-1; i>=0; i--)
                            {
                                ROI *r = [[sortedROIs objectAtIndex:i] retain];

                                @try
                                {
                                    [r drawTextualData];
                                }
                                @catch (NSException * e)
                                {
                                    NSLog( @"drawTextualData ROI Exception : %@", e);
                                }

                                [r release];
                            }
                        }
                    }

                    if( is2DViewer) [[[self windowController] roiLock] unlock];
                }
                [rectArray release];
                rectArray = nil;
            }

            if(repulsorRadius != 0)
            {
                roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
                roiScalef (2.0f / drawingFrameRect.size.width, -2.0f /  drawingFrameRect.size.height, 1.0f); // scale to port per pixel scale
                roiTranslatef (-(drawingFrameRect.size.width) / 2.0f, -(drawingFrameRect.size.height) / 2.0f, 0.0f); // translate center to upper left
                
                [self drawRepulsorToolArea];
            }
            
            if(ROISelectorStartPoint.x!=ROISelectorEndPoint.x || ROISelectorStartPoint.y!=ROISelectorEndPoint.y)
            {
                roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
                roiScalef (2.0f / drawingFrameRect.size.width, -2.0f /  drawingFrameRect.size.height, 1.0f); // scale to port per pixel scale
                roiTranslatef (-(drawingFrameRect.size.width) / 2.0f, -(drawingFrameRect.size.height) / 2.0f, 0.0f); // translate center to upper left
                
                [self drawROISelectorRegion];
            }
            
            //			if(ctx == _alternateContext && [[NSApplication sharedApplication] isActive]) // iChat Theatre context
            //			{
            //				roiLoadIdentity (); // reset model view matrix to identity (eliminates rotation basically)
            //				roiScalef (2.0f / drawingFrameRect.size.width, -2.0f /  drawingFrameRect.size.height, 1.0f); // scale to port per pixel scale
            //				roiTranslatef (-(drawingFrameRect.size.width) / 2.0f, -(drawingFrameRect.size.height) / 2.0f, 0.0f); // translate center to upper left
            //
            //				NSPoint eventLocation = [[self window] convertScreenToBase: [NSEvent mouseLocation]];
            //
            //				// location of the mouse in the OsiriX View
            //				eventLocation = [self convertPoint:eventLocation fromView:nil];
            //				eventLocation.y = [self frame].size.height - eventLocation.y;
            //
            //				// generate iChat cursor Texture Buffer (only once)
            //				if(!iChatCursorTextureBuffer)
            //				{
            //					NSLog(@"generate iChatCursor Texture Buffer");
            //					NSImage *iChatCursorImage;
            //					if ((iChatCursorImage = [[NSCursor pointingHandCursor] image]))
            //					{
            //						iChatCursorHotSpot = [[NSCursor pointingHandCursor] hotSpot];
            //						iChatCursorImageSize = [iChatCursorImage size];
            //
            //						NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:[iChatCursorImage TIFFRepresentation]]; // [NSBitmapImageRep imageRepWithData: [iChatCursorImage TIFFRepresentation]]
            //
            //						iChatCursorTextureBuffer = malloc([bitmap bytesPerRow] * iChatCursorImageSize.height);
            //						memcpy(iChatCursorTextureBuffer, [bitmap bitmapData], [bitmap bytesPerRow] * iChatCursorImageSize.height);
            //
            //						[bitmap release];
            //
            //						iChatCursorTextureName = 0;
            //						glGenTextures(1, &iChatCursorTextureName);
            //						glBindTexture(GL_TEXTURE_RECTANGLE_EXT, iChatCursorTextureName);
            //						glPixelStorei(GL_UNPACK_ROW_LENGTH, [bitmap bytesPerRow]/4);
            //						glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, 1);
            //						glTexParameteri (GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE, GL_STORAGE_CACHED_APPLE);
            //
            //						glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, iChatCursorImageSize.width, iChatCursorImageSize.height, 0, GL_RGBA, GL_UNSIGNED_INT_8_8_8_8_REV, iChatCursorTextureBuffer);
            //					}
            //				}
            //
            //				// draw the cursor in the iChat Theatre View
            //				if(iChatCursorTextureBuffer)
            //				{
            //					eventLocation.x -= iChatCursorHotSpot.x;
            //					eventLocation.y -= iChatCursorHotSpot.y;
            //
            //					roiEnable(GL_TEXTURE_RECTANGLE_EXT);
            //
            //					glBindTexture(GL_TEXTURE_RECTANGLE_EXT, iChatCursorTextureName);
            //					roiBlendEquation(GL_FUNC_ADD);
            //					roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            //					roiEnable(GL_BLEND);
            //
            //					roiColor4f(1.0, 1.0, 1.0, 1.0);
            //					roiBegin(GL_QUAD_STRIP);
            //						glTexCoord2f(0, 0);
            //						roiVertex2f(eventLocation.x, eventLocation.y);
            //
            //						glTexCoord2f(iChatCursorImageSize.width, 0);
            //						roiVertex2f(eventLocation.x + iChatCursorImageSize.width, eventLocation.y);
            //
            //						glTexCoord2f(0, iChatCursorImageSize.height);
            //						roiVertex2f(eventLocation.x, eventLocation.y + iChatCursorImageSize.height);
            //
            //						glTexCoord2f(iChatCursorImageSize.width, iChatCursorImageSize.height);
            //						roiVertex2f(eventLocation.x + iChatCursorImageSize.width, eventLocation.y + iChatCursorImageSize.height);
            //
            //						roiEnd();
            //					roiDisable(GL_BLEND);
            //
            //					roiDisable(GL_TEXTURE_RECTANGLE_EXT);
            //				}
            //			} // end iChat Theatre context
            
            if( showDescriptionInLarge && showDescriptionInLargeText)
            {
                NSSize boxSize = [self convertSizeToBacking: [showDescriptionInLargeText frameSize]];
                NSRect r = NSMakeRect( drawingFrameRect.size.width/2 - boxSize.width/2, drawingFrameRect.size.height/2 - boxSize.height/2, boxSize.width, boxSize.height);
                
                [[HorosAnnotationOverlay overlayForView: self] addBox: showDescriptionInLargeText rect: r];
            }
        }
        
        if( lensActive)
            [self drawMagnifyingLens];
        
        [self drawRectAnyway:aRect];
        // The picture that could not be drawn says why, and so does a plane the
        // MPR computed on the CPU because Metal declined it (#735).
        NSString *pixelRendererMessage = nil;
        if( dcmPixList && curImage > -1 && (planarDrawn == NO || self.horosEngineNotice))
            pixelRendererMessage = self.horosPlanarFallbackReason;
        if (pixelRendererMessage) {
            roiMatrixMode(GL_MODELVIEW); roiLoadIdentity();
            roiScalef(2.f/drawingFrameRect.size.width, -2.f/drawingFrameRect.size.height, 1.f);
            roiColor3f(1.f, 0.8f, 0.2f);
            [self DrawNSStringGL:pixelRendererMessage : DCMViewMainFont :0 :drawingFrameRect.size.height/2 - 24*sf align:DCMViewTextAlignCenter useStringTexture:YES];
        }
        
    }
    @catch (NSException * e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    
    [annotationOverlay commitInverted: gInvertColors && [stringID isEqualToString: @"export"] == NO scale: sf];
    
    [performanceTrace endDraw:drawSpan index:curImage];
    
    //	[NSOpenGLContext clearCurrentContext];
    
    drawingFrameRect = [self convertRectToBacking: [self frame]];
    
    //	if( ctx == _alternateContext)
    //		drawingFrameRect = savedDrawingFrameRect;
    
    //	if(iChatRunning) [drawLock unlock];
    
    (void) [self _checkHasChanged:YES];
    
}

- (void) setFrame:(NSRect)frameRect
{
    [super setFrame: frameRect];
    
    previousViewSize = frameRect.size;
}

- (void) reshape	// scrolled, moved or resized
{
    if( dcmPixList)
    {
        BOOL is2DViewer = [self is2DViewer];
        
        NSRect rect = [self frame];
        
        if( [[NSUserDefaults standardUserDefaults] boolForKey: @"AlwaysScaleToFit"] && is2DViewer)
        {
            if( NSEqualSizes( previousViewSize, rect.size) == NO)
            {
                if( is2DViewer)
                    [[self windowController] setUpdateTilingViewsValue: YES];
                
                [self scaleToFit];
                
                if( is2DViewer == YES)
                {
                    if( curImage >= 0 && COPYSETTINGSINSERIES == NO)
                    {
                        ViewerController *v = [self windowController];
                        
                        for( int i = 0 ; i < [v  maxMovieIndex]; i++)
                        {
                            for( DCMPix *pix in [v pixList: i])
                            {
                                if( pix != self.curDCM)
                                {
                                    [pix.imageObj setValue: nil forKey: @"scale"];
                                    
                                    
                                    NSPoint o = NSMakePoint( 0, 0);
                                    if( pix.shutterEnabled)
                                    {
                                        o.x = ((self.curDCM.pwidth  * 0.5f ) - ( self.curDCM.shutterRect.origin.x + ( self.curDCM.shutterRect.size.width  * 0.5f ))) * scaleValue;
                                        o.y = -((self.curDCM.pheight * 0.5f ) - ( self.curDCM.shutterRect.origin.y + ( self.curDCM.shutterRect.size.height * 0.5f ))) * scaleValue;
                                    }
                                    
                                    [pix.imageObj setValue: [NSNumber numberWithFloat: o.x] forKey:@"xOffset"];
                                    [pix.imageObj setValue: [NSNumber numberWithFloat: o.y] forKey:@"yOffset"];
                                }
                            }
                        }
                    }
                    
                    [[self windowController] setUpdateTilingViewsValue: NO];
                    
                    if( [[self window] isMainWindow])
                        [[self windowController] propagateSettings];
                }
            }
        }
        else
        {
            if( previousViewSize.width != 0 && previousViewSize.height != 0)
            {
                float yChanged = sqrt( (rect.size.height / previousViewSize.height) * (rect.size.width / previousViewSize.width));
                
                if( yChanged > 0.01 && yChanged < 1000) yChanged = yChanged;
                else yChanged = 0.01;
                
                if( is2DViewer)
                {
                    [[self windowController] setUpdateTilingViewsValue: YES];
                    
                    if( curImage >= 0 && COPYSETTINGSINSERIES == NO)
                    {
                        ViewerController *v = [self windowController];
                        
                        if( [[v imageViews] objectAtIndex: 0] == self)
                        {
                            for( int i = 0 ; i < [v  maxMovieIndex]; i++)
                            {
                                for( DCMPix *pix in [v pixList: i])
                                {
                                    if( pix !=  self.curDCM)
                                    {
                                        float s = [[pix.imageObj valueForKey: @"scale"] floatValue];
                                        
                                        if( s)
                                            [pix.imageObj setValue: [NSNumber numberWithFloat: s * yChanged] forKey: @"scale"];
                                        else
                                            [pix.imageObj setValue: nil forKeyPath: @"scale"];
                                    }
                                }
                            }
                        }
                    }
                }
                
                self.scaleValue = scaleValue * yChanged;
                
                if( is2DViewer)
                    [[self windowController] setUpdateTilingViewsValue: NO];
                
                origin.x *= yChanged;
                origin.y *= yChanged;
                
                if( is2DViewer == YES)
                {
                    if( [[self window] isMainWindow])
                        [[self windowController] propagateSettings];
                }
            }
        }
    }
}

-(unsigned char*) getRawPixels:(long*) width :(long*) height :(long*) spp :(long*) bpp :(BOOL) screenCapture :(BOOL) force8bits
{
    return [self getRawPixelsWidth:width height:height spp:spp bpp:bpp screenCapture:screenCapture force8bits:force8bits removeGraphical:YES squarePixels:NO allTiles:[[NSUserDefaults standardUserDefaults] boolForKey:@"includeAllTiledViews"] allowSmartCropping:NO origin: nil spacing: nil];
}

- (unsigned char*) getRawPixelsWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allTiles:(BOOL) allTiles allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing
{
    return [self getRawPixelsWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allTiles:(BOOL) allTiles allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing offset:(int*) nil isSigned:(BOOL*) nil];
}

- (unsigned char*) getRawPixelsWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allTiles:(BOOL) allTiles allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing offset:(int*) offset isSigned:(BOOL*) isSigned
{
    if( allTiles && [self is2DViewer] && (_imageRows != 1 || _imageColumns != 1))
    {
        NSArray		*views = [[[self windowController] seriesView] imageViews];
        
        // Create a large buffer for all views
        // All views are identical
        
        unsigned char	*firstView = [[views objectAtIndex: 0] getRawPixelsViewWidth:width height:height spp:spp bpp:bpp screenCapture:screenCapture force8bits: force8bits removeGraphical:removeGraphical squarePixels:squarePixels allowSmartCropping:NO origin: imOrigin spacing: imSpacing offset: offset isSigned: isSigned];
        unsigned char	*globalView = nil;
        
        long viewSize =  *bpp * *spp * (*width+4) * (*height+4) / 8;
        int	globalWidth = *width * _imageColumns;
        int globalHeight = *height * _imageRows;
        
        if( firstView)
        {
            globalView = malloc( viewSize * (_imageColumns) * (_imageRows));
            
            free( firstView);
            
            if( globalView)
            {
                for( int x = 0; x < _imageColumns; x++ )
                {
                    for( int y = 0; y < _imageRows; y++)
                    {
                        unsigned char	*aView = [[views objectAtIndex: x + y*_imageColumns] getRawPixelsViewWidth:width height:height spp:spp bpp:bpp screenCapture:screenCapture force8bits: force8bits removeGraphical:removeGraphical squarePixels:squarePixels allowSmartCropping:NO origin: imOrigin spacing: imSpacing offset: offset isSigned: isSigned];
                        
                        if( aView)
                        {
                            unsigned char	*o = globalView + *spp*globalWidth*y**height**bpp/8 +  x**width**spp**bpp/8;
                            
                            for( int yy = 0 ; yy < *height; yy++)
                            {
                                memcpy( o + yy**spp*globalWidth**bpp/8, aView + yy**spp**width**bpp/8, *spp**width**bpp/8);
                            }
                            
                            free( aView);
                        }
                    }
                }
                
                *width = globalWidth;
                *height = globalHeight;
            }
        }
        
        return globalView;
    }
    else return [self getRawPixelsViewWidth:width height:height spp:spp bpp:bpp screenCapture:screenCapture force8bits: force8bits removeGraphical:removeGraphical squarePixels:squarePixels allowSmartCropping:allowSmartCropping origin: imOrigin spacing: imSpacing offset: offset isSigned: isSigned];
}

- (unsigned char*) getRawPixelsWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allTiles:(BOOL) allTiles allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing offset:(int*) offset isSigned:(BOOL*) isSigned views: (NSArray*) views viewsRect: (NSArray*) rects
{
    NSMutableArray *viewsRect = [NSMutableArray arrayWithArray: rects];
    
    if( [views count] > 1 && [views count] == [viewsRect count])
    {
        unsigned char	*tempData = nil;
        
        NSRect unionRect = [[viewsRect objectAtIndex: 0] rectValue];
        for( NSValue *rect in viewsRect)
            unionRect = NSUnionRect( [rect rectValue], unionRect);
        
        for( int i = 0; i < [views count]; i++ )
        {
            NSRect curRect = [[viewsRect objectAtIndex: i] rectValue];
            BOOL intersect;
            
            // X move
            do
            {
                intersect = NO;
                
                for( int x = 0 ; x < [views count]; x++)
                {
                    if( x != i)
                    {
                        NSRect	rect = [[viewsRect objectAtIndex: x] rectValue];
                        if( NSIntersectsRect( curRect, rect))
                        {
                            curRect.origin.x += 2;
                            intersect = YES;
                        }
                    }
                }
                
                if( intersect == NO)
                {
                    curRect.origin.x --;
                    if( curRect.origin.x <= unionRect.origin.x) intersect = YES;
                }
            }
            while( intersect == NO);
            
            [viewsRect replaceObjectAtIndex: i withObject: [NSValue valueWithRect: curRect]];
        }
        
        for( int i = 0; i < [views count]; i++)
        {
            NSRect curRect = [[viewsRect objectAtIndex: i] rectValue];
            BOOL intersect;
            
            // Y move
            do {
                intersect = NO;
                
                for( int x = 0 ; x < [views count]; x++)
                {
                    if( x != i)
                    {
                        NSRect	rect = [[viewsRect objectAtIndex: x] rectValue];
                        if( NSIntersectsRect( curRect, rect))
                        {
                            curRect.origin.y-= 2;
                            intersect = YES;
                        }
                    }
                }
                
                if( intersect == NO)
                {
                    curRect.origin.y ++;
                    if( curRect.origin.y + curRect.size.height > unionRect.origin.y + unionRect.size.height) intersect = YES;
                }
            }
            while( intersect == NO);
            
            [viewsRect replaceObjectAtIndex: i withObject: [NSValue valueWithRect: curRect]];
        }
        
        // Re-Compute the enclosing rect
        unionRect = [[viewsRect objectAtIndex: 0] rectValue];
        for( int i = 0; i < [views count]; i++)
        {
            unionRect = NSUnionRect( [[viewsRect objectAtIndex: i] rectValue], unionRect);
        }
        
        *width = unionRect.size.width;
        if( *width % 4 != 0) *width += 4;
        *width /= 4;
        *width *= 4;
        *height = unionRect.size.height;
        
        unsigned char * data = nil;
        long dataSize = 0;
        
        for( int i = 0; i < [views count]; i++)
        {
            long iwidth, iheight, ispp, ibpp;
            float iimSpacing[ 2];
            BOOL iisSigned;
            int ioffset;
            
            tempData = [[views objectAtIndex: i] getRawPixelsWidth: &iwidth
                                                            height: &iheight
                                                               spp: &ispp
                                                               bpp: &ibpp
                                                     screenCapture: screenCapture
                                                        force8bits: force8bits
                                                   removeGraphical: removeGraphical
                                                      squarePixels: squarePixels
                                                          allTiles: allTiles
                                                allowSmartCropping: allowSmartCropping
                                                            origin: nil
                                                           spacing: iimSpacing
                                                            offset: &ioffset
                                                          isSigned: &iisSigned];
            
            if( tempData)
            {
                if( i == 0)
                {
                    if( imSpacing)
                    {
                        imSpacing[ 0] = iimSpacing[ 0];
                        imSpacing[ 1] = iimSpacing[ 1];
                    }
                    
                    if( imOrigin)
                    {
                        imOrigin[ 0] = 0;
                        imOrigin[ 1] = 0;
                        imOrigin[ 2] = 0;
                    }
                    
                    *spp = ispp;
                    *bpp = ibpp;
                    if( offset) *offset = ioffset;
                    if( isSigned) *isSigned = iisSigned;
                    
                    dataSize = (4+*width) * (4+*height) * *spp * *bpp/8;
                    data = calloc( 1, dataSize);
                }
                else
                {
                    if( imSpacing)
                    {
                        if( fabs( imSpacing[ 0] - iimSpacing[ 0]) > 0.005 || fabs( imSpacing[ 1] - iimSpacing[ 1]) > 0.005)
                        {
                            imSpacing[ 0] = 0;
                            imSpacing[ 1] = 0;
                        }
                    }
                }
                
                
                NSRect	bounds = [[viewsRect objectAtIndex: i] rectValue];	//[views bounds];
                
                bounds.origin.x -= unionRect.origin.x;
                bounds.origin.y -= unionRect.origin.y;
                
                if( data)
                {
                    unsigned char *o = data + (*bpp/8) * *spp * *width * (long) (*height - bounds.origin.y - iheight) + (long) bounds.origin.x * *spp * (*bpp/8);
                    
                    if( o >= data)
                    {
                        for( long y = 0 ; y < iheight; y++)
                        {
                            long size = (*bpp/8) * ispp * iwidth;
                            long ooffset = (*bpp/8) * y * *spp * *width;
                            
                            if( o + ooffset + size < data + dataSize)
                                memcpy( o + ooffset, tempData + (*bpp/8) * y *ispp * iwidth, size);
                            else
                                N2LogStackTrace( @"**** o + ooffset + size< data + dataSize");
                        }
                    }
                }
                free( tempData);
            }
        }
        
        return data;
    }
    else
    {
        return [self getRawPixelsWidth: width
                                height: height
                                   spp: spp
                                   bpp: bpp
                         screenCapture: screenCapture
                            force8bits: force8bits
                       removeGraphical: removeGraphical
                          squarePixels: squarePixels
                              allTiles: allTiles
                    allowSmartCropping: allowSmartCropping
                                origin: imOrigin
                               spacing: imSpacing
                                offset: offset
                              isSigned: isSigned];
    }
}

- (NSRect) smartCrop: (NSPoint*) ori
{
    NSPoint oo = [self origin];
    
    NSRect usefulRect = [self.curDCM usefulRectWithRotation: rotation scale: scaleValue xFlipped: xFlipped yFlipped: yFlipped];
    
    NSSize rectSize = drawingFrameRect.size;
    
    if( xFlipped) oo.x = - oo.x;
    if( yFlipped) oo.y = - oo.y;
    
    oo = [DCMPix rotatePoint: oo aroundPoint:NSMakePoint( 0, 0) angle: -rotation*deg2rad];
    
    NSPoint cov = NSMakePoint( rectSize.width/2 + oo.x - usefulRect.size.width/2, rectSize.height/2 - oo.y - usefulRect.size.height/2);
    
    usefulRect.origin = cov;
    
    NSRect frameRect;
    
    frameRect.size = rectSize;
    frameRect.origin.x = frameRect.origin.y = 0;
    
    if( usefulRect.size.width < 256)
    {
        usefulRect.origin.x -= (int) ((256 - usefulRect.size.width) / 2);
        usefulRect.size.width = 256;
    }
    
    if( usefulRect.size.height < 256)
    {
        usefulRect.origin.y -= (int) ((256 - usefulRect.size.height) / 2);
        usefulRect.size.height = 256;
    }
    
    NSRect smartRect = NSIntersectionRect( frameRect, usefulRect);
    
    if( ori)
    {
        ori->x = ori->y = 0;
        if( NSEqualRects( usefulRect, smartRect) == NO)
        {
            ori->x = (usefulRect.origin.x - smartRect.origin.x) / 2 + (usefulRect.origin.x+usefulRect.size.width - (smartRect.origin.x+smartRect.size.width)) / 2;
            ori->y = - ((usefulRect.origin.y - smartRect.origin.y) / 2 + (usefulRect.origin.y+usefulRect.size.height - (smartRect.origin.y+smartRect.size.height)) / 2);
            
            *ori = [DCMPix rotatePoint: *ori aroundPoint:NSMakePoint( 0, 0) angle: rotation*deg2rad];
        }
    }
    
    smartRect.origin.x = (int) smartRect.origin.x;
    smartRect.origin.y = (int) smartRect.origin.y;
    smartRect.size.width = (int) smartRect.size.width;
    smartRect.size.height = (int) smartRect.size.height;
    
    return smartRect;
}

- (NSRect) smartCrop
{
    return [self smartCrop: nil];
}

-(unsigned char*) getRawPixelsViewWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing
{
    return [self getRawPixelsViewWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing offset:(int*) nil isSigned:(BOOL*) nil];
}

-(unsigned char*) getRawPixelsViewWidth:(long*) width height:(long*) height spp:(long*) spp bpp:(long*) bpp screenCapture:(BOOL) screenCapture force8bits:(BOOL) force8bits removeGraphical:(BOOL) removeGraphical squarePixels:(BOOL) squarePixels allowSmartCropping:(BOOL) allowSmartCropping origin:(float*) imOrigin spacing:(float*) imSpacing offset:(int*) offset isSigned:(BOOL*) isSigned
{
    unsigned char	*buf = nil;
    
    if( isSigned) *isSigned = NO;
    if( offset) *offset = 0;
    
    if(
#ifndef OSIRIX_LIGHT
       [self class] == [OrthogonalMPRPETCTView class] ||
#endif
       [self class] == [OrthogonalMPRView class]) allowSmartCropping = NO;	// <- MPR 2D, Ortho MPR
    
    if( screenCapture)	// Pixels displayed in current window
    {
        for( ROI *r in curRoiList)	[r setROIMode: ROI_sleep];
        
        if( force8bits == YES || self.curDCM.isRGB == YES || blendingView != nil)		// Screen Capture in RGB - 8 bit
        {
            NSPoint shiftOrigin;
            BOOL smartCropped = NO;
            NSRect smartCroppedRect;
            
            if( allowSmartCropping && [[NSUserDefaults standardUserDefaults] boolForKey: @"ScreenCaptureSmartCropping"])
            {
                smartCroppedRect = [self smartCrop: &shiftOrigin];
                
                if( smartCroppedRect.size.width == drawingFrameRect.size.width && smartCroppedRect.size.height == drawingFrameRect.size.height)
                    smartCropped = NO;
                else
                {
                    *width = smartCroppedRect.size.width;
                    *height = smartCroppedRect.size.height;
                    smartCropped = YES;
                }
                
                //                if( self.blendingView)
                //                {
                //                    blendedViewRect = [self.blendingView smartCrop: &blendedShiftOrigin];
                //                    NSRect unionRect = NSUnionRect( blendedViewRect, smartCroppedRect);;
                //
                //                    #define NSRectCenterX(r) (r.origin.x+r.size.width/2.)
                //                    #define NSRectCenterY(r) (r.origin.y+r.size.height/2.)
                //
                //                    NSPoint oo = NSMakePoint( NSRectCenterX(smartCroppedRect) - NSRectCenterX(unionRect), NSRectCenterY(smartCroppedRect) - NSRectCenterY(unionRect));
                //
                //                    if( xFlipped) {oo.x = -oo.x; shiftOrigin.x *=-1;}
                //                    if( yFlipped) {oo.y = -oo.y; shiftOrigin.y *=-1;}
                //
                //                    shiftOrigin.x = oo.x*cos((rotation)*deg2rad) + oo.y*sin((rotation)*deg2rad) + shiftOrigin.x;
                //                    shiftOrigin.y = oo.x*sin((rotation)*deg2rad) - oo.y*cos((rotation)*deg2rad) + shiftOrigin.y;
                //
                //                    oo = NSMakePoint( NSRectCenterX(blendedViewRect) - NSRectCenterX(unionRect), NSRectCenterY(blendedViewRect) - NSRectCenterY(unionRect));
                //
                //                    if( blendingView.xFlipped) {oo.x = -oo.x; blendedShiftOrigin.x *= -1.;}
                //                    if( blendingView.yFlipped) {oo.y = -oo.y; blendedShiftOrigin.y *= -1.;}
                //
                //                    blendedShiftOrigin.x = oo.x*cos((blendingView.rotation)*deg2rad) + oo.y*sin((blendingView.rotation)*deg2rad) + blendedShiftOrigin.x;
                //                    blendedShiftOrigin.y = oo.x*sin((blendingView.rotation)*deg2rad) - oo.y*cos((blendingView.rotation)*deg2rad) + blendedShiftOrigin.y;
                //
                //                    smartCroppedRect = unionRect;
                //
                //                    if( smartCroppedRect.size.width == drawingFrameRect.size.width && smartCroppedRect.size.height == drawingFrameRect.size.height)
                //                        smartCropped = NO;
                //                    else
                //                    {
                //                        *width = smartCroppedRect.size.width;
                //                        *height = smartCroppedRect.size.height;
                //                        smartCropped = YES;
                //                    }
                //                }
            }
            else smartCroppedRect = NSMakeRect( 0, 0, drawingFrameRect.size.width, drawingFrameRect.size.height);
            
            if( imOrigin)
            {
                NSPoint tempPt = [self ConvertFromUpLeftView2GL: smartCroppedRect.origin];
                [self.curDCM convertPixX: tempPt.x pixY: tempPt.y toDICOMCoords: imOrigin pixelCenter: YES];
            }
            
            if( imSpacing)
            {
                imSpacing[ 0] = [self.curDCM pixelSpacingX] / scaleValue;
                imSpacing[ 1] = [self.curDCM pixelSpacingX] / scaleValue;
            }
            
            *width = smartCroppedRect.size.width;
            *height = smartCroppedRect.size.height;
            *spp = 3;
            *bpp = 8;
            
            buf = calloc( 1, 10 + *width * *height * 4 * *bpp/8);
            if( buf)
            {
                NSString *str = nil;
                
                if( removeGraphical)
                {
                    str = [[self stringID] retain];
                    [self setStringID: @"export"];
                }
                
                if( smartCropped)
                    screenCaptureRect = smartCroppedRect;
                
                [self display];
                [self.blendingView display];
                
                // The picture Metal drew for this frame, drawn again and read
                // back, rows from the top (#728).
                BOOL inverted = gInvertColors && [stringID isEqualToString: @"export"] == NO;
                long frameWidth = drawingFrameRect.size.width, frameHeight = drawingFrameRect.size.height;
                NSData *frame = [self horosPlanarPixelsWidth: frameWidth height: frameHeight inverted: inverted];
                unsigned char clear = (whiteBackground && dcmPixList && curImage > -1) != inverted ? 255 : 0;
                long x0 = smartCroppedRect.origin.x, y0 = smartCroppedRect.origin.y;
                for( long y = 0; y < *height; y++)
                {
                    unsigned char *row = buf + y * *width * 3;
                    for( long x = 0; x < *width; x++)
                    {
                        long fx = x0 + x, fy = y0 + y;
                        if( frame && fx >= 0 && fy >= 0 && fx < frameWidth && fy < frameHeight)
                        {
                            const unsigned char *bgra = (const unsigned char *) frame.bytes + (fy * frameWidth + fx) * 4;
                            row[ 3*x] = bgra[ 2]; row[ 3*x+1] = bgra[ 1]; row[ 3*x+2] = bgra[ 0];
                        }
                        else
                            row[ 3*x] = row[ 3*x+1] = row[ 3*x+2] = clear;
                    }
                }
                
                screenCaptureRect = NSMakeRect(0, 0, 0, 0);
                
                // The former identifier comes back, nil included: a view that had
                // none kept "export" and drew as if it were still exporting.
                if( removeGraphical)
                {
                    [self setStringID: str];
                    [str release];
                }
                
                [self setNeedsDisplay: YES];	// for refresh, later
                
                // The graphics and text are not in the picture: they are drawn above it.
                [[HorosAnnotationOverlay overlayForView: self] compositeOntoRGB: buf width: *width height: *height
                    originX: smartCroppedRect.origin.x originY: smartCroppedRect.origin.y];
            }
        }
        else // Screen Capture in 16 bit BW
        {
            float s = [self scaleValue];
            NSPoint o = [self origin];
            
            NSSize destRectSize = drawingFrameRect.size;
            
            // We want the full resolution, not less, not more
            destRectSize.width /= s;
            destRectSize.height /= s;
            o.x /= s;
            o.y /= s;
            s = 1;
            
            DCMPix *im = [self.curDCM renderInRectSize: destRectSize atPosition:o rotation: [self rotation] scale: s xFlipped: xFlipped yFlipped: yFlipped smartCrop: YES];
            
            if( im)
            {
                if( imSpacing)
                {
                    imSpacing[ 0] = [im pixelSpacingX];
                    imSpacing[ 1] = [im pixelSpacingX];
                }
                
                if( imOrigin)
                {
                    imOrigin[ 0] = [im originX];
                    imOrigin[ 1] = [im originY];
                    imOrigin[ 2] = [im originZ];
                }
                
                *width = [im pwidth];
                *height = [im pheight];
                *spp = 1;
                *bpp = 16;
                
                vImage_Buffer srcf, dst8;
                
                srcf.height = *height;
                srcf.width = *width;
                srcf.rowBytes = *width * sizeof( float);
                
                dst8.height =  *height;
                dst8.width = *width;
                dst8.rowBytes = *width * sizeof( short);
                
                buf = malloc( *width * *height * *spp * *bpp/8);
                
                srcf.data = [im fImage];
                dst8.data = buf;
                
                float slope = 1;
                
                if( [[[dcmFilesList objectAtIndex: curImage] valueForKey:@"modality"] isEqualToString:@"PT"])
                    slope = im.appliedFactorPET2SUV * im.slope;
                
                if( buf)
                {
                    if( [self.curDCM minValueOfSeries] < -1024)
                    {
                        if( isSigned) *isSigned = YES;
                        if( offset) *offset = 0;
                        
                        vImageConvert_FTo16S( &srcf, &dst8, 0,  slope, 0);
                    }
                    else
                    {
                        if( isSigned) *isSigned = NO;
                        
                        if( [self.curDCM minValueOfSeries] >= 0)
                        {
                            if( offset) *offset = 0;
                            vImageConvert_FTo16U( &srcf, &dst8, 0,  slope, 0);
                        }
                        else
                        {
                            if( offset) *offset = -1024;
                            vImageConvert_FTo16U( &srcf, &dst8, -1024,  slope, 0);
                        }
                    }
                }
            }
        }
    }
    else // Pixels contained in memory  -> only RGB or 16 bits data
    {
        DCMPix *dcm = self.curDCM;
        
        if( [self xFlipped] || [self yFlipped] || [self rotation] != 0)
            dcm = [self.curDCM renderWithRotation: [self rotation] scale: 1.0 xFlipped: [self xFlipped] yFlipped: [self yFlipped] backgroundOffset: 0];
        
        if( dcm)
        {
            if( imOrigin)
            {
                imOrigin[ 0] = [dcm originX];
                imOrigin[ 1] = [dcm originY];
                imOrigin[ 2] = [dcm originZ];
            }
            
            if( imSpacing)
            {
                imSpacing[ 0] = [dcm pixelSpacingX];
                imSpacing[ 1] = [dcm pixelSpacingY];
            }
            
            BOOL isRGB = dcm.isRGB;
            
            *width = dcm.pwidth;
            *height = dcm.pheight;
            
            if( [dcm thickSlabVRActivated])
            {
                force8bits = YES;
                
                if( dcm.stackMode == 4 || dcm.stackMode == 5) isRGB = YES;
            }
            
            if( isRGB == YES)
            {
                [self display];
                
                *spp = 3;
                *bpp = 8;
                
                long i = *width * *height * *spp * *bpp / 8;
                buf = malloc( i );
                if( buf )
                {
                    unsigned char *dst = buf, *src = (unsigned char*) dcm.baseAddr;
                    i = *width * *height;
                    
                    // CONVERT ARGB TO RGB
                    while( i-- > 0)
                    {
                        src++;
                        *dst++ = *src++;
                        *dst++ = *src++;
                        *dst++ = *src++;
                    }
                }
            }
            //		else if( colorBuf != nil)		// A CLUT is applied
            //		{
            ////			BOOL BWInverse = YES;
            ////
            ////			// Is it inverse BW? We consider an inverse BW as a mono-channel image.
            ////			for( int i = 0; i < 256 && BWInverse == YES; i++)
            ////			{
            ////				if( redTable[i] != 255-i || greenTable[i] != 255 -i || blueTable[i] != 255-i) BWInverse = NO;
            ////			}
            ////
            ////			if( BWInverse == NO)
            ////			{
            //				[self display];
            //
            //				*spp = 3;
            //				*bpp = 8;
            //
            //				long i = *width * *height * *spp * *bpp / 8;
            //				buf = malloc( i );
            //				if( buf)
            //				{
            //					unsigned char *dst = buf, *src = colorBuf;
            //					i = *width * *height;
            //
            //					// CONVERT ARGB TO RGB
            //					while( i-- > 0)
            //					{
            //						src++;
            //						*dst++ = *src++;
            //						*dst++ = *src++;
            //						*dst++ = *src++;
            //					}
            //				}
            ////			}
            ////			else processed = NO;
            //		}
            else
            {
                if( force8bits)	// I don't want 16 bits data, only 8 bits data
                {
                    [self display];
                    
                    *spp = 1;
                    *bpp = 8;
                    
                    long i = *width * *height * *spp * *bpp / 8;
                    buf = malloc( i);
                    if( buf ) memcpy( buf, dcm.baseAddr, *width**height);
                }
                else	// Give me 16 bits !
                {
                    vImage_Buffer			srcf, dst8;
                    
                    *spp = 1;
                    *bpp = 16;
                    
                    srcf.height = *height;
                    srcf.width = *width;
                    srcf.rowBytes = *width * sizeof( float);
                    
                    dst8.height =  *height;
                    dst8.width = *width;
                    dst8.rowBytes = *width * sizeof( short);
                    
                    srcf.data = [dcm computefImage];
                    
                    float slope = 1;
                    
                    if( [[[dcmFilesList objectAtIndex: curImage] valueForKey:@"modality"] isEqualToString:@"PT"])
                        slope = dcm.appliedFactorPET2SUV * dcm.slope;
                    
                    long i = *width * *height * *spp * *bpp / 8;
                    buf = malloc( i);
                    if( buf)
                    {
                        dst8.data = buf;
                        
                        if( [dcm minValueOfSeries] < -1024)
                        {
                            if( isSigned) *isSigned = YES;
                            if( offset) *offset = 0;
                            
                            vImageConvert_FTo16S( &srcf, &dst8, 0,  slope, 0);
                        }
                        else
                        {
                            if( isSigned) *isSigned = NO;
                            
                            if( [dcm minValueOfSeries] >= 0)
                            {
                                if( offset) *offset = 0;
                                vImageConvert_FTo16U( &srcf, &dst8, 0,  slope, 0);
                            }
                            else
                            {
                                if( offset) *offset = -1024;
                                vImageConvert_FTo16U( &srcf, &dst8, -1024,  slope, 0);
                            }
                        }
                    }
                    
                    if( srcf.data != dcm.fImage ) free( srcf.data );
                }
            }
            
            // IF 8 bits or RGB, IF non-square pixels -> square pixels
            
            if( squarePixels == YES && *bpp == 8 && self.pixelSpacingX != self.pixelSpacingY)
            {
                vImage_Buffer	srcVimage, dstVimage;
                
                srcVimage.data = buf;
                srcVimage.height = *height;
                srcVimage.width = *width;
                srcVimage.rowBytes = *width * (*bpp/8) * *spp;
                
                dstVimage.height =  (int) ((float) *height * self.pixelSpacingY / self.pixelSpacingX);
                dstVimage.width = *width;
                dstVimage.rowBytes = *width * (*bpp/8) * *spp;
                dstVimage.data = malloc( dstVimage.rowBytes * dstVimage.height);
                
                if( *spp == 3)
                {
                    vImage_Buffer	argbsrcVimage, argbdstVimage;
                    
                    argbsrcVimage = srcVimage;
                    argbsrcVimage.rowBytes =  *width * 4;
                    argbsrcVimage.data = calloc( argbsrcVimage.rowBytes * argbsrcVimage.height, 1);
                    
                    argbdstVimage = dstVimage;
                    argbdstVimage.rowBytes =  *width * 4;
                    argbdstVimage.data = calloc( argbdstVimage.rowBytes * argbdstVimage.height, 1);
                    
                    if( dstVimage.data && argbsrcVimage.data && argbdstVimage.data)
                    {
                        vImageConvert_RGB888toARGB8888( &srcVimage, nil, 0, &argbsrcVimage, 0, 0);
                        vImageScale_ARGB8888( &argbsrcVimage, &argbdstVimage, nil, kvImageHighQualityResampling);
                        vImageConvert_ARGB8888toRGB888( &argbdstVimage, &dstVimage, 0);
                        
                        free( argbsrcVimage.data);
                        free( argbdstVimage.data);
                    }
                }
                else
                {
                    if( dstVimage.data)
                        vImageScale_Planar8( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
                }
                
                free( buf);
                
                if( imSpacing)
                    imSpacing[ 1] = imSpacing[ 0];
                
                buf = dstVimage.data;
                *height = dstVimage.height;
            }
        }
    }
    
    return buf;
}

- (NSImage*) exportNSImageCurrentImageWithSize:(int) size
{
    float imOrigin[ 3], imSpacing[ 2];
    long width, height, spp, bpp;
    //	NSRect savedFrame = drawingFrameRect;
    
    unsigned char *data = [self getRawPixelsViewWidth: &width height: &height spp: &spp bpp: &bpp screenCapture: YES force8bits: YES removeGraphical: YES squarePixels: YES allowSmartCropping: NO origin: imOrigin spacing: imSpacing offset: nil isSigned: nil];
    
    if( data)
    {
        if( size)
        {
            if( spp != 3)
                NSLog( @"********* spp != 3 I'll NOT resize");
            else
            {
                unsigned char *cropData;
                int cropHeight, cropWidth;
                //				float rescale = 0;
                //				NSPoint croppedOrigin;
                
                if( width > height)
                {
                    //					rescale = (float) size / (float) height;
                    cropHeight = height;
                    cropWidth = height;
                }
                else
                {
                    //					rescale = (float) size / (float) width;
                    cropHeight = width;
                    cropWidth = width;
                }
                
                //				croppedOrigin = NSMakePoint( ((width-cropWidth)/2.), ((height - cropHeight)/2.));
                
                cropData = data + spp*((width-cropWidth)/2) + spp*((height - cropHeight)/2)*width;
                
                // resize the data
                
                vImage_Buffer src, dest;
                
                src.data = cropData;
                src.rowBytes = width * spp;
                src.height = cropHeight;
                src.width = cropWidth;
                
                dest.data = malloc( size*size*spp);
                dest.rowBytes = size*spp;
                dest.width = dest.height = size;
                
                if( dest.data)
                {
                    vImage_Buffer	argbsrcVimage, argbdstVimage;
                    
                    argbsrcVimage = src;
                    argbsrcVimage.rowBytes =  src.width * 4;
                    argbsrcVimage.data = calloc( argbsrcVimage.rowBytes * argbsrcVimage.height, 1);
                    
                    argbdstVimage = dest;
                    argbdstVimage.rowBytes =  dest.width * 4;
                    argbdstVimage.data = calloc( argbdstVimage.rowBytes * argbdstVimage.height, 1);
                    
                    vImageConvert_RGB888toARGB8888( &src, nil, 0, &argbsrcVimage, 0, 0);
                    vImageScale_ARGB8888( &argbsrcVimage, &argbdstVimage, nil, kvImageHighQualityResampling);
                    vImageConvert_ARGB8888toRGB888( &argbdstVimage, &dest, 0);
                    
                    free( argbsrcVimage.data);
                    free( argbdstVimage.data);
                    
                    free( data);
                    
                    data = dest.data;
                    width = size;
                    height = size;
                }
            }
        }
        
        NSBitmapImageRep *rep;
        
        rep = [[[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:nil
                pixelsWide:width
                pixelsHigh:height
                bitsPerSample:bpp
                samplesPerPixel:spp
                hasAlpha:NO
                isPlanar:NO
                colorSpaceName:NSCalibratedRGBColorSpace
                bytesPerRow:width*bpp*spp/8
                bitsPerPixel:bpp*spp] autorelease];
        
        memcpy( [rep bitmapData], data, height*width*bpp*spp/8);
        
        NSImage *image = [[[NSImage alloc] init] autorelease];
        [image addRepresentation:rep];
        
        free( data);
        
        return image;
    }
    
    return [NSImage imageNamed: @"Empty.tif"];
}

- (NSDictionary*) exportDCMCurrentImage: (DICOMExport*) exportDCM size:(int) size
{
    return [self exportDCMCurrentImage: exportDCM size: size views: nil viewsRect: nil];
}

- (NSDictionary*) exportDCMCurrentImage: (DICOMExport*) exportDCM size:(int) size  views: (NSArray*) views viewsRect: (NSArray*) viewsRect
{
    return [self exportDCMCurrentImage: exportDCM size: size views: views viewsRect: viewsRect exportSpacingAndOrigin: YES];
}

- (NSDictionary*) exportDCMCurrentImage: (DICOMExport*) exportDCM size:(int) size  views: (NSArray*) views viewsRect: (NSArray*) viewsRect exportSpacingAndOrigin: (BOOL) exportSpacingAndOrigin
{
    NSString *f = nil;
    float o[ 9], imOrigin[ 3], imSpacing[ 2];
    long width, height, spp, bpp;
    
    long annotCopy = [[NSUserDefaults standardUserDefaults] integerForKey: @"ANNOTATIONS"];
    long clutBarsCopy = [[NSUserDefaults standardUserDefaults] integerForKey: @"CLUTBARS"];
    
    if( [[NSUserDefaults standardUserDefaults] boolForKey: @"keepCLUTBarsForSecondaryCapture"])
        [DCMView setCLUTBARS: clutBarsCopy ANNOTATIONS: annotGraphics];
    else
        [DCMView setCLUTBARS: barHide ANNOTATIONS: annotGraphics];
    
    unsigned char *data = nil;
    
    if( [views count] > 1 && [views count] == [viewsRect count])
    {
        data = [self getRawPixelsWidth: &width
                                height: &height
                                   spp: &spp
                                   bpp: &bpp
                         screenCapture: YES
                            force8bits: YES
                       removeGraphical: YES
                          squarePixels: YES
                              allTiles: NO
                    allowSmartCropping: NO
                                origin: imOrigin
                               spacing: imSpacing
                                offset: nil
                              isSigned: nil
                                 views: views
                             viewsRect: viewsRect];
    }
    else
    {
        data = [self getRawPixelsViewWidth: &width
                                    height: &height
                                       spp: &spp
                                       bpp: &bpp
                             screenCapture: YES
                                force8bits: YES
                           removeGraphical: YES
                              squarePixels: YES
                        allowSmartCropping: NO
                                    origin: imOrigin
                                   spacing: imSpacing
                                    offset: nil
                                  isSigned: nil];
    }
    
    if( data)
    {
        if( size)
        {
            if( spp != 3)
                NSLog( @"********* spp != 3 I'll NOT resize");
            else
            {
                unsigned char *cropData;
                int cropHeight, cropWidth;
                float rescale = 0;
                NSPoint croppedOrigin;
                
                if( width > height)
                {
                    rescale = (float) size / (float) height;
                    cropHeight = height;
                    cropWidth = height;
                }
                else
                {
                    rescale = (float) size / (float) width;
                    cropHeight = width;
                    cropWidth = width;
                }
                
                croppedOrigin = NSMakePoint( ((width-cropWidth)/2.), ((height - cropHeight)/2.));
                
                cropData = data + spp*((width-cropWidth)/2) + spp*((height - cropHeight)/2)*width;
                
                // resize the data
                
                vImage_Buffer src, dest;
                
                src.data = cropData;
                src.rowBytes = width * spp;
                src.height = cropHeight;
                src.width = cropWidth;
                
                dest.data = calloc( size*size*spp, 1);
                dest.rowBytes = size*spp;
                dest.width = dest.height = size;
                
                if( dest.data)
                {
                    vImage_Buffer	argbsrcVimage, argbdstVimage;
                    
                    argbsrcVimage = src;
                    argbsrcVimage.rowBytes =  src.width * 4;
                    argbsrcVimage.data = calloc( argbsrcVimage.rowBytes * argbsrcVimage.height, 1);
                    
                    argbdstVimage = dest;
                    argbdstVimage.rowBytes =  dest.width * 4;
                    argbdstVimage.data = calloc( argbdstVimage.rowBytes * argbdstVimage.height, 1);
                    
                    vImageConvert_RGB888toARGB8888( &src, nil, 0, &argbsrcVimage, 0, 0);
                    vImageScale_ARGB8888( &argbsrcVimage, &argbdstVimage, nil, kvImageHighQualityResampling);
                    vImageConvert_ARGB8888toRGB888( &argbdstVimage, &dest, 0);
                    
                    free( argbsrcVimage.data);
                    free( argbdstVimage.data);
                    
                    free( data);
                    
                    data = dest.data;
                    width = size;
                    height = size;
                    
                    // correct the spacing & origin
                    
//                    if( imOrigin)
                    {
                        NSPoint tempPt = [self ConvertFromUpLeftView2GL: croppedOrigin];
                        [self.curDCM convertPixX: tempPt.x pixY: tempPt.y toDICOMCoords: imOrigin pixelCenter: YES];
                    }
                    
//                    if( imSpacing)
                    {
                        imSpacing[ 0] /= rescale;
                        imSpacing[ 1] /= rescale;
                    }
                }
            }
        }
        
        [exportDCM setSourceFile: [self.imageObj valueForKey:@"completePath"]];
        
        float thickness, location;
        
        [self getThickSlabThickness:&thickness location:&location];
        [exportDCM setSliceThickness: thickness];
        [exportDCM setSlicePosition: location];
        
        if( [views count] <= 1)
        {
            [self orientationCorrectedToView: o];
            [exportDCM setOrientation: o];
        }
        
        if( exportSpacingAndOrigin && (imSpacing[ 0] != 0 || imSpacing[ 1] != 0 || imOrigin[ 0] != 0 || imOrigin[ 0] != 1 || imOrigin[ 0] != 2))
        {
            [exportDCM setPosition: imOrigin];
            [exportDCM setPixelSpacing: imSpacing[ 0] :imSpacing[ 1]];
        }
        [exportDCM setPixelData: data samplesPerPixel:spp bitsPerSample:bpp width: width height: height];
        [exportDCM setModalityAsSource: NO];
        
        f = [exportDCM writeDCMFile: nil withExportDCM: dcmExportPlugin];
        if( f == nil) NSRunCriticalAlertPanel( NSLocalizedString(@"Error", nil),  NSLocalizedString(@"Error during the creation of the DICOM File!", nil), NSLocalizedString(@"OK", nil), nil, nil);
        
        free( data);
    }
    
    [DCMView setCLUTBARS: clutBarsCopy ANNOTATIONS: annotCopy];
    
    return [NSDictionary dictionaryWithObjectsAndKeys: f, @"file", nil];
}

- (NSImage*) nsimage
{
    return [self nsimage: NO allViewers: NO];
}

- (NSImage*) nsimage:(BOOL) originalSize
{
    return [self nsimage: originalSize allViewers: NO];
}

- (NSImage*) nsimage:(BOOL) originalSize allViewers:(BOOL) allViewers
{
    NSBitmapImageRep	*rep;
    long				width, height, spp, bpp;
    NSString			*colorSpace;
    unsigned char		*data;
    
    NSDisableScreenUpdates();
    
    if( stringID == nil && originalSize == NO)
    {
        //		if( [ViewerController numberOf2DViewer] > 1 || _imageColumns != 1 || _imageRows != 1 || [self isKeyImage] == YES)
        {
            if( [self is2DViewer] && (_imageColumns != 1 || _imageRows != 1))
            {
                NSArray	*vs = [[self windowController] imageViews];
                
                [vs makeObjectsPerformSelector: @selector(setStringID:) withObject: @"copy"];
                [vs makeObjectsPerformSelector: @selector(display)];
            }
            else
            {
                stringID = [@"copy" retain];	// to remove the red square around the image
                [self display];
            }
        }
    }
    
    if( [self is2DViewer] == NO) allViewers = NO;
    
    if( allViewers && [ViewerController numberOf2DViewer] > 1)
    {
        NSArray	*viewers = [ViewerController getDisplayed2DViewers];
        
        //order windows from left-top to right-bottom
        NSMutableArray	*cWindows = [NSMutableArray arrayWithArray: viewers];
        NSMutableArray	*cResult = [NSMutableArray array];
        int wCount = [cWindows count];
        
        for( int i = 0; i < wCount; i++)
        {
            int index = 0;
            float minY = [[[cWindows objectAtIndex: 0] window] frame].origin.y;
            
            for( int x = 0; x < [cWindows count]; x++)
            {
                if( [[[cWindows objectAtIndex: x] window] frame].origin.y > minY)
                {
                    minY  = [[[cWindows objectAtIndex: x] window] frame].origin.y;
                    index = x;
                }
            }
            
            float minX = [[[cWindows objectAtIndex: index] window] frame].origin.x;
            
            for( int x = 0; x < [cWindows count]; x++)
            {
                if( [[[cWindows objectAtIndex: x] window] frame].origin.x < minX && [[[cWindows objectAtIndex: x] window] frame].origin.y >= minY)
                {
                    minX = [[[cWindows objectAtIndex: x] window] frame].origin.x;
                    index = x;
                }
            }
            
            [cResult addObject: [cWindows objectAtIndex: index]];
            [cWindows removeObjectAtIndex: index];
        }
        
        viewers = cResult;
        
        NSMutableArray	*viewsRect = [NSMutableArray array];
        
        // Compute the enclosing rect
        for( ViewerController *v in viewers)
        {
            [[v seriesView] selectFirstTilingView];
            
            NSRect	bounds = [[v imageView] bounds];
            
            if( [[NSUserDefaults standardUserDefaults] boolForKey:@"includeAllTiledViews"])
            {
                bounds.size.width *= [[v seriesView] imageColumns];
                bounds.size.height *= [[v seriesView] imageRows];
            }
            
            NSRect or = {[v.imageView convertPoint:bounds.origin toView:nil], NSZeroSize};
            bounds.origin = [v.window convertRectToScreen:or].origin;
            
            bounds = NSIntegralRect(bounds);
            
            bounds.origin.x *= v.window.backingScaleFactor;
            bounds.origin.y *= v.window.backingScaleFactor;
            
            bounds.size.width *= v.window.backingScaleFactor;
            bounds.size.height *= v.window.backingScaleFactor;
            
            [viewsRect addObject: [NSValue valueWithRect: bounds]];
        }
        
        data = [self getRawPixelsWidth:  &width
                                height: &height
                                   spp: &spp
                                   bpp: &bpp
                         screenCapture: YES
                            force8bits: YES
                       removeGraphical: NO
                          squarePixels: YES
                              allTiles: [[NSUserDefaults standardUserDefaults] boolForKey: @"includeAllTiledViews"]
                    allowSmartCropping: NO //[[NSUserDefaults standardUserDefaults] boolForKey: @"allowSmartCropping"]
                                origin: nil
                               spacing: nil
                                offset: nil
                              isSigned: nil
                                 views: [viewers valueForKey: @"imageView"]
                             viewsRect: viewsRect];
    }
    else data = [self getRawPixelsWidth :&width height:&height spp:&spp bpp:&bpp screenCapture:!originalSize force8bits: YES removeGraphical:NO squarePixels:YES allTiles: [[NSUserDefaults standardUserDefaults] boolForKey:@"includeAllTiledViews"] allowSmartCropping: [[NSUserDefaults standardUserDefaults] boolForKey: @"allowSmartCropping"] origin: nil spacing: nil];
    
    if( [stringID isEqualToString:@"copy"])
    {
        if( [self is2DViewer] && (_imageColumns != 1 || _imageRows != 1))
        {
            NSArray	*vs = [[self windowController] imageViews];
            
            [vs makeObjectsPerformSelector: @selector(setStringID:) withObject: nil];
            [vs makeObjectsPerformSelector: @selector(display)];
        }
        else
        {
            [stringID release];
            stringID = nil;
            
            [self setNeedsDisplay: YES];
        }
    }
    
    if( spp == 3) colorSpace = NSCalibratedRGBColorSpace;
    else colorSpace = NSCalibratedWhiteColorSpace;
    
    rep = [[[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes: nil
            pixelsWide: width
            pixelsHigh: height
            bitsPerSample: bpp
            samplesPerPixel: spp
            hasAlpha: NO
            isPlanar: NO
            colorSpaceName: colorSpace
            bytesPerRow: width*bpp*spp/8
            bitsPerPixel: bpp*spp] autorelease];
    
    if( data)
        memcpy( [rep bitmapData], data, height*width*bpp*spp/8);
    
    NSImage *image = [[[NSImage alloc] init] autorelease];
    [image addRepresentation:rep];
    
    free( data);
    
    NSEnableScreenUpdates();
    
    return image;
}

- (BOOL) zoomIsSoftwareInterpolated
{
    return zoomIsSoftwareInterpolated;
}

-(void) setScaleValueCentered:(float) x
{
    if( x < 0.01 ) return;
    if( x > 100) return;
    if( isnan( x)) return;
    if( curImage < 0) return;
    
    if( x != scaleValue)
    {
        if( scaleValue)
        {
            [self setOriginX:((origin.x * x) / scaleValue) Y:((origin.y * x) / scaleValue)];
        }
        
        scaleValue = x;
        
        if( scaleValue < 0.01) scaleValue = 0.01;
        if( scaleValue > 100) scaleValue = 100;
        if( isnan( scaleValue)) scaleValue = 100;
        
        if( [self softwareInterpolation] || [blendingView softwareInterpolation])
            [self loadTextures];
        else if( zoomIsSoftwareInterpolated || [blendingView zoomIsSoftwareInterpolated])
            [self loadTextures];
        
        if( [self is2DViewer])
        {
            // Series Level
            if( [self isScaledFit] == NO)
                [self.seriesObj setValue:[NSNumber numberWithFloat: scaleValue / sqrt( [self frame].size.height * [self frame].size.width)] forKey:@"scale"];
            else
                [self.seriesObj setValue: nil forKeyPath: @"scale"];
            [self.seriesObj setValue:[NSNumber numberWithInt: 3] forKey: @"displayStyle"];
            
            // Image Level
            if( curImage >= 0 && COPYSETTINGSINSERIES == NO && [self isScaledFit] == NO)
                [self.imageObj setValue:[NSNumber numberWithFloat:scaleValue] forKey:@"scale"];
            else
                [self.imageObj setValue: nil forKey:@"scale"];
        }
        
        [self updateTilingViews];
        
        [self setNeedsDisplay:YES];
    }
}


- (void) setScaleValue:(float) x
{
    if( isnan( x)) return;
    if( curImage < 0) return;
    if( self.curDCM == nil) return;
    if( x < 0.01) x = 0.01;
    if( x > 100) x = 100;
    
    if( scaleValue != x )
    {
        scaleValue = x;
        
        if( [self softwareInterpolation] || [blendingView softwareInterpolation])
            [self loadTextures];
        else if( zoomIsSoftwareInterpolated || [blendingView zoomIsSoftwareInterpolated])
            [self loadTextures];
        
        if( [self is2DViewer] && firstTimeDisplay)
        {
            if( [[self windowController] isPostprocessed] == NO)
            {
                @try {
                    // Series Level
                    if( [self isScaledFit] == NO)
                        [self.seriesObj setValue:[NSNumber numberWithFloat: scaleValue / sqrt( [self frame].size.height * [self frame].size.width)] forKey:@"scale"];
                    else
                        [self.seriesObj setValue: nil forKey:@"scale"];
                    
                    [self.seriesObj setValue:[NSNumber numberWithInt: 3] forKey: @"displayStyle"];
                    
                    // Image Level
                    if( curImage >= 0 && COPYSETTINGSINSERIES == NO && [self isScaledFit] == NO)
                        [self.imageObj setValue:[NSNumber numberWithFloat:scaleValue] forKey:@"scale"];
                    else
                        [self.imageObj setValue: nil forKey:@"scale"];
                }
                @catch ( NSException *e) {
                    N2LogException( e);
                }
            }
        }
        
        [self updateTilingViews];
        
        [self setNeedsDisplay:YES];
    }
}

-(void) setAlpha:(float) a
{
    float   val, ii;
    float   src[ 256];
    long i;
    
    switch( blendingMode )
    {
        case 0:				// LINEAR FUSION
            for( i = 0; i < 256; i++ ) src[ i] = i;
            break;
            
        case 1:				// HIGH-LOW-HIGH
            for( i = 0; i < 128; i++) src[ i] = (127 - i)*2;
            for( i = 128; i < 256; i++) src[ i] = (i-127)*2;
            break;
            
        case 2:				// LOW-HIGH-LOW
            for( i = 0; i < 128; i++) src[ i] = i*2;
            for( i = 128; i < 256; i++) src[ i] = 256 - (i-127)*2;
            break;
            
        case 3:				// LOG
            for( i = 0; i < 256; i++) src[ i] = 255. * log10( 1. + (i/255.)*9.);
            break;
            
        case 4:				// LOG INV
            for( i = 0; i < 256; i++) src[ i] = 255. * (1. - log10( 1. + ((255-i)/255.)*9.));
            break;
            
        case 5:				// FLAT
            for( i = 0; i < 256; i++) src[ i] = 128;
            break;
    }
    
    if( a <= 0)
    {
        a += 256;
        
        for(i=0; i < 256; i++) 
        {
            ii = src[ i];
            val = (a * ii) / 256.;
            
            if( val > 255) val = 255;
            if( val < 0) val = 0;
            alphaTable[i] = val;
        }
    }
    else
    {
        if( a == 256) for(i=0; i < 256; i++) alphaTable[i] = 255;
        else
        {
            for(i=0; i < 256; i++) 
            {
                ii = src[ i];
                val = (256. * ii)/(256 - a);
                
                if( val > 255) val = 255;
                if( val < 0) val = 0;
                alphaTable[i] = val;
            }
        }
    }
}

-(void) setBlendingFactor:(float) f
{
    blendingFactor = f;
    
    if( blendingFactor < -256) blendingFactor = -256;
    if( blendingFactor > 256) blendingFactor = 256;
    
    [blendingView setAlpha: blendingFactor];
    [self loadTextures];
    [self setNeedsDisplay: YES];
    
    if( [self is2DViewer])
    {
        if( blendingFactor != [[[self windowController] blendingSlider] floatValue])
        {
            [[[self windowController] blendingSlider] setFloatValue: blendingFactor];
            [[self windowController] blendingSlider: [[self windowController] blendingSlider]];
        }
    }
}

-(void) setBlendingMode:(long) f
{
    blendingMode = f;
    
    if( [blendingView blendingMode] != blendingMode)
        [blendingView setBlendingMode: blendingMode];
    
    [blendingView setAlpha: blendingFactor];
    
    [self loadTextures];
    [self setNeedsDisplay: YES];
}

-(void) setRotation:(float) x
{
    if( rotation != x )
    {
        rotation = x;
        
        if( rotation < 0) rotation += 360;
        if( rotation > 360) rotation -= 360;
        
        [self.seriesObj setValue:[NSNumber numberWithFloat:rotation] forKey:@"rotationAngle"];
        
        // Image Level
        if( curImage >= 0 && COPYSETTINGSINSERIES == NO)
            [self.imageObj setValue:[NSNumber numberWithFloat:rotation] forKey:@"rotationAngle"];
        else
            [self.imageObj setValue: nil forKey:@"rotationAngle"];
        
        [self updateTilingViews];
        
        [self setNeedsDisplay: YES];
    }
}

- (void) orientationCorrectedToView:(float*) correctedOrientation
{
    float	o[ 9];
    float   yRot = -1, xRot = -1;
    float	rot = rotation;
    
    [self.curDCM orientation: o];
    
    if( yFlipped && xFlipped)
    {
        rot = rot + 180;
    }
    else
    {
        if( yFlipped )
        {
            xRot *= -1;
            yRot *= -1;
            
            o[ 3] *= -1;
            o[ 4] *= -1;
            o[ 5] *= -1;
        }
        
        if( xFlipped )
        {
            xRot *= -1;
            yRot *= -1;
            
            o[ 0] *= -1;
            o[ 1] *= -1;
            o[ 2] *= -1;
        }
    }
    
    // Compute normal vector
    o[6] = o[1]*o[5] - o[2]*o[4];
    o[7] = o[2]*o[3] - o[0]*o[5];
    o[8] = o[0]*o[4] - o[1]*o[3];
    
    XYZ vector, rotationVector; 
    
    rotationVector.x = o[ 6];	rotationVector.y = o[ 7];	rotationVector.z = o[ 8];
    
    vector.x = o[ 0];	vector.y = o[ 1];	vector.z = o[ 2];
    vector =  ArbitraryRotate(vector, xRot*rot*deg2rad, rotationVector);
    o[ 0] = vector.x;	o[ 1] = vector.y;	o[ 2] = vector.z;
    
    vector.x = o[ 3];	vector.y = o[ 4];	vector.z = o[ 5];
    vector =  ArbitraryRotate(vector, yRot*rot*deg2rad, rotationVector);
    o[ 3] = vector.x;	o[ 4] = vector.y;	o[ 5] = vector.z;
    
    // Compute normal vector
    o[6] = o[1]*o[5] - o[2]*o[4];
    o[7] = o[2]*o[3] - o[0]*o[5];
    o[8] = o[0]*o[4] - o[1]*o[3];
    
    double length = sqrt(o[ 0]*o[ 0] + o[ 1]*o[ 1] + o[ 2]*o[ 2]);
    if( length)	{	o[0] = o[ 0] / length;	o[1] = o[ 1] / length;	o[ 2] = o[ 2] / length;	}
    
    length = sqrt(o[ 3]*o[ 3] + o[ 4]*o[ 4] + o[ 5]*o[ 5]);
    if( length)	{	o[ 3] = o[ 3] / length;	o[ 4] = o[ 4] / length;	o[ 5] = o[ 5] / length;	}
    
    length = sqrt(o[ 6]*o[ 6] + o[ 7]*o[ 7] + o[ 8]*o[ 8]);
    if( length)	{	o[6] = o[ 6] / length;	o[ 7] = o[ 7] / length;	o[ 8] = o[ 8] / length;	}
    
    memcpy( correctedOrientation, o, sizeof o );
}

#ifndef OSIRIX_LIGHT
- (N3AffineTransform)pixToSubDrawRectTransform // converst points in DCMPix "Slice Coordinates" to coordinates that need to be passed to GL in subDrawRect
{
    N3AffineTransform pixToSubDrawRectTransform;
    
#ifndef NDEBUG
    if( isnan( self.curDCM.pixelSpacingX) || isnan( self.curDCM.pixelSpacingY) || self.curDCM.pixelSpacingX <= 0 || self.curDCM.pixelSpacingY <= 0 || self.curDCM.pixelSpacingX > 1000 || self.curDCM.pixelSpacingY > 1000)
        NSLog( @"******* CPR pixel spacing incorrect for pixToSubDrawRectTransform");
#endif
    
    pixToSubDrawRectTransform = N3AffineTransformIdentity;
    //    pixToSubDrawRectTransform = N3AffineTransformConcat(pixToSubDrawRectTransform, N3AffineTransformMakeScale(1.0/self.curDCM.pixelSpacingX, 1.0/self.curDCM.pixelSpacingY, 1));
    pixToSubDrawRectTransform = N3AffineTransformConcat(pixToSubDrawRectTransform, N3AffineTransformMakeTranslation(self.curDCM.pwidth * -0.5, self.curDCM.pheight * -0.5, 0));
    pixToSubDrawRectTransform = N3AffineTransformConcat(pixToSubDrawRectTransform, N3AffineTransformMakeScale(scaleValue, scaleValue, 1));
    
    pixToSubDrawRectTransform.m14 = 0.0;
    pixToSubDrawRectTransform.m24 = 0.0;
    pixToSubDrawRectTransform.m34 = 0.0;
    pixToSubDrawRectTransform.m44 = 1.0;
    
    return pixToSubDrawRectTransform;
}
#endif

-(void) setOriginWithRotationX:(float) x Y:(float) y
{
    x = x*cos(rotation*deg2rad) + y*sin(rotation*deg2rad);
    y = x*sin(rotation*deg2rad) - y*cos(rotation*deg2rad);
    
    [self setOriginX: x Y: y];
}

-(void) setOrigin:(NSPoint) x
{
    [self setOriginX: x.x Y: x.y];
}

-(void) setOriginX:(float) x Y:(float) y
{
    if( curImage < 0) return;
    if( self.curDCM == nil) return;
    
    if( x > -100000 && x < 100000) x = x;
    else x = 0;
    
    if( y > -100000 && y < 100000) y = y;
    else y = 0;
    
    if( origin.x != x || origin.y != y)
    {
        origin.x = x;
        origin.y = y;
        [self updateTilingViews];
        
        [self setNeedsDisplay:YES];
        
        if( [self is2DViewer] == YES && [[self windowController] isPostprocessed] == NO)
        {
            // Series Level
            [self.seriesObj setValue:[NSNumber numberWithFloat:x] forKey:@"xOffset"];
            [self.seriesObj setValue:[NSNumber numberWithFloat:y] forKey:@"yOffset"];
            
            // Image Level
            if( curImage >= 0 && COPYSETTINGSINSERIES == NO)
            {
                [self.imageObj setValue:[NSNumber numberWithFloat:x] forKey:@"xOffset"];
                [self.imageObj setValue:[NSNumber numberWithFloat:y] forKey:@"yOffset"];
            }
            else
            {
                [self.imageObj setValue: nil forKey:@"xOffset"];
                [self.imageObj setValue: nil forKey:@"yOffset"];
            }
        }
    }
}

- (void) colorTables:(unsigned char **) a :(unsigned char **) r :(unsigned char **)g :(unsigned char **) b
{
    *a = alphaTable;
    *r = redTable;
    *g = greenTable;
    *b = blueTable;
}

- (void) blendingColorTables:(unsigned char **) a :(unsigned char **) r :(unsigned char **)g :(unsigned char **) b
{
    if( [[[NSUserDefaults standardUserDefaults] stringForKey:@"PET Clut Mode"] isEqualToString: @"B/W Inverse"])
    {
        *a = alphaTable;
        *r = PETredTable;
        *g = PETgreenTable;
        *b = PETblueTable;
    }
    else
    {
        [blendingView colorTables:a :r :g :b];
    }
}

- (BOOL) softwareInterpolation
{
    if(	scaleValue > 2 && NOINTERPOLATION == NO && 
       SOFTWAREINTERPOLATION == YES && self.curDCM.pwidth <= SOFTWAREINTERPOLATION_MAX)
    {
        return YES;
    }
    return NO;
}

- (IBAction) sliderRGBFactor:(id) sender
{
    switch( [sender tag])
    {
        case 0: redFactor = [sender floatValue];  break;
        case 1: greenFactor = [sender floatValue];  break;
        case 2: blueFactor = [sender floatValue];  break;
    }
    
    [self reapplyWindowLevel];
    
    [self loadTextures];
    [self setNeedsDisplay:YES];
}

- (void) sliderAction:(id) sender
{
    long	x = curImage;//x = curImage before sliderAction
    
    if( flippedData) curImage = (long)[dcmPixList count] -1 -[sender intValue];
    else curImage = [sender intValue];
    
    [self setIndex:curImage];
    
    [self sendSyncMessage:curImage - x];
    
    if( [self is2DViewer] == YES)
    {
        [[self windowController] propagateSettings];
        [[self windowController] adjustKeyImage];
    }
}

+ (BOOL) labelFontSizeMenuItemIsEnabled:(NSMenuItem *)item
{
    float size = [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"];
    if( [item action] == @selector(increaseFontSize:))
        return size < 60;
    if( [item action] == @selector(decreaseFontSize:))
        return size > 6;
    return YES;
}

- (void) increaseFontSize:(id) sender
{
    if( [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"] < 60)
    {
        [[NSUserDefaults standardUserDefaults] setFloat: [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"] + 1 forKey: @"LabelFONTSIZE"];
        [[NSNotificationCenter defaultCenter] postNotificationName:OsirixLabelGLFontChangeNotification object: sender];
    }
}

- (void) decreaseFontSize:(id) sender
{
    if( [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"] > 6)
    {
        [[NSUserDefaults standardUserDefaults] setFloat: [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"] - 1 forKey: @"LabelFONTSIZE"];
        [[NSNotificationCenter defaultCenter] postNotificationName:OsirixLabelGLFontChangeNotification object: sender];
    }
}

- (void) changeLabelGLFontNotification:(NSNotification*) note
{
    if( self.window.backingScaleFactor != 0)
    {
        [labelFont release];
        
        labelFont = [[NSFont fontWithName: [[NSUserDefaults standardUserDefaults] stringForKey:@"LabelFONTNAME"] size: [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"]] retain];
        if( labelFont == nil) labelFont = [[NSFont userFixedPitchFontOfSize: [[NSUserDefaults standardUserDefaults] floatForKey: @"LabelFONTSIZE"]] retain];
        
        [ROI setFontHeight: [DCMView sizeOfString: @"B" forFont: labelFont].height];
        
        [self setNeedsDisplay:YES];
    }
}

- (void) changeGLFontNotification:(NSNotification*) note
{
    if( self.window.backingScaleFactor != 0)
    {
        [fontGL release];
        
        fontGL = [[NSFont fontWithName: [[NSUserDefaults standardUserDefaults] stringForKey:@"FONTNAME"] size: [[NSUserDefaults standardUserDefaults] floatForKey: @"FONTSIZE"]] retain];
        if( fontGL == nil) fontGL = [[NSFont fontWithName:@"Geneva" size:14] retain];
        
        stringSize = [self convertSizeToBacking: [DCMView sizeOfString:@"B" forFont:fontGL]];
        
        [self setNeedsDisplay:YES];
    }
}

- (void)changeFont:(id)sender
{
    NSFont *oldFont = fontGL;
    NSFont *newFont = [sender convertFont:oldFont];
    
    [[NSUserDefaults standardUserDefaults] setObject: [newFont fontName] forKey: @"FONTNAME"];
    [[NSUserDefaults standardUserDefaults] setFloat: [newFont pointSize] forKey: @"FONTSIZE"];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixGLFontChangeNotification object: sender];
}

// The picture is uploaded when it is drawn (#728): nothing is kept to load.
- (void) loadTextures
{
}

-(void) becomeMainWindow
{
    [self updateTilingViews];
    
    [self invalidateReferenceLines];
    slicePoint3D[ 0] = HUGE_VALF;
    
    [self sendSyncMessage: 0];
    [self computeColor];
    [self setNeedsDisplay:YES];
}

-(void) becomeKeyWindow
{
    [self invalidateReferenceLines];
    slicePoint3D[ 0] = HUGE_VALF;
    
    [self erase2DPointMarker];
    if( blendingView) [blendingView erase2DPointMarker];
    
    [self sendSyncMessage: 0];
    
    [self flagsChanged: [[NSApplication sharedApplication] currentEvent]];
    
    [self setNeedsDisplay:YES];
}

- (BOOL)becomeFirstResponder
{
    isKeyView = YES;
    
    [self updateTilingViews];
    
    if (curImage < 0)
    {
        if( flippedData)
        {
            if( listType == 'i') [self setIndex: (long)[dcmPixList count] -1 ];
            else [self setIndexWithReset:(long)[dcmPixList count] -1  :YES];
        }
        else
        {
            if( listType == 'i') [self setIndex: 0];
            else [self setIndexWithReset:0 :YES];
        }
        
        [self updateTilingViews];
    }
    
    [self becomeKeyWindow];
    [self setNeedsDisplay:YES];
    
    if( [self is2DViewer])
    {
        [[self windowController] adjustSlider];
        [[self windowController] propagateSettings];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixDCMViewDidBecomeFirstResponderNotification object:self];
    
    [self flagsChanged: [[NSApplication sharedApplication] currentEvent]];
    
    return YES;
}

// ** TILING SUPPORT

- (id)initWithFrame:(NSRect)frame
{
    [AppController initialize];
    
    [DCMView setDefaults];
    
    return [self initWithFrame:frame imageRows:1  imageColumns:1];
    
}

- (id)initWithFrame:(NSRect)frame imageRows:(int)rows  imageColumns:(int)columns
{
    self = [self initWithFrameInt:frame];
    if (self)
    {
        drawing = YES;
        _tag = 0;
        _imageRows = rows;
        _imageColumns = columns;
        isKeyView = NO;
        timeIntervalForDrag = 1.0;
        annotationType = [[NSUserDefaults standardUserDefaults] integerForKey:@"ANNOTATIONS"];
        
        [self setAutoresizingMask:NSViewMinXMargin];
        
        noScale = NO;
        flippedData = NO;
        
        lensZoomFactor = 4;
        lensSizeFactor = 1.0f;
        
        //notifications
        NSNotificationCenter *nc;
        nc = [NSNotificationCenter defaultCenter];
        [nc addObserver: self
               selector: @selector(updateCurrentImage:)
                   name: OsirixDCMUpdateCurrentImageNotification
                 object: nil];
        
        [self.window makeFirstResponder: self];
    }
    return self;
    
}

- (void)resizeWithOldSuperviewSize:(NSSize)oldBoundsSiz
{
    if( [self is2DViewer] != YES)
    {
        [super resizeWithOldSuperviewSize:oldBoundsSiz];
        return;
    }
    
    NSRect superFrame = [[self superview] bounds];
    
    int newWidth = superFrame.size.width / _imageColumns;
    int newHeight = superFrame.size.height / _imageRows;
    int newY = newHeight * (int)(_tag / _imageColumns);
    int newX = newWidth * (int)(_tag % _imageColumns);
    NSRect newFrame = NSMakeRect(newX, newY, newWidth, newHeight);
    
    BOOL wasScaledToFit = [self isScaledFit];
    
    [self setFrame:newFrame];
    
    if( wasScaledToFit)
        [self scaleToFit];
    
    [self setNeedsDisplay:YES];
}

-(void)keyUp:(NSEvent *)theEvent
{
    if ([self eventToPlugins:theEvent]) return;
    [super keyUp:theEvent];
}

-(void) setRows:(int)rows columns:(int)columns
{
    if( _imageRows == 1 && _imageColumns == 1 && rows == 1 && columns == 1)
    {
        //		NSLog(@"No Resize");
        return;
    }
    _imageRows = rows;
    _imageColumns = columns;
    
    NSRect rect = [[self superview] bounds];
    [self resizeWithOldSuperviewSize:rect.size];
    [self setNeedsDisplay:YES];
}

-(void)setImageParamatersFromView:(DCMView *)aView
{
    if (aView != self && dcmPixList != nil)
    {
        int offset = [self tag] - [aView tag];
        int prevCurImage = [self curImage];
        
        if( flippedData)
            offset = -offset;
        
        curImage = [aView curImage] + offset;
        
        if (curImage < 0)
        {
            curImage = -1;
            
            if( flippedData == NO)
            {
                if( [self is2DViewer])
                {
                    [NSObject cancelPreviousPerformRequestsWithTarget:[self windowController] selector: @selector(selectFirstTilingView) object: nil];
                    [[self windowController] performSelector:@selector(selectFirstTilingView) withObject:nil afterDelay:0];
                }
            }
        }
        else if (curImage >= [dcmPixList count])
        {
            curImage = -1;
            
            if( flippedData)
            {
                if( [self is2DViewer])
                {
                    [NSObject cancelPreviousPerformRequestsWithTarget:[self windowController] selector: @selector(selectFirstTilingView) object: nil];
                    [[self windowController] performSelector:@selector(selectFirstTilingView) withObject:nil afterDelay:0];
                }
            }
        }
        
        if(aView.curDCM)
        {
            [self setCOPYSETTINGSINSERIESdirectly: aView.COPYSETTINGSINSERIES];
            
            if( curImage < 0)
            {
                
            }
            else if( COPYSETTINGSINSERIES)
            {
                if( [aView curWL] != 0 && [aView curWW] != 0)
                {
                    if( curWL != [aView curWL] || curWW != [aView curWW])
                        [self setWLWW:[aView curWL] :[aView curWW]];
                }	
                self.scaleValue = aView.scaleValue;
                self.rotation = aView.rotation;
                [self setOrigin: [aView origin]];
                
                self.xFlipped = aView.xFlipped;
                self.yFlipped = aView.yFlipped;
                
                // Blending
                if (blendingView != aView.blendingView)
                    self.blendingView = aView.blendingView;
                if (blendingFactor != aView.blendingFactor)
                    self.blendingFactor = aView.blendingFactor;
                if (blendingMode != aView.blendingMode)
                    self.blendingMode = aView.blendingMode;
                
                // CLUT
                unsigned char *aR, *aG, *aB;
                [aView getCLUT: &aR :&aG :&aB];
                [self setCLUT:aR :aG: aB];
            }
        }
        
        self.flippedData = aView.flippedData;
        [self setMenu: [aView menu]];
        
        if( prevCurImage != [self curImage])
            [self setIndex:[self curImage]];
    }
}

- (BOOL)resignFirstResponder
{
    isKeyView = NO;
    [self setNeedsDisplay:YES];
    [self sendSyncMessage: 0];
    
    return [super resignFirstResponder];
}

-(void) updateCurrentImage: (NSNotification*) note
{
    if( stringID == nil)
    {
        DCMView *otherView = [note object];
        
        if ([[[note object] superview] isEqual:[self superview]] && ![otherView isEqual: self]) 
            [self setImageParamatersFromView: otherView];
    }
}

-(void)newImageViewisKey:(NSNotification *)note
{
    if ([note object] != self)
        isKeyView = NO;
}

//cursor methods

- (void)mouseEntered:(NSEvent *)theEvent
{
    [self eventToPlugins:theEvent];
    cursorSet = YES;
}

- (void)mouseExited:(NSEvent *)theEvent
{
    [self horosHideScrollPreview];
    [self eventToPlugins: theEvent];
    
    [self mouseMoved: theEvent];
    
    [self deleteLens];
#ifdef new_loupe
    [self hideLoupe];
#endif
    mouseXPos = 0;
    mouseYPos = 0;
    
    cursorSet = NO;
}

-(void)cursorUpdate:(NSEvent *)theEvent
{
    [self flagsChanged: theEvent];
    [cursor set];
    cursorSet = YES;
}

- (void) checkCursor
{
    if(cursorSet == YES && [[self window] isKeyWindow] == YES)
    {
        [cursor set];
    }
}

-(void) setCursorForView: (ToolMode) tool
{
    NSCursor	*c;
    
    if( [self roiTool:tool])
    {
        c = [NSCursor crossCursor];
        //		else c = [NSCursor crosshairCursor];		//crossCursor
    }
    else if (tool == tTranslate)
        c = [NSCursor openHandCursor];
    else if (tool == tRotate)
        c = [NSCursor rotateCursor];
    else if (tool == tZoom)
        c = [NSCursor zoomCursor];
    else if (tool == tWL)
        c = [NSCursor contrastCursor];
    else if (tool == tNext)
        c = [NSCursor stackCursor];
    else if (tool == tText)
        c = [NSCursor IBeamCursor];
    else if (tool == t3DRotate)
        c = [NSCursor crosshairCursor];
    else if (tool == tCross)
        c = [NSCursor crosshairCursor];
    else if (tool == tRepulsor)
        c = [NSCursor crosshairCursor];
    else if (tool == tROISelector)
        c = [NSCursor crosshairCursor];
    else if (tool == tCamera3D)
        c = [NSCursor rotate3DCameraCursor];
    else	
        c = [NSCursor arrowCursor];
    
    if( c != cursor)
    {
        [cursor release];
        cursor = [c retain];
    }
}

/*
 *  Formula K(SUV)=K(Bq/cc)*(Wt(kg)/Dose(Bq)*1000 cc/kg 
 *						  
 *  Where: K(Bq/cc) = is a pixel value calibrated to Bq/cc and decay corrected to scan start time
 *		 Dose = the injected dose in Bq at injection time (This value is decay corrected to scan start time. The injection time must be part of the dataset.)
 *		 Wt = patient weight in kg
 *		 1000=the number of cc/kg for water (an approximate conversion of patient weight to distribution volume)
 */

- (float) getBlendedSUV
{
    if( [blendingView.curDCM SUVConverted]) return blendingPixelMouseValue;
    
    if( [[blendingView.curDCM units] isEqualToString:@"CNTS"]) return blendingPixelMouseValue * [blendingView.curDCM philipsFactor];
    return blendingPixelMouseValue * [blendingView.curDCM patientsWeight] * 1000. / ([blendingView.curDCM radionuclideTotalDoseCorrected] * [self.curDCM decayFactor]);
}

- (float)getSUV
{
    if( self.curDCM.SUVConverted) return pixelMouseValue;
    
    if( [self.curDCM.units isEqualToString:@"CNTS"]) return pixelMouseValue * self.curDCM.philipsFactor;
    else return pixelMouseValue * self.curDCM.patientsWeight * 1000.0f / (self.curDCM.radionuclideTotalDoseCorrected * [self.curDCM decayFactor]);
}


+ (void)setPluginOverridesMouse: (BOOL)override { // is deprecated in @interface
    pluginOverridesMouse = override;
}

- (IBAction) realSize:(id)sender
{
    if( self.curDCM.pixelSpacingX == 0 || self.curDCM.pixelSpacingY == 0)
    {
        NSRunCriticalAlertPanel(NSLocalizedString(@"Actual Size Error",nil), NSLocalizedString(@"This image is not calibrated.",nil) , NSLocalizedString( @"OK",nil), nil, nil);
    }
    else
    {
        CGSize f = CGDisplayScreenSize( [[[[[self window] screen] deviceDescription] valueForKey: @"NSScreenNumber"] intValue]);
        CGRect r = CGDisplayBounds( [[[[[self window] screen] deviceDescription] valueForKey: @"NSScreenNumber"] intValue]); 
        
        if( f.width != 0 && f.height != 0)
        {
            NSLog( @"screen pixel ratio: %f", fabs( (f.width/r.size.width) - (f.height/r.size.height)));
            if( fabs( (f.width/r.size.width) - (f.height/r.size.height)) < 0.01)
            {
                [self setScaleValue: self.curDCM.pixelSpacingX / (f.width/r.size.width)];
            }
            else
            {
                NSRunCriticalAlertPanel(NSLocalizedString(@"Actual Size Error",nil), NSLocalizedString(@"Displayed pixels are non-squared pixel. Images cannot be displayed at actual size.",nil) , NSLocalizedString( @"OK",nil), nil, nil);
            }
        }
        else
            NSRunCriticalAlertPanel(NSLocalizedString(@"Actual Size Error",nil), NSLocalizedString(@"This screen doesn't support this function.",nil) , NSLocalizedString( @"OK",nil), nil, nil);
    }
}

- (IBAction)actualSize:(id)sender
{
    [self setOriginX: 0 Y: 0];
    self.rotation = 0.0f;
    self.scaleValue = 1.0f;
    
    if( [self is2DViewer] == YES)
    {
        if( [[self window] isMainWindow])
            [[self windowController] propagateSettings];
    }
}

- (IBAction)scaleToFit:(id)sender
{
    [self setOriginX: 0 Y: 0];
    self.rotation = 0.0f;
    [self scaleToFit];
    
    if( [self is2DViewer] == YES)
    {
        if( [[self window] isMainWindow])
            [[self windowController] propagateSettings];
    }
}

//Database links
- (DicomImage *)imageObj
{
    //	if( stringID == nil || [stringID isEqualToString: @"previewDatabase"])  <- this will break the DICOM export function: no sourceFilePath in DICOMExport
    {
#ifdef NDEBUG
#else
        if( [NSThread isMainThread] == NO)
            NSLog( @"******************* warning this object should be used only on the main thread. Create your own Context !");
#endif
        if( curImage >= 0 && curImage < dcmFilesList.count)
            return [dcmFilesList objectAtIndex: curImage];
        
        else if( [dcmPixList indexOfObject: self.curDCM] != NSNotFound && dcmFilesList.count == dcmPixList.count)
            return [dcmFilesList objectAtIndex: [dcmPixList indexOfObject: self.curDCM]];
        
        else
            return [self.curDCM imageObj];
    }
    
    return nil;
}

- (DicomSeries *)seriesObj
{
    //	if( stringID == nil || [stringID isEqualToString:@"previewDatabase"]) <- this will break the DICOM export function: no sourceFilePath in DICOMExport
    {
#ifdef NDEBUG
#else
        if( [NSThread isMainThread] == NO)
            NSLog( @"******************* warning this object should be used only on the main thread. Create your own Context !");
#endif
        if( curImage >= 0 && curImage < dcmFilesList.count)
            return [[dcmFilesList objectAtIndex: curImage] valueForKey: @"series"];
        else if( [dcmPixList indexOfObject: self.curDCM] != NSNotFound)
            return [[dcmFilesList objectAtIndex: [dcmPixList indexOfObject: self.curDCM]] valueForKey: @"series"];
        else return [self.curDCM seriesObj];
    }
    
    return nil;
}

- (DicomStudy *)studyObj
{
    //	if( stringID == nil || [stringID isEqualToString:@"previewDatabase"]) <- this will break the DICOM export function: no sourceFilePath in DICOMExport
    {
#ifdef NDEBUG
#else
        if( [NSThread isMainThread] == NO)
            NSLog( @"******************* warning this object should be used only on the main thread. Create your own Context !");
#endif
        if( curImage >= 0 && curImage < dcmFilesList.count)
            return [[dcmFilesList objectAtIndex: curImage] valueForKeyPath: @"series.study"];
        else if( [dcmPixList indexOfObject: self.curDCM] != NSNotFound)
            return [[dcmFilesList objectAtIndex: [dcmPixList indexOfObject: self.curDCM]] valueForKeyPath: @"series.study"];
        else return [self.curDCM studyObj];
    }
    
    return nil;
}

- (void) updatePresentationStateFromSeriesOnlyImageLevel: (BOOL) onlyImage
{
    return [self updatePresentationStateFromSeriesOnlyImageLevel: onlyImage scale: firstTimeDisplay offset: [self is2DViewer]];
}

- (void) updatePresentationStateFromSeriesOnlyImageLevel: (BOOL) onlyImage scale: (BOOL) scale offset: (BOOL) offset
{
    NSManagedObject *series = self.seriesObj;
    NSManagedObject *image = self.imageObj;
    
    if( series)
    {
        if( [image valueForKey:@"xFlipped"])
            self.xFlipped = [[image valueForKey:@"xFlipped"] boolValue];
        else if( !onlyImage)
            self.xFlipped = [[series valueForKey:@"xFlipped"] boolValue];
        else
            self.xFlipped = NO;
        
        if( [image valueForKey:@"yFlipped"])
            self.yFlipped = [[image valueForKey:@"yFlipped"] boolValue];
        else if( !onlyImage)
            self.yFlipped = [[series valueForKey:@"yFlipped"] boolValue];
        else
            self.yFlipped = NO;
        
        if( [stringID isEqualToString:@"previewDatabase"] == NO)
        {
            if((scale && [[NSUserDefaults standardUserDefaults] boolForKey:@"AlwaysScaleToFit"] == NO) || COPYSETTINGSINSERIES == NO)
            {
                if( [image valueForKey:@"scale"])
                {
                    if( [[image valueForKey:@"scale"] floatValue] != 0)
                        [self setScaleValue: [[image valueForKey:@"scale"] floatValue]];
                    else
                        [self scaleToFit];
                }
                else if( !onlyImage)
                {
                    if( [series valueForKey:@"scale"])
                    {
                        if( [[series valueForKey:@"scale"] floatValue] != 0)
                        {
                            if( [[series valueForKey:@"displayStyle"] intValue] == 3)
                                [self setScaleValue: [[series valueForKey:@"scale"] floatValue] * sqrt( [self frame].size.height * [self frame].size.width)];
                            else if( [[series valueForKey:@"displayStyle"] intValue] == 2)
                                [self setScaleValue: [[series valueForKey:@"scale"] floatValue] * [self frame].size.width];
                            else
                                [self setScaleValue: [[series valueForKey:@"scale"] floatValue]];
                        }
                        else
                            [self scaleToFit];
                    }
                    else
                        [self scaleToFit];
                }
                else 
                    [self scaleToFit];
            }
            else
                [self scaleToFit];
        }
        else
            [self scaleToFit];
        
        if( [image valueForKey:@"rotationAngle"])
            [self setRotation: [[image valueForKey:@"rotationAngle"] floatValue]];
        else if( !onlyImage)
            [self setRotation:  [[series valueForKey:@"rotationAngle"] floatValue]];
        else
            [self setRotation: 0];
        
        if( [stringID isEqualToString:@"previewDatabase"] == NO)
        {
            if( (offset && [[NSUserDefaults standardUserDefaults] boolForKey:@"AlwaysScaleToFit"] == NO) || COPYSETTINGSINSERIES == NO)
            {
                NSPoint o = NSMakePoint( HUGE_VALF, HUGE_VALF);
                
                if( [image valueForKey:@"xOffset"])  o.x = [[image valueForKey:@"xOffset"] floatValue];
                else if( !onlyImage) o.x = [[series valueForKey:@"xOffset"] floatValue];
                
                if( [image valueForKey:@"yOffset"])  o.y = [[image valueForKey:@"yOffset"] floatValue];
                else if( !onlyImage) o.y = [[series valueForKey:@"yOffset"] floatValue];
                
                if( o.x != HUGE_VALF && o.y != HUGE_VALF)
                    [self setOrigin: o];
            }
        }
        
        float ww = 0, wl = 0;
        
        if( [image valueForKey:@"windowWidth"]) ww = [[image valueForKey:@"windowWidth"] floatValue];
        else if( !onlyImage && [series valueForKey:@"windowWidth"]) ww = [[series valueForKey:@"windowWidth"] floatValue];
        else if( ![self is2DViewer])
            ww = curWW;
        
        if( [image valueForKey:@"windowLevel"]) wl = [self.curDCM calibratedWindowLevelForStoredLevel:[[image valueForKey:@"windowLevel"] floatValue]];
        else if( !onlyImage && [series valueForKey:@"windowLevel"]) wl = [self.curDCM calibratedWindowLevelForStoredLevel:[[series valueForKey:@"windowLevel"] floatValue]];
        else if( ![self is2DViewer])
            wl = curWL;
        
        if( ww == 0)
        {
            if( (curImage >= 0) || COPYSETTINGSINSERIES == NO || [self is2DViewer] == NO)
            {
                ww = self.curDCM.savedWW;
                wl = self.curDCM.savedWL;
            }
            else
            {
                ww = [[dcmPixList objectAtIndex: [dcmPixList count]/2] savedWW];
                wl = [[dcmPixList objectAtIndex: [dcmPixList count]/2] savedWL];
            }
        }
        
        if( ww != 0 || wl != 0)
        {
            if( ww != 0.0)
            {
                if( [[[dcmFilesList objectAtIndex: curImage] valueForKey:@"modality"] isEqualToString:@"PT"] || ([[NSUserDefaults standardUserDefaults] boolForKey:@"mouseWindowingNM"] == YES && [[[dcmFilesList objectAtIndex: curImage] valueForKey:@"modality"] isEqualToString:@"NM"]))
                {
                    float from, to;
                    
                    switch( [[NSUserDefaults standardUserDefaults] integerForKey:@"DEFAULTPETWLWW"])
                    {
                        case 0:
                            if( self.curDCM.SUVConverted == NO)
                            {
                                curWW = ww;
                                curWL = wl;
                            }
                            else
                            {
                                if( [self is2DViewer] == YES)
                                {
                                    curWW = ww * [[self windowController] factorPET2SUV];
                                    curWL = wl * [[self windowController] factorPET2SUV];
                                }
                            }
                            break;
                            
                        case 1:
                            from = self.curDCM.maxValueOfSeries * [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWFROM"] / 100.;
                            to = self.curDCM.maxValueOfSeries * [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWTO"] / 100.;
                            
                            if( to - from != 0)
                            {
                                curWW = to - from;
                                curWL = from + (curWW/2.);
                            }
                            break;
                            
                        case 2:
                            if( self.curDCM.SUVConverted)
                            {
                                from = [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWFROMSUV"];
                                to = [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWTOSUV"];
                                
                                if( to - from != 0)
                                {
                                    curWW = to - from;
                                    curWL = from + (curWW/2.);
                                }
                            }
                            else
                            {
                                curWW = ww;
                                curWL = wl;
                            }
                            break;
                    }
                }
                else
                {
                    curWW = ww;
                    curWL = wl;
                }
                
                [self setWLWW:curWL :curWW];
            }
        }
        else if( onlyImage == NO)
        {
            if( [[[dcmFilesList objectAtIndex: curImage] valueForKey:@"modality"] isEqualToString:@"PT"] || ([[NSUserDefaults standardUserDefaults] boolForKey:@"mouseWindowingNM"] == YES && [[[dcmFilesList objectAtIndex: curImage] valueForKey:@"modality"] isEqualToString:@"NM"]))
            {
                float from, to;
                
                curWW = ww;
                curWL = wl;
                
                switch( [[NSUserDefaults standardUserDefaults] integerForKey:@"DEFAULTPETWLWW"])
                {
                    case 0:
                        // Do nothing
                        break;
                        
                    case 1:
                        from = self.curDCM.maxValueOfSeries * [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWFROM"] / 100.;
                        to = self.curDCM.maxValueOfSeries * [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWTO"] / 100.;
                        
                        curWW = to - from;
                        curWL = from + (curWW/2.);
                        break;
                        
                    case 2:
                        if( self.curDCM.SUVConverted)
                        {
                            from = [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWFROMSUV"];
                            to = [[NSUserDefaults standardUserDefaults] floatForKey:@"PETWLWWTOSUV"];
                            
                            curWW = to - from;
                            curWL = from + (curWW/2.);
                        }
                        else
                        {
                            curWW = ww;
                            curWL = wl;
                        }
                        break;
                }
                
                [self setWLWW:curWL :curWW];
            }
        }
    }
}

- (void) updatePresentationStateFromSeries
{
    [self updatePresentationStateFromSeriesOnlyImageLevel: NO];
}

//resize Window to a scale of Image Size
-(void)resizeWindowToScale:(float)resizeScale
{
    NSRect frame =  [self frame]; 
    float curImageWidth = self.curDCM.pwidth * resizeScale;
    float curImageHeight = self.curDCM.pheight* resizeScale;
    float frameWidth = frame.size.width;
    float frameHeight = frame.size.height;
    NSWindow *window = [self window];
    NSRect windowFrame = [window frame];
    float newWidth = windowFrame.size.width - (frameWidth - curImageWidth) * _imageColumns;
    float newHeight = windowFrame.size.height - (frameHeight - curImageHeight) * _imageRows;
    NSPoint center;
    center.x = windowFrame.origin.x + windowFrame.size.width/2.0;
    center.y = windowFrame.origin.y + windowFrame.size.height/2.0;
    
    NSArray *screens = [NSScreen screens];
    
    for(NSScreen* loopItem in screens)
    {
        if( NSPointInRect( center, [loopItem frame]))
        {
            NSRect screenFrame = [AppController usefullRectForScreen: loopItem];
            
            if( newHeight > screenFrame.size.height) newHeight = screenFrame.size.height;
            if( newWidth > screenFrame.size.width) newWidth = screenFrame.size.width;
            
            if( center.y + newHeight/2.0 > screenFrame.size.height)
            {
                center.y = screenFrame.size.height/2.0;
            }
        }
    }
    
    windowFrame.size.height = newHeight;
    windowFrame.size.width = newWidth;
    
    //keep window centered
    windowFrame.origin.y = center.y - newHeight/2.0;
    windowFrame.origin.x = center.x - newWidth/2.0;
    
    if( [self is2DViewer])
        [[self windowController] setWindowFrame: windowFrame];
    else
        [window setFrame:windowFrame display:YES];
    [self setNeedsDisplay:YES];
}

- (IBAction)resizeWindow:(id)sender
{
    if([[self windowController] FullScreenON] == FALSE)
    {
        float resizeScale = 1.0;
        float curImageWidth = self.curDCM.pwidth;
        float curImageHeight = self.curDCM.pheight;
        float widthRatio =  320.0 / curImageWidth ;
        float heightRatio =  320.0 / curImageHeight;
        switch ([sender tag]) {
            case 0: resizeScale = 0.25; // 25%
                break;
            case 1: resizeScale = 0.5;  //50%
                break;
            case 2: resizeScale = 1.0; //Actual Size 100%
                break;
            case 3: resizeScale = 2.0; // 200%
                break;
            case 4: resizeScale = 3.0; //300%
                break;
            case 5: // iPod Video
                resizeScale = (widthRatio <= heightRatio) ? widthRatio : heightRatio;
                break;
        }
        [self resizeWindowToScale:resizeScale];
    }
}

- (void)subDrawRect: (NSRect)aRect   // Subclassable, default does nothing.
{
    return;
}

- (void)drawRectAnyway:(NSRect)aRect // Subclassable, default does nothing.
{
    return;
}

#pragma mark-  PET  Tables
+ (unsigned char*) PETredTable
{
    return PETredTable;
}

+ (unsigned char*) PETgreenTable
{
    return PETgreenTable;
}

+ (unsigned char*) PETblueTable
{
    return PETblueTable;
}

#pragma mark-  Drag and Drop

// Implemented in Swift since #834: DCMView+DragAndDrop.swift, but for
// -draggingSourceOperationMaskForLocal:, which the SDK marks unavailable to Swift.

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal{
    return NSDragOperationEvery;
}

#pragma mark -
#pragma mark Hot Keys

// Implemented in Swift since #834: DCMView+HotKeys.swift.




//#pragma mark -
//#pragma mark IMAVManager delegate methods.
//// The IMAVManager will call this to ask for the context we'll be providing frames with.
//- (void)getOpenGLBufferContext:(CGLContextObj *)contextOut pixelFormat:(CGLPixelFormatObj *)pixelFormatOut
//{
//
//    *contextOut = [_alternateContext CGLContextObj];
//    *pixelFormatOut = [[self pixelFormat] CGLPixelFormatObj];
//}
//
//// The IMAVManager will call this when it wants a frame.
//// Note that this will be called on a non-main thread.
//
//- (BOOL)renderIntoOpenGLBuffer:(CVOpenGLBufferRef)buffer onScreen:(int *)screenInOut forTime:(CVTimeStamp*)timeStamp
//{
//	// We ignore the timestamp, signifying that we're providing content for 'now'.	
//	if(!_hasChanged)
//		return NO;
//	
//	if( [[self window] isVisible] == NO)
//		return NO;
//	
//	if( [self is2DViewer])
//	{
//		if( [[self windowController] windowWillClose])
//			return NO;
//	}
//	
//	// Make sure we agree on the screen ID.
// 	CGLContextObj cgl_ctx = [_alternateContext CGLContextObj];
//	CGLGetVirtualScreen(cgl_ctx, screenInOut);
//	
//	//CGLContextObj CGL_MACRO_CONTEXT = [_alternateContext CGLContextObj];
//	//CGLGetVirtualScreen(CGL_MACRO_CONTEXT, screenInOut);
//	
//	// Attach the OpenGLBuffer and render into the _alternateContext.
//
////	if (CVOpenGLBufferAttach(buffer, [_alternateContext CGLContextObj], 0, 0, *screenInOut) == kCVReturnSuccess) {
//	if (CVOpenGLBufferAttach(buffer, cgl_ctx, 0, 0, *screenInOut) == kCVReturnSuccess)
//	{
//        // In case the buffers have changed in size, reset the viewport.
//        NSDictionary *attributes = (NSDictionary *)CVOpenGLBufferGetAttributes(buffer);
//        GLfloat width = [[attributes objectForKey:(NSString *)kCVOpenGLBufferWidth] floatValue];
//        GLfloat height = [[attributes objectForKey:(NSString *)kCVOpenGLBufferHeight] floatValue];
//		iChatWidth = width;
//		iChatHeight = height;
//		
//		// Render!
//		iChatDrawing = YES;
//        [self drawRect:NSMakeRect(0,0,width,height) withContext:_alternateContext];
//		iChatDrawing = NO;
//        return YES;
//    }
//	else
//	{
//        // This should never happen.  The safest thing to do if it does it return
//        // 'NO' (signifying that the frame has not changed).
//        return NO;
//    }
//}
//
//// Callback from IMAVManager asking what pixel format we'll be providing frames in.
//- (void)getPixelBufferPixelFormat:(OSType *)pixelFormatOut
//{
//    *pixelFormatOut = kCVPixelFormatType_32ARGB;
//}
//
//// This callback is called periodically when we're in the IMAVActive state.
//// We copy (actually, re-render) what's currently on the screen into the provided 
//// CVPixelBufferRef.
////
//// Note that this will be called on a non-main thread. 
//- (BOOL) renderIntoPixelBuffer:(CVPixelBufferRef)buffer forTime:(CVTimeStamp*)timeStamp
//{
//    // We ignore the timestamp, signifying that we're providing content for 'now'.
//	CVReturn err;
//	
//	// If the image has not changed since we provided the last one return 'NO'.
//    // This enables more efficient transmission of the frame when there is no
//    // new information.
//	if ([self checkHasChanged])
//		return NO;
//	
//    // Lock the pixel buffer's base address so that we can draw into it.
//	if((err = CVPixelBufferLockBaseAddress(buffer, 0)) != kCVReturnSuccess) {
//        // This should not happen.  If it does, the safe thing to do is return 
//        // 'NO'.
//		NSLog(@"Warning, could not lock pixel buffer base address in %s - error %ld", __func__, (long)err);
//		return NO;
//	}
//    @synchronized (self)
//	{
//		// Create a CGBitmapContext with the CVPixelBuffer.  Parameters /must/ match 
//		// pixel format returned in getPixelBufferPixelFormat:, above, width and
//		// height should be read from the provided CVPixelBuffer.
//		size_t width = CVPixelBufferGetWidth(buffer); 
//		size_t height = CVPixelBufferGetHeight(buffer);
//		CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
//		CGContextRef cgContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer),
//													   width, height,
//													   8,
//													   CVPixelBufferGetBytesPerRow(buffer),
//													   colorSpace,
//													   kCGImageAlphaPremultipliedFirst);
//		CGColorSpaceRelease(colorSpace);
//		
//		// Derive an NSGraphicsContext, make it current, and ask our SlideshowView 
//		// to draw.
//		NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithGraphicsPort:cgContext flipped:NO];
//		[NSGraphicsContext setCurrentContext:context];
//		//get NSImage and draw in the rect
//		
//		[self drawImage: [self nsimage:NO] inBounds:NSMakeRect(0.0, 0.0, width, height)];
//		[context flushGraphics];
//		
//		// Clean up - remember to unlock the pixel buffer's base address (we locked
//		// it above so that we could draw into it).
//		CGContextRelease(cgContext);
//		CVPixelBufferUnlockBaseAddress(buffer, 0);
//	}
//    return YES;
//}


// The _hasChanged flag is set to 'NO' after any check (by a client of this 
// class), and 'YES' after a frame is drawn that is not identical to the 
// previous one (in the drawInBounds: method).

// Returns the current state of the flag, and sets it to the passed in value.


#pragma mark -
#pragma mark Window Controler methods.
- (id) windowController
{
    return [[self window] windowController];
}

- (BOOL) is2DViewer
{
    if( is2DViewerCached)
        return is2DViewerValue;
    
    if( [self window])
    {
        is2DViewerCached = YES;
        is2DViewerValue = [[self windowController] is2DViewer];
    }
    //	else NSLog( @"**** NO Window defined");
    
    return is2DViewerValue;
}

#pragma mark -
#pragma mark 12 bit
- (void)setIsLUT12Bit:(BOOL)boo;
{
    for (DCMPix* pix in dcmPixList)
    {
        pix.isLUT12Bit = boo;
    }
}

- (BOOL)isLUT12Bit;
{
    BOOL is12Bit = YES;
    for (DCMPix* pix in dcmPixList)
    {
        is12Bit = is12Bit && pix.isLUT12Bit;
    }
    return is12Bit;
}

#pragma mark -
#pragma mark Loupe
// +PasteboardTypes and +PluginPasteboardTypes are implemented in Swift since
// #834: DCMView+Loupe.swift.
//
//- (void)displayLoupeWithCenter:(NSPoint)center;
//{
//	if(!loupeController)
//		loupeController = [[LoupeController alloc] init];
//
//	if(!lensTexture)
//	{
//		[self hideLoupe];
//		return;
//	}
//	
//	if(![[loupeController window] isVisible])
//		[loupeController showWindow:nil];
//		
//	[loupeController setTexture:lensTexture withSize:NSMakeSize(LENSSIZE, LENSSIZE) bytesPerRow:LENSSIZE rotation:self.rotation];
//	[loupeController setWindowCenter:center];
//	[loupeController drawLoupeBorder:YES];
//}
//
//- (void)hideLoupe;
//{
//	if([[loupeController window] isVisible])
//		[[loupeController window] orderOut:self];
//}



@end

// The file-scope statics and globals the Swift blocks of DCMView (#834) use.
@implementation DCMView (SwiftStatics)

+(double)horos_static_deg2rad
{
    return deg2rad;
}

+(unsigned char *)horos_static_PETredTable
{
    return PETredTable;
}

+(void)setHoros_static_PETredTable:(unsigned char *)value
{
    PETredTable = value;
}

+(unsigned char *)horos_static_PETgreenTable
{
    return PETgreenTable;
}

+(void)setHoros_static_PETgreenTable:(unsigned char *)value
{
    PETgreenTable = value;
}

+(unsigned char *)horos_static_PETblueTable
{
    return PETblueTable;
}

+(void)setHoros_static_PETblueTable:(unsigned char *)value
{
    PETblueTable = value;
}

+(BOOL)horos_static_avoidSetWLWWRentry
{
    return avoidSetWLWWRentry;
}

+(void)setHoros_static_avoidSetWLWWRentry:(BOOL)value
{
    avoidSetWLWWRentry = value;
}

+(NSDictionary *)horos_static__hotKeyDictionary
{
    return _hotKeyDictionary;
}

+(void)setHoros_static__hotKeyDictionary:(NSDictionary *)value
{
    _hotKeyDictionary = value;
}

+(NSDictionary *)horos_static__hotKeyModifiersDictionary
{
    return _hotKeyModifiersDictionary;
}

+(void)setHoros_static__hotKeyModifiersDictionary:(NSDictionary *)value
{
    _hotKeyModifiersDictionary = value;
}

+(NSRecursiveLock *)horos_static_drawLock
{
    return drawLock;
}

+(void)setHoros_static_drawLock:(NSRecursiveLock *)value
{
    drawLock = value;
}

+(short)horos_static_syncro
{
    return syncro;
}

+(void)setHoros_static_syncro:(short)value
{
    syncro = value;
}

+(BOOL)horos_static_gDontListenToSyncMessage
{
    return gDontListenToSyncMessage;
}

+(void)setHoros_static_gDontListenToSyncMessage:(BOOL)value
{
    gDontListenToSyncMessage = value;
}

@end
