//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXVTKContour.h"
#import "IsiXVTKInternal.hpp"

#include <vtkContourFilter.h>
#include <vtkImageImport.h>
#include <vtkMarchingSquares.h>
#include <vtkNew.h>
#include <vtkPolyData.h>
#include <vtkPolyDataAlgorithm.h>
#include <vtkPolyDataConnectivityFilter.h>

#include <vector>

@implementation IsiXVTKContour
{
    std::vector<double> _coordinates;
}

- (instancetype)initWithLineCount:(NSInteger)lineCount coordinates:(std::vector<double> &&)coordinates
{
    self = [super init];
    if (self) {
        _lineCount = lineCount;
        _coordinates = std::move(coordinates);
        _pointCount = (NSInteger)(_coordinates.size() / 2);
    }
    return self;
}

+ (IsiXVTKContour *)traceMask:(const uint8_t *)mask width:(NSInteger)width height:(NSInteger)height
                       tracer:(IsiXVTKContourTracer)tracer largestRegion:(BOOL)largestRegion error:(NSError **)error
{
    const char *operation = "IsiXVTKContour trace";
    if (!mask || width <= 0 || height <= 0) {
        if (error) *error = IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"no mask, or an empty one", operation);
        return nil;
    }
    if (tracer != IsiXVTKContourTracerMarchingSquares && tracer != IsiXVTKContourTracerContourFilter) {
        if (error) *error = IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"no such tracer", operation);
        return nil;
    }

    vtkNew<vtkImageImport> image;
    vtkNew<vtkMarchingSquares> squares;
    vtkNew<vtkContourFilter> contour;
    vtkPolyDataAlgorithm *line = tracer == IsiXVTKContourTracerMarchingSquares ? (vtkPolyDataAlgorithm *)squares.GetPointer()
                                                                                : (vtkPolyDataAlgorithm *)contour.GetPointer();
    vtkNew<vtkPolyDataConnectivityFilter> regions, again;

    IsiXVTKContour *traced = nil;
    IsiXVTKGuard(error, operation, {image.GetPointer(), line, regions.GetPointer(), again.GetPointer()}, [&]() -> NSError * {
        image->SetWholeExtent(0, (int)width - 1, 0, (int)height - 1, 0, 0);
        image->SetDataExtentToWholeExtent();
        image->SetDataScalarTypeToUnsignedChar();
        // VTK only reads the mask.
        image->SetImportVoidPointer(const_cast<uint8_t *>(mask));
        image->Update();

        // VTK places the value of mask pixel i at coordinate i (its centre);
        // the middle of the 0/255 range puts the line on the pixel boundaries.
        if (tracer == IsiXVTKContourTracerMarchingSquares) {
            squares->SetValue(0, 127.5);
            squares->SetInputConnection(image->GetOutputPort());
            squares->Update();
        } else {
            contour->SetValue(0, 127.5);
            contour->SetInputConnection(image->GetOutputPort());
        }

        for (vtkPolyDataConnectivityFilter *filter : {regions.GetPointer(), again.GetPointer()}) {
            filter->SetColorRegions(1);
            if (largestRegion) filter->SetExtractionModeToLargestRegion();
            else filter->SetExtractionModeToAllRegions();
        }
        regions->SetInputConnection(line->GetOutputPort());
        regions->Update();
        again->SetInputConnection(regions->GetOutputPort());
        again->Update();

        vtkPolyData *output = again->GetOutput();
        NSInteger lines = (NSInteger)output->GetNumberOfLines();
        NSInteger available = (NSInteger)output->GetNumberOfPoints();
        NSInteger count = lines < available ? lines : available;
        std::vector<double> coordinates;
        coordinates.reserve((size_t)(count > 0 ? count : 0) * 2);
        for (NSInteger index = 0; index < count; index++) {
            double point[3];
            output->GetPoint(index, point);
            coordinates.push_back(point[0]);
            coordinates.push_back(point[1]);
        }
        traced = [[IsiXVTKContour alloc] initWithLineCount:lines coordinates:std::move(coordinates)];
        return nil;
    });
    return traced;
}

- (double)xAtIndex:(NSInteger)index
{
    return index >= 0 && index < _pointCount ? _coordinates[(size_t)index * 2] : 0;
}

- (double)yAtIndex:(NSInteger)index
{
    return index >= 0 && index < _pointCount ? _coordinates[(size_t)index * 2 + 1] : 0;
}

@end
