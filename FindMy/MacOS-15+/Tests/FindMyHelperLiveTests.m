#import <Foundation/Foundation.h>

#import "FindMyFriendPayload.h"
#import "FindMyHelper.h"
#import "FindMyLocateSession.h"
#import "GCDAsyncSocket.h"
#import "ServerConnection.h"

@interface FMLHandle : NSObject
@property(nonatomic, copy) NSString *identifier;
@end

@implementation FMLHandle
@end

@interface BBMockLiveLocation : NSObject
@property(nonatomic) double altitude;
@property(nonatomic, copy) NSString *coarseAddressLabel;
@property(nonatomic) double horizontalAccuracy;
@property(nonatomic, copy) NSArray *labels;
@property(nonatomic) double latitude;
@property(nonatomic) long long locationType;
@property(nonatomic) double longitude;
@property(nonatomic) double speed;
@property(nonatomic) double timestamp;
@property(nonatomic) double verticalAccuracy;
@end

@implementation BBMockLiveLocation
@end

static NSMutableArray<NSDictionary *> *BBRecordedStarts = nil;
static NSMutableArray<NSDictionary *> *BBRecordedStops = nil;
static NSArray *BBMockCachedFriends = nil;
static NSMutableDictionary<NSString *, id> *BBMockCachedLocations = nil;
static FindMyLocationUpdateCallback BBLiveCallback = nil;
static BOOL BBUseAsyncDelayedFriendResolution = NO;

@implementation FindMyLocateSession

- (void)setLocationUpdateCallback:(nullable FindMyLocationUpdateCallback)callback {
    BBLiveCallback = [callback copy];
}

- (void)startUpdatingFriendsWithInitialUpdates:(BOOL)includeInitialUpdates completion:(FindMyCompletion)completion {
    completion();
}

- (void)startMonitoringActiveLocationSharingDeviceChangeWithCompletion:(FindMyCompletion)completion {
    completion();
}

- (nullable NSArray *)cachedFriendsSharingLocationsWithMe {
    return BBUseAsyncDelayedFriendResolution ? @[] : (BBMockCachedFriends ?: @[]);
}

- (void)getFriendsSharingLocationsWithMeWithCompletion:(FindMyFriendsCompletion)completion {
    NSArray *friends = BBMockCachedFriends ?: @[];
    if (BBUseAsyncDelayedFriendResolution) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            completion(friends);
        });
        return;
    }
    completion(friends);
}

- (nullable id)cachedLocationForHandle:(id)locationHandle includeAddress:(BOOL)includeAddress {
    NSString *identifier = [FindMyFriendPayload identifierForHandle:locationHandle];
    return identifier == nil ? nil : BBMockCachedLocations[identifier];
}

- (void)startRefreshingLocationForHandles:(NSArray *)locationHandles
                                  priority:(long long)priority
                               isFromGroup:(BOOL)isFromGroup
                            reverseGeocode:(BOOL)reverseGeocode
                                completion:(FindMyCompletion)completion {
    NSMutableArray<NSString *> *ids = [[NSMutableArray alloc] init];
    for (id handle in locationHandles) {
        NSString *identifier = [FindMyFriendPayload identifierForHandle:handle];
        if (identifier != nil) {
            [ids addObject:identifier];
        }
    }
    [BBRecordedStarts addObject:@{
        @"handles": ids,
        @"priority": @(priority),
        @"reverseGeocode": @(reverseGeocode),
    }];
    completion();
}

- (void)stopRefreshingLocationForHandles:(NSArray *)locationHandles
                                 priority:(long long)priority
                              isFromGroup:(BOOL)isFromGroup
                               completion:(FindMyCompletion)completion {
    NSMutableArray<NSString *> *ids = [[NSMutableArray alloc] init];
    for (id handle in locationHandles) {
        NSString *identifier = [FindMyFriendPayload identifierForHandle:handle];
        if (identifier != nil) {
            [ids addObject:identifier];
        }
    }
    [BBRecordedStops addObject:@{
        @"handles": ids,
        @"priority": @(priority),
    }];
    completion();
}

@end

@interface BBLiveRecordingSocket : GCDAsyncSocket
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *sentMessages;
@end

@implementation BBLiveRecordingSocket

- (instancetype)init {
    self = [super initWithDelegate:nil delegateQueue:dispatch_get_main_queue()];
    if (self != nil) {
        _sentMessages = [[NSMutableArray alloc] init];
    }
    return self;
}

