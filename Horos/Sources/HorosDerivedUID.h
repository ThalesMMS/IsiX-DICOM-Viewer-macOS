#import <Foundation/Foundation.h>

/// An identifier for an object that arrived without one.
///
/// A file with no `SeriesInstanceUID` was indexed with an **empty** series
/// identifier, and one with no `StudyInstanceUID` was indexed under the
/// patient's name — which the C-FIND SCP then answers with, as a `UI`. Neither
/// is a UID: `UI` allows 64 characters of digits and dots.
///
/// The identifier is **derived**, not generated: the same file, imported twice,
/// yields the same UID, so a re-import lands in the series it landed in before.
/// That is why this is not `dcmGenerateUniqueIdentifier`, which is what the
/// exporter uses when it is creating something genuinely new.
///
/// The root is the one this application already mints under elsewhere: DCMTK's
/// `SITE_UID_ROOT`, OFFIS's `1.2.276.0.7230010.3`, with the `.1.2` and `.1.3`
/// arcs `DICOMExport` uses for studies and series.
///
/// It is the IsiXImaging module's DerivedUID (IsiXDerivedUID), which the
/// application and the Decompress service both link: Swift imports the module,
/// and Objective-C names the class HorosDerivedUID here.
// __swift__: Swift itself reading the bridging header, which sees the module directly.
#if !defined(__swift__) && __has_include("IsiXImaging-Swift.h")
// Found in GENERATED_MODULEMAP_DIR: these targets compile without clang modules.
#import "IsiXImaging-Swift.h"

@compatibility_alias HorosDerivedUID IsiXDerivedUID;
#endif
