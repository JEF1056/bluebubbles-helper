#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "NetworkController.h"
#import "TUProxyCall.h"
#import "TUCall.h"
#import "TUCallCenter.h"
#import "TUHandle.h"

@interface TUCallProvider : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, getter=isFaceTimeProvider) BOOL faceTimeProvider;
@property (nonatomic, readonly, getter=isTelephonyProvider) BOOL telephonyProvider;
@end

@interface TUCallProviderManager : NSObject
@property (nonatomic, readonly) TUCallProvider *faceTimeProvider;
@property (nonatomic, readonly) TUCallProvider *telephonyProvider;
@end

@interface TUDialRequest : NSObject
@property (nonatomic, readonly) TUCallProvider *provider;
@property (nonatomic, retain) TUHandle *handle;
@property (nonatomic, copy) NSSet<TUHandle *> *handles;
@property (nonatomic, getter=isVideo) BOOL video;
@property (nonatomic, readonly, getter=isValid) BOOL valid;
@end

@interface TUCallCenter (DialingTest)
- (void)dialWithRequest:(id)request completionWithError:(void (^)(TUCall *call, NSError *error))completion;
@end

@interface BLUEBUBBLESFACETIMEHELPER : NSObject
+ (instancetype)sharedInstance;
- (NSDictionary *)callStatusPayloadForCall:(TUCall *)call;
- (void)callStatusChanged:(NSNotification *)notification;
- (void)handleMessage:(NetworkController *)controller message:(NSString *)message;
@end

#pragma mark - Test Doubles

@interface MockProvider : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, getter=isFaceTimeProvider) BOOL faceTimeProvider;
@property (nonatomic, getter=isTelephonyProvider) BOOL telephonyProvider;
@end

@implementation MockProvider
@end

@interface MockCall : NSObject
@property (nonatomic, copy) NSString *audioMode;
@property (nonatomic) int callStatus;
@property (nonatomic, copy) NSString *callUUID;
@property (nonatomic, getter=isConversation) BOOL conversation;
@property (nonatomic) int disconnectedReason;
@property (nonatomic, copy) NSString *endedErrorString;
@property (nonatomic, copy) NSString *endedReasonString;
@property (nonatomic, strong) TUHandle *handle;
@property (nonatomic, copy) NSArray *remoteParticipantHandles;
@property (nonatomic) BOOL isSendingAudio;
@property (nonatomic) BOOL isSendingVideo;
@property (nonatomic, getter=isOutgoing) BOOL outgoing;
@property (nonatomic, getter=isVideo) BOOL video;
@property (nonatomic, getter=isHostedOnCurrentDevice) BOOL hostedOnCurrentDevice;
@property (nonatomic, strong) id provider;
@property (nonatomic, getter=isUplinkMuted) BOOL uplinkMuted;
@end

@implementation MockCall
@end

@interface MockNetworkController : NetworkController
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *sentMessages;
@end

@implementation MockNetworkController
- (instancetype)init {
    self = [super init];
    if (self) {
        _sentMessages = [NSMutableArray array];
    }
    return self;
}
- (void)sendMessage:(NSDictionary *)message {
    [self.sentMessages addObject:message];
}
@end

#pragma mark - TUCallCenter Swizzle Harness

static NSMutableDictionary<NSString *, MockCall *> *gMockCalls;
static NSMutableArray<MockCall *> *gDisconnectedCalls;
static TUDialRequest *gLastDialRequest;
static MockCall *gNextDialCall;
static NSError *gNextDialError;
static MockNetworkController *gMockSharedNetworkController;

@implementation NetworkController (TestHook)
+ (NetworkController *)bb_test_sharedInstance {
    return gMockSharedNetworkController;
}
@end

