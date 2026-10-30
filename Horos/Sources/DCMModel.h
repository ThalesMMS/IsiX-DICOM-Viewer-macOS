//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The in-memory DICOM dataset (DCMObject and its attributes) for Objective-C:
// the IsiXDICOMDataset module, with the value types of IsiXDICOMFile it holds.
// The DCMTK adapter fills it (HorosDCMTKObject) and writes it
// (IsiXDCMTKObjectWriter).
//
// The module names its classes IsiXDCM...; the aliases keep the names the
// Objective-C code and the plugin headers have always used. Swift imports the
// module itself, so it reads none of this. The generated headers are found in
// GENERATED_MODULEMAP_DIR, because the targets compiling these files build
// without clang modules.

#if !defined(__swift__)
#import <Foundation/Foundation.h>
#import "IsiXImaging-Swift.h"
#import "IsiXDICOMFile-Swift.h"
#import "IsiXDICOMDataset-Swift.h"

@compatibility_alias DCMObject IsiXDCMObject;
@compatibility_alias DCMAttribute IsiXDCMAttribute;
@compatibility_alias DCMSequenceAttribute IsiXDCMSequenceAttribute;
@compatibility_alias DCMPixelDataAttribute IsiXDCMPixelDataAttribute;
@compatibility_alias DCMTransferSyntax IsiXDCMTransferSyntax;
#endif
