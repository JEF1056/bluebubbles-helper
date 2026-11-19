@import AppKit;

#import <Foundation/Foundation.h>

#import "NetworkController.h"
#import "Logging.h"
#import "ZKSwizzle.h"
#import "TUConversationManager.h"
#import "TUConversationLink.h"
#import "TUConversationManagerXPCClient.h"
#import "TUProxyCall.h"
#import "TUAnswerRequest.h"
#import "TUCallCenter.h"
#import "TUConversation.h"
#import "TUConversationJoinRequest.h"
#import "TUConversationMember.h"
#import "CSDConversation.h"
#import "CSDConversationManager.h"
#import "TUCall.h"
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
- (instancetype)initWithProvider:(TUCallProvider *)provider;
@property (nonatomic, retain) TUHandle *handle;
@property (nonatomic, copy) NSSet<TUHandle *> *handles;
@property (nonatomic, getter=isVideo) BOOL video;
@property (nonatomic, readonly, getter=isValid) BOOL valid;
@end

@interface TUCallCenter (Dialing)
- (void)dialWithRequest:(id)request completionWithError:(void (^)(TUCall *call, NSError *error))completion;
@end

static NSString *BBExtractCallUUID(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    id val = data[@"callUUID"];
    if (![val isKindOfClass:[NSString class]]) val = data[@"call_uuid"];
    return ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) ? val : nil;
}

@interface BLUEBUBBLESFACETIMEHELPER : NSObject
+ (instancetype)sharedInstance;
- (NSDictionary *)callStatusPayloadForCall:(TUCall *)call;
- (void)callStatusChanged:(NSNotification *)notification;
- (void)handleMessage:(NetworkController *)controller message:(NSString *)message;
- (TUConversationManager *)sharedConversationManager;
- (void)sendGeneratedLinkReply:(TUConversationLink *)link error:(NSError *)error transaction:(NSString *)transaction replyController:(NetworkController *)replyController;
- (void)generateLinkForCallUUID:(NSString *)callUUID attemptsLeft:(NSInteger)attemptsLeft linkRetriesLeft:(NSInteger)linkRetriesLeft deadline:(NSDate *)deadline transaction:(NSString *)transaction replyController:(NetworkController *)replyController;
@end

// This can be used to dump the methods of any class
@interface NSObject (Private)
- (NSString*)_methodDescription;
@end

BLUEBUBBLESFACETIMEHELPER *plugin;

@implementation BLUEBUBBLESFACETIMEHELPER

- (TUConversationManager *)sharedConversationManager {
    TUConversationManager *manager = [[TUCallCenter sharedInstance] conversationManager];
    if (manager != nil) return manager;
    static TUConversationManager *fallbackManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fallbackManager = [[TUConversationManager alloc] init];
    });
    return fallbackManager;
}

- (void)sendGeneratedLinkReply:(TUConversationLink *)link
                         error:(NSError *)error
                   transaction:(NSString *)transaction
               replyController:(NetworkController *)replyController {
    if (transaction == nil) return;
    NSString *urlString = [[link URL] absoluteString];
    if ([urlString length] > 0) {
        [replyController sendMessage:@{@"transactionId": transaction, @"url": urlString}];
    } else {
        NSString *errMsg = error != nil ? ([error localizedDescription] ?: @"Failed to generate FaceTime link!") : @"Failed to generate FaceTime link!";
        [replyController sendMessage:@{@"transactionId": transaction, @"error": errMsg}];
    }
}

