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
- (void)replayCurrentCallsToController:(NetworkController *)controller;
- (void)initializeNetworkController;
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
@property (nonatomic, copy) NSString *uniqueProxyIdentifier;
@property (nonatomic, strong) NSUUID *callGroupUUID;
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
@property (nonatomic) int filteredOutReason;
@property (nonatomic, strong) NSDate *dateConnected;
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
static id gLastJoinRequest;
static MockCall *gNextDialCall;
static NSError *gNextDialError;
static MockNetworkController *gMockSharedNetworkController;
static id gMockGeneratedLink;
static BOOL gDidInvalidateLink = NO;
static NSMutableArray *gMockActiveConversations;
static NSMutableArray *gApprovedPendingMembers;
static NSMutableArray<MockCall *> *gAnsweredCalls;
static BOOL gSkipInvalidateCompletion = NO;

@interface MockConversationLink : NSObject
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, copy) NSUUID *groupUUID;
@end
@implementation MockConversationLink
@end

@implementation NetworkController (TestHook)
+ (NetworkController *)bb_test_sharedInstance {
    return gMockSharedNetworkController;
}
@end

@implementation TUConversationManager (TestHook)
- (void)bb_test_generateLinkWithInvitedMemberHandles:(NSSet *)handles linkLifetimeScope:(NSInteger)scope completionHandler:(void (^)(TUConversationLink *, NSError *))completion {
    if (completion) {
        completion(gMockGeneratedLink, gMockGeneratedLink ? nil : [NSError errorWithDomain:@"Test" code:1 userInfo:nil]);
    }
}
- (void)bb_test_invalidateLink:(TUConversationLink *)link completionHandler:(void (^)(BOOL, NSError *))completion {
    gDidInvalidateLink = YES;
    if (!gSkipInvalidateCompletion && completion) completion(YES, nil);
}
- (NSSet *)bb_test_activatedConversationLinks {
    return gMockGeneratedLink ? [NSSet setWithObject:gMockGeneratedLink] : [NSSet set];
}
- (NSSet *)bb_test_activeConversations {
    return [NSSet setWithArray:(gMockActiveConversations ?: @[])];
}
- (void)bb_test_approvePendingMember:(id)member forConversation:(id)convo {
    if (member != nil) [gApprovedPendingMembers addObject:@{@"member": member, @"convo": convo ?: [NSNull null]}];
}
@end

@implementation TUCallCenter (TestHook)
- (TUCall *)bb_test_callWithCallUUID:(NSString *)uuid {
    MockCall *call = gMockCalls[uuid];
    return (call != nil && [call.callUUID isEqualToString:uuid]) ? (TUCall *)call : nil;
}
- (TUCall *)bb_test_callWithUniqueProxyIdentifier:(NSString *)upi {
    for (MockCall *call in [gMockCalls allValues]) {
        if ([call.uniqueProxyIdentifier isEqualToString:upi]) {
            return (TUCall *)call;
        }
    }
    return nil;
}
- (NSArray<TUCall *> *)bb_test_currentCalls {
    return (NSArray<TUCall *> *)[gMockCalls allValues];
}
- (void)bb_test_disconnectCall:(TUCall *)call {
    if (call != nil) {
        [gDisconnectedCalls addObject:(MockCall *)call];
    }
}
- (void)bb_test_disconnectCall:(TUCall *)call withReason:(int)reason {
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
- (TUCall *)bb_test_joinConversationWithConversationRequest:(id)request {
    gLastJoinRequest = request;
    return (TUCall *)gNextDialCall;
}
- (void)bb_test_answerOrJoinCall:(TUCall *)call {
    if (call != nil) [gAnsweredCalls addObject:(MockCall *)call];
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
    gMockGeneratedLink = nil;
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
    gLastJoinRequest = nil;
    MockConversationLink *mockLink = [[MockConversationLink alloc] init];
    mockLink.URL = [NSURL URLWithString:@"https://facetime.apple.com/join#v=1&p=test"];
    mockLink.groupUUID = [NSUUID UUID];
    gMockGeneratedLink = mockLink;

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"start-call",
        @"transactionId": @"tx-s1",
        @"data": @{@"addresses": @[@"+15551234567"], @"video": @YES, @"isTelephony": @NO}
    })];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    AssertTrue(gLastJoinRequest != nil, @"Expected TUJoinConversationRequest to be dispatched for FaceTime call");
    AssertTrue([gLastJoinRequest valueForKey:@"conversationLink"] == mockLink, @"Expected conversationLink on FaceTime join request");
    AssertTrue([[gLastJoinRequest valueForKey:@"isVideo"] isEqual:@YES], @"Expected video=YES on FaceTime join request");
    NSDictionary *reply1 = nc.sentMessages.lastObject;
    AssertTrue([reply1[@"call_uuid"] isEqualToString:@"dialed-ft-uuid"], @"Expected call_uuid in start-call reply");
    AssertTrue([reply1[@"is_video"] isEqual:@YES], @"Expected is_video=YES in start-call reply");
    AssertTrue([reply1[@"url"] isKindOfClass:[NSString class]] && [reply1[@"url"] length] > 0, @"Expected pregenerated url in start-call reply");

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

