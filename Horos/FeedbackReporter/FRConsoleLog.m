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
// Modified in this fork: host runtime and platform API adaptations; upstream credits retained.


#import "FRConsoleLog.h"
#import "FRConstants.h"
#import "FRApplication.h"

#import <OSLog/OSLog.h>

@implementation FRConsoleLog

+ (NSString*) logSince:(NSDate*)since maxSize:(nullable NSNumber*)maximumSize
{
    assert(since);

    // Current-process scope reads the app's own unified log without requesting
    // system-wide log access. Unlike the former ASL sender query, it cannot
    // retrieve entries from an earlier process after a crash/relaunch.
    NSError *error = nil;
    OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&error];
    if (store == nil) {
        NSLog(@"Could not read this process's unified log: %@", error);
        return @"";
    }
    OSLogEnumerator *entries = [store entriesEnumeratorWithOptions:OSLogEnumeratorReverse
                                                        position:nil predicate:nil error:&error];
    if (entries == nil) {
        NSLog(@"Could not enumerate this process's unified log: %@", error);
        return @"";
    }

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSMutableArray<NSString *> *lines = [[NSMutableArray alloc] init];
    NSUInteger length = 0;
    for (OSLogEntry *entry in entries) {
        if ([entry.date compare:since] == NSOrderedAscending) break;
        if (![entry isKindOfClass:OSLogEntryLog.class]) continue;
        NSString *line = [NSString stringWithFormat:@"%@: %@\n",
                          [dateFormatter stringFromDate:entry.date], entry.composedMessage];
        [lines addObject:line];
        length += line.length;
        // Preserve the former whole-line policy: the newest line which crosses
        // the character budget remains included, including a zero budget.
        if (maximumSize != nil && length > maximumSize.unsignedIntegerValue) break;
    }
    NSMutableString *result = [[NSMutableString alloc] init];
    for (NSString *line in lines.reverseObjectEnumerator) [result appendString:line];
    return result;
}

@end
