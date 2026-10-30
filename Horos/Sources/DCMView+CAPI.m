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
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// The part of DCMView that stays in Objective-C. The class is implemented in
// Swift (DCMView.swift and its extensions). Here are:
// - the globals the former DCMView.m defined, which other files and plugins
//   read and write by name: syncro, gDontListenToSyncMessage, OVERFLOWLINES,
//   CLUTBARS, MAXNUMBEROF32BITVIEWERS, SOFTWAREINTERPOLATION_MAX and
//   DISPLAYCROSSREFERENCELINES, with their initial values;
// - the pasteboard type names;
// - the C functions of the plane and segment arithmetic, which keep their names
//   and forward to Swift (DCMView+Geometry.swift and IsiXImaging);
// - the methods whose float[2][3] parameter Swift cannot declare
//   (-drawCrossLines:... and -computeSliceIntersection:sliceFromTo:vector:origin:),
//   which forward to their Swift bodies with a pointer to the first element.

#import "DCMView.h"
#import "Horos-Swift.h"

// The float[2][3] methods, which DCMView.h declared when the class was
// Objective-C; Swift reaches them through its own declarations (DCMView.swift).
@interface DCMView (ArrayParameters)
- (void) computeSliceIntersection: (DCMPix*) oPix sliceFromTo: (float[2][3]) sft vector: (float*) vectorB origin: (float*) originB;
- (void) drawCrossLines:(float[2][3]) sft;
- (void) drawCrossLines:(float[2][3]) sft withShift: (double) shift;
- (void) drawCrossLines:(float[2][3]) sft withShift: (double) shift showPoint: (BOOL) showPoint;
- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular;
- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular withShift:(double) shift;
- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular withShift:(double) shift half:(BOOL) half;
- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular withShift:(double) shift half:(BOOL) half showPoint: (BOOL) showPoint;
@end

#pragma mark - Globals

short syncro = syncroLOC;
BOOL gDontListenToSyncMessage = NO;
BOOL OVERFLOWLINES = NO;
int CLUTBARS, MAXNUMBEROF32BITVIEWERS = 4, SOFTWAREINTERPOLATION_MAX, DISPLAYCROSSREFERENCELINES = YES;

__attribute__((used)) NSString * const HorosPasteboardType = @"com.opensource.horos";
__attribute__((used)) NSString * const HorosPasteboardTypePlugin = @"com.opensource.horos.plugin";


#pragma mark - Plane and segment arithmetic

int intersect3D_SegmentPlane( float *P0, float *P1, float *Pnormal, float *Ppoint, float* resultPt )
{
    return [DCMView horosSegmentPlane: P0 : P1 : Pnormal : Ppoint : resultPt];
}

XYZ ArbitraryRotate(XYZ p,double theta,XYZ r)
{
    return [DCMView horosArbitraryRotate: p theta: theta axis: r];
}

short intersect3D_2Planes( float *Pn1, float *Pv1, float *Pn2, float *Pv2, float *u, float *iP)
{
    return [DCMView horosTwoPlanes: Pn1 : Pv1 : Pn2 : Pv2 : u : iP];
}

BOOL lineIntersectsRect(NSPoint lineStarts, NSPoint lineEnds, NSRect rect)
{
    return [DCMView horosLineFrom: lineStarts to: lineEnds intersectsRect: rect];
}

#pragma mark - What Swift cannot declare

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

@implementation DCMView (ArrayParameters)

- (void) computeSliceIntersection: (DCMPix*) oPix sliceFromTo: (float[2][3]) sft vector: (float*) vectorB origin: (float*) originB
{
    [self horosComputeSliceIntersection: oPix sliceFromTo: (float*) sft vector: vectorB origin: originB];
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

// DCMView+Drawing.swift draws the line.
- (void) drawCrossLines:(float[2][3]) sft perpendicular:(BOOL) perpendicular withShift:(double) shift half:(BOOL) half showPoint:(BOOL) showPoint
{
    [self horosDrawCrossLines: &sft[ 0][ 0] perpendicular: perpendicular withShift: shift half: half showPoint: showPoint];
}

@end

#pragma clang diagnostic pop
