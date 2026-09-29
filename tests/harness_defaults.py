"""Keep the preferences a harness writes in its own process (#923).

A harness is a bare executable, most often named "test"; its persistent
defaults are ~/Library/Preferences/<name>.plist, shared by every harness of
that name. A test that set a preference there could see another test, running
alongside, change it between two of its checks (#874), and every run left its
keys in the file.

Compiled into a harness, OBJC (appended to an Objective-C source; a
constructor installs it) or SWIFT (put first in a main.swift, whose top-level
code installs it) makes -setObject:forKey: and -removeObjectForKey: of the
standard defaults change the process's argument domain instead. -setBool:,
-setInteger:, -setFloat: and the other setters, and Swift's set(_:forKey:),
all go through -setObject:forKey:. The argument domain is volatile, the
process's own and searched first, so the harness and the code under test read
back what either of them wrote, and nothing reaches the shared file. Other
UserDefaults instances (suites) keep their own behavior. A key never written
still reads through to the persistent domain.
"""

OBJC = r'''
// The standard defaults keep what they are given in the process's argument
// domain, not in the persistent domain that every harness of this name shares
// (tests/harness_defaults.py).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
@interface NSUserDefaults (HorosHarnessArgumentDomain)
@end
@implementation NSUserDefaults (HorosHarnessArgumentDomain)
- (void)horosHarness_setObject:(id)value forKey:(NSString *)key {
    if (self != [NSUserDefaults standardUserDefaults]) { [self horosHarness_setObject:value forKey:key]; return; }
    NSMutableDictionary *domain = [NSMutableDictionary dictionaryWithDictionary:[self volatileDomainForName:NSArgumentDomain]];
    if (value) [domain setObject:value forKey:key]; else [domain removeObjectForKey:key];
    [self setVolatileDomain:domain forName:NSArgumentDomain];
}
- (void)horosHarness_removeObjectForKey:(NSString *)key {
    if (self != [NSUserDefaults standardUserDefaults]) { [self horosHarness_removeObjectForKey:key]; return; }
    NSMutableDictionary *domain = [NSMutableDictionary dictionaryWithDictionary:[self volatileDomainForName:NSArgumentDomain]];
    [domain removeObjectForKey:key];
    [self setVolatileDomain:domain forName:NSArgumentDomain];
}
@end
__attribute__((constructor)) static void horosHarnessArgumentDomain(void) {
    Class defaults = [NSUserDefaults class];
    method_exchangeImplementations(class_getInstanceMethod(defaults, @selector(setObject:forKey:)),
                                   class_getInstanceMethod(defaults, @selector(horosHarness_setObject:forKey:)));
    method_exchangeImplementations(class_getInstanceMethod(defaults, @selector(removeObjectForKey:)),
                                   class_getInstanceMethod(defaults, @selector(horosHarness_removeObjectForKey:)));
}
'''

SWIFT = r'''
// The standard defaults keep what they are given in the process's argument
// domain, not in the persistent domain that every harness of this name shares
// (tests/harness_defaults.py).
import Foundation
import ObjectiveC
extension UserDefaults {
    @objc(horosHarness_setObject:forKey:) func horosHarness_setObject(_ value: Any?, forKey key: String) {
        guard self === UserDefaults.standard else { return horosHarness_setObject(value, forKey: key) }
        var domain = volatileDomain(forName: UserDefaults.argumentDomain)
        domain[key] = value
        setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
    @objc(horosHarness_removeObjectForKey:) func horosHarness_removeObject(forKey key: String) {
        guard self === UserDefaults.standard else { return horosHarness_removeObject(forKey: key) }
        var domain = volatileDomain(forName: UserDefaults.argumentDomain)
        domain[key] = nil
        setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}
for (original, replacement) in [("setObject:forKey:", "horosHarness_setObject:forKey:"),
                                ("removeObjectForKey:", "horosHarness_removeObjectForKey:")] {
    method_exchangeImplementations(class_getInstanceMethod(UserDefaults.self, Selector(original))!,
                                   class_getInstanceMethod(UserDefaults.self, Selector(replacement))!)
}
'''
