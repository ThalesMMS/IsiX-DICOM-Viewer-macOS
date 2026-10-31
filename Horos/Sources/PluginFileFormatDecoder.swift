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
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/** \brief Plugin for adding file format

 The implementation of PluginFileFormatDecoder, declared in
 PluginFileFormatDecoder.h: the base class of a file-format plugin's principal
 class. DicomFile asks it for the dimensions and identifiers of a file it is
 importing, and DCMPix for the pixels of an image to show.

 A plugin built for Horos or OsiriX subclasses it in Objective-C and fills the
 instance variables the former SDK declared directly, under its own manual
 retain/release: an object it stores there is retained by it, and the class
 releases it with the instance. Those instance variables are the stored
 properties below, with the former names and Objective-C types (no accessor of
 their own: the plugin reads and writes the memory, the host sends the
 messages). The linker exports each one's offset under the
 _OBJC_IVAR_$_PluginFileFormatDecoder.<name> symbol the plugin's binary looks up
 (Horos/Scripts/Horos/legacy-plugin-ivar-aliases.rsp, a linker response file in
 OTHER_LDFLAGS: per instance variable, -alias gives the Swift field offset
 symbol the Objective-C name, and -u keeps that name through dead stripping,
 which drops an exported name nothing in the application references; the file
 takes no comments). A renamed or retyped property changes the Swift symbol the
 file names, and the link fails.
 */
@objc @implementation extension PluginFileFormatDecoder {
    final var _height: NSNumber?
    final var _width: NSNumber?
    final var _fImage: UnsafeMutablePointer<Float>?
    final var _rowBytes: NSNumber?
    final var _windowWidth: NSNumber?
    final var _windowLevel: NSNumber?
    /// YES unless the plugin says otherwise, as the former -init set it.
    final var _isRGB: Bool = true

    final var _patientName: NSString?
    final var _patientID: NSString?
    final var _studyID: NSString?
    final var _seriesID: NSString?
    final var _imageID: NSString?
    final var _studyDescription: NSString?
    final var _seriesDescription: NSString?

    override init() {
        super.init()
        NSLog("Plugin fileFormat Init")
    }

    // not used currently
    class func decodedData(atPath path: String!) -> UnsafeMutablePointer<Float>! {
        nil
    }

    /// The plugin's: the pixels of the file, float grey levels or ARGB bytes,
    /// which the caller frees. Nil here.
    func checkLoad(atPath path: String!) -> UnsafeMutablePointer<Float>! {
        nil
    }

    func height() -> NSNumber! { _height }

    func width() -> NSNumber! { _width }

    func rowBytes() -> NSNumber! { _rowBytes }

    func windowWidth() -> NSNumber! { _windowWidth }

    func windowLevel() -> NSNumber! { _windowLevel }

    func isRGB() -> Bool { _isRGB }

    func patientName() -> String! { _patientName as String? }

    func patientID() -> String! { _patientID as String? }

    func studyID() -> String! { _studyID as String? }

    func seriesID() -> String! { _seriesID as String? }

    func imageID() -> String! { _imageID as String? }

    func studyDescription() -> String! { _studyDescription as String? }

    func seriesDescription() -> String! { _seriesDescription as String? }
}