- (BOOL)isDisconnected {
    return NO;
}

- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([message isKindOfClass:[NSDictionary class]]) {
        [self.sentMessages addObject:message];
    }
}

@end

static void BBAssert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static BOOL BBWaitUntil(BOOL (^condition)(void), NSTimeInterval timeoutSeconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

int main(void) {
    @autoreleasepool {
        BBRecordedStarts = [[NSMutableArray alloc] init];
        BBRecordedStops = [[NSMutableArray alloc] init];
        BBMockCachedLocations = [[NSMutableDictionary alloc] init];

        FMLHandle *alice = [[FMLHandle alloc] init];
        alice.identifier = @"alice@example.com";
        FMLHandle *bob = [[FMLHandle alloc] init];
        bob.identifier = @"bob@example.com";
        BBMockCachedFriends = @[alice, bob];

        BBMockLiveLocation *aliceCached = [[BBMockLiveLocation alloc] init];
        aliceCached.latitude = 37.3349;
        aliceCached.longitude = -122.0090;
        aliceCached.timestamp = 1700000000.0;
        aliceCached.locationType = 1;
        aliceCached.horizontalAccuracy = 65.0;
        BBMockCachedLocations[@"alice@example.com"] = aliceCached;

        BBLiveRecordingSocket *socket = [[BBLiveRecordingSocket alloc] init];
        [[ServerConnection sharedInstance] setValue:socket forKey:@"socket"];

        FindMyHelper *helper = [FindMyHelper sharedInstance];

        // 1. Start live location for Alice -> priority 2 (.live), reverseGeocode YES, cached snapshot returned
        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"ALICE@example.com"}
             transactionIdentifier:@"tx-live-1"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStarts.count >= 1 && socket.sentMessages.count >= 1;
        }, 0.5), @"start-findmy-live-location must start refresh and reply");

        NSDictionary *startAlice = BBRecordedStarts.firstObject;
        BBAssert([startAlice[@"handles"] isEqual:@[@"alice@example.com"]], @"start must target alice");
        BBAssert([startAlice[@"priority"] isEqual:@2], @"live start must use LocatePriority.live (2)");
        BBAssert([startAlice[@"reverseGeocode"] isEqual:@YES], @"live start must enable reverseGeocode");
        BBAssert(BBLiveCallback != nil, @"locationUpdateCallback must be installed");

        // 2. Simulate pushed shallow then live callback -> live callback clears locating override (is_locating_in_progress: false)
        [socket.sentMessages removeAllObjects];
        BBMockLiveLocation *aliceLive = [[BBMockLiveLocation alloc] init];
        aliceLive.latitude = 37.3352;
        aliceLive.longitude = -122.0094;
        aliceLive.timestamp = 1700000005.25;
        aliceLive.locationType = 2;
        aliceLive.horizontalAccuracy = 4.5;
        aliceLive.verticalAccuracy = 3.0;
        aliceLive.speed = 2.4;
        aliceLive.altitude = 18.0;
        aliceLive.coarseAddressLabel = @"Cupertino, CA";
        BBLiveCallback(aliceLive, alice);

        BBAssert(socket.sentMessages.count == 1, @"locationUpdateCallback must stream immediately");
        NSDictionary *pushedEvent = socket.sentMessages.firstObject;
        BBAssert([pushedEvent[@"event"] isEqualToString:@"new-findmy-location"], @"must emit new-findmy-location");
        NSDictionary *pushedPayload = [pushedEvent[@"data"] firstObject];
        BBAssert([pushedPayload[@"status"] isEqualToString:@"live"], @"status must be live");
        BBAssert([pushedPayload[@"location_type"] isEqual:@2], @"location_type must be 2");
        BBAssert([pushedPayload[@"horizontal_accuracy"] isEqual:@4.5], @"horizontal_accuracy must match");
        BBAssert([pushedPayload[@"speed"] isEqual:@2.4], @"speed must match");
        BBAssert([pushedPayload[@"altitude"] isEqual:@18.0], @"altitude must match");
        BBAssert([pushedPayload[@"last_updated"] isEqual:@1700000005250], @"last_updated must be ms");
        BBAssert([pushedPayload[@"is_locating_in_progress"] isEqual:@NO],
                 @"is_locating_in_progress must be false once live updates arrive");

        // 3. Switch live location to Bob -> cleanly stops Alice before starting Bob
        [BBRecordedStarts removeAllObjects];
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"bob@example.com"}
             transactionIdentifier:@"tx-live-2"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStops.count >= 1 && BBRecordedStarts.count >= 1 && socket.sentMessages.count >= 1;
        }, 0.5), @"switching live friend must stop prior live handle and start new one");
        BBAssert([BBRecordedStops.firstObject[@"handles"] isEqual:@[@"alice@example.com"]],
                 @"prior live handle alice must be stopped");
        BBAssert([BBRecordedStops.firstObject[@"priority"] isEqual:@2],
                 @"live stop must pass priority 2");
        BBAssert([BBRecordedStarts.firstObject[@"handles"] isEqual:@[@"bob@example.com"]],
                 @"new live handle bob must be started");

        // 4. Stale stop for Alice while Bob is active must be ignored
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"stop-findmy-live-location"
                              data:@{@"handle": @"alice@example.com"}
             transactionIdentifier:@"tx-stop-stale"];
        BBAssert(BBWaitUntil(^BOOL { return socket.sentMessages.count >= 1; }, 0.5),
                 @"stale stop must still acknowledge transaction");
        BBAssert(BBRecordedStops.count == 0, @"stale stop for alice must not stop active bob live session");
        BBAssert([socket.sentMessages.firstObject[@"stopped"] isEqual:@NO], @"stale stop must report stopped: false");

        // 5. Stop for Bob stops Bob cleanly
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"stop-findmy-live-location"
                              data:@{@"handle": @"bob@example.com"}
             transactionIdentifier:@"tx-stop-bob"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStops.count == 1 && socket.sentMessages.count == 1;
        }, 0.5), @"stop for bob must stop refreshing and reply");
        BBAssert([BBRecordedStops.firstObject[@"handles"] isEqual:@[@"bob@example.com"]],
                 @"stop must pass bob handle");
        BBAssert([socket.sentMessages.firstObject[@"stopped"] isEqual:@YES], @"stop must report stopped: true");

        // 6. Race test: start(Alice) -> start(Bob) with async handle resolution -> stop(Alice) arrives mid-resolution
        //    stop(Alice) must NOT bump generation or kill pending start(Bob).
        [BBRecordedStarts removeAllObjects];
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"alice@example.com"}
             transactionIdentifier:@"tx-race-alice"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStarts.count == 1 && socket.sentMessages.count == 1;
        }, 0.5), @"race setup start alice must finish");

        [BBRecordedStarts removeAllObjects];
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        BBUseAsyncDelayedFriendResolution = YES;

        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"bob@example.com"}
             transactionIdentifier:@"tx-race-bob"];
        [helper handleServerAction:@"stop-findmy-live-location"
                              data:@{@"handle": @"alice@example.com"}
             transactionIdentifier:@"tx-race-stop-alice"];

        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStarts.count >= 1 && socket.sentMessages.count >= 2;
        }, 0.5), @"bob live start must still succeed when stop(alice) lands during async resolution");
        BBUseAsyncDelayedFriendResolution = NO;

        NSDictionary *stopAliceRaceReply = nil;
        NSDictionary *startBobRaceReply = nil;
        for (NSDictionary *msg in socket.sentMessages) {
            if ([msg[@"transactionId"] isEqualToString:@"tx-race-stop-alice"]) stopAliceRaceReply = msg;
            if ([msg[@"transactionId"] isEqualToString:@"tx-race-bob"]) startBobRaceReply = msg;
        }
        BBAssert(stopAliceRaceReply != nil && [stopAliceRaceReply[@"stopped"] isEqual:@NO],
                 @"stale stop(alice) mid-resolution must return stopped: false");
        BBAssert([stopAliceRaceReply[@"activeHandle"] isEqualToString:@"bob@example.com"],
                 @"stale stop(alice) must report pending bob handle");
        BBAssert(startBobRaceReply != nil && [startBobRaceReply[@"live"] isEqual:@YES],
                 @"start(bob) must complete with live: true instead of superseded");
        BBAssert(startBobRaceReply[@"superseded"] == nil, @"start(bob) must not be superseded");

        NSLog(@"PASS: FindMyHelperLiveTests");
    }
    return 0;
}