@interface DtmfMockCall : MockCall
@property (nonatomic) BOOL supportsDTMFTones;
@property (nonatomic, copy) NSString *lastPlayedDtmf;
- (void)playDTMFToneForKey:(unsigned char)key;
@end

@implementation DtmfMockCall
- (void)playDTMFToneForKey:(unsigned char)key {
    self.lastPlayedDtmf = [NSString stringWithFormat:@"%c", key];
}
@end

static void TestPlayDtmf(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockNetworkController *nc = [[MockNetworkController alloc] init];

    // 1. Missing call -> error
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"play-dtmf",
        @"transactionId": @"tx-d1",
        @"data": @{@"callUUID": @"missing-call", @"digit": @"5"}
    })];
    AssertTrue(nc.sentMessages.lastObject[@"error"] != nil, @"Missing call must return error");

    // 2. Invalid digit -> error
    DtmfMockCall *call = [[DtmfMockCall alloc] init];
    call.callUUID = @"dtmf-call";
    call.callStatus = 1;
    call.supportsDTMFTones = YES;
    gMockCalls[@"dtmf-call"] = call;

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"play-dtmf",
        @"transactionId": @"tx-d2",
        @"data": @{@"callUUID": @"dtmf-call", @"digit": @"Z"}
    })];
    AssertTrue(nc.sentMessages.lastObject[@"error"] != nil, @"Invalid digit must return error");

    // 3. Valid digit on call implementing playDTMFToneForKey: -> played: true
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"play-dtmf",
        @"transactionId": @"tx-d3",
        @"data": @{@"callUUID": @"dtmf-call", @"digit": @"#"}
    })];
    AssertTrue([nc.sentMessages.lastObject[@"played"] isEqual:@YES], @"Expected played:true when selector present");
    AssertTrue([call.lastPlayedDtmf isEqualToString:@"#"], @"Expected # to be played");

    // 4. Call without DTMF selector -> played: false, fallback: "bridge"
    MockCall *plainCall = [[MockCall alloc] init];
    plainCall.callUUID = @"plain-call";
    plainCall.callStatus = 1;
    gMockCalls[@"plain-call"] = plainCall;

    [helper handleMessage:nc message:JsonString(@{
        @"action": @"play-dtmf",
        @"transactionId": @"tx-d4",
        @"data": @{@"callUUID": @"plain-call", @"digit": @"7"}
    })];
    AssertTrue([nc.sentMessages.lastObject[@"played"] isEqual:@NO], @"Expected played:false when selector absent");
    AssertTrue([nc.sentMessages.lastObject[@"fallback"] isEqualToString:@"bridge"], @"Expected bridge fallback");

    printf("PASS: TestPlayDtmf\n");
}

@interface FakeFramingSocket : GCDAsyncSocket
@property (nonatomic, strong) NSMutableArray<NSData *> *writtenData;
@end

