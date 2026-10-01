// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// SPDX-License-Identifier: LGPL-3.0-only

#ifndef HOROS_VR_IMAGE_IMPORT_H
#define HOROS_VR_IMAGE_IMPORT_H

#include <vtkImageImport.h>
#include <vtkImageData.h>
#include <vtkPointData.h>
#include <vtkDataArray.h>

class HorosVRImageImport : public vtkImageImport
{
public:
    static HorosVRImageImport *New()
    {
        auto importer = new HorosVRImageImport;
        importer->InitializeObjectBase();
        return importer;
    }
    vtkTypeMacro(HorosVRImageImport, vtkImageImport);

protected:
    void ExecuteDataWithInformation(vtkDataObject *output, vtkInformation *info) override
    {
        this->Superclass::ExecuteDataWithInformation(output, info);
        auto image = vtkImageData::SafeDownCast(output);
        // Reimporting the same buffer first allocates a one-voxel output.
        // VTK's SetArray can then retain that tuple count when the pointer and
        // capacity already match. Restore the count for the imported extent.
        image->GetPointData()->GetScalars()->SetNumberOfTuples(image->GetNumberOfPoints());
    }
};

#endif
