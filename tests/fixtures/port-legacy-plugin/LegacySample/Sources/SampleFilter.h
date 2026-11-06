// A legacy plugin for the converter's test (see SampleFilter.m).

#import <Foundation/Foundation.h>
#import "PluginFilter.h"

@interface SampleFilter : PluginFilter
{
    IBOutlet NSWindow *window;
}
- (long) filterImage: (NSString*) menuName;
@end
