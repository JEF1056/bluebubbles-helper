//
//  NetworkController.m
//  BLUEBUBBLESFACETIMEHELPER
//
//  Created by Samer Shihabi on 11/20/20.
//  Copyright © 2020 BlueBubbleMessaging. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "NetworkController.h"
#import "GCDAsyncSocket.h"
#import "Logging.h"

static const NSUInteger kBBMaxSocketMessageBytes = 64 * 1024 * 1024;

@interface NetworkController () {
    NSMutableData *_readBuffer;
}
@end

@implementation NetworkController

@synthesize messageReceivedBlock;


#pragma mark - Singleton

static id sharedInstance = nil;

+ (void)initialize {
  if (self == [NetworkController class]) {
    sharedInstance = [[self alloc] init];
  }
}

+ (NetworkController*)sharedInstance {
  return sharedInstance;
}


#pragma mark - Public methods

#define CLAMP(x, low, high) ({\
  __typeof__(x) __x = (x); \
  __typeof__(low) __low = (low);\
  __typeof__(high) __high = (high);\
  __x > __high ? __high : (__x < __low ? __low : __x);\
  })

- (void)connect {
    // we need to get the port to open the server on (to allow multiple users to use the bundle)
    // we'll base this off the users uid (a unique id for each user, starting from 501)
    // we'll subtract 501 to get an id starting at 0, incremented for each user
    // then we add this to the base port to get a unique port for the socket
    int port = CLAMP(45670 + getuid()-501, 45670, 65535);
    DLog("BLUEBUBBLESFACETIMEHELPER: Connecting to socket on port %{public}d", port);
    if (asyncSocket != nil) {
        asyncSocket.delegate = nil;
        [asyncSocket disconnect];
    }
    _readBuffer = [[NSMutableData alloc] init];
    // connect to socket
    asyncSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    NSError *err = nil;
    if (![asyncSocket connectToHost:@"localhost" onPort:port error:&err]) {
        // If there was an error, it's likely something like "already connected" or "no delegate set"
        DLog("BLUEBUBBLESFACETIMEHELPER: Error connecting to socket: %{public}@", err);
        return;
    }
    // Read LF-delimited frames up to 64MB so multi-byte UTF-8 sequences cannot split across reads.
    [asyncSocket readDataToData:[GCDAsyncSocket LFData] withTimeout:(-1) maxLength:kBBMaxSocketMessageBytes tag:(1)];
}



- (void)disconnect {
    [_readBuffer setLength:0];
    [asyncSocket disconnect];
}

- (void)sendMessage:(NSDictionary*)data {
    if (![data isKindOfClass:[NSDictionary class]] || ![NSJSONSerialization isValidJSONObject:data]) {
        return;
    }
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:&error];
    if (error != nil || jsonData == nil) {
        DLog("BLUEBUBBLESFACETIMEHELPER: Failed to serialize data: %{public}@", error);
        return;
    }
    NSString *message = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (message == nil) {
        return;
    }
    // add a newline to the message so back-to-back messages are split and sent correctly
    NSString *jsonMessage = [NSString stringWithFormat:(@"%@\r\n"), message];
    NSData* finalData = [jsonMessage dataUsingEncoding:NSUTF8StringEncoding];
    DLog("BLUEBUBBLESFACETIMEHELPER: Sending data: %{public}@", data);
    [asyncSocket writeData:(finalData) withTimeout:(-1) tag:(1)];
}

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port {
    DLog("BLUEBUBBLESFACETIMEHELPER: socket:%{public}p didConnectToHost:%{public}@ port:%{public}hu", sock, host, port);
    NSDictionary *message = @{@"event": @"ping", @"message": @"Helper Connected!"};
    [self sendMessage:message];
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock {
    DLog("BLUEBUBBLESFACETIMEHELPER: socketDidSecure:%{public}p", sock);
}

// called when a message is sent to the server
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag {
    DLog("BLUEBUBBLESFACETIMEHELPER: socket:%p didWriteDataWithTag:%ld", sock, tag);
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    [asyncSocket readDataToData:[GCDAsyncSocket LFData] withTimeout:(-1) maxLength:kBBMaxSocketMessageBytes tag:(1)];
    if (data.length == 0) {
        return;
    }
    if (_readBuffer == nil) {
        _readBuffer = [[NSMutableData alloc] init];
    }
    if (data.length > kBBMaxSocketMessageBytes || _readBuffer.length > kBBMaxSocketMessageBytes - data.length) {
        DLog("BLUEBUBBLESFACETIMEHELPER: Incoming socket frame exceeded 64MB limit; disconnecting");
        [_readBuffer setLength:0];
        [sock disconnect];
        return;
    }
    [_readBuffer appendData:data];

    NSData *lfData = [GCDAsyncSocket LFData];
    while (YES) {
        NSRange nlRange = [_readBuffer rangeOfData:lfData options:0 range:NSMakeRange(0, _readBuffer.length)];
        if (nlRange.location == NSNotFound) {
            break;
        }
        NSData *frameData = [_readBuffer subdataWithRange:NSMakeRange(0, nlRange.location)];
        [_readBuffer replaceBytesInRange:NSMakeRange(0, nlRange.location + 1) withBytes:NULL length:0];

        if (frameData.length > 0 && ((const uint8_t *)frameData.bytes)[frameData.length - 1] == '\r') {
            frameData = [frameData subdataWithRange:NSMakeRange(0, frameData.length - 1)];
        }
        if (frameData.length == 0) {
            continue;
        }

        NSString *str = [[NSString alloc] initWithData:frameData encoding:NSUTF8StringEncoding];
        if (str == nil || str.length == 0) {
            DLog("BLUEBUBBLESFACETIMEHELPER: Dropping invalid UTF-8 socket frame (%lu bytes)", (unsigned long)frameData.length);
            continue;
        }
        DLog("BLUEBUBBLESFACETIMEHELPER: event: %{public}@ socket:%{public}p didReadData:withTag:%{public}ld", str, sock, tag);
        if (messageReceivedBlock != nil) {
            messageReceivedBlock(self, str);
        }
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    [_readBuffer setLength:0];
    DLog("BLUEBUBBLESFACETIMEHELPER: Disconnected from server, attempting to reconnect in 5 seconds...");
    double delayInSeconds = 5.0;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        DLog("BLUEBUBBLESFACETIMEHELPER: Attempting to reconnect");
        [self connect];
    });
}

@end
