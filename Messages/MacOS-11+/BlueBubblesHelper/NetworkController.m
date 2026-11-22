//
//  NetworkController.m
//  BlueBubblesHelper
//
//  Created by Samer Shihabi on 11/20/20.
//  Copyright © 2020 BlueBubbleMessaging. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <os/log.h>
#import "NetworkController.h"
#import "GCDAsyncSocket.h"
#import "Logging.h"
#import "BlueBubblesHelper.h"

static const NSUInteger kBBMaxSocketMessageBytes = 64 * 1024 * 1024;
static const NSTimeInterval kBBReconnectInitialDelaySeconds = 5.0;
static const NSTimeInterval kBBReconnectMaxDelaySeconds = 60.0;

@interface NetworkController () {
    NSMutableData *_readBuffer;
    BOOL _reconnectScheduled;
    NSTimeInterval _reconnectDelaySeconds;
}
- (void)scheduleReconnect;
@end

@implementation NetworkController


#pragma mark - Singleton

static id sharedInstance = nil;
static os_log_t logger;

+ (void)initialize {
  if (self == [NetworkController class]) {
      sharedInstance = [[self alloc] init];
      logger = os_log_create("BlueBubblesHelper", "network-socket");
  }
}

+ (NetworkController*)sharedInstance {
  return sharedInstance;
}


#pragma mark - Public methods

#define CLAMP(x, low, high) (MAX(low, MIN(x, high)))

- (void)scheduleReconnect {
    double delayInSeconds = kBBReconnectInitialDelaySeconds;
    @synchronized (self) {
        if (_reconnectScheduled) {
            return;
        }
        _reconnectScheduled = YES;
        delayInSeconds = _reconnectDelaySeconds > 0 ? _reconnectDelaySeconds : kBBReconnectInitialDelaySeconds;
        _reconnectDelaySeconds = MIN(delayInSeconds * 2.0, kBBReconnectMaxDelaySeconds);
    }
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void) {
        @synchronized (self) {
            self->_reconnectScheduled = NO;
        }
        [self connect];
    });
}

- (void)connect {
    // we need to get the port to open the server on (to allow multiple users to use the bundle)
    // we'll base this off the users uid (a unique id for each user, starting from 501)
    // we'll subtract 501 to get an id starting at 0, incremented for each user
    // then we add this to the base port to get a unique port for the socket
    int port = CLAMP(45670 + getuid()-501, 45670, 65535);
    os_log(logger, "Connecting to socket on port %d...", port);

    GCDAsyncSocket *oldSocket = nil;
    GCDAsyncSocket *sock = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    @synchronized (self) {
        _reconnectScheduled = NO;
        oldSocket = asyncSocket;
        asyncSocket = sock;
        _readBuffer = [[NSMutableData alloc] init];
    }
    if (oldSocket != nil) {
        oldSocket.delegate = nil;
        [oldSocket disconnect];
    }

    NSError *err = nil;
    if (![sock connectToHost:@"localhost" onPort:port error:&err]) {
        // If there was an error, it's likely something like "already connected" or "no delegate set"
        os_log_error(logger, "Failed to connect to socket! %@", err);
        @synchronized (self) {
            if (asyncSocket == sock) {
                asyncSocket = nil;
            }
        }
        [self scheduleReconnect];
        return;
    }

    // Read LF-delimited JSON frames up to 64MB so multi-byte UTF-8 sequences cannot split across chunks.
    [sock readDataToData:[GCDAsyncSocket LFData] withTimeout:(-1) maxLength:kBBMaxSocketMessageBytes tag:(1)];
}

- (void)sendMessage:(NSDictionary*)data {
    if (![data isKindOfClass:[NSDictionary class]] || ![NSJSONSerialization isValidJSONObject:data]) {
        return;
    }
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:&error];
    if (error != nil || jsonData == nil) {
        os_log_error(logger, "Failed to serialize data! %@", error);
    } else {
        NSString *message = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if (message == nil) {
            return;
        }
        // add a newline to the message so back-to-back messages are split and sent correctly
        NSString *jsonMessage = [NSString stringWithFormat:(@"%@\r\n"), message];
        NSData* finalData = [jsonMessage dataUsingEncoding:NSUTF8StringEncoding];
        
        GCDAsyncSocket *sock = nil;
        @synchronized (self) {
            sock = asyncSocket;
        }
        os_log(logger, "Sending data to server:\r\n%@", data);
        [sock writeData:(finalData) withTimeout:(-1) tag:(1)];
    }
}

