/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Â version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. Â See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. Â If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Â  OsiriX
 Â Copyright (c) OsiriX Team
 Â All rights reserved.
 Â Distributed under GNU - LGPL
 Â 
 Â See http://www.osirix-viewer.com/copyright.html for details.
 Â  Â  This software is distributed WITHOUT ANY WARRANTY; without even
 Â  Â  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Â  Â  PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork
/*
 
 File: OpenGLScreenReader.m
 
 Abstract: OpenGLScreenReader class implementation. Contains
            OpenGL code which creates a full-screen OpenGL context
            to use for rendering, then calls glReadPixels to read the 
            actual screen bits.
 
 Version: 1.0
 
 Disclaimer: IMPORTANT:  This Apple software is supplied to you by 
 Apple Inc. ("Apple") in consideration of your agreement to the
 following terms, and your use, installation, modification or
 redistribution of this Apple software constitutes acceptance of these
 terms.  If you do not agree with these terms, please do not use,
 install, modify or redistribute this Apple software.
 
 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software. 
 Neither the name, trademarks, service marks or logos of Apple Inc. 
 may be used to endorse or promote products derived from the Apple
 Software without specific prior written permission from Apple.  Except
 as expressly stated in this notice, no other rights or licenses, express
 or implied, are granted by Apple herein, including but not limited to
 any patent rights that may be infringed by your derivative works or by
 other works in which the Apple Software may be incorporated.
 
 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
 
 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 
 Copyright (C) 2007 Apple Inc. All Rights Reserved.
 
 */ 
 

import AppKit

/// The implementation of OpenGLScreenReader, declared in
/// OpenGLScreenReader.h: the class the plugin SDK of Horos and OsiriX read
/// the screen with, through a full-screen OpenGL context, and wrote it as a
/// TIFF file.
///
/// The application has no OpenGL context, and the system gives the picture
/// of the screen only to an application the user allowed to record it, a
/// permission the application does not ask for. The class reads nothing,
/// keeps no picture and writes no file; each method says so once in the log.
@objc @implementation extension OpenGLScreenReader {
    private static let noCapture = "the application has no OpenGL context to read the screen with and does not ask for the screen recording permission"

    @objc(screenSnapshotToFilePath:)
    class func screenSnapshot(toFilePath path: String!) {
        FormerSDKFacade.inert("OpenGLScreenReader", "+screenSnapshotToFilePath:", because: noCapture)
    }

    /// The buffer given is left as it is.
    @objc(readPartialScreenToBuffer:bufferHeight:bufferBaseAddress:)
    func readPartialScreen(toBuffer width: Int, bufferHeight height: Int, bufferBaseAddress baseAddress: UnsafeMutableRawPointer!) {
        FormerSDKFacade.inert("OpenGLScreenReader", "-readPartialScreenToBuffer:bufferHeight:bufferBaseAddress:", because: Self.noCapture)
    }

    func readFullScreenToBuffer() {
        FormerSDKFacade.inert("OpenGLScreenReader", "-readFullScreenToBuffer", because: Self.noCapture)
    }

    func createTIFFImageFileOnDesktop() {
        FormerSDKFacade.inert("OpenGLScreenReader", "-createTIFFImageFileOnDesktop", because: Self.noCapture)
    }

    @objc(createTIFFImageFileToPath:)
    func createTIFFImageFile(toPath path: String!) {
        FormerSDKFacade.inert("OpenGLScreenReader", "-createTIFFImageFileToPath:", because: Self.noCapture)
    }
}
