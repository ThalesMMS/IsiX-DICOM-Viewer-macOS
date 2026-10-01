/*
 * Copyright 2008-2019, Torsten Curdt
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
// Modified in this fork: the reports the system writes today (.ips) are found beside the former .crash files; upstream credits retained.

#include <unistd.h>
#include <pwd.h>

#import "FRCrashLogFinder.h"

// The system's bug types of a crash report: 309 today, 109 on the first systems that wrote .ips.
static BOOL FRIsCrashBugType(id value)
{
    NSString *type = [value isKindOfClass:[NSNumber class]] ? [value stringValue] : value;
    return [type isKindOfClass:[NSString class]] && ([type isEqualToString:@"309"] || [type isEqualToString:@"109"]);
}

@implementation FRCrashLogFinder

+ (nullable NSURL *)fileURLForLibrarySubdirectory:(NSString *)pathComponent
                                         inDomain:(NSSearchPathDomainMask)domain
{
    assert(pathComponent);
    assert(domain != NSAllDomainsMask);

    NSError *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *url = [fileManager URLForDirectory:NSLibraryDirectory
                                     inDomain:domain
                            appropriateForURL:nil
                                       create:NO
                                        error:&error];
    if (url) {
        url = [url URLByAppendingPathComponent:pathComponent isDirectory:YES];
    }

    return url;
}

// An .ips report is two JSON objects: a header on the first line, which names the
// process, and the report after it.
+ (nullable NSDictionary *)headerOfReportAtURL:(NSURL *)url body:(NSDictionary * _Nullable __autoreleasing * _Nullable)body
{
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL];
    if (data == nil) {
        return nil;
    }
    const char *bytes = data.bytes;
    const char *newline = memchr(bytes, '\n', data.length);
    NSUInteger headerLength = newline ? (NSUInteger)(newline - bytes) : data.length;
    id header = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(0, headerLength)] options:0 error:NULL];
    if (![header isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    if (body && newline) {
        NSUInteger start = headerLength + 1;
        id parsed = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(start, data.length - start)] options:0 error:NULL];
        *body = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
    }
    return header;
}

// A report of this application: named after it, of its bundle when the report says
// which, and a crash rather than another kind of diagnostic.
+ (BOOL)reportAtURL:(NSURL *)url isCrashOfApplication:(NSString *)baseName bundleIdentifier:(nullable NSString *)identifier
{
    NSDictionary *header = [self headerOfReportAtURL:url body:NULL];
    if (header == nil) {
        return NO;
    }
    id name = header[@"app_name"] ?: header[@"name"];
    if (![name isKindOfClass:[NSString class]] || ![name isEqualToString:baseName]) {
        return NO;
    }
    id reportIdentifier = header[@"bundleID"];
    if (identifier.length && [reportIdentifier isKindOfClass:[NSString class]] && ![reportIdentifier isEqualToString:identifier]) {
        return NO;
    }
    id type = header[@"bug_type"];
    return type == nil || FRIsCrashBugType(type);
}

+ (NSArray *)crashLogsInDirectories:(NSArray<NSURL *> *)directories
                              since:(nullable NSDate *)testDate
                           baseName:(NSString *)baseName
                   bundleIdentifier:(nullable NSString *)identifier
{
    assert(directories);
    assert(baseName);

    // The former reports: the name, an underscore, the date. Today's: the name, a hyphen, the date.
    NSString *crashPrefix = [baseName stringByAppendingString:@"_"];
    NSString *ipsPrefix = [baseName stringByAppendingString:@"-"];

    NSMutableArray *matchingFiles = [NSMutableArray array];
    NSDirectoryEnumerationOptions options = (NSDirectoryEnumerationSkipsSubdirectoryDescendants |
                                             NSDirectoryEnumerationSkipsPackageDescendants |
                                             NSDirectoryEnumerationSkipsHiddenFiles);
    NSFileManager *fileManager = [NSFileManager defaultManager];

    for (NSURL *directory in directories)
    {
        NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:directory
                                              includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLIsRegularFileKey]
                                                                 options:options
                                                            errorHandler:nil];
        for (NSURL *fileURL in enumerator)
        {
            NSString *fileName = [fileURL lastPathComponent];
            NSString *extension = [fileURL pathExtension];
            BOOL isCrashFile = [extension isEqualToString:@"crash"] && [fileName hasPrefix:crashPrefix];
            BOOL isReportFile = [extension isEqualToString:@"ips"] && ([fileName hasPrefix:ipsPrefix] || [fileName hasPrefix:crashPrefix]);
            if (!isCrashFile && !isReportFile) {
                continue;
            }

            // Is the modification date newer than the given date? (If no given date, accept the file.)
            NSDate *fileDate = nil;
            if (![fileURL getResourceValue:&fileDate forKey:NSURLContentModificationDateKey error:NULL] || fileDate == nil) {
                continue;
            }
            if (testDate && [testDate compare:fileDate] != NSOrderedAscending) {
                continue;
            }

            NSNumber *isRegularFile = nil;
            if (![fileURL getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:NULL] || ![isRegularFile boolValue]) {
                continue;
            }

            // Another process can share the prefix: the report says whose it is.
            if (isReportFile && ![self reportAtURL:fileURL isCrashOfApplication:baseName bundleIdentifier:identifier]) {
                continue;
            }

            [matchingFiles addObject:@{@"date" : fileDate, @"fileURL" : fileURL}];
        }
    }

    // Sort from oldest to newest.
    NSSortDescriptor *sd = [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:YES];
    [matchingFiles sortUsingDescriptors:@[sd]];

    NSMutableArray *fileURLs = [NSMutableArray arrayWithCapacity:[matchingFiles count]];
    for (NSDictionary *item in matchingFiles) {
        [fileURLs addObject:[item objectForKey:@"fileURL"]];
    }
    return fileURLs;
}

+ (NSArray*)findCrashLogsSince:(nullable NSDate *)date
                  withBaseName:(NSString *)inBaseName
{
    assert(inBaseName);

    // The 3 folders checked for crash reports.
    NSString *diagnosticReports = @"Logs/DiagnosticReports";
    NSMutableArray<NSURL *> *directories = [NSMutableArray array];
    NSURL *logDir1 = [self fileURLForLibrarySubdirectory:diagnosticReports inDomain:NSLocalDomainMask];
    NSURL *logDir2 = [self fileURLForLibrarySubdirectory:diagnosticReports inDomain:NSUserDomainMask];
    NSURL *logDir3 = nil;
    const struct passwd *passwd = getpwuid(getuid());
    if (passwd) {
        const char *realHome = passwd->pw_dir;
        if (realHome) {
            logDir3 = [NSURL fileURLWithPathComponents:@[@(realHome), @"Library", diagnosticReports]];
        }
    }

    // Without App Sandbox, logDir3 will usually be the same as logDir2, in which case don't search it twice.
    if (logDir2 && logDir3 && [logDir2 isEqual:logDir3]) {
        logDir3 = nil;
    }
    if (logDir1) [directories addObject:logDir1];
    if (logDir2) [directories addObject:logDir2];
    if (logDir3) [directories addObject:logDir3];

    return [self crashLogsInDirectories:directories
                                  since:date
                               baseName:inBaseName
                       bundleIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
}

// What the crash tab shows. A .crash file is text already. An .ips report is JSON:
// its readable lines come first - what crashed, why, and the thread that did - and
// the report as the system wrote it follows.
+ (nullable NSString *)textOfReportAtURL:(NSURL *)url
{
    NSString *contents = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    if (contents == nil || ![[url pathExtension] isEqualToString:@"ips"]) {
        return contents;
    }

    NSDictionary *body = nil;
    NSDictionary *header = [self headerOfReportAtURL:url body:&body];
    if (header == nil) {
        return contents;
    }

    NSMutableString *text = [NSMutableString string];
    void (^line)(NSString *, id) = ^(NSString *label, id value) {
        if ([value isKindOfClass:[NSNumber class]]) value = [value stringValue];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
            [text appendFormat:@"%@ %@\n", label, value];
        }
    };
    NSString *(^string)(id) = ^NSString *(id value) {
        if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
        return [value isKindOfClass:[NSString class]] ? value : nil;
    };

    NSString *process = string(body[@"procName"]) ?: string(header[@"app_name"]);
    NSString *pid = string(body[@"pid"]);
    line(@"Process:", pid ? [NSString stringWithFormat:@"%@ [%@]", process, pid] : process);
    line(@"Identifier:", header[@"bundleID"]);
    NSString *version = string(header[@"app_version"]), *build = string(header[@"build_version"]);
    line(@"Version:", [build length] ? [NSString stringWithFormat:@"%@ (%@)", version ?: @"", build] : version);
    line(@"Date/Time:", body[@"captureTime"] ?: header[@"timestamp"]);
    line(@"OS Version:", header[@"os_version"]);

    NSDictionary *exception = [body[@"exception"] isKindOfClass:[NSDictionary class]] ? body[@"exception"] : nil;
    NSString *type = string(exception[@"type"]), *signal = string(exception[@"signal"]);
    line(@"Exception Type:", [signal length] ? [NSString stringWithFormat:@"%@ (%@)", type ?: @"", signal] : type);
    line(@"Exception Codes:", exception[@"codes"]);
    NSDictionary *termination = [body[@"termination"] isKindOfClass:[NSDictionary class]] ? body[@"termination"] : nil;
    line(@"Termination Reason:", termination[@"indicator"]);

    NSArray *threads = [body[@"threads"] isKindOfClass:[NSArray class]] ? body[@"threads"] : nil;
    NSArray *images = [body[@"usedImages"] isKindOfClass:[NSArray class]] ? body[@"usedImages"] : nil;
    NSNumber *faulting = [body[@"faultingThread"] isKindOfClass:[NSNumber class]] ? body[@"faultingThread"] : nil;
    if (faulting && faulting.unsignedIntegerValue < threads.count) {
        NSDictionary *thread = threads[faulting.unsignedIntegerValue];
        NSArray *frames = [thread isKindOfClass:[NSDictionary class]] && [thread[@"frames"] isKindOfClass:[NSArray class]] ? thread[@"frames"] : nil;
        [text appendFormat:@"\nThread %@ Crashed:\n", faulting];
        NSUInteger index = 0;
        for (NSDictionary *frame in frames) {
            if (![frame isKindOfClass:[NSDictionary class]]) continue;
            NSNumber *imageIndex = [frame[@"imageIndex"] isKindOfClass:[NSNumber class]] ? frame[@"imageIndex"] : nil;
            NSDictionary *usedImage = imageIndex && imageIndex.unsignedIntegerValue < images.count ? images[imageIndex.unsignedIntegerValue] : nil;
            NSString *imageName = [usedImage isKindOfClass:[NSDictionary class]] ? string(usedImage[@"name"]) : nil;
            NSString *symbol = string(frame[@"symbol"]);
            NSString *place = symbol ? [NSString stringWithFormat:@"%@ + %@", symbol, string(frame[@"symbolLocation"]) ?: @"0"]
                                     : [NSString stringWithFormat:@"image offset %@", string(frame[@"imageOffset"]) ?: @"?"];
            NSString *image = [imageName ?: @"???" stringByPaddingToLength:MAX((NSUInteger)30, [imageName length]) withString:@" " startingAtIndex:0];
            [text appendFormat:@"%-3lu %@ %@\n", (unsigned long)index, image, place];
            if (++index == 40) break;
        }
    }

    if (text.length == 0) {
        return contents;
    }
    [text appendString:@"\n"];
    [text appendString:contents];
    return text;
}

@end
