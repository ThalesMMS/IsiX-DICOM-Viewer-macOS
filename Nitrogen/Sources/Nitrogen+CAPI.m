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

// The constants and globals of Nitrogen in the Horos and OsiriX plugin SDK. A
// plugin built for that SDK is not rebuilt: it looks these names up in the
// application's flat namespace, where a constant a header defines static, or
// that Swift declares, is not found. Each is defined here once, with the type
// and the value the SDK gave it, marked used so that the linker keeps it
// although the application may not read it, and declared by its header, which
// this file imports so that the compiler compares the two. The ones the SDK
// declared without const stay writable, as it had them.

#import <Cocoa/Cocoa.h>
#import "N3Geometry.h"
#import "N3BezierCore.h"
#import "N2Alignment.h"
#import "N2MinMax.h"
#import "N2Operators.h"
#import "N2Step.h"
#import "N2Steps.h"
#import "N2View.h"
#import "N2DisclosureBox.h"
#import "N2Exceptions.h"
#import "NSException+N2.h"
#import "NSThread+N2.h"
#import "SMTPClient.h"
#import "NS(Attributed)String+Geometrics.h"

#define FORMER_SDK __attribute__((used))

#pragma mark - N3 geometry

FORMER_SDK const N3Vector N3VectorZero = {0.0, 0.0, 0.0};
FORMER_SDK const N3AffineTransform N3AffineTransformIdentity = {1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0};
FORMER_SDK const N3Line N3LineXAxis = {{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}};
FORMER_SDK const N3Line N3LineYAxis = {{0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}};
FORMER_SDK const N3Line N3LineZAxis = {{0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}};
FORMER_SDK const N3Line N3LineInvalid = {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}};
FORMER_SDK const N3Plane N3PlaneXZero = {{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}};
FORMER_SDK const N3Plane N3PlaneYZero = {{0.0, 0.0, 0.0}, {0.0, 1.0, 0.0}};
FORMER_SDK const N3Plane N3PlaneZZero = {{0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}};
FORMER_SDK const N3Plane N3PlaneInvalid = {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}};

#pragma mark - N3 Bezier

FORMER_SDK const CGFloat N3BezierDefaultFlatness = 0.1;
FORMER_SDK const CGFloat N3BezierDefaultSubdivideSegmentLength = 3;

static const void *N3BezierCoreRetainCallback(CFAllocatorRef allocator, const void *value)
{
    return N3BezierCoreRetain((N3BezierCoreRef)value);
}

static void N3BezierCoreReleaseCallback(CFAllocatorRef allocator, const void *value)
{
    N3BezierCoreRelease((N3BezierCoreRef)value);
}

static CFStringRef N3BezierCoreCopyDescriptionCallBack(const void *value)
{
    return N3BezierCoreCopyDescription((N3BezierCoreRef)value);
}

static Boolean N3BezierCoreEqualCallBack(const void *value1, const void *value2)
{
    return N3BezierCoreEqualToBezierCore((N3BezierCoreRef)value1, (N3BezierCoreRef)value2);
}

FORMER_SDK const CFArrayCallBacks kN3BezierCoreArrayCallBacks = {
    0,
    N3BezierCoreRetainCallback,
    N3BezierCoreReleaseCallback,
    N3BezierCoreCopyDescriptionCallBack,
    N3BezierCoreEqualCallBack
};

FORMER_SDK const CFDictionaryValueCallBacks kN3BezierCoreDictionaryValueCallBacks = {
    0,
    N3BezierCoreRetainCallback,
    N3BezierCoreReleaseCallback,
    N3BezierCoreCopyDescriptionCallBack,
    N3BezierCoreEqualCallBack
};

#pragma mark - N2 layout

FORMER_SDK const N2Alignment N2Top = 1<<0;
FORMER_SDK const N2Alignment N2Bottom = 1<<1;
FORMER_SDK const N2Alignment N2Left = 1<<2;
FORMER_SDK const N2Alignment N2Right = 1<<3;

// CGFLOAT_MIN is the smallest positive CGFloat, not the most negative one.
FORMER_SDK const CGFloat N2NoMin = CGFLOAT_MIN, N2NoMax = CGFLOAT_MAX;

#pragma mark - N2 notifications

FORMER_SDK NSNotificationName N2StepDidBecomeActiveNotification = @"N2StepDidBecomeActiveNotification";
FORMER_SDK NSNotificationName N2StepDidBecomeInactiveNotification = @"N2StepDidBecomeInactiveNotification";
FORMER_SDK NSNotificationName N2StepDidBecomeEnabledNotification = @"N2StepDidBecomeEnabledNotification";
FORMER_SDK NSNotificationName N2StepDidBecomeDisabledNotification = @"N2StepDidBecomeDisabledNotification";
FORMER_SDK NSNotificationName N2StepTitleDidChangeNotification = @"N2StepTitleDidChangeNotification";
FORMER_SDK NSNotificationName N2StepsDidAddStepNotification = @"N2StepsDidAddStepNotification";
FORMER_SDK NSNotificationName N2StepsWillRemoveStepNotification = @"N2StepsWillRemoveStepNotification";
FORMER_SDK NSString *N2StepsNotificationStep = @"N2StepsNotificationStep";

