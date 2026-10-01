/*
 * Reads each file named on the command line with the DCMTK the application
 * compiles - the pinned upstream library - and prints what came back.
 *
 * The point is not what it parses but that reading a file which lies about its
 * own structure stays inside the buffers it was given. Built with
 * AddressSanitizer by tests/test-dcmtk-parser-robustness.py.
 */
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcistrmf.h>
#include <cstdio>
#ifdef __APPLE__
#include <malloc/malloc.h>
#endif
#include "HorosDCMTKSeekableInput.h"
#include <cstring>
#include <sys/resource.h>
#include "../Horos/Sources/HorosDICOMProbe.h"
#ifdef HOROS_TEST_DICOM_METHODS
#import <Foundation/Foundation.h>
@interface DicomFile : NSObject
+ (BOOL)isDICOMFile:(NSString *)path compressed:(BOOL *)compressed image:(BOOL *)image;
+ (BOOL)isDICOMFile:(NSString *)path compressed:(BOOL *)compressed image:(BOOL *)image mayTranscode:(BOOL *)mayTranscode;
+ (BOOL)isDICOMFileWithPrivateTransferSyntax:(NSString *)path compressed:(BOOL *)compressed image:(BOOL *)image;
@end
#include HOROS_TEST_DICOM_METHODS
#endif
int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: parse <file>...\n"); return 2; }
    if (std::strcmp(argv[1], "--probe") == 0) {
#ifdef HOROS_TEST_DICOM_METHODS
        @autoreleasepool {
        for (NSString *path in @[@"", @"/missing-dicom-file"]) {
            if ([DicomFile isDICOMFile:path compressed:NULL image:NULL]) return 3;
        }
        if ([DicomFile isDICOMFile:nil compressed:NULL image:NULL]) return 3;
        BOOL nilCompressed = YES, nilImage = YES, nilTranscode = YES;
        if ([DicomFile isDICOMFile:nil compressed:&nilCompressed image:&nilImage mayTranscode:&nilTranscode] ||
            nilCompressed || nilImage || nilTranscode) return 3;
        unichar invalid[] = {0xd800};
        NSString *invalidPath = [NSString stringWithCharacters:invalid length:1];
        if ([DicomFile isDICOMFile:invalidPath compressed:NULL image:NULL]) return 3;
#endif
        for (int i = 2; i < argc; ++i) {
            const auto result = HorosDICOMProbe::inspect(argv[i]);
#ifdef HOROS_TEST_DICOM_METHODS
            NSString *path = [NSString stringWithUTF8String:argv[i]];
            const unsigned fallbackBefore = HorosTestPrivateFallbackCalls;
            for (int mask = 0; mask < 8; ++mask) {
                BOOL compressed = NO, image = NO, mayTranscode = NO;
                BOOL recognized = [DicomFile isDICOMFile:path
                    compressed:(mask & 1) ? &compressed : NULL
                    image:(mask & 2) ? &image : NULL
                    mayTranscode:(mask & 4) ? &mayTranscode : NULL];
                if (recognized != result.recognized ||
                    ((mask & 1) && compressed != result.compressed) ||
                    ((mask & 2) && image != result.image) ||
                    ((mask & 4) && mayTranscode != result.mayTranscode)) return 3;
                BOOL legacy = [DicomFile isDICOMFile:path
                    compressed:(mask & 1) ? &compressed : NULL
                    image:(mask & 2) ? &image : NULL];
                if (legacy != recognized ||
                    ((mask & 1) && compressed != result.compressed) ||
                    ((mask & 2) && image != result.image)) return 3;
            }
            const bool expectsFallback = !result.recognized && !result.transferSyntax.empty() &&
                result.transferSyntax.find("1.2.840.10008.") != 0;
            if (HorosTestPrivateFallbackCalls - fallbackBefore != (expectsFallback ? 16 : 0)) return 3;
#endif
            printf("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", argv[i],
                result.recognized, result.datasetReadable, result.image,
                result.compressed, result.mayTranscode, result.needsInflation,
                result.transferSyntax.c_str());
        }
        struct rusage usage;
        getrusage(RUSAGE_SELF, &usage);
        fprintf(stderr, "probe peak RSS bytes=%ld\n", usage.ru_maxrss);
#ifdef HOROS_TEST_DICOM_METHODS
        }
#endif
        return 0;
    }
    for (int i = 1; i < argc; i++) {
        HorosDCMTKSeekableInput input;
        DcmFileFormat &file = input.fileFormat();
        const char *temporary = getenv("TMPDIR");
        OFCondition status = input.load(argv[i], temporary ? temporary : "/tmp");
        const char *sop = NULL;
        unsigned short rows = 0;
        if (status.good()) {
            file.getDataset()->findAndGetString(DCM_SOPClassUID, sop, OFFalse);
            file.getDataset()->findAndGetUint16(DCM_Rows, rows, 0, OFFalse);
        }
        unsigned long pixelLength = 0;
        OFCondition saved = EC_IllegalCall;
        if (status.good() && strstr(argv[i], "deflated-valid")) {
            DcmElement *pixels = NULL;
            file.getDataset()->findAndGetElement(DCM_PixelData, pixels);
            pixelLength = pixels ? pixels->getLength() : 0;
            // Deferred values must still be readable when the caller saves.
            std::string output = std::string(temporary ? temporary : "/tmp") + "/parser-roundtrip.dcm";
            saved = file.saveFile(output.c_str(), EXS_LittleEndianExplicit);
        }
        size_t allocated = 0;
#ifdef __APPLE__
        malloc_statistics_t statistics = {};
        malloc_zone_statistics(malloc_default_zone(), &statistics);
        allocated = statistics.size_in_use;
#endif
        printf("%-28s %-28s rows=%u sop=%s good=%d pixels=%lu saved=%d allocated=%zu\n", argv[i], status.text(), (unsigned) rows, sop ? sop : "-", status.good(), pixelLength, saved.good(), allocated);
        fflush(stdout);
    }
    return 0;
}