@implementation TUCallCenter (TestHook)
- (TUCall *)bb_test_callWithCallUUID:(NSString *)uuid {
    return (TUCall *)gMockCalls[uuid];
}
- (void)bb_test_disconnectCall:(TUCall *)call {
    if (call != nil) {
        [gDisconnectedCalls addObject:(MockCall *)call];
    }
}
- (void)bb_test_dialWithRequest:(id)request completionWithError:(void (^)(TUCall *, NSError *))completion {
    gLastDialRequest = (TUDialRequest *)request;
    if (completion) {
        completion((TUCall *)gNextDialCall, gNextDialError);
    }
}
@end

static void SwizzleSelector(Class cls, SEL origSel, SEL altSel, BOOL isClassMethod) {
    Method orig = isClassMethod ? class_getClassMethod(cls, origSel) : class_getInstanceMethod(cls, origSel);
    Method alt = isClassMethod ? class_getClassMethod(cls, altSel) : class_getInstanceMethod(cls, altSel);
    assert(orig != NULL && alt != NULL);
    method_exchangeImplementations(orig, alt);
}

static NSString *JsonString(NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void AssertTrue(BOOL cond, NSString *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", [msg UTF8String]);
        exit(1);
    }
}

#pragma mark - Tests

static void TestCallStatusMetadataSerialization(BLUEBUBBLESFACETIMEHELPER *helper) {
    // 1. FaceTime Video call
    MockProvider *ftProvider = [[MockProvider alloc] init];
    ftProvider.identifier = @"com.apple.telephonyutilities.callservicesd.FaceTimeProvider";
    ftProvider.faceTimeProvider = YES;
    ftProvider.telephonyProvider = NO;

    MockCall *ftVideo = [[MockCall alloc] init];
    ftVideo.callUUID = @"ft-video-uuid";
    ftVideo.callStatus = 4;
    ftVideo.audioMode = @"video";
    ftVideo.handle = [TUHandle handleWithDestinationID:@"user@icloud.com"];
    ftVideo.isSendingAudio = YES;
    ftVideo.isSendingVideo = YES;
    ftVideo.video = YES;
    ftVideo.hostedOnCurrentDevice = YES;
    ftVideo.provider = ftProvider;

    NSDictionary *ftPayload = [helper callStatusPayloadForCall:(TUCall *)ftVideo];
    AssertTrue([ftPayload[@"is_video"] isEqual:@YES], @"FT video is_video should be YES");
    AssertTrue([ftPayload[@"is_telephony"] isEqual:@NO], @"FT video is_telephony should be NO");
    AssertTrue([ftPayload[@"provider_identifier"] isEqualToString:ftProvider.identifier], @"FT provider_identifier mismatch");

    // 2. Telephony / Continuity call
    MockProvider *telProvider = [[MockProvider alloc] init];
    telProvider.identifier = @"com.apple.coretelephony";
    telProvider.faceTimeProvider = NO;
    telProvider.telephonyProvider = YES;

    MockCall *telCall = [[MockCall alloc] init];
    telCall.callUUID = @"tel-uuid";
    telCall.callStatus = 4;
    telCall.audioMode = @"audio";
    telCall.handle = [TUHandle handleWithDestinationID:@"+15551234567"];
    telCall.isSendingAudio = YES;
    telCall.isSendingVideo = NO;
    telCall.video = NO;
    telCall.hostedOnCurrentDevice = NO;
    telCall.provider = telProvider;

    NSDictionary *telPayload = [helper callStatusPayloadForCall:(TUCall *)telCall];
    AssertTrue([telPayload[@"is_video"] isEqual:@NO], @"Telephony is_video should be NO");
    AssertTrue([telPayload[@"is_telephony"] isEqual:@YES], @"Telephony is_telephony should be YES");
    AssertTrue([telPayload[@"provider_identifier"] isEqualToString:@"com.apple.coretelephony"], @"Telephony provider_identifier mismatch");

    // 3. Continuity fallback when provider is nil and hostedOnCurrentDevice == NO
    MockCall *relayFallback = [[MockCall alloc] init];
    relayFallback.callUUID = @"relay-uuid";
    relayFallback.callStatus = 1;
    relayFallback.hostedOnCurrentDevice = NO;
    NSDictionary *relayPayload = [helper callStatusPayloadForCall:(TUCall *)relayFallback];
    AssertTrue([relayPayload[@"is_telephony"] isEqual:@YES], @"Relay call with hostedOnCurrentDevice=NO should set is_telephony=YES");
    AssertTrue(relayPayload[@"provider_identifier"] == [NSNull null], @"Nil provider should yield NSNull provider_identifier");

    // 4. callStatusChanged: emits ft-call-status-changed with new fields and ignores nil object
    [gMockSharedNetworkController.sentMessages removeAllObjects];
    [helper callStatusChanged:[NSNotification notificationWithName:@"TUCallCenterCallStatusChangedNotification" object:nil]];
    AssertTrue(gMockSharedNetworkController.sentMessages.count == 0, @"Nil call notification should not emit");

    [helper callStatusChanged:[NSNotification notificationWithName:@"TUCallCenterCallStatusChangedNotification" object:telCall]];
    AssertTrue(gMockSharedNetworkController.sentMessages.count == 1, @"Expected 1 ft-call-status-changed event");
    NSDictionary *emitted = gMockSharedNetworkController.sentMessages.firstObject;
    AssertTrue([emitted[@"event"] isEqualToString:@"ft-call-status-changed"], @"Unexpected event name");
    AssertTrue([emitted[@"data"][@"is_telephony"] isEqual:@YES], @"Emitted payload missing is_telephony");
    AssertTrue([emitted[@"data"][@"provider_identifier"] isEqualToString:@"com.apple.coretelephony"], @"Emitted payload missing provider_identifier");
    printf("PASS: TestCallStatusMetadataSerialization\n");
}