#pragma mark - Private methods
// The data from the server is in the form of a json string, so we need to convert it to a NSDictionary
- (NSDictionary*) jsonDecode:(NSString*) json {
    if (![json isKindOfClass:[NSString class]] || json.length == 0) {
        return nil;
    }
    // For some reason the data is sometimes duplicated, so account for that
    NSRange range = [json rangeOfString:@"}\n{"];
    if (range.location != NSNotFound) {
        json = [json substringWithRange:NSMakeRange(0, range.location + 1)];
    }
    
    NSError *error = nil;
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (jsonData == nil || jsonData.length == 0) {
        return nil;
    }
    id dictionary = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&error];
    if (error != nil || ![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    
    return (NSDictionary *)dictionary;
}


#pragma mark - Socket state change handlers

- (void)socket:(GCDAsyncSocket*)sock didConnectToHost:(NSString*)host port:(UInt16)port {
    @synchronized (self) {
        if (sock != asyncSocket) {
            return;
        }
        _reconnectScheduled = NO;
        _reconnectDelaySeconds = kBBReconnectInitialDelaySeconds;
    }
    os_log(logger, "Helper socket connected on port:%{public}hu", port);
    
    NSDictionary *message = @{
        @"event": @"ping",
        @"message": @"Helper Connected!",
        @"process": [[NSBundle mainBundle] bundleIdentifier],
        // Actions added after the first release of the helper, so the server knows what it can ask for
        @"capabilities": @[@"send-rich-link", @"get-pinned-chats", @"update-chat-pinned"],
    };
    [self sendMessage:message];
}

- (void)socket:(GCDAsyncSocket*)sock didReadData:(NSData*)data withTag:(long)tag {
    @synchronized (self) {
        if (sock != asyncSocket) {
            return;
        }
    }
    [sock readDataToData:[GCDAsyncSocket LFData] withTimeout:(-1) maxLength:kBBMaxSocketMessageBytes tag:(1)];
    if (data.length == 0) {
        return;
    }
    if (_readBuffer == nil) {
        _readBuffer = [[NSMutableData alloc] init];
    }
    if (data.length > kBBMaxSocketMessageBytes || _readBuffer.length > kBBMaxSocketMessageBytes - data.length) {
        os_log_error(logger, "Incoming socket frame exceeded 64MB limit; disconnecting");
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
            os_log_error(logger, "Dropping invalid UTF-8 socket frame (%lu bytes)", (unsigned long)frameData.length);
            continue;
        }
        os_log(logger, "Received data from server:\r\n%{public}@\r\nwith tag: %{public}ld", str, tag);

        NSDictionary *dictionary = [self jsonDecode:str];
        if (dictionary == nil) {
            continue;
        }
        NSString *event = [dictionary[@"action"] isKindOfClass:[NSString class]] ? dictionary[@"action"] : nil;
        if (event.length == 0) {
            continue;
        }
        NSDictionary *eventData = [dictionary[@"data"] isKindOfClass:[NSDictionary class]] ? dictionary[@"data"] : @{};
        NSString *transaction = [dictionary[@"transactionId"] isKindOfClass:[NSString class]] ? dictionary[@"transactionId"] : nil;
        [[BlueBubblesHelper sharedInstance] handleServerEvent:event data:eventData transactionId:transaction];
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    @synchronized (self) {
        if (sock != asyncSocket) {
            return;
        }
        asyncSocket = nil;
        [_readBuffer setLength:0];
    }
    os_log_error(logger, "Disconnected from server, attempting to reconnect in 5 seconds...\r\n(%{public}@)", err);
    [self scheduleReconnect];
}

@end
