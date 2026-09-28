#import <Foundation/Foundation.h>

// Main-thread-owned request identities prevent stale unmount/remount results.
@interface HorosVolumeDiscovery : NSObject {
    NSOperationQueue *_queue;
    NSMutableDictionary *_tokens;
}
- (BOOL)discoverPath:(NSString *)path worker:(id (^)(void))worker completion:(void (^)(id))completion;
- (void)cancelPath:(NSString *)path;
- (void)cancelAll;
@end

// The implementation is in BrowserController+Sources+CAPI.m. It used to be
// here, and every plugin that includes <Horos/Horos.h> compiled a second
// HorosVolumeDiscovery of its own (#779).