static void TestDeclineAndLeaveCall(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockNetworkController *nc = [[MockNetworkController alloc] init];

    int validStatuses[] = {4, 3, 1};
    NSString *actions[] = {@"decline-call", @"leave-call"};
    for (int a = 0; a < 2; a++) {
        for (int i = 0; i < 3; i++) {
            int status = validStatuses[i];
            NSString *uuid = [NSString stringWithFormat:@"call-%d-%d", a, status];
            MockCall *call = [[MockCall alloc] init];
            call.callUUID = uuid;
            call.callStatus = status;
            gMockCalls[uuid] = call;

            [gDisconnectedCalls removeAllObjects];
            [nc.sentMessages removeAllObjects];

            NSString *msg = JsonString(@{
                @"action": actions[a],
                @"transactionId": @"tx-1",
                @"data": @{@"callUUID": uuid}
            });
            [helper handleMessage:nc message:msg];

            AssertTrue(gDisconnectedCalls.count == 1 && gDisconnectedCalls.firstObject == call,
                       ([NSString stringWithFormat:@"%@ should disconnect call on status %d", actions[a], status]));
            AssertTrue(nc.sentMessages.count == 1 && nc.sentMessages.firstObject[@"error"] == nil,
                       ([NSString stringWithFormat:@"%@ should succeed without error on status %d", actions[a], status]));
        }
    }

    // Disconnected status (6) should return error and NOT disconnect
    MockCall *ended = [[MockCall alloc] init];
    ended.callUUID = @"ended-uuid";
    ended.callStatus = 6;
    gMockCalls[@"ended-uuid"] = ended;

    [gDisconnectedCalls removeAllObjects];
    [nc.sentMessages removeAllObjects];
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"decline-call",
        @"transactionId": @"tx-ended",
        @"data": @{@"callUUID": @"ended-uuid"}
    })];
    AssertTrue(gDisconnectedCalls.count == 0, @"Disconnected call should not call disconnectCall:");
    AssertTrue(nc.sentMessages.count == 1 && nc.sentMessages.firstObject[@"error"] != nil, @"Expected error for status 6");

    // Missing callUUID should return error
    [nc.sentMessages removeAllObjects];
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"decline-call",
        @"transactionId": @"tx-missing",
        @"data": @{}
    })];
    AssertTrue(nc.sentMessages.count == 1 && nc.sentMessages.firstObject[@"error"] != nil, @"Expected error for missing callUUID");
    printf("PASS: TestDeclineAndLeaveCall\n");
}

