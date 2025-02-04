//
//  TAASProxyResponse.m
//  TAAS-proxy
//
//  Created by Marshall Rose on 5/9/14.
//  Copyright (c) 2014 The Thing System. All rights reserved.
//

#import "TAASProxyResponse.h"
#import "AppDelegate.h"
#import "RequestUtils.h"
#import "HTTPLogging.h"


// Log levels : off, error, warn, info, verbose
// Other flags: HTTP_LOG_FLAG_TRACE
static const int httpLogLevel = HTTP_LOG_LEVEL_VERBOSE;


@interface TAASProxyResponse ()

@property (strong, nonatomic) NSString                  *server;

@property (        nonatomic) BOOL                       oneshotP;
@property (strong, nonatomic) NSString                  *behavior;
@property (strong, nonatomic) NSMutableData             *body;

@property (strong, nonatomic) HTTPConnection            *upstream;
@property (        nonatomic) UInt64                     dataOffset;
@property (        nonatomic) NSInteger                  statusCode;
@property (strong, nonatomic) NSMutableDictionary       *headerFields;
@property (strong, nonatomic) NSMutableData             *data;

@end


@implementation TAASProxyResponse

- (id)initWithURI:(NSString *)URI
    forConnection:(HTTPConnection *)parent {
    if ((self = [super init]))  {
        HTTPLogInfo(@"%@[%p]: initWithURI: %@", THIS_FILE, self, URI);

        self.upstream = parent;

        self.server = [[URI stringByDeletingLastURLPathComponent] stringByDeletingURLQuery];
        NSURL *url = [NSURL URLWithString:URI];
        if (url == nil) {
            HTTPLogWarn(@"%@[%p]: invalid URI: %@", THIS_FILE, self, URI);
            return nil;
        }

        self.oneshotP = [[url path] isEqualToString:@"/oneshot"];
        self.behavior = nil;
        self.body = nil;
        if (self.oneshotP) {
          NSDictionary *parameters = [URI URLQueryParameters];

          self.behavior = [parameters objectForKey:@"behavior"];
          if (self.behavior == nil) self.behavior = @"";
          self.body = [NSMutableData data];
        }

        NSURLRequest *request = [NSURLRequest requestWithURL:url];
        if (request == nil) {
            HTTPLogWarn(@"%@[%p]: invalid URL: %@", THIS_FILE, self, URI);
            return nil;
        }

        self.downstream = [[NSURLConnection alloc] initWithRequest:request
                                                          delegate:self
                                                  startImmediately:NO];
        if (self.downstream == nil) {
            HTTPLogWarn(@"%@[%p]: unable to create connection to %@", THIS_FILE, self, URI);
            return nil;
        }
        [self.downstream scheduleInRunLoop:[NSRunLoop mainRunLoop]
                                   forMode:NSRunLoopCommonModes];

        self.dataOffset = 0;
        self.statusCode = 0;
        self.headerFields = nil;
        self.data = nil;

        [self.downstream start];
    }

    return self;
}

- (void)abort {
    HTTPLogTrace();

    if (self.downstream != nil) {
        [self.downstream cancel];
        self.downstream = nil;
    }
    if (self.upstream != nil) [self.upstream responseDidAbort:self];
}

- (BOOL)isDone {
    HTTPLogTrace2(@"%@[%p]: isDone: %@", THIS_FILE, self,
                  (self.downstream != nil) || ((self.data != nil) && ([self.data length] > 0))
                      ? @"NO" : @"YES");

    if ((self.downstream != nil) || ((self.data != nil) && ([self.data length] > 0))) return NO;
    if (!self.oneshotP) return YES;

    NSError *error;
    NSString *text = nil;
    const char *bytes = (const char *)[self.body bytes];
    if ((self.body.length > 3) && (bytes[0] == '{')) {
        error = nil;
        NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:self.body
                                                                   options:kNilOptions
                                                                     error:&error];
        NSDictionary *oops;
        if ((dictionary != nil) && ((oops = [dictionary objectForKey:@"error"]) != nil)) {
            text = [oops objectForKey:@"diagnostic"];
        }
    }
    if (text == nil) {
        if ([self.behavior isEqualToString:@"perform"]) return YES;
        text = [NSString stringWithUTF8String:[self.body bytes]];
    }
    HTTPLogVerbose(@"text to speech: %@", text);
    if (text.length == 0) text = @"no information available";

    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
    AVAudioSession *audioSession = appDelegate.audioSession;
    if (audioSession == nil) {
        appDelegate.audioSession = [AVAudioSession sharedInstance];
        audioSession = appDelegate.audioSession;
    }

    error = nil;
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
    if (error != nil) HTTPLogError(@"error setting audio session category to play and record: %@", error);

    error = nil;
    [audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
    if (error != nil) {
        HTTPLogError(@"error overriding audio port use speaker: %@", error);
        appDelegate.audioSession = nil;
    }

    AVSpeechUtterance *speechUtterance = [AVSpeechUtterance speechUtteranceWithString:text];
    // based on observation
    speechUtterance.rate = 0.30;
    speechUtterance.volume = 1.0;
    [appDelegate.speechSynthesizer speakUtterance:speechUtterance];

    return YES;
}

