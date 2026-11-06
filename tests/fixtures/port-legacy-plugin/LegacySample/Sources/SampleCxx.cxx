// Objective-C++ in a .cxx file: the legacy project gave it the type sourcecode.cpp.objcpp.

#import <Cocoa/Cocoa.h>
#include <vector>

long SampleCxxCount(void)
{
    std::vector<int> values(3, 1);
    if (NSRunAlertPanel(@"Sample", @"%lu values", nil, nil, nil, (unsigned long)values.size()) == NSAlertDefaultReturn)
        return (long)[[NSString stringWithFormat: @"%d", values[0]] length];
    return 0;
}