@implementation FakeFramingSocket
- (instancetype)init {
    self = [super initWithDelegate:nil delegateQueue:dispatch_get_main_queue()];
    if (self) {
        _writtenData = [NSMutableArray array];
    }
    return self;
}
- (void)readDataToData:(NSData *)data withTimeout:(NSTimeInterval)timeout maxLength:(NSUInteger)length tag:(long)tag {
    (void)data; (void)timeout; (void)length; (void)tag;
}
- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    (void)timeout; (void)tag;
    if (data != nil) [self.writtenData addObject:data];
}
- (void)disconnect {
}
@end

static void TestNetworkControllerFramingAndTypeGuards(BLUEBUBBLESFACETIMEHELPER *helper) {
    NetworkController *nc = [[NetworkController alloc] init];
    FakeFramingSocket *fakeSock = [[FakeFramingSocket alloc] init];
    [nc setValue:fakeSock forKey:@"asyncSocket"];

    NSMutableArray<NSString *> *frames = [NSMutableArray array];
    nc.messageReceivedBlock = ^(id sender, NSString *msg) {
        (void)sender;
        [frames addObject:msg];
    };

    // 1. Split UTF-8 frame + CRLF + multi-frame chunk + invalid UTF-8 frame + empty line
    [nc socket:fakeSock didReadData:[@"{\"a\":1}\r" dataUsingEncoding:NSUTF8StringEncoding] withTag:1];
    AssertTrue(frames.count == 0, @"Incomplete frame without LF must stay buffered");

    NSMutableData *chunk2 = [NSMutableData dataWithData:[@"\n\n{\"b\":\"hi\"}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    const uint8_t badUtf8[] = {0xFF, 0xFE, 0x0A};
    [chunk2 appendBytes:badUtf8 length:sizeof(badUtf8)];
    [chunk2 appendData:[@"{\"ok\":true}\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [nc socket:fakeSock didReadData:chunk2 withTag:1];

    AssertTrue(frames.count == 3, @"Expected 3 valid UTF-8 frames (empty and invalid UTF-8 skipped)");
    AssertTrue([frames[0] isEqualToString:@"{\"a\":1}"], @"First frame must strip trailing CR");
    AssertTrue([frames[1] isEqualToString:@"{\"b\":\"hi\"}"], @"Second frame must decode cleanly");
    AssertTrue([frames[2] isEqualToString:@"{\"ok\":true}"], @"Valid frame after invalid UTF-8 must decode");

    // 2. handleMessage type guards must ignore non-dict JSON and bad data without crashing
    [helper handleMessage:nc message:@"[]"];
    [helper handleMessage:nc message:@"{bad-json"];
    [helper handleMessage:nc message:JsonString(@{@"action": @"start-call", @"transactionId": @"tx-bad", @"data": @"not-a-dict"})];

    // 3. sendMessage nil / non-serializable guard must not write "(null)"
    NSUInteger countBefore = fakeSock.writtenData.count;
    [nc sendMessage:(id)@"not-a-dict"];
    [nc sendMessage:@{@"bad": [NSDate date]}];
    AssertTrue(fakeSock.writtenData.count == countBefore, @"Invalid sendMessage must not write to socket");

    printf("PASS: TestNetworkControllerFramingAndTypeGuards\n");
}

static void TestTUProxyCallNilCallUUIDFallback(BLUEBUBBLESFACETIMEHELPER *helper) {
    // macOS 26.4 TUProxyCall leaves callUUID nil at dial/join creation and populates
    // uniqueProxyIdentifier immediately until callservicesd sends updateWithCall:.
    MockCall *call = [[MockCall alloc] init];
    call.callUUID = nil;
    call.uniqueProxyIdentifier = @"UPI-MACOS26-1111";
    call.callStatus = 3; // outgoing / dialing
    call.outgoing = YES;
    gNextDialCall = call;
    gNextDialError = nil;
    gMockGeneratedLink = nil;
    [gMockCalls removeAllObjects];
    gMockCalls[@"slot-1"] = call;

    MockNetworkController *nc = [[MockNetworkController alloc] init];
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"start-call",
        @"transactionId": @"tx-nil-uuid-dial",
        @"data": @{
            @"addresses": @[@"+16266165776"],
            @"isVideo": @NO
        }
    })];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    AssertTrue(nc.sentMessages.count == 1, @"start-call with nil callUUID should still reply");
    NSDictionary *reply = nc.sentMessages.firstObject;
    AssertTrue([reply[@"call_uuid"] isEqualToString:@"UPI-MACOS26-1111"],
               @"start-call should fall back to uniqueProxyIdentifier when callUUID is nil");
    AssertTrue([reply[@"unique_proxy_identifier"] isEqualToString:@"UPI-MACOS26-1111"],
               @"start-call should include unique_proxy_identifier");

    // Verify status update payload before callUUID is populated
    NSDictionary *prePayload = [helper callStatusPayloadForCall:(TUCall *)call];
    AssertTrue([prePayload[@"call_uuid"] isEqualToString:@"UPI-MACOS26-1111"],
               @"status payload should fall back to uniqueProxyIdentifier while callUUID is nil");
    AssertTrue([prePayload[@"unique_proxy_identifier"] isEqualToString:@"UPI-MACOS26-1111"],
               @"status payload should carry unique_proxy_identifier");

    // Simulate callservicesd assigning real callUUID later while client still references UPI
    call.callUUID = @"REAL-CALL-UUID-2222";
    call.callStatus = 1; // active
    NSDictionary *postPayload = [helper callStatusPayloadForCall:(TUCall *)call];
    AssertTrue([postPayload[@"call_uuid"] isEqualToString:@"REAL-CALL-UUID-2222"],
               @"status payload should report real callUUID once populated");
    AssertTrue([postPayload[@"unique_proxy_identifier"] isEqualToString:@"UPI-MACOS26-1111"],
               @"status payload should continue reporting unique_proxy_identifier for server aliasing");

    // Client sends set-muted and leave-call using the initial UPI identifier
    MockNetworkController *muteNc = [[MockNetworkController alloc] init];
    [helper handleMessage:muteNc message:JsonString(@{
        @"action": @"set-muted",
        @"transactionId": @"tx-mute-by-upi",
        @"data": @{@"callUUID": @"UPI-MACOS26-1111", @"muted": @YES}
    })];
    AssertTrue(call.isUplinkMuted == YES, @"set-muted by uniqueProxyIdentifier should find call even after callUUID changes");
    AssertTrue([muteNc.sentMessages.lastObject[@"muted"] isEqual:@YES],
               @"set-muted reply should confirm muted state");

    [gDisconnectedCalls removeAllObjects];
    MockNetworkController *leaveNc = [[MockNetworkController alloc] init];
    [helper handleMessage:leaveNc message:JsonString(@{
        @"action": @"leave-call",
        @"transactionId": @"tx-leave-by-upi",
        @"data": @{@"callUUID": @"UPI-MACOS26-1111"}
    })];
    AssertTrue(gDisconnectedCalls.count == 1 && gDisconnectedCalls.firstObject == call,
               @"leave-call by uniqueProxyIdentifier should disconnect call");

    gNextDialCall = nil;
    [gMockCalls removeAllObjects];
    printf("PASS: TestTUProxyCallNilCallUUIDFallback\n");
}

@interface MockParticipant : NSObject
@property (nonatomic, getter=isLightweight) BOOL lightweight;
@property (nonatomic, getter=isLocalAccountHandle) BOOL localAccountHandle;
@end

@implementation MockParticipant
@end

@interface MockConversation : NSObject
@property (nonatomic, strong) NSUUID *UUID;
@property (nonatomic, strong) NSUUID *groupUUID;
@property (nonatomic, strong) MockConversationLink *link;
@property (nonatomic) NSInteger state;
@property (nonatomic, getter=isPendingConversation) BOOL pendingConversation;
@property (nonatomic) BOOL hasJoined;
@property (nonatomic) BOOL hasReceivedLetMeInRequest;
@property (nonatomic) NSInteger letMeInRequestState;
@property (nonatomic, copy) NSSet *pendingMembers;
@property (nonatomic, copy) NSSet *remoteMembers;
@property (nonatomic, copy) NSSet *activeRemoteParticipants;
@property (nonatomic, copy) NSSet *activeLightweightParticipants;
@end

@implementation MockConversation
@end

@interface BLUEBUBBLESFACETIMEHELPER (ConversationDebugTest)
- (NSDictionary *)conversationDebugDictionary:(id)convo;
@end

static void TestConversationDebugDictionary(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockParticipant *webUser = [[MockParticipant alloc] init];
    webUser.lightweight = YES;
    MockParticipant *callee = [[MockParticipant alloc] init];
    callee.lightweight = NO;
    callee.localAccountHandle = NO;

    MockConversationLink *link = [[MockConversationLink alloc] init];
    link.URL = [NSURL URLWithString:@"https://facetime.apple.com/join#v=1&p=monitor-test"];
    link.groupUUID = [NSUUID UUID];

    MockConversation *convo = [[MockConversation alloc] init];
    convo.UUID = [NSUUID UUID];
    convo.groupUUID = link.groupUUID;
    convo.link = link;
    convo.state = 2;
    convo.hasJoined = NO;
    convo.activeRemoteParticipants = [NSSet setWithObjects:webUser, callee, nil];
    convo.activeLightweightParticipants = [NSSet setWithObject:webUser];
    convo.remoteMembers = [NSSet set];
    convo.pendingMembers = [NSSet set];

    NSDictionary *dict = [helper conversationDebugDictionary:convo];
    AssertTrue([dict[@"link"] isEqualToString:@"https://facetime.apple.com/join#v=1&p=monitor-test"], @"Expected link in conversation debug dict");
    AssertTrue([dict[@"hasJoined"] isEqual:@NO], @"Expected hasJoined=NO");
    AssertTrue([dict[@"activeRemoteParticipantCount"] isEqual:@2], @"Expected 2 active remote participants");
    AssertTrue([dict[@"activeLightweightParticipantCount"] isEqual:@1], @"Expected 1 lightweight participant");
    AssertTrue([dict[@"activeNonLightweightParticipantCount"] isEqual:@1], @"Expected 1 non-lightweight participant");
    printf("PASS: TestConversationDebugDictionary\n");
}

@interface MockConversationMember : NSObject
@property (nonatomic, strong) TUHandle *handle;
@end
@implementation MockConversationMember
@end

static void TestSilencedAndFilteredCallPayload(BLUEBUBBLESFACETIMEHELPER *helper) {
    // 1. First-seen incoming status 6, never connected, filteredOutReason=6 -> is_incoming_silenced=YES
    MockCall *silenced = [[MockCall alloc] init];
    silenced.callUUID = @"silenced-uuid-1";
    silenced.callStatus = 6;
    silenced.outgoing = NO;
    silenced.dateConnected = nil;
    silenced.filteredOutReason = 6;
    NSDictionary *p1 = [helper callStatusPayloadForCall:(TUCall *)silenced];
    AssertTrue([p1[@"filtered_out_reason"] isEqual:@6], @"Expected filtered_out_reason == 6");
    AssertTrue([p1[@"is_incoming_silenced"] isEqual:@YES], @"First-seen incoming status 6 must set is_incoming_silenced=YES");

    // 2. Normal incoming call: status 4 first, then status 6 without connecting -> is_incoming_silenced=NO
    MockCall *normalMissed = [[MockCall alloc] init];
    normalMissed.callUUID = @"normal-missed-uuid-2";
    normalMissed.callStatus = 4;
    normalMissed.outgoing = NO;
    normalMissed.dateConnected = nil;
    normalMissed.filteredOutReason = 0;
    NSDictionary *p2a = [helper callStatusPayloadForCall:(TUCall *)normalMissed];
    AssertTrue([p2a[@"is_incoming_silenced"] isEqual:@NO], @"Status 4 must not be silenced");
    normalMissed.callStatus = 6;
    NSDictionary *p2b = [helper callStatusPayloadForCall:(TUCall *)normalMissed];
    AssertTrue([p2b[@"is_incoming_silenced"] isEqual:@NO], @"Call seen at status 4 before status 6 must set is_incoming_silenced=NO");

    // 3. First-seen status 6 that had connected or was outgoing -> is_incoming_silenced=NO
    MockCall *connectedCall = [[MockCall alloc] init];
    connectedCall.callUUID = @"connected-uuid-3";
    connectedCall.callStatus = 6;
    connectedCall.outgoing = NO;
    connectedCall.dateConnected = [NSDate date];
    AssertTrue([[helper callStatusPayloadForCall:(TUCall *)connectedCall][@"is_incoming_silenced"] isEqual:@NO], @"Connected call must set is_incoming_silenced=NO");

    MockCall *outgoingCall = [[MockCall alloc] init];
    outgoingCall.callUUID = @"outgoing-uuid-4";
    outgoingCall.callStatus = 6;
    outgoingCall.outgoing = YES;
    AssertTrue([[helper callStatusPayloadForCall:(TUCall *)outgoingCall][@"is_incoming_silenced"] isEqual:@NO], @"Outgoing call must set is_incoming_silenced=NO");

    printf("PASS: TestSilencedAndFilteredCallPayload\n");
}

static void TestImmediateObserversAndReplay(BLUEBUBBLESFACETIMEHELPER *helper) {
    // Verify immediate observer registration (no 5s delay)
    [helper initializeNetworkController];
    [gMockSharedNetworkController.sentMessages removeAllObjects];

    MockCall *ringing = [[MockCall alloc] init];
    ringing.callUUID = @"immediate-ring-uuid";
    ringing.callStatus = 4;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TUCallCenterCallStatusChangedNotification" object:ringing];
    AssertTrue(gMockSharedNetworkController.sentMessages.count == 1, @"Observer must fire immediately without 5s delay");
    AssertTrue([gMockSharedNetworkController.sentMessages.lastObject[@"data"][@"call_uuid"] isEqualToString:@"immediate-ring-uuid"], @"Expected immediate call status event");

    // Verify replayCurrentCallsToController: replays current TUCallCenter calls
    [gMockCalls removeAllObjects];
    gMockCalls[@"immediate-ring-uuid"] = ringing;
    MockNetworkController *nc = [[MockNetworkController alloc] init];
    [helper replayCurrentCallsToController:nc];
    AssertTrue(nc.sentMessages.count == 1, @"Expected 1 replayed call on connect");
    AssertTrue([nc.sentMessages.firstObject[@"event"] isEqualToString:@"ft-call-status-changed"], @"Expected ft-call-status-changed on replay");
    AssertTrue([nc.sentMessages.firstObject[@"data"][@"call_uuid"] isEqualToString:@"immediate-ring-uuid"], @"Expected replayed call_uuid");
    [gMockCalls removeAllObjects];

    printf("PASS: TestImmediateObserversAndReplay\n");
}

static void TestAnswerCallAndBatchedMessages(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockNetworkController *nc = [[MockNetworkController alloc] init];
    [gMockSharedNetworkController.sentMessages removeAllObjects];
    [gAnsweredCalls removeAllObjects];
    [gMockCalls removeAllObjects];

    // 1. Unknown call replies via replyController (not sharedInstance) with "Call not found!"
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"answer-call",
        @"transactionId": @"tx-a1",
        @"data": @{@"callUUID": @"missing-answer-uuid"}
    })];
    AssertTrue(nc.sentMessages.count == 1, @"answer-call error must reply via replyController");
    AssertTrue(gMockSharedNetworkController.sentMessages.count == 0, @"answer-call must not reply via sharedInstance");
    AssertTrue([nc.sentMessages.firstObject[@"error"] isEqualToString:@"Call not found!"], @"Expected Call not found! error");

    // 2. Batched }\n{ messages both execute
    MockCall *ringCall = [[MockCall alloc] init];
    ringCall.callUUID = @"batch-ring-uuid";
    ringCall.callStatus = 4;
    gMockCalls[@"batch-ring-uuid"] = ringCall;

    [nc.sentMessages removeAllObjects];
    NSString *m1 = JsonString(@{@"action": @"answer-call", @"transactionId": @"tx-b1", @"data": @{@"callUUID": @"batch-ring-uuid"}});
    NSString *m2 = JsonString(@{@"action": @"set-muted", @"transactionId": @"tx-b2", @"data": @{@"callUUID": @"batch-ring-uuid", @"muted": @YES}});
    [helper handleMessage:nc message:[NSString stringWithFormat:@"%@\n%@", m1, m2]];
    AssertTrue(gAnsweredCalls.count == 1 && gAnsweredCalls.firstObject == ringCall, @"First batched message must answer call");
    AssertTrue(ringCall.isUplinkMuted == YES, @"Second batched message must mute call");
    AssertTrue(nc.sentMessages.count == 2, @"Both batched messages must reply");
    AssertTrue([nc.sentMessages[0][@"transactionId"] isEqualToString:@"tx-b1"], @"Expected tx-b1 reply");
    AssertTrue([nc.sentMessages[1][@"transactionId"] isEqualToString:@"tx-b2"], @"Expected tx-b2 reply");

    [gMockCalls removeAllObjects];
    printf("PASS: TestAnswerCallAndBatchedMessages\n");
}