- (void)generateLinkForCallUUID:(NSString *)callUUID
                   attemptsLeft:(NSInteger)attemptsLeft
                linkRetriesLeft:(NSInteger)linkRetriesLeft
                       deadline:(NSDate *)deadline
                    transaction:(NSString *)transaction
                replyController:(NetworkController *)replyController {
    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    TUCall *call = [callCenter callWithCallUUID:callUUID];
    if (call == nil || [call callStatus] == 6) {
        if (transaction != nil) {
            [replyController sendMessage:@{@"transactionId": transaction, @"error": @"Call is no longer active!"}];
        }
        return;
    }

    NSTimeInterval remaining = deadline != nil ? [deadline timeIntervalSinceNow] : 0;
    TUConversation *convo = [callCenter activeConversationForCall:call];
    // Wait until callservicesd has joined/registered the conversation (avoids dropped XPC link completion).
    BOOL convoReady = convo != nil && (([convo respondsToSelector:@selector(hasJoined)] && [convo hasJoined]) ||
                                       ([convo respondsToSelector:@selector(state)] && [convo state] >= 2));
    if (!convoReady) {
        if (attemptsLeft > 0 && remaining > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                [self generateLinkForCallUUID:callUUID attemptsLeft:(attemptsLeft - 1) linkRetriesLeft:linkRetriesLeft deadline:deadline transaction:transaction replyController:replyController];
            });
            return;
        }
        if (convo == nil) {
            if (transaction != nil) {
                [replyController sendMessage:@{@"transactionId": transaction, @"error": @"No active conversation found for call!"}];
            }
            return;
        }
    }

    TUConversationLink *existingLink = [convo link];
    if ([[[existingLink URL] absoluteString] length] > 0) {
        [self sendGeneratedLinkReply:existingLink error:nil transaction:transaction replyController:replyController];
        return;
    }

    if (remaining <= 0) {
        [self sendGeneratedLinkReply:nil error:nil transaction:transaction replyController:replyController];
        return;
    }

    TUConversationManager *manager = [self sharedConversationManager];
    __block BOOL handled = NO;
    NSTimeInterval attemptTimeout = MIN(5.0, remaining);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attemptTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (handled) return;
        handled = YES;
        DLog("BLUEBUBBLESFACETIMEHELPER: generateLinkForConversation timed out (retriesLeft=%ld)", (long)linkRetriesLeft);
        if (linkRetriesLeft > 0 && [deadline timeIntervalSinceNow] > 0) {
            [self generateLinkForCallUUID:callUUID attemptsLeft:attemptsLeft linkRetriesLeft:(linkRetriesLeft - 1) deadline:deadline transaction:transaction replyController:replyController];
            return;
        }
        [self sendGeneratedLinkReply:[convo link] error:nil transaction:transaction replyController:replyController];
    });
    [manager generateLinkForConversation:convo completionHandler:^(TUConversationLink *arg0, NSError *arg1) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handled) return;
            handled = YES;
            DLog("BLUEBUBBLESFACETIMEHELPER: generated link for call %{public}@ (err=%{public}@)", [arg0 URL], arg1);
            TUConversationLink *resolvedLink = arg0 ?: [convo link];
            if ([[[resolvedLink URL] absoluteString] length] == 0 && linkRetriesLeft > 0 && [deadline timeIntervalSinceNow] > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [self generateLinkForCallUUID:callUUID attemptsLeft:attemptsLeft linkRetriesLeft:(linkRetriesLeft - 1) deadline:deadline transaction:transaction replyController:replyController];
                });
                return;
            }
            [self sendGeneratedLinkReply:resolvedLink error:arg1 transaction:transaction replyController:replyController];
        });
    }];
}

// BLUEBUBBLESFACETIMEHELPER is a singleton
+ (instancetype)sharedInstance {
    static BLUEBUBBLESFACETIMEHELPER *plugin = nil;
    @synchronized(self) {
        if (!plugin) {
            plugin = [[self alloc] init];
        }
    }
    return plugin;
}

// Helper method to log a long string
-(void) logString:(NSString*)logString{

        int stepLog = 800;
        NSInteger strLen = [@([logString length]) integerValue];
        NSInteger countInt = strLen / stepLog;

        if (strLen > stepLog) {
        for (int i=1; i <= countInt; i++) {
            NSString *character = [logString substringWithRange:NSMakeRange((i*stepLog)-stepLog, stepLog)];
            DLog("BLUEBUBBLESFACETIMEHELPER: %{public}@", character);

        }
        NSString *character = [logString substringWithRange:NSMakeRange((countInt*stepLog), strLen-(countInt*stepLog))];
            DLog("BLUEBUBBLESFACETIMEHELPER: %{public}@", character);
        } else {

            DLog("BLUEBUBBLESFACETIMEHELPER: %{public}@", logString);
        }

}