FORMER_SDK NSNotificationName N2ViewBoundsSizeDidChangeNotification = @"N2ViewBoundsSizeDidChangeNotification";
FORMER_SDK NSString *N2ViewBoundsSizeDidChangeNotificationOldBoundsSize = @"oldBoundsSize";

FORMER_SDK NSNotificationName N2DisclosureBoxDidToggleNotification = @"N2DisclosureBoxDidToggleNotification";
FORMER_SDK NSNotificationName N2DisclosureBoxWillExpandNotification = @"N2DisclosureBoxWillExpandNotification";
FORMER_SDK NSNotificationName N2DisclosureBoxDidExpandNotification = @"N2DisclosureBoxDidExpandNotification";
FORMER_SDK NSNotificationName N2DisclosureBoxDidCollapseNotification = @"N2DisclosureBoxDidCollapseNotification";

// The names of N2Connection.h and N2ConnectionListener.h, declared here too:
// this file is compiled without the headers of the classes.
extern NSString *N2ConnectionStatusDidChangeNotification;
extern NSString *N2ConnectionListenerOpenedConnectionNotification;
extern NSString *N2ConnectionListenerOpenedConnection;
FORMER_SDK NSString *N2ConnectionStatusDidChangeNotification = @"N2ConnectionStatusDidChangeNotification";
FORMER_SDK NSString *N2ConnectionListenerOpenedConnectionNotification = @"N2ConnectionListenerOpenedConnectionNotification";
FORMER_SDK NSString *N2ConnectionListenerOpenedConnection = @"N2ConnectionListenerOpenedConnection";

#pragma mark - N2 errors and exceptions

FORMER_SDK NSString * const N2ErrorDomain = @"N2";
FORMER_SDK NSString *N2VirtualMethodException = @"N2VirtualMethodException";
FORMER_SDK NSString *N2LinesDontInterceptException = @"N2LinesDontInterceptException";

#pragma mark - NSThread (N2)

FORMER_SDK NSString * const NSThreadNameKey = @"name";
FORMER_SDK NSString * const NSThreadUniqueIdKey = @"uniqueId";
FORMER_SDK NSString * const NSThreadIsCancelledKey = @"isCancelled";
FORMER_SDK NSString * const NSThreadSupportsCancelKey = @"supportsCancel";
FORMER_SDK NSString * const NSThreadSupportsBackgroundingKey = @"supportsBackgrounding";
FORMER_SDK NSString * const NSThreadStatusKey = @"status";
FORMER_SDK NSString * const NSThreadProgressKey = @"progress";
FORMER_SDK NSString * const NSThreadProgressDetailsKey = @"progressDetails";
FORMER_SDK NSString * const NSThreadSubthreadsAwareProgressKey = @"subthreadsAwareProgress";

#pragma mark - SMTP

FORMER_SDK NSString * const SMTPServerAddressKey = @"SMTPServerAddress";
FORMER_SDK NSString * const SMTPServerPortsKey = @"SMTPServerPorts";
FORMER_SDK NSString * const SMTPServerTLSModeKey = @"SMTPServerTLSMode";
FORMER_SDK NSString * const SMTPFromKey = @"SMTPFrom";
FORMER_SDK NSString * const SMTPServerAuthFlagKey = @"SMTPServerAuthFlag";
FORMER_SDK NSString * const SMTPServerAuthUsernameKey = @"SMTPServerAuthUsername";
FORMER_SDK NSString * const SMTPServerAuthPasswordKey = @"SMTPServerAuthPassword";
FORMER_SDK NSString * const SMTPToKey = @"SMTPTo";
FORMER_SDK NSString * const SMTPHeadersKey = @"SMTPHeaders";
FORMER_SDK NSString * const SMTPSubjectKey = @"SMTPSubject";
FORMER_SDK NSString * const SMTPMessageKey = @"SMTPMessage";

#pragma mark - Inherited globals

// Of SBJsonBase.h and ISO8601DateFormatter.h, declared here too: this file is
// compiled without the headers of the classes. The Swift that implements the
// classes keeps the same two values as constants of its own, since Swift does
// not read a C variable that anything may write.
extern NSString *SBJSONErrorDomain;
extern unichar ISO8601DefaultTimeSeparatorCharacter;
FORMER_SDK NSString *SBJSONErrorDomain = @"org.brautaset.JSON.ErrorDomain";
FORMER_SDK unichar ISO8601DefaultTimeSeparatorCharacter = ':';

// Read and set back by the measures of NS(Attributed)String+Geometrics.swift.
FORMER_SDK int gNSStringGeometricsTypesetterBehavior = NSTypesetterLatestBehavior;