static void TestAdmitAnyPendingMemberAndInvalidateTimeout(BLUEBUBBLESFACETIMEHELPER *helper) {
    MockNetworkController *nc = [[MockNetworkController alloc] init];
    [gApprovedPendingMembers removeAllObjects];

    NSUUID *conv1UUID = [NSUUID UUID];
    NSUUID *conv2UUID = [NSUUID UUID];
    MockConversationMember *mem1 = [[MockConversationMember alloc] init];
    mem1.handle = [TUHandle handleWithDestinationID:@"alice@icloud.com"];
    MockConversationMember *mem2 = [[MockConversationMember alloc] init];
    mem2.handle = [TUHandle handleWithDestinationID:@"bob@icloud.com"];

    MockConversation *c1 = [[MockConversation alloc] init];
    c1.groupUUID = conv1UUID;
    c1.pendingMembers = [NSSet setWithObject:mem1];
    MockConversation *c2 = [[MockConversation alloc] init];
    c2.groupUUID = conv2UUID;
    c2.pendingMembers = [NSSet setWithObject:mem2];
    gMockActiveConversations = [NSMutableArray arrayWithObjects:c1, c2, nil];

    // Filtered by conversationUUID
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"admit-any-pending-member",
        @"transactionId": @"tx-admit-1",
        @"data": @{@"conversationUUID": [[conv1UUID UUIDString] lowercaseString]}
    })];
    AssertTrue(gApprovedPendingMembers.count == 1, @"Expected only 1 conversation's pending member approved");
    NSDictionary *admitData = nc.sentMessages.lastObject[@"data"];
    AssertTrue([admitData[@"admittedCount"] isEqual:@1], @"Expected admittedCount == 1");
    AssertTrue([admitData[@"admittedMembers"] count] == 1, @"Expected 1 admittedMembers entry");
    AssertTrue([admitData[@"admittedParticipants"] isEqualToArray:@[@"alice@icloud.com"]], @"Expected admittedParticipants string array");

    // invalidate-link timeout replies with error
    MockConversationLink *tLink = [[MockConversationLink alloc] init];
    tLink.URL = [NSURL URLWithString:@"https://facetime.apple.com/join#v=1&p=timeout"];
    tLink.groupUUID = [NSUUID UUID];
    gMockGeneratedLink = tLink;
    gSkipInvalidateCompletion = YES;
    [nc.sentMessages removeAllObjects];
    [helper handleMessage:nc message:JsonString(@{
        @"action": @"invalidate-link",
        @"transactionId": @"tx-inv-timeout",
        @"data": @{@"url": [tLink.URL absoluteString]}
    })];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5.2]];
    gSkipInvalidateCompletion = NO;
    AssertTrue(nc.sentMessages.count == 1 && nc.sentMessages.firstObject[@"error"] != nil, @"Expected invalidate-link timeout error reply");

    [gMockActiveConversations removeAllObjects];
    printf("PASS: TestAdmitAnyPendingMemberAndInvalidateTimeout\n");
}

