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


#import <Cocoa/Cocoa.h>
#import "Point3D.h"

/** \brief Interpolates flight path between FlyThru steps

What an interpolation answers. Swift sees the protocol as
Interpolation3DProtocol, because the class below has its name.
*/

@protocol Interpolation3D <NSObject>

- (void) addPoint: (float) t : (Point3D*) p;
- (Point3D*) evaluateAt: (float) t;

@end

/** \brief Interpolates flight path between FlyThru steps

The abstract class of the plugin SDK of Horos and OsiriX, the superclass of
Spline3D and Piecewise3D, which override its two methods: here -addPoint::
does nothing and -evaluateAt: answers nil.

Interpolation3D.swift implements the class (@objc @implementation): the
runtime has an Objective-C class of this name, which a plugin's subclass can
inherit from.
*/

@interface Interpolation3D : NSObject <Interpolation3D>

- (void) addPoint: (float) t : (Point3D*) p;
- (Point3D*) evaluateAt: (float) t;

@end
