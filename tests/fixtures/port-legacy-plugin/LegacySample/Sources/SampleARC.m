// Written for ARC: the legacy project compiles it with -fobjc-arc.

#import <Cocoa/Cocoa.h>

@interface SampleARC : NSObject
@end

@implementation SampleARC

- (NSInteger) ask
{
    NSCalendarDate *date = [NSCalendarDate dateWithYear: 2026 month: 10 day: 29 hour: 12 minute: 0 second: 0 timeZone: nil];
    return NSRunAlertPanel(@"Sample", @"%ld", nil, nil, nil, (long)[date dayOfMonth]);
}

@end
