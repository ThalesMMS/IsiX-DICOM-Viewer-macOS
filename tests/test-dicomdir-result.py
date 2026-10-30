#!/usr/bin/env python3
"""+[DicomDir createDicomDirAtDir:error:] reports every DCMTK outcome and keeps the previous index.

DicomDir.swift is compiled as the app has it, with the real ExportArchive
(the staging archive moved over the destination only once complete) and the
IsiXDICOMFile rules, over a stand-in for the DCMTK adapter (IsiXDCMTKDicomDir)
whose answers each scenario controls: success; DCMTK refusing to create, to
add a file, to write or to add the series icons; a C++ exception; and an
Objective-C exception raised on the way, which the former @try caught. Only
success replaces the previous index; every failure is an NSError with a
reason, and no staging folder is left behind. The files the adapter is asked
to index leave out the DICOMDIR itself, its backup, macOS metadata and a stale
staging folder.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]

BRIDGE = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
#import "DicomDir.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const IsiXDCMTKErrorDomain;
FOUNDATION_EXPORT NSString * const IsiXDCMTKConditionTextKey;
typedef NS_ENUM(NSInteger, IsiXDCMTKConditionKind) { IsiXDCMTKConditionKindOther = 0, IsiXDCMTKConditionKindException = 7 };
@interface IsiXDCMTKError : NSObject
+ (IsiXDCMTKConditionKind)kindOfError:(nullable NSError *)error;
@end
@interface IsiXDCMTKDicomDir : NSObject
+ (nullable NSArray<NSString *> *)relativePathsOfFilesInFolder:(nonnull NSString *)folder error:(NSError **)error
    NS_SWIFT_NAME(relativePathsOfFiles(inFolder:));
+ (BOOL)writeDicomDirAtPath:(nonnull NSString *)path folder:(nonnull NSString *)folder
              relativePaths:(nonnull NSArray<NSString *> *)relativePaths error:(NSError **)error
    NS_SWIFT_NAME(writeDicomDir(atPath:folder:relativePaths:));
@end
#ifdef __cplusplus
extern "C"
#endif
void _N2LogExceptionImpl(NSException * _Nonnull e, BOOL logStack, const char * _Nonnull pf);
NS_ASSUME_NONNULL_END
'''

STUBS = r'''
#import "bridge.h"
NSString * const IsiXDCMTKErrorDomain = @"IsiXDCMTKError";
NSString * const IsiXDCMTKConditionTextKey = @"IsiXDCMTKConditionText";
int scenario;
NSArray *indexed;
void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"%s: %@", pf, e); }
@implementation IsiXDCMTKError
+ (IsiXDCMTKConditionKind)kindOfError:(NSError *)error { return (IsiXDCMTKConditionKind)[error.userInfo[@"kind"] integerValue]; }
@end
static NSError *condition(NSString *text) {
    return [NSError errorWithDomain:IsiXDCMTKErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: text,
        IsiXDCMTKConditionTextKey: @"controlled DCMTK failure", @"kind": @0}];
}
@implementation IsiXDCMTKDicomDir
+ (NSArray *)relativePathsOfFilesInFolder:(NSString *)folder error:(NSError **)error {
    return @[@"IMAGE001", @"DICOMDIR", @"DICOMDIR.BAK", @".DS_Store", @"SUB/._IMAGE001", @".horos-zip-stale/archive.zip"];
}
+ (BOOL)writeDicomDirAtPath:(NSString *)path folder:(NSString *)folder relativePaths:(NSArray *)paths error:(NSError **)error {
    indexed = [paths copy];
    NSError *failure = nil;
    switch (scenario) {
        case 1: failure = condition(@"Couldn't create new DICOMDIR file: controlled DCMTK failure"); break;
        case 2: failure = condition(@"Couldn't add IMAGE001 to DICOMDIR: controlled DCMTK failure"); break;
        case 3: failure = condition(@"Couldn't write DICOMDIR file: controlled DCMTK failure"); break;
        case 4: failure = [NSError errorWithDomain:IsiXDCMTKErrorDomain code:-1 userInfo:@{
            NSLocalizedDescriptionKey: @"DicomDirInterface: controlled C++ failure",
            IsiXDCMTKConditionTextKey: @"controlled C++ failure", @"kind": @7}]; break;
        case 5: failure = condition(@"Could not write DICOMDIR series icons: controlled DCMTK failure"); break;
        case 6: [NSException raise:NSGenericException format:@"controlled Objective-C failure"]; break;
        default: break;
    }
    if (failure) { if (error) *error = failure; return NO; }
    return [@"new index" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}
@end
'''

DRIVER = r'''
#import "bridge.h"
#include <cstdio>
extern int scenario;
extern NSArray *indexed;
static const char *reasons[] = {"", "Couldn't create new DICOMDIR file: controlled DCMTK failure",
    "Couldn't add IMAGE001 to DICOMDIR: controlled DCMTK failure", "Couldn't write DICOMDIR file: controlled DCMTK failure",
    "controlled C++ failure", "Could not write DICOMDIR series icons: controlled DCMTK failure", "controlled Objective-C failure"};
int main(int argc, char **argv) { @autoreleasepool {
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    for (scenario = 0; scenario < 7; scenario++) {
        NSString *folder = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", scenario]];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *index = [folder stringByAppendingPathComponent:@"DICOMDIR"];
        [@"old index" writeToFile:index atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSError *error = nil;
        BOOL result = [DicomDir createDicomDirAtDir:folder error:&error];
        if (![[NSString stringWithContentsOfFile:index encoding:NSUTF8StringEncoding error:NULL]
                isEqual:scenario == 0 ? @"new index" : @"old index"]) { fprintf(stderr, "FAIL %d: previous index preservation\n", scenario); return 1; }
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL])
            if ([name hasPrefix:@".horos-zip-"]) { fprintf(stderr, "FAIL %d: staging cleanup\n", scenario); return 1; }
        if (![indexed isEqual:@[@"IMAGE001"]]) { fprintf(stderr, "FAIL %d: indexed %s\n", scenario, indexed.description.UTF8String); return 1; }
        if (result != (scenario == 0) || (!!error) != (scenario != 0) ||
            (error && (![error.domain isEqualToString:NSCocoaErrorDomain] || error.code != NSFileWriteUnknownError ||
                       ![error.localizedFailureReason isEqualToString:@(reasons[scenario])] ||
                       ![error.userInfo[NSFilePathErrorKey] isEqualToString:folder]))) {
            fprintf(stderr, "FAIL scenario %d result %d error %s\n", scenario, result, error.description.UTF8String);
            return 1;
        }
        [DicomDir createDicomDirAtDir:folder];
    }
    puts("PASS: DICOMDIR success, create/add/write/icon failures, a C++ and an Objective-C exception produce the result, "
         "the error and the index the export expects");
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-dicomdir-result-') as folder:
    work = Path(folder)
    (work / 'bridge.h').write_text(BRIDGE)
    (work / 'stubs.mm').write_text(STUBS)
    (work / 'driver.mm').write_text(DRIVER)
    modules = work / 'modules'
    imaging = isix_modules.module_flags('IsiXImaging', modules)
    isix_modules.module_flags('IsiXDICOMFile', modules, extra=imaging)
    includes = ['-I' + str(work), '-I' + str(root / 'Horos/Sources')]
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-wmo', '-swift-version', '6', '-module-name', 'Horos',
                            '-import-objc-header', str(work / 'bridge.h'), '-I', str(modules),
                            *[a for i in includes for a in ('-Xcc', i)], '-c',
                            str(root / 'Horos/Sources/DicomDir.swift'), str(root / 'Horos/Sources/ExportArchive.swift'),
                            '-o', str(work / 'swift.o')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: DicomDir.swift does not compile')
        raise SystemExit(1)
    objects = [str(work / 'swift.o')]
    for name, language in (('stubs.mm', 'objective-c++'), ('driver.mm', 'objective-c++'),
                           (str(root / 'Horos/Sources/HorosObjCException.m'), 'objective-c')):
        source = Path(name) if name.startswith('/') else work / name
        obj = work / (source.name + '.o')
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-x', language, *includes, '-c', str(source), '-o', str(obj)],
                       check=True)
        objects.append(str(obj))
    subprocess.run(['xcrun', 'swiftc', *objects, str(modules / 'libIsiXDICOMFile.a'), str(modules / 'libIsiXImaging.a'),
                    '-lc++', '-framework', 'Foundation', '-o', str(work / 'test')], check=True)
    run = subprocess.run([str(work / 'test'), str(work / 'files')], capture_output=True, text=True, timeout=60)
    print(run.stdout, end='')
    if run.returncode:
        print(run.stderr[-3000:])
        raise SystemExit(1)