// Called when macforge initializes the plugin
+ (void)load {
    // Create the singleton
    plugin = [BLUEBUBBLESFACETIMEHELPER sharedInstance];

    // Get OS version for debugging purposes
    NSUInteger major = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
    NSUInteger minor = [[NSProcessInfo processInfo] operatingSystemVersion].minorVersion;
    DLog("BLUEBUBBLESFACETIMEHELPER: %{public}@ loaded into %{public}@ on macOS %ld.%ld", [self className], [[NSBundle mainBundle] bundleIdentifier], (long)major, (long)minor);

    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.FaceTime"] || [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.TelephonyUtilities"]) {
        DLog("BLUEBUBBLESFACETIMEHELPER: Initializing Connection...");
        [plugin initializeNetworkController];
    } else {
        DLog("BLUEBUBBLESFACETIMEHELPER: Injected into non-FaceTime process %@, aborting.", [[NSBundle mainBundle] bundleIdentifier]);
        return;
    }
}

-(void) DumpObjcMethods:(Class) clz {

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(clz, &methodCount);

    DLog("BLUEBUBBLESFACETIMEHELPER: Found %d methods on '%s'\n", methodCount, class_getName(clz));

    for (unsigned int i = 0; i < methodCount; i++) {
        Method method = methods[i];

        DLog("\tBLUEBUBBLESFACETIMEHELPER: '%s' has method named '%s' of encoding '%s'\n",
               class_getName(clz),
               sel_getName(method_getName(method)),
               method_getTypeEncoding(method));
    }

    free(methods);
}

// Private method to initialize all the things required by the plugin to communicate with the main
// server over a tcp socket
-(void) initializeNetworkController {
    // Get the network controller
    NetworkController *controller = [NetworkController sharedInstance];
    [controller connect];

    // Upon receiving a message
    controller.messageReceivedBlock =  ^(NetworkController *controller, NSString *data) {
        [self handleMessage:controller message: data];
    };
    NSDictionary *message = @{@"event": @"ping", @"message": @"Helper Connected!"};
    [controller sendMessage:message];

    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        DLog("BLUEBUBBLESFACETIMEHELPER: Registering call listeners...");

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callStatusChanged:) name:@"TUCallCenterVideoCallStatusChangedNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callStatusChanged:) name:@"TUCallCenterCallStatusChangedNotification" object:nil];
        
        // [self handleMessage:controller message:@"{\"action\":\"invalidate-link\",\"transactionId\":\"bruh\",\"data\":{\"url\":\"https://facetime.apple.com/join#v=1&p=5rYoTVvAEe6LSjJziwUUiw&k=h9yNjziqokL3lLK-JEq-1_uae-KCvqKvayGsrkdNmGg\"}}"];
    });
}

-(NSDictionary *) callStatusPayloadForCall:(TUCall *)call {
    if (call == nil) return nil;
    id provider = [call respondsToSelector:@selector(provider)] ? [call provider] : nil;
    NSString *providerIdentifier = [provider respondsToSelector:@selector(identifier)] ? [(TUCallProvider *)provider identifier] : nil;
    BOOL isTelephonyProvider = [provider respondsToSelector:@selector(isTelephonyProvider)] && [(TUCallProvider *)provider isTelephonyProvider];
    BOOL isFaceTimeProvider = [provider respondsToSelector:@selector(isFaceTimeProvider)] && [(TUCallProvider *)provider isFaceTimeProvider];
    BOOL isHostedOnCurrentDevice = [call respondsToSelector:@selector(isHostedOnCurrentDevice)] ? [call isHostedOnCurrentDevice] : YES;
    BOOL isTelephony = isTelephonyProvider || (!isFaceTimeProvider && !isHostedOnCurrentDevice);
    BOOL isVideo = [call respondsToSelector:@selector(isVideo)] ? [call isVideo] : [call isSendingVideo];

    return @{
        @"audio_mode": [call audioMode] ?: [NSNull null],
        @"call_status": [NSNumber numberWithInt:[call callStatus]] ?: [NSNull null],
        @"call_uuid": [call callUUID] ?: [NSNull null],
        @"is_conversation": [NSNumber numberWithBool:[call isConversation]] ?: [NSNull null],
        @"disconnected_reason": [NSNumber numberWithInt:[call disconnectedReason]] ?: [NSNull null],
        @"ended_error": [call endedErrorString] ?: [NSNull null],
        @"ended_reason": [call endedReasonString] ?: [NSNull null],
        @"handle": [[call handle] dictionaryRepresentation] ?: [NSNull null],
        @"is_sending_audio": [NSNumber numberWithBool:[call isSendingAudio]] ?: [NSNull null],
        @"is_sending_video": [NSNumber numberWithBool:[call isSendingVideo]] ?: [NSNull null],
        @"is_outgoing": [NSNumber numberWithBool:[call isOutgoing]] ?: [NSNull null],
        @"is_video": [NSNumber numberWithBool:isVideo],
        @"is_telephony": [NSNumber numberWithBool:isTelephony],
        @"provider_identifier": providerIdentifier ?: [NSNull null],
    };
}

