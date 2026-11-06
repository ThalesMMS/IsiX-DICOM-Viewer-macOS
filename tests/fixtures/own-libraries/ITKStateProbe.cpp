//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// See ITKStateProbe.h. Two kinds of evidence that the two copies of ITK stay
// apart:
//
// - code: the image that holds each function this side calls, found with
//   dladdr. The templates and inline functions (Image<float, 3>::FillBuffer,
//   ImageRegion<3>::GetNumberOfPixels, ConnectedThresholdImageFilter::AddSeed)
//   are weak definitions that the application exports, and dyld binds a
//   bundle's uses of an exported weak definition to the application's copy;
//   Version::GetITKVersion and MultiThreaderBase::SetGlobalDefaultNumberOfThreads
//   are ordinary definitions, which two-level namespace keeps apart;
// - state: ITK's global settings (the default number of threads, the output
//   window), set by each side before and after the other. In ITK 5.4 they
//   are found through SingletonIndex::GetInstance, an ordinary function, so
//   they stay apart even when the templates do not; the check guards against
//   a library or version that keeps them in a weak definition.

#include "ITKStateProbe.h"

#include <dlfcn.h>
#include <cstring>
#include <sstream>
#include <string>

#include "itkConnectedThresholdImageFilter.h"
#include "itkImage.h"
#include "itkImageRegionConstIterator.h"
#include "itkImageRegionIteratorWithIndex.h"
#include "itkMultiThreaderBase.h"
#include "itkOutputWindow.h"
#include "itkVersion.h"

#ifdef ISIX_PROBE_HOST
#  define ISIX_PROBE_SIDE "host"
#  define ISIX_PROBE_WINDOW IsiXHostProbeOutputWindow
#else
#  define ISIX_PROBE_SIDE "plugin"
#  define ISIX_PROBE_WINDOW IsiXPluginProbeOutputWindow
#endif
#define ISIX_PROBE_STRING(x) ISIX_PROBE_STRING0(x)
#define ISIX_PROBE_STRING0(x) #x

namespace
{
using FloatImage = itk::Image<float, 3>;
using Connected = itk::ConnectedThresholdImageFilter<FloatImage, FloatImage>;

/// An output window of this side's own class, to tell whose is installed.
class ISIX_PROBE_WINDOW : public itk::OutputWindow
{
public:
  using Self = ISIX_PROBE_WINDOW;
  using Pointer = itk::SmartPointer<Self>;
  static Pointer
  New()
  {
    Pointer window = new Self;
    window->UnRegister();
    return window;
  }
  const char *
  GetNameOfClass() const override
  {
    return ISIX_PROBE_STRING(ISIX_PROBE_WINDOW);
  }
};

/// The code address of a function or of a non-virtual member function.
template <typename T>
const void *
codeAddress(T function)
{
  const void * address = nullptr;
  std::memcpy(&address, &function, sizeof address);
  return address;
}

std::string
imageOf(const void * address)
{
  Dl_info info;
  return dladdr(address, &info) && info.dli_fname ? info.dli_fname : "";
}

std::string
quoted(const std::string & text)
{
  std::string out = "\"";
  for (char c : text)
  {
    if (c == '"' || c == '\\')
      out += '\\';
    out += c;
  }
  return out + "\"";
}

/// An 8 x 8 x 4 image whose pixel (x, y, z) is x + 8 y, grown from (0, 0, 0)
/// between 0 and 20: rows 0 and 1 and the first five pixels of row 2 of every
/// slice, 21 x 4 = 84 pixels.
unsigned long
connectedPixels()
{
  auto image = FloatImage::New();
  FloatImage::RegionType region;
  region.SetSize({ { 8, 8, 4 } });
  image->SetRegions(region);
  image->Allocate();
  image->FillBuffer(0.0f);
  for (itk::ImageRegionIteratorWithIndex<FloatImage> it(image, region); !it.IsAtEnd(); ++it)
  {
    const auto index = it.GetIndex();
    it.Set(static_cast<float>(index[0] + 8 * index[1]));
  }
  auto filter = Connected::New();
  filter->SetInput(image);
  filter->SetLower(0.0f);
  filter->SetUpper(20.0f);
  filter->SetReplaceValue(1.0f);
  filter->AddSeed({ { 0, 0, 0 } });
  filter->Update();
  unsigned long count = 0;
  for (itk::ImageRegionConstIterator<FloatImage> it(filter->GetOutput(), region); !it.IsAtEnd(); ++it)
    count += it.Get() == 1.0f ? 1 : 0;
  return count;
}

std::string
report()
{
  std::ostringstream out;
  out << "{\"side\":\"" ISIX_PROBE_SIDE "\""
      << ",\"version\":" << quoted(itk::Version::GetITKVersion())
      << ",\"threads\":" << itk::MultiThreaderBase::GetGlobalDefaultNumberOfThreads()
      << ",\"outputWindow\":" << quoted(itk::OutputWindow::GetInstance()->GetNameOfClass())
      << ",\"connected\":" << connectedPixels()
      << ",\"ownImage\":" << quoted(imageOf(reinterpret_cast<const void *>(&connectedPixels))) << ",\"images\":{"
      << "\"Version::GetITKVersion\":" << quoted(imageOf(codeAddress(&itk::Version::GetITKVersion)))
      << ",\"MultiThreaderBase::SetGlobalDefaultNumberOfThreads\":"
      << quoted(imageOf(codeAddress(&itk::MultiThreaderBase::SetGlobalDefaultNumberOfThreads)))
      << ",\"Image<float,3>::FillBuffer\":" << quoted(imageOf(codeAddress(&FloatImage::FillBuffer)))
      << ",\"ImageRegion<3>::GetNumberOfPixels\":"
      << quoted(imageOf(codeAddress(&FloatImage::RegionType::GetNumberOfPixels)))
      << ",\"ConnectedThresholdImageFilter::AddSeed\":" << quoted(imageOf(codeAddress(&Connected::AddSeed)))
      << "}}";
  return out.str();
}

std::string lastReport;
} // namespace

extern "C" const char *
ISIX_PROBE(configure)(int threads)
{
  itk::MultiThreaderBase::SetGlobalDefaultNumberOfThreads(static_cast<itk::ThreadIdType>(threads));
  itk::OutputWindow::SetInstance(ISIX_PROBE_WINDOW::New());
  lastReport = report();
  return lastReport.c_str();
}

extern "C" const char *
ISIX_PROBE(report)(void)
{
  lastReport = report();
  return lastReport.c_str();
}
