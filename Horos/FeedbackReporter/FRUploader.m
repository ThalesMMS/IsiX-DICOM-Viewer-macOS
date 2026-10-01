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


#import "FRConstants.h"
#import "FRUploader.h"

// Private interface.
@interface FRUploader() <NSURLSessionDataDelegate>
@property (readwrite, weak, nonatomic) id<FRUploaderDelegate> delegate;
@property (readwrite, copy, nonatomic) NSURL *targetURL;
@property (readwrite, strong, nonatomic, nullable) NSURLSessionDataTask *connection;
@property (readwrite, strong, nonatomic) NSMutableData *responseData;
@property (readwrite, strong, nonatomic, nullable) NSURLSession *session;
@end

@implementation FRUploader

// Cover the superclass' designated initialiser
- (instancetype)init NS_UNAVAILABLE
{
    assert(0);
    return nil;
}

- (instancetype) initWithTargetURL:(NSURL*)targetURL delegate:(id<FRUploaderDelegate>)delegate
{
    assert(targetURL);
    assert(delegate);

    self = [super init];
    if (self != nil) {
        _targetURL = [targetURL copy];
        _delegate = delegate;
        _responseData = [[NSMutableData alloc] init];
    }
    
    return self;
}

- (NSData *) generateFormData: (NSDictionary *)dict forBoundary:(NSString*)formBoundary
{
    assert(dict);
    assert(formBoundary);

    NSMutableData *result = [[NSMutableData alloc] initWithCapacity:100];

    [dict enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
     
        [result appendData:[[NSString stringWithFormat:@"--%@\r\n", formBoundary] dataUsingEncoding:NSUTF8StringEncoding]];

        if ([value class] != [NSURL class]) {
            NSString *disposition = [NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n%@", key, value];
            [result appendData:[disposition dataUsingEncoding:NSUTF8StringEncoding]];
        }
        else {
            NSURL *url = (NSURL *)value;
            if ([url isFileURL]) {
                NSData *fileData = [NSData dataWithContentsOfURL:url];
                if (fileData) {
                    NSString *disposition = [NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", key, [url lastPathComponent]];
                    [result appendData:[disposition dataUsingEncoding:NSUTF8StringEncoding]];
                    
                    [result appendData:[@"Content-Type: application/octet-stream\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
                    [result appendData:fileData];
                }
            }
        }
        
        [result appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }];

    [result appendData:[[NSString stringWithFormat:@"--%@--\r\n", formBoundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    return result;
}


- (nullable NSString*) post:(NSDictionary*)dict
{
    assert(dict);

    NSString *formBoundary = [[NSProcessInfo processInfo] globallyUniqueString];

    NSData *formData = [self generateFormData:dict forBoundary:formBoundary];

    NSLog(@"Posting %lu bytes to %@", (unsigned long)[formData length], [self targetURL]);

    NSMutableURLRequest *post = [NSMutableURLRequest requestWithURL:[self targetURL]];
    
    NSString *boundaryString = [NSString stringWithFormat: @"multipart/form-data; boundary=%@", formBoundary];
    [post addValue: boundaryString forHTTPHeaderField: @"Content-Type"];
    [post setHTTPMethod: @"POST"];
    [post setHTTPBody:formData];
    [post setCachePolicy:NSURLRequestReloadIgnoringCacheData];

    __block NSData *result = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:post
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
            (void)response;
            result = data;
            error = failure;
            dispatch_semaphore_signal(finished);
        }];
    [task resume];
    // The public synchronous selector remains synchronous. The session's
    // completion queue is independent of the caller, including the main thread.
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);

    if (result == nil) {
        NSLog(@"Post failed. Error: %ld, Description: %@", (long)[error code], [error localizedDescription]);
        return nil;
    }

    return [[NSString alloc] initWithData:result
                                 encoding:NSUTF8StringEncoding];
}

- (void) postAndNotify:(NSDictionary*)dict
{
    assert(dict);

    NSString *formBoundary = [[NSProcessInfo processInfo] globallyUniqueString];

    NSData *formData = [self generateFormData:dict forBoundary:formBoundary];

    NSUInteger formSize = [formData length];

    NSUInteger maximumPOSTSize = [[[[NSBundle mainBundle] infoDictionary] objectForKey:PLIST_KEY_MAXPOSTSIZE] unsignedIntegerValue];
    if (maximumPOSTSize == 0) {
        maximumPOSTSize = 100 * 1000 * 1000; // 100 megabytes
    }

    if (formSize <= maximumPOSTSize) {
        NSLog(@"Posting %lu bytes to %@", (unsigned long)formSize, [self targetURL]);
        
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self targetURL]];
        
        NSString *boundaryString = [NSString stringWithFormat: @"multipart/form-data; boundary=%@", formBoundary];
        [request addValue: boundaryString forHTTPHeaderField: @"Content-Type"];
        [request setHTTPMethod: @"POST"];
        [request setHTTPBody:formData];
        
        [self.responseData setLength:0];
        self.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                     delegate:self delegateQueue:NSOperationQueue.mainQueue];
        NSURLSessionDataTask *connection = [self.session dataTaskWithRequest:request];
        [self setConnection:connection];
        
        id<FRUploaderDelegate> strongDelegate = [self delegate];
        if (connection != nil) {
            if ([strongDelegate respondsToSelector:@selector(uploaderStarted:)]) {
                [strongDelegate performSelector:@selector(uploaderStarted:) withObject:self];
            }
            [connection resume];
        } else {
            [self.session invalidateAndCancel];
            self.session = nil;
            if ([strongDelegate respondsToSelector:@selector(uploaderFailed:withError:)]) {
                NSError *error = [NSError errorWithDomain:@"Failed to establish connection" code:0 userInfo:nil];
                [strongDelegate performSelector:@selector(uploaderFailed:withError:) withObject:self
                                     withObject:error];
            }
        }
    } else {
        NSLog(@"Refusing post of size %lu bytes, which is greater than max of %lu",
              (unsigned long)formSize,
              (unsigned long)maximumPOSTSize);
    }
}



- (void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data
{
    if (session != self.session || task != self.connection) return;
    [self.responseData appendData:data];
}

- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error
{
    if (session != self.session || task != self.connection) return;
    // Clear the completed operation before calling a delegate which may cancel
    // or start another upload. Completion callbacks keep the original main-queue
    // contract of the NSURLConnection created by the feedback controller.
    self.connection = nil;
    self.session = nil;
    [session finishTasksAndInvalidate];
    id<FRUploaderDelegate> strongDelegate = self.delegate;
    if (error != nil) {
        if ([strongDelegate respondsToSelector:@selector(uploaderFailed:withError:)])
            [strongDelegate uploaderFailed:self withError:error];
    } else if ([strongDelegate respondsToSelector:@selector(uploaderFinished:)]) {
        [strongDelegate uploaderFinished:self];
    }
}

- (void) cancel
{
    NSURLSession *session = self.session;
    self.connection = nil;
    self.session = nil;
    [session invalidateAndCancel];
}

- (nullable NSString*) response
{
    return [[NSString alloc] initWithData:[self responseData]
                                 encoding:NSUTF8StringEncoding];
}

@end