-(void) callStatusChanged: (NSNotification *)notification {
    TUCall *call = [notification object];
    NSDictionary *data = [self callStatusPayloadForCall:call];
    if (data == nil) return;
    [[NetworkController sharedInstance] sendMessage: @{@"event": @"ft-call-status-changed", @"data": data}];
}

-(NSArray<TUConversation*>*) conversationCandidatesForManager:(TUConversationManager*)manager {
    NSMutableArray<TUConversation*> *conversations = [[NSMutableArray alloc] init];
    NSMutableSet<NSString*> *seen = [[NSMutableSet alloc] init];

    void (^addConversation)(TUConversation*) = ^(TUConversation *convo) {
        if (convo == nil) return;
        NSString *uuid = [[convo groupUUID] UUIDString] ?: [[convo UUID] UUIDString] ?: [convo description];
        if ([seen containsObject:uuid]) return;
        [seen addObject:uuid];
        [conversations addObject:convo];
    };

    for (TUConversation *convo in [manager activeConversations]) {
        addConversation(convo);
    }

    if ([manager respondsToSelector:@selector(incomingPendingConversations)]) {
        for (TUConversation *convo in [manager incomingPendingConversations]) {
            addConversation(convo);
        }
    }

    return conversations;
}

-(NSDictionary*) conversationDebugDictionary:(TUConversation*)convo {
    NSMutableArray *pendingMembers = [[NSMutableArray alloc] init];
    for (TUConversationMember *member in [convo pendingMembers]) {
        [pendingMembers addObject:@{
            @"handleUUID": [[[member handle] value] description] ?: [NSNull null],
            @"description": [member description] ?: [NSNull null],
            @"joinedFromLetMeIn": [NSNumber numberWithBool:[member joinedFromLetMeIn]],
            @"dateReceivedLetMeIn": [member dateReceivedLetMeIn] ? [NSNumber numberWithDouble:[[member dateReceivedLetMeIn] timeIntervalSince1970] * 1000] : [NSNull null],
        }];
    }

    return @{
        @"uuid": [[convo UUID] UUIDString] ?: [NSNull null],
        @"groupUUID": [[convo groupUUID] UUIDString] ?: [NSNull null],
        @"state": [NSNumber numberWithInteger:[convo state]],
        @"pendingConversation": [NSNumber numberWithBool:[convo isPendingConversation]],
        @"hasJoined": [NSNumber numberWithBool:[convo hasJoined]],
        @"hasReceivedLetMeInRequest": [NSNumber numberWithBool:[convo hasReceivedLetMeInRequest]],
        @"letMeInRequestState": [NSNumber numberWithInteger:[convo letMeInRequestState]],
        @"pendingMemberCount": [NSNumber numberWithUnsignedInteger:[[convo pendingMembers] count]],
        @"remoteMemberCount": [NSNumber numberWithUnsignedInteger:[[convo remoteMembers] count]],
        @"activeRemoteParticipantCount": [NSNumber numberWithUnsignedInteger:[[convo activeRemoteParticipants] count]],
        @"pendingMembers": pendingMembers,
    };
}