- (void)connectionDidClose {
    HTTPLogTrace();

    self.upstream = nil;
}


#pragma mark - delayed response

- (BOOL)delayResponseHeaders {
    HTTPLogTrace2(@"%@[%p]: delayResponseHeaders: %@", THIS_FILE, self,
                  (self.headerFields == nil) ? @"YES" : @"NO");

    return (self.headerFields == nil);
}

- (NSInteger)status {
    HTTPLogTrace2(@"%@[%p]: status: %lu", THIS_FILE, self, (unsigned long)self.statusCode);

    return self.statusCode;
}

- (NSDictionary *)httpHeaders {
    HTTPLogTrace2(@"%@[%p]: httpHeaders: %@", THIS_FILE, self, self.headerFields);

    return self.headerFields;
}

-(NSData *)readDataOfLength:(NSUInteger)length {
    HTTPLogTrace2(@"%@[%p]: readDataOfLength: %lu", THIS_FILE, self, (unsigned long)length);

    if (!self.data) return nil;

    if (length > [self.data length]) length = [self.data length];

    NSData *result = [NSData dataWithBytes:[self.data bytes] length:length];
    [self.data replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    HTTPLogTrace2(@"%@[%p]: returning %lu octets, %lu octets remaining", THIS_FILE, self,
                  (unsigned long)length, (unsigned long)[self.data length]);

    self.dataOffset += length;
    return result;
}


#pragma mark - dynamic data

- (BOOL)isChunked {
    HTTPLogTrace();

    return YES;
}

- (UInt64)contentLength {
    HTTPLogTrace();

    return 0;
}

- (UInt64)offset {
    HTTPLogTrace2(@"%@[%p]: offset: %lu", THIS_FILE, self, (unsigned long)self.dataOffset);

    return self.dataOffset;
}

- (void)setOffset:(UInt64)offset {
    HTTPLogTrace2(@"%@[%p]: setOffset: %lu", THIS_FILE, self, (unsigned long)offset);
}


#pragma mark - NSURLConnection delegate methods

-                        (void)connection:(NSURLConnection *)connection
willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
NSLog(@"appDelegate.pinnedCertValidator=%@",appDelegate.pinnedCertValidator);

    if (appDelegate.pinnedCertValidator != nil) {
        [appDelegate.pinnedCertValidator validateChallenge:challenge];
        return;
    }

    [challenge.sender
                 useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]
    forAuthenticationChallenge:challenge];
}

- (void)connection:(NSURLConnection *)theConnection
didReceiveResponse:(NSURLResponse *)response {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    HTTPLogTrace2(@"%@[%p] didReceiveResponse: status=%d", THIS_FILE, self, (int)httpResponse.statusCode);
    if (self.upstream == nil) return;

    self.statusCode = [httpResponse statusCode];
    self.headerFields = [[httpResponse allHeaderFields] mutableCopy];
    [self.headerFields setObject:@"close" forKey:@"Connection"];

    [self.upstream responseHasAvailableData:self];
}

- (void)connection:(NSURLConnection *)theConnection
    didReceiveData:(NSData *)data {
    HTTPLogTrace2(@"%@[%p] didReceiveData: length=%lu", THIS_FILE, self, (unsigned long)[data length]);
    if (self.upstream == nil)  return;

    if ((self.body != nil) && ([self.body length] < 512)) {
        [self.body appendData:data];
        if ([self.body length] > 512) [self.body setLength:512];
        u_char bytes[1];
        bytes[0] = '\0';
        [self.body appendBytes:bytes length:1];
    }

    if (self.data != nil) {
        [self.data appendData:data];
    } else {
        self.data = [data mutableCopy];
    }

    [self.upstream responseHasAvailableData:self];
}

- (void)connection:(NSURLConnection *)theConnection
  didFailWithError:(NSError *)error {
    HTTPLogError(@"%@[%p] didFailWithError: %@", THIS_FILE, self, error);

    AppDelegate *appDelegate = (AppDelegate *) [UIApplication sharedApplication].delegate;
    RootController *rootController = appDelegate.rootController;
    NSString *format = ([[error domain] isEqualToString:@"NSURLErrorDomain"] && ([error code] == -1012))
                       ? @"unwilling to trust %@"
                       : @"failed to connect to %@";
    [rootController notifyUser:[NSString stringWithFormat:format, self.server]
                                                withTitle:kError];


    [self abort];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)theConnection {
    HTTPLogTrace();

    self.downstream = nil;

    if (self.upstream == nil) return;

    [self.upstream responseHasAvailableData:self];
}

@end