static void TestSetMuted(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockNetworkController *nc = [[MockNetworkController alloc] init];
    MockCall *call = [[MockCall alloc] init];
    call.callUUID = @"mute-uuid";
    call.callStatus = 1;
    call.uplinkMuted = NO;
    gMockCalls[@"mute-uuid"] = call;

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"set-muted",
        @"transactionId": @"tx-m1",
        @"data": @{@"callUUID": @"mute-uuid", @"muted": @YES}
    })];
    AssertTrue(call.isUplinkMuted == YES, @"Expected uplinkMuted == YES");
    AssertTrue([nc.sentMessages.lastObject[@"muted"] isEqual:@YES], @"Expected muted: true reply");

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"set-muted",
        @"transactionId": @"tx-m2",
        @"data": @{@"callUUID": @"mute-uuid", @"muted": @NO}
    })];
    AssertTrue(call.isUplinkMuted == NO, @"Expected uplinkMuted == NO");
    AssertTrue([nc.sentMessages.lastObject[@"muted"] isEqual:@NO], @"Expected muted: false reply");
    printf("PASS: TestSetMuted\n");
}

static void TestGenerateLink(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockNetworkController *nc = [[MockNetworkController alloc] init];
    
    // 1. Generic link path when callUUID is null: uses async sharedConversationManager without spurious sync error
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"generate-link",
        @"transactionId": @"tx-g1",
        @"data": @{@"callUUID": [NSNull null]}
    })];
    AssertTrue(nc.sentMessages.count == 0 || nc.sentMessages.lastObject[@"error"] != nil, @"Expected async generic link or clean unsupported error");

    // 2. Inactive call error reply test
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"generate-link",
        @"transactionId": @"tx-g2",
        @"data": @{@"callUUID": @"non-existent-uuid"}
    })];
    AssertTrue([nc.sentMessages.lastObject[@"error"] isEqualToString:@"Call is no longer active!"], @"Expected inactive call error");

    // 3. Valid active call enters polling/link-generation without immediate inactive-call error
    MockCall *activeCall = [[MockCall alloc] init];
    activeCall.callUUID = @"valid-uuid";
    activeCall.callStatus = 3; // Dialing/Ringing
    gMockCalls[@"valid-uuid"] = activeCall;
    NSUInteger beforeCount = nc.sentMessages.count;

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"generate-link",
        @"transactionId": @"tx-g3",
        @"data": @{@"callUUID": @"valid-uuid"}
    })];
    AssertTrue([helper respondsToSelector:@selector(sharedConversationManager)], @"Expected helper to respond to sharedConversationManager");
    AssertTrue(nc.sentMessages.count == beforeCount, @"Expected active call generate-link to poll asynchronously rather than fail synchronously");
    printf("PASS: TestGenerateLink\n");
}