// Run when receiving a new message from the tcp socket
-(void) handleMessage: (NetworkController*)controller  message:(NSString *)message {
    // The data is in the form of a json string, so we need to convert it to a NSDictionary
    // for some reason the data is sometimes duplicated, so account for that
    NSRange range = [message rangeOfString:@"}\n{"];
    if(range.location != NSNotFound) {
        message = [message substringWithRange:NSMakeRange(0, range.location + 1)];
    }
    DLog("BLUEBUBBLESFACETIMEHELPER: Received raw json: %{public}@", message);
    NSError *error;
    NSData *jsonData = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&error];

    // Event is the type of packet that was sent
    NSString *event = dictionary[@"action"];
    // Data is the actual information that we need in the packet
    NSDictionary *data = dictionary[@"data"];
    // Transaction ID enables us to communicate back to the server that the action was complete
    NSString *transaction = nil;
    if ([dictionary objectForKey:(@"transactionId")] != [NSNull null]) {
        transaction = dictionary[@"transactionId"];
    }

    DLog("BLUEBUBBLESFACETIMEHELPER: Message received: %{public}@, %{public}@", event, data);
    
    if ([event isEqualToString:@"answer-call"]) {
        TUCall *call = [[TUCallCenter sharedInstance] callWithCallUUID:(data[@"callUUID"])];
        
        if ([call callStatus] != 4) {
            if (transaction != nil) {
                [[NetworkController sharedInstance] sendMessage: @{@"transactionId": transaction, @"error": @"Call is not waiting to be answered!"}];
            }
            return;
        }
        
        [[TUCallCenter sharedInstance] answerOrJoinCall:call];
        if (transaction != nil) {
            [[NetworkController sharedInstance] sendMessage: @{@"transactionId": transaction}];
        }
    } else if ([event isEqualToString:@"leave-call"] || [event isEqualToString:@"decline-call"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        NSString *callUUID = BBExtractCallUUID(data);
        TUCall *call = callUUID != nil ? [[TUCallCenter sharedInstance] callWithCallUUID:callUUID] : nil;
        int status = call != nil ? [call callStatus] : 0;

        if (call == nil || (status != 1 && status != 3 && status != 4)) {
            if (transaction != nil) {
                [replyController sendMessage: @{
                    @"transactionId": transaction,
                    @"error": call == nil ? @"Call not found!" : @"Call is not active, dialing, or ringing!"
                }];
            }
            return;
        }

        [[TUCallCenter sharedInstance] disconnectCall:call];
        if (transaction != nil) {
            [replyController sendMessage: @{@"transactionId": transaction}];
        }
    } else if ([event isEqualToString:@"set-muted"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        NSString *callUUID = BBExtractCallUUID(data);
        TUCall *call = callUUID != nil ? [[TUCallCenter sharedInstance] callWithCallUUID:callUUID] : nil;
        if (call == nil) {
            if (transaction != nil) {
                [replyController sendMessage: @{@"transactionId": transaction, @"error": @"Call not found!"}];
            }
            return;
        }

        id mutedVal = [data isKindOfClass:[NSDictionary class]] ? data[@"muted"] : nil;
        if (mutedVal == nil || mutedVal == [NSNull null] || ![mutedVal respondsToSelector:@selector(boolValue)]) {
            if (transaction != nil) {
                [replyController sendMessage: @{@"transactionId": transaction, @"error": @"Missing muted flag!"}];
            }
            return;
        }

        BOOL muted = [mutedVal boolValue];
        [call setUplinkMuted:muted];
        if (transaction != nil) {
            [replyController sendMessage: @{@"transactionId": transaction, @"muted": @(muted)}];
        }
    } else if ([event isEqualToString:@"generate-link"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        NSString *callUUID = BBExtractCallUUID(data);
        if (callUUID != nil) {
            [self generateLinkForCallUUID:callUUID attemptsLeft:40 linkRetriesLeft:2 deadline:[NSDate dateWithTimeIntervalSinceNow:15.0] transaction:transaction replyController:replyController];
        } else {
            TUConversationManager *manager = [self sharedConversationManager];
            if (manager == nil) {
                if (transaction != nil) {
                    [replyController sendMessage:@{@"transactionId": transaction, @"error": @"TUConversationManager unavailable!"}];
                }
                return;
            }
            if ([manager respondsToSelector:@selector(generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:)]) {
                [manager generateLinkWithInvitedMemberHandles:@[] linkLifetimeScope:0 completionHandler:^(TUConversationLink *arg0, NSError *arg1) {
                    [self sendGeneratedLinkReply:arg0 error:arg1 transaction:transaction replyController:replyController];
                }];
            } else if (transaction != nil) {
                [replyController sendMessage:@{@"transactionId": transaction, @"error": @"Failed to generate generic link!"}];
            }
        }
    } else if ([event isEqualToString:@"admit-pending-member"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        id rawConvUUID = data[@"conversationUUID"];
        id rawHandleUUID = data[@"handleUUID"];
        if (![rawConvUUID isKindOfClass:[NSString class]] || [(NSString *)rawConvUUID length] == 0 ||
            ![rawHandleUUID isKindOfClass:[NSString class]] || [(NSString *)rawHandleUUID length] == 0) {
            if (transaction != nil) {
                [replyController sendMessage:@{@"transactionId": transaction, @"error": @"conversationUUID and handleUUID are required!"}];
            }
            return;
        }
        NSString *targetConvUUID = (NSString *)rawConvUUID;
        NSString *targetHandleUUID = (NSString *)rawHandleUUID;
        TUConversationManager *manager = [self sharedConversationManager];
        TUConversation *convo = nil;

        for (TUConversation *i in [self conversationCandidatesForManager:manager]) {
            if ([[[i groupUUID] UUIDString] isEqualToString:targetConvUUID]) {
                convo = i;
                break;
            }
        }

        BOOL admitted = NO;
        if (convo != nil) {
            for (TUConversationMember *member in [convo pendingMembers]) {
                if ([[[member handle] value] isEqualToString:targetHandleUUID]) {
                    [manager approvePendingMember:member forConversation:convo];
                    admitted = YES;
                    break;
                }
            }
        }

        if (transaction != nil) {
            if (admitted) {
                [replyController sendMessage:@{@"transactionId": transaction}];
            } else {
                [replyController sendMessage:@{@"transactionId": transaction, @"error": @"Pending member or conversation not found!"}];
            }
        }
    } else if ([event isEqualToString:@"admit-any-pending-member"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        TUConversationManager *manager = [self sharedConversationManager];
        NSMutableArray *admittedMembers = [[NSMutableArray alloc] init];

        for (TUConversation *convo in [self conversationCandidatesForManager:manager]) {
            for (TUConversationMember *member in [convo pendingMembers]) {
                DLog("BLUEBUBBLESFACETIMEHELPER: approving pending member %{public}@", member);
                [manager approvePendingMember:member forConversation:convo];
                [admittedMembers addObject:@{
                    @"conversationUUID": [[convo groupUUID] UUIDString] ?: [NSNull null],
                    @"handleUUID": [[[member handle] value] description] ?: [NSNull null],
                }];
            }
        }

        if (transaction != nil) {
            [replyController sendMessage:@{
                @"transactionId": transaction,
                @"data": @{
                    @"admittedCount": @([admittedMembers count]),
                    @"admittedMembers": admittedMembers,
                },
            }];
        }
    } else if ([event isEqualToString:@"get-conversation-state"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        TUConversationManager *manager = [self sharedConversationManager];
        NSMutableArray *conversations = [[NSMutableArray alloc] init];
        for (TUConversation *convo in [self conversationCandidatesForManager:manager]) {
            [conversations addObject:[self conversationDebugDictionary:convo]];
        }

        if (transaction != nil) {
            [replyController sendMessage:@{
                @"transactionId": transaction,
                @"data": @{
                    @"conversationCount": @([conversations count]),
                    @"conversations": conversations,
                },
            }];
        }
    } else if ([event isEqualToString:@"get-active-links"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        TUConversationManager *manager = [self sharedConversationManager];
        NSArray<TUConversationLink*>* links = [[manager activatedConversationLinks] allObjects];
        
        NSMutableArray *linkArray = [NSMutableArray array];
        for (TUConversationLink* link in links) {
            NSMutableArray *handleArray = [NSMutableArray array];
            [[[link invitedMemberHandles] allObjects] enumerateObjectsUsingBlock:^(TUHandle* obj, NSUInteger idx, BOOL *stop) {
                [handleArray addObject:[obj dictionaryRepresentation]];
            }];
            NSDictionary* linkData = @{
                @"url": [[link URL] absoluteString] ?: [NSNull null],
                @"creation_date": [NSNumber numberWithDouble:([[link creationDate] timeIntervalSince1970] * 1000)] ?: [NSNull null],
                @"expiration_date": [NSNumber numberWithDouble:([[link expirationDate] timeIntervalSince1970] * 1000)] ?: [NSNull null],
                @"group_uuid": [[link groupUUID] UUIDString] ?: [NSNull null],
                @"name": [link linkName] ?: [NSNull null],
                @"handles": handleArray ?: [NSNull null],
            };
            [linkArray addObject:linkData];
        }
        
        if (transaction != nil) {
            [replyController sendMessage:@{@"transactionId": transaction, @"data": @{@"links": linkArray}}];
        }
    } else if ([event isEqualToString:@"invalidate-link"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        TUConversationManager *manager = [self sharedConversationManager];
        NSArray<TUConversationLink*>* links = [[manager activatedConversationLinks] allObjects];
        NSString *targetUrl = data[@"url"];
        BOOL invalidated = NO;
        
        for (TUConversationLink* link in links) {
            if ([[[link URL] absoluteString] isEqualToString:targetUrl]) {
                if ([manager respondsToSelector:@selector(invalidateLink:completionHandler:)]) {
                    [manager invalidateLink:link completionHandler:^(char arg0, NSError* arg1) {
                        if (transaction != nil) {
                            [replyController sendMessage:@{@"transactionId": transaction}];
                        }
                    }];
                } else {
                    TUConversationManagerXPCClient *client = [[TUConversationManagerXPCClient alloc] init];
                    [client invalidateLink:link completionHandler:^(char arg0, NSError* arg1) {
                        if (transaction != nil) {
                            [replyController sendMessage:@{@"transactionId": transaction}];
                        }
                    }];
                }
                invalidated = YES;
                break;
            }
        }
        if (!invalidated && transaction != nil) {
            [replyController sendMessage:@{@"transactionId": transaction, @"error": @"Link not found to invalidate!"}];
        }
    } else if ([event isEqualToString:@"start-call"]) {
        NetworkController *replyController = controller ?: [NetworkController sharedInstance];
        id rawAddresses = [data isKindOfClass:[NSDictionary class]] ? data[@"addresses"] : nil;
        NSMutableArray<TUHandle *> *handles = [NSMutableArray array];
        if ([rawAddresses isKindOfClass:[NSArray class]]) {
            for (id addr in (NSArray *)rawAddresses) {
                if ([addr isKindOfClass:[NSString class]] && [(NSString *)addr length] > 0) {
                    TUHandle *handle = [TUHandle handleWithDestinationID:addr];
                    if (handle != nil) {
                        [handles addObject:handle];
                    }
                }
            }
        }
        if ([handles count] == 0) {
            if (transaction != nil) {
                [replyController sendMessage: @{@"transactionId": transaction, @"error": @"No valid addresses provided!"}];
            }
            return;
        }

        BOOL video = [data[@"video"] respondsToSelector:@selector(boolValue)] ? [data[@"video"] boolValue] : NO;
        BOOL isTelephony = [data[@"isTelephony"] respondsToSelector:@selector(boolValue)] ? [data[@"isTelephony"] boolValue] : NO;

        TUCallCenter *callCenter = [TUCallCenter sharedInstance];
        TUCallProviderManager *providerManager = (TUCallProviderManager *)[callCenter providerManager];
        if (providerManager == nil) {
            Class pmClass = NSClassFromString(@"TUCallProviderManager");
            providerManager = pmClass != Nil ? [[pmClass alloc] init] : nil;
        }

        TUCallProvider *provider = isTelephony ? [providerManager telephonyProvider] : [providerManager faceTimeProvider];
        if (provider == nil) {
            if (transaction != nil) {
                [replyController sendMessage: @{@"transactionId": transaction, @"error": @"Requested call provider is unavailable!"}];
            }
            return;
        }

        Class dialReqClass = NSClassFromString(@"TUDialRequest");
        TUDialRequest *request = dialReqClass != Nil ? [[dialReqClass alloc] initWithProvider:provider] : nil;
        if (request == nil) {
            if (transaction != nil) {
                [replyController sendMessage: @{@"transactionId": transaction, @"error": @"TUDialRequest is unavailable!"}];
            }
            return;
        }

        if ([handles count] == 1) {
            request.handle = [handles firstObject];
        } else {
            request.handles = [NSSet setWithArray:handles];
        }
        request.video = isTelephony ? NO : video;

        if (![request isValid]) {
            if (transaction != nil) {
                [replyController sendMessage: @{@"transactionId": transaction, @"error": @"Invalid dial request!"}];
            }
            return;
        }

        void (^finishDial)(TUCall *, NSError *) = ^(TUCall *call, NSError *dialError) {
            if (transaction == nil) return;
            if (dialError != nil || call == nil) {
                [replyController sendMessage: @{
                    @"transactionId": transaction,
                    @"error": dialError != nil ? ([dialError localizedDescription] ?: @"Failed to start call!") : @"Failed to start call!"
                }];
                return;
            }
            NSMutableDictionary *response = [([self callStatusPayloadForCall:call] ?: @{}) mutableCopy];
            response[@"transactionId"] = transaction;
            response[@"call_uuid"] = [call callUUID] ?: [NSNull null];
            [replyController sendMessage:response];
        };

        if ([callCenter respondsToSelector:@selector(dialWithRequest:completionWithError:)]) {
            [callCenter dialWithRequest:request completionWithError:finishDial];
        } else {
            [callCenter dialWithRequest:request completion:^(TUCall *call) {
                finishDial(call, nil);
            }];
        }
    }
}

@end


//ZKSwizzleInterface(BBH_NSNotificationCenter, NSNotificationCenter, NSObject)
//@implementation BBH_NSNotificationCenter
//
//- (void)addObserver:(id)observer selector:(SEL)aSelector name:(nullable NSNotificationName)aName object:(nullable id)anObject {
//    if ([aName isEqualToString:@"CNContactStoreDidChangeNotification"]) {
//        return ZKOrig(void, observer, aSelector, aName, anObject);
//    }
//    DLog("BLUEBUBBLESFACETIMEHELPER: >>>>>>>>>>>>> name %{public}@", aName);
//    DLog("BLUEBUBBLESFACETIMEHELPER: observer %{public}@", observer);
//    DLog("BLUEBUBBLESFACETIMEHELPER: sel %{public}@", NSStringFromSelector(aSelector));
//    DLog("BLUEBUBBLESFACETIMEHELPER: object %{public}@", anObject);
//    return ZKOrig(void, observer, aSelector, aName, anObject);
//}
//
//@end


//ZKSwizzleInterface(WBWT_TUConversationManager, TUConversationManager, NSObject)
//@implementation WBWT_TUConversationManager
//
//-(void)receivedTrackedPendingMember:(TUConversationMember*)member forConversationLink:(TUConversationLink*)link {
//    NSDictionary *data = @{
//        @"letmein_received": [NSNumber numberWithDouble:[[member dateReceivedLetMeIn] timeIntervalSince1970] * 1000] ?: [NSNull null],
//        @"letmein_initiated": [NSNumber numberWithDouble:[[member dateInitiatedLetMeIn] timeIntervalSince1970] * 1000] ?: [NSNull null],
//        @"handle": [[member handle] dictionaryRepresentation],
//        @"name": [member nickname],
//        @"link": [[link URL] absoluteString],
//    };
//    DLog("BLUEBUBBLESFACETIMEHELPER: object %{public}@", [[[TUConversationManager alloc] init] activeConversationWithGroupUUID:([link groupUUID])]);
//    [[NetworkController sharedInstance] sendMessage: @{@"event": @"received-pending-member", @"data": data}];
//    return ZKOrig(void, member, link);
//}
//
//@end
//
//ZKSwizzleInterface(WBWT_NSUserNotification, CSDConversation, NSObject)
//@implementation WBWT_NSUserNotification
//
//- (void)addPendingMembers:(id)arg1 triggeredLocally:(BOOL)arg2 {
//    DLog("BLUEBUBBLESFACETIMEHELPER: got pending member %{public}@", arg1);
////    NSUUID *guid = (NSUUID *)ZKHookIvar(self, NSUUID*, "_groupUUID");
////    DLog("BLUEBUBBLESFACETIMEHELPER: convo %{public}@", guid);
////    //DLog("BLUEBUBBLESFACETIMEHELPER: convo 2 %{public}@", [[[TUConversationManager alloc] init] activeConversations]);
////    DLog("BLUEBUBBLESFACETIMEHELPER: convo %{public}@", NSClassFromString(@"CSDConversationManager"));
//    // [[[TUConversationManagerXPCClient alloc] init] approvePendingMember:[arg1 firstObject] forConversation:([[[[TUConversationManager alloc] init] activeConversationWithGroupUUID:guid] firstObject])];
//    return ZKOrig(void, arg1, arg2);
//}
//
//@end