int main(void) {
    @autoreleasepool {
        gMockCalls = [NSMutableDictionary dictionary];
        gDisconnectedCalls = [NSMutableArray array];
        gApprovedPendingMembers = [NSMutableArray array];
        gAnsweredCalls = [NSMutableArray array];
        gMockSharedNetworkController = [[MockNetworkController alloc] init];

        SwizzleSelector([NetworkController class], @selector(sharedInstance), @selector(bb_test_sharedInstance), YES);
        SwizzleSelector([TUCallCenter class], @selector(callWithCallUUID:), @selector(bb_test_callWithCallUUID:), NO);
        SwizzleSelector([TUCallCenter class], @selector(callWithUniqueProxyIdentifier:), @selector(bb_test_callWithUniqueProxyIdentifier:), NO);
        SwizzleSelector([TUCallCenter class], @selector(currentCalls), @selector(bb_test_currentCalls), NO);
        SwizzleSelector([TUCallCenter class], @selector(disconnectCall:), @selector(bb_test_disconnectCall:), NO);
        SwizzleSelector([TUCallCenter class], @selector(disconnectCall:withReason:), @selector(bb_test_disconnectCall:withReason:), NO);
        SwizzleSelector([TUCallCenter class], @selector(dialWithRequest:completionWithError:), @selector(bb_test_dialWithRequest:completionWithError:), NO);
        SwizzleSelector([TUCallCenter class], @selector(joinConversationWithConversationRequest:), @selector(bb_test_joinConversationWithConversationRequest:), NO);
        SwizzleSelector([TUCallCenter class], @selector(answerOrJoinCall:), @selector(bb_test_answerOrJoinCall:), NO);
        SwizzleSelector([TUConversationManager class], @selector(generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:), @selector(bb_test_generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:), NO);
        SwizzleSelector([TUConversationManager class], @selector(invalidateLink:completionHandler:), @selector(bb_test_invalidateLink:completionHandler:), NO);
        SwizzleSelector([TUConversationManager class], @selector(activatedConversationLinks), @selector(bb_test_activatedConversationLinks), NO);
        SwizzleSelector([TUConversationManager class], @selector(activeConversations), @selector(bb_test_activeConversations), NO);
        SwizzleSelector([TUConversationManager class], @selector(approvePendingMember:forConversation:), @selector(bb_test_approvePendingMember:forConversation:), NO);

        BLUEBUBBLESFACETIMEHELPER *helper = [BLUEBUBBLESFACETIMEHELPER sharedInstance];
        TestCallStatusMetadataSerialization(helper);
        TestSilencedAndFilteredCallPayload(helper);
        TestImmediateObserversAndReplay(helper);
        TestDeclineAndLeaveCall(helper);
        TestAnswerCallAndBatchedMessages(helper);
        TestAdmitAnyPendingMemberAndInvalidateTimeout(helper);
        TestSetMuted(helper);
        TestStartCall(helper);
        TestGenerateLink(helper);
        TestPlayDtmf(helper);
        TestNetworkControllerFramingAndTypeGuards(helper);
        TestTUProxyCallNilCallUUIDFallback(helper);
        TestConversationDebugDictionary(helper);

        // Test end-and-invalidate-call
        MockConversationLink *endLink = [[MockConversationLink alloc] init];
        endLink.URL = [NSURL URLWithString:@"https://facetime.apple.com/join#v=1&p=endtest"];
        endLink.groupUUID = [NSUUID UUID];
        gMockGeneratedLink = endLink;

        MockCall *endCall = [[MockCall alloc] init];
        endCall.callUUID = @"end-inv-uuid";
        endCall.callStatus = 1;
        gMockCalls[@"end-inv-uuid"] = endCall;
        gDidInvalidateLink = NO;
        [gDisconnectedCalls removeAllObjects];
        [helper handleMessage:gMockSharedNetworkController message:JsonString(@{
            @"action": @"end-and-invalidate-call",
            @"transactionId": @"tx-e1",
            @"data": @{@"callUUID": @"end-inv-uuid", @"url": [endLink.URL absoluteString]}
        })];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        AssertTrue([gDisconnectedCalls containsObject:endCall], @"Expected end-and-invalidate-call to disconnect call");
        AssertTrue(gDidInvalidateLink == YES, @"Expected end-and-invalidate-call to invalidate link");
        AssertTrue([gMockSharedNetworkController.sentMessages.lastObject[@"ended"] isEqual:@YES], @"Expected ended:true reply");
        printf("PASS: TestEndAndInvalidateCall\n");
        printf("ALL FACETIME HELPER TESTS PASSED\n");
    }
    return 0;
}
