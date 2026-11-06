//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the Decompress service's Swift reaches of the DCMTK adapters, which
// this target compiles: Objective-C and C types only. The dataset model finds
// the adapter that reads a file (HorosDCMTKObject) by name.
#import "Adapters/DCMTK/IsiXDCMTKCodecs.h"
#import "Adapters/DCMTK/IsiXDCMTKTranscoding.h"
#import "Adapters/DCMTK/IsiXDCMTKDicomDir.h"
#import "HorosObjCException.h"