static void TestStartCall(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockNetworkController *nc = [[MockNetworkController alloc] init];

    // 1. FaceTime Video start-call
    MockProvider *ftProv = [[MockProvider alloc] init];
    ftProv.identifier = @"com.apple.telephonyutilities.callservicesd.FaceTimeProvider";
    ftProv.faceTimeProvider = YES;

    MockCall *dialedFT = [[MockCall alloc] init];
    dialedFT.callUUID = @"dialed-ft-uuid";
    dialedFT.callStatus = 3;
    dialedFT.video = YES;
    dialedFT.hostedOnCurrentDevice = YES;
    dialedFT.provider = ftProv;
    gNextDialCall = dialedFT;
    gNextDialError = nil;
    gLastDialRequest = nil;

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"start-call",
        @"transactionId": @"tx-s1",
        @"data": @{@"addresses": @[@"+15551234567"], @"video": @YES, @"isTelephony": @NO}
    })];
    AssertTrue(gLastDialRequest != nil, @"Expected TUDialRequest to be dispatched");
    AssertTrue(gLastDialRequest.isValid == YES, @"Expected valid FaceTime TUDialRequest");
    AssertTrue(gLastDialRequest.isVideo == YES, @"Expected video=YES on FaceTime request");
    AssertTrue(gLastDialRequest.provider.isFaceTimeProvider == YES, @"Expected faceTimeProvider");
    NSDictionary *reply1 = nc.sentMessages.lastObject;
    AssertTrue([reply1[@"call_uuid"] isEqualToString:@"dialed-ft-uuid"], @"Expected call_uuid in start-call reply");
    AssertTrue([reply1[@"is_video"] isEqual:@YES], @"Expected is_video=YES in start-call reply");

    // 2. Telephony start-call (forces audio)
    MockProvider *telProv = [[MockProvider alloc] init];
    telProv.identifier = @"com.apple.coretelephony";
    telProv.telephonyProvider = YES;

    MockCall *dialedTel = [[MockCall alloc] init];
    dialedTel.callUUID = @"dialed-tel-uuid";
    dialedTel.callStatus = 3;
    dialedTel.video = NO;
    dialedTel.hostedOnCurrentDevice = NO;
    dialedTel.provider = telProv;
    gNextDialCall = dialedTel;
    gLastDialRequest = nil;

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"start-call",
        @"transactionId": @"tx-s2",
        @"data": @{@"addresses": @[@"+15557654321"], @"video": @YES, @"isTelephony": @YES}
    })];
    AssertTrue(gLastDialRequest != nil, @"Expected Telephony TUDialRequest");
    AssertTrue(gLastDialRequest.isValid == YES, @"Expected valid Telephony TUDialRequest");
    AssertTrue(gLastDialRequest.isVideo == NO, @"Telephony request must force video=NO");
    AssertTrue(gLastDialRequest.provider.isTelephonyProvider == YES, @"Expected telephonyProvider");
    NSDictionary *reply2 = nc.sentMessages.lastObject;
    AssertTrue([reply2[@"call_uuid"] isEqualToString:@"dialed-tel-uuid"], @"Expected telephony call_uuid");
    AssertTrue([reply2[@"is_telephony"] isEqual:@YES], @"Expected is_telephony=YES");

    // 3. Empty addresses error
    gLastDialRequest = nil;
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"start-call",
        @"transactionId": @"tx-s3",
        @"data": @{@"addresses": @[], @"video": @NO, @"isTelephony": @NO}
    })];
    AssertTrue(gLastDialRequest == nil, @"Empty addresses must not dial");
    AssertTrue(nc.sentMessages.lastObject[@"error"] != nil, @"Empty addresses must return error");
    printf("PASS: TestStartCall\n");
}

int main(void) {
    @autoreleasepool {
        gMockCalls = [NSMutableDictionary dictionary];
        gDisconnectedCalls = [NSMutableArray array];
        gMockSharedNetworkController = [[MockNetworkController alloc] init];

        SwizzleSelector([NetworkController class], @selector(sharedInstance), @selector(bb_test_sharedInstance), YES);
        SwizzleSelector([TUCallCenter class], @selector(callWithCallUUID:), @selector(bb_test_callWithCallUUID:), NO);
        SwizzleSelector([TUCallCenter class], @selector(disconnectCall:), @selector(bb_test_disconnectCall:), NO);
        SwizzleSelector([TUCallCenter class], @selector(dialWithRequest:completionWithError:), @selector(bb_test_dialWithRequest:completionWithError:), NO);

        BLUEBUBBLESFACETIMEHELPER *helper = [BLUEBUBBLESFACETIMEHELPER sharedInstance];
        TestCallStatusMetadataSerialization(helper);
        TestDeclineAndLeaveCall(helper);
        TestSetMuted(helper);
        TestStartCall(helper);
        TestGenerateLink(helper);
        printf("ALL FACETIME HELPER TESTS PASSED\n");
    }
    return 0;
}
