@import AppKit;

#import <Foundation/Foundation.h>
#import <objc/message.h>

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

static NSString *BBNonEmptyString(id value) {
    return ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) ? (NSString *)value : nil;
}

static NSString *BBExtractCallUUID(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    NSString *val = BBNonEmptyString(data[@"callUUID"]);
    if (val == nil) val = BBNonEmptyString(data[@"call_uuid"]);
    if (val == nil) val = BBNonEmptyString(data[@"uniqueProxyIdentifier"]);
    if (val == nil) val = BBNonEmptyString(data[@"unique_proxy_identifier"]);
    return val;
}

static NSString *BBCallUniqueProxyIdentifier(TUCall *call) {
    if (call == nil) return nil;
    if ([call respondsToSelector:@selector(uniqueProxyIdentifier)]) {
        NSString *upi = BBNonEmptyString([call uniqueProxyIdentifier]);
        if (upi != nil) return upi;
    }
    if ([call respondsToSelector:@selector(uniqueProxyIdentifierUUID)]) {
        NSUUID *uuid = [call uniqueProxyIdentifierUUID];
        if ([uuid isKindOfClass:[NSUUID class]]) {
            NSString *s = BBNonEmptyString([uuid UUIDString]);
            if (s != nil) return s;
        }
    }
    return nil;
}

// macOS 26.4+ TUProxyCall leaves _callUUID nil until callservicesd sends updateWithCall:,
// while uniqueProxyIdentifier is populated immediately at dial/join creation.
static NSString *BBResolvedCallUUID(TUCall *call) {
    if (call == nil) return nil;
    if ([call respondsToSelector:@selector(callUUID)]) {
        NSString *uuid = BBNonEmptyString([call callUUID]);
        if (uuid != nil) return uuid;
    }
    NSString *upi = BBCallUniqueProxyIdentifier(call);
    if (upi != nil) return upi;
    if ([call respondsToSelector:@selector(callGroupUUID)]) {
        NSUUID *groupUUID = [call callGroupUUID];
        if ([groupUUID isKindOfClass:[NSUUID class]]) {
            NSString *s = BBNonEmptyString([groupUUID UUIDString]);
            if (s != nil) return s;
        }
    }
    return nil;
}

static TUCall *BBFindCallByIdentifier(TUCallCenter *callCenter, NSString *identifier) {
    NSString *target = BBNonEmptyString(identifier);
    if (callCenter == nil || target == nil) return nil;
    TUCall *call = [callCenter callWithCallUUID:target];
    if (call != nil) return call;
    if ([callCenter respondsToSelector:@selector(callWithUniqueProxyIdentifier:)]) {
        call = [callCenter callWithUniqueProxyIdentifier:target];
        if (call != nil) return call;
    }
    NSArray<TUCall *> *lists[3] = {
        [callCenter respondsToSelector:@selector(currentCalls)] ? [callCenter currentCalls] : nil,
        [callCenter respondsToSelector:@selector(incomingCalls)] ? [callCenter incomingCalls] : nil,
        [callCenter respondsToSelector:@selector(callsHostedElsewhere)] ? [callCenter callsHostedElsewhere] : nil,
    };
    for (int i = 0; i < 3; i++) {
        for (TUCall *candidate in lists[i]) {
            NSString *candidateUUID = [candidate respondsToSelector:@selector(callUUID)] ? BBNonEmptyString([candidate callUUID]) : nil;
            if ([candidateUUID isEqualToString:target] ||
                [BBCallUniqueProxyIdentifier(candidate) isEqualToString:target]) {
                return candidate;
            }
        }
    }
    return nil;
}

static void BBSendReply(NetworkController *controller, NSString *transaction, NSDictionary *extra) {
    if (transaction == nil) return;
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:(extra ?: @{})];
    payload[@"transactionId"] = transaction;
    [(controller ?: [NetworkController sharedInstance]) sendMessage:payload];
}

@interface BLUEBUBBLESFACETIMEHELPER : NSObject {
    BOOL _listenersRegistered;
    id _conversationHandoffDelegate;
}
+ (instancetype)sharedInstance;
- (void)callStatusChanged:(NSNotification *)notification;
- (void)replayCurrentCallsToController:(NetworkController *)controller;
- (void)handleMessage:(NetworkController *)controller message:(NSString *)message;
@end

@interface BLUEBUBBLESFACETIMEHELPER (Fork)
- (NSDictionary *)callStatusPayloadForCall:(TUCall *)call;
- (TUConversationManager *)sharedConversationManager;
- (void)sendGeneratedLinkReply:(TUConversationLink *)link error:(NSError *)error transaction:(NSString *)transaction replyController:(NetworkController *)replyController;
- (void)generateLinkForCallUUID:(NSString *)callUUID attemptsLeft:(NSInteger)attemptsLeft linkRetriesLeft:(NSInteger)linkRetriesLeft deadline:(NSDate *)deadline transaction:(NSString *)transaction replyController:(NetworkController *)replyController;
- (NSArray<TUConversation *> *)conversationCandidatesForManager:(TUConversationManager *)manager;
- (NSDictionary *)conversationDebugDictionary:(TUConversation *)convo;
- (void)emitHandoffEligibleConversation:(TUConversation *)convo toController:(NetworkController *)controller;
- (void)replayHandoffEligibleConversationToController:(NetworkController *)controller;
- (BOOL)handleForkMessage:(NetworkController *)replyController event:(NSString *)event data:(NSDictionary *)data transaction:(NSString *)transaction;
@end

// This can be used to dump the methods of any class
@interface NSObject (Private)
- (NSString*)_methodDescription;
@end

BLUEBUBBLESFACETIMEHELPER *plugin;

@implementation BLUEBUBBLESFACETIMEHELPER

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
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.FaceTime"] && ![bundleID isEqualToString:@"com.apple.TelephonyUtilities"]) {
        DLog("BLUEBUBBLESFACETIMEHELPER: Injected into non-FaceTime process %@, aborting.", bundleID);
        return;
    }

    // Defer initialization to avoid work under dyld loader lock
    dispatch_async(dispatch_get_main_queue(), ^{
        plugin = [BLUEBUBBLESFACETIMEHELPER sharedInstance];

        NSUInteger major = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
        NSUInteger minor = [[NSProcessInfo processInfo] operatingSystemVersion].minorVersion;
        DLog("BLUEBUBBLESFACETIMEHELPER: %{public}@ loaded into %{public}@ on macOS %ld.%ld", [self className], bundleID, (long)major, (long)minor);

        DLog("BLUEBUBBLESFACETIMEHELPER: Deferring connection until app launch...");
        if (NSApp != nil && [NSApp isRunning]) {
            [plugin initializeNetworkController];
        } else {
            __block id launchObserver = nil;
            launchObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                                               object:nil
                                                                                queue:[NSOperationQueue mainQueue]
                                                                           usingBlock:^(NSNotification * _Nonnull note) {
                (void)note;
                if (launchObserver != nil) {
                    [[NSNotificationCenter defaultCenter] removeObserver:launchObserver];
                    launchObserver = nil;
                }
                DLog("BLUEBUBBLESFACETIMEHELPER: App finished launching; initializing connection...");
                [plugin initializeNetworkController];
            }];
        }
    });
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

    if (!_listenersRegistered) {
        _listenersRegistered = YES;
        DLog("BLUEBUBBLESFACETIMEHELPER: Registering call listeners...");
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callStatusChanged:) name:@"TUCallCenterVideoCallStatusChangedNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(callStatusChanged:) name:@"TUCallCenterCallStatusChangedNotification" object:nil];
        TUConversationManager *manager = [self sharedConversationManager];
        Class delegateCls = NSClassFromString(@"BBConversationHandoffDelegate");
        if (manager != nil && delegateCls != Nil && [manager respondsToSelector:@selector(addDelegate:queue:)]) {
            _conversationHandoffDelegate = [[delegateCls alloc] init];
            [manager addDelegate:_conversationHandoffDelegate queue:dispatch_get_main_queue()];
        }
    }
}

-(void) replayCurrentCallsToController:(NetworkController *)controller {
    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    if (callCenter == nil) return;
    NSMutableArray<TUCall *> *calls = [NSMutableArray array];
    if ([callCenter respondsToSelector:@selector(currentCalls)]) {
        for (TUCall *call in [callCenter currentCalls]) {
            if (call != nil && ![calls containsObject:call]) [calls addObject:call];
        }
    }
    if ([callCenter respondsToSelector:@selector(incomingCalls)]) {
        for (TUCall *call in [callCenter incomingCalls]) {
            if (call != nil && ![calls containsObject:call]) [calls addObject:call];
        }
    }
    if ([callCenter respondsToSelector:@selector(callsHostedElsewhere)]) {
        for (TUCall *call in [callCenter callsHostedElsewhere]) {
            if (call != nil && ![calls containsObject:call]) [calls addObject:call];
        }
    }
    NetworkController *target = controller ?: [NetworkController sharedInstance];
    for (TUCall *call in calls) {
        NSDictionary *data = [self callStatusPayloadForCall:call];
        if (data != nil) {
            [target sendMessage:@{@"event": @"ft-call-status-changed", @"data": data}];
        }
    }
    [self replayHandoffEligibleConversationToController:target];
}

-(void) callStatusChanged: (NSNotification *)notification {
    TUCall *call = [notification object];
    NSDictionary *data = [self callStatusPayloadForCall:call];
    if (data == nil) return;
    [[NetworkController sharedInstance] sendMessage: @{@"event": @"ft-call-status-changed", @"data": data}];
}

// Run when receiving a new message from the tcp socket
-(void) handleMessage: (NetworkController*)controller  message:(NSString *)message {
    if (![message isKindOfClass:[NSString class]] || message.length == 0) {
        return;
    }
    // Split batched JSON objects delimited by }\n{ so no message is dropped.
    NSRange range = [message rangeOfString:@"}\n{"];
    if (range.location != NSNotFound) {
        NSString *first = [message substringToIndex:range.location + 1];
        NSString *rest = [message substringFromIndex:range.location + 2];
        [self handleMessage:controller message:first];
        [self handleMessage:controller message:rest];
        return;
    }
    DLog("BLUEBUBBLESFACETIMEHELPER: Received raw json: %{public}@", message);
    NSError *error = nil;
    NSData *jsonData = [message dataUsingEncoding:NSUTF8StringEncoding];
    if (jsonData == nil || jsonData.length == 0) {
        return;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&error];
    if (error != nil || ![parsed isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *dictionary = (NSDictionary *)parsed;

    // Event is the type of packet that was sent
    NSString *event = [dictionary[@"action"] isKindOfClass:[NSString class]] ? dictionary[@"action"] : nil;
    if (event.length == 0) {
        return;
    }
    // Data is the actual information that we need in the packet
    NSDictionary *data = [dictionary[@"data"] isKindOfClass:[NSDictionary class]] ? dictionary[@"data"] : @{};
    // Transaction ID enables us to communicate back to the server that the action was complete
    NSString *transaction = [dictionary[@"transactionId"] isKindOfClass:[NSString class]] ? dictionary[@"transactionId"] : nil;

    DLog("BLUEBUBBLESFACETIMEHELPER: Message received: %{public}@, %{public}@", event, data);
    NetworkController *replyController = controller ?: [NetworkController sharedInstance];

    if ([self handleForkMessage:replyController event:event data:data transaction:transaction]) return;

    if ([event isEqualToString:@"answer-call"]) {
        NSString *callUUID = BBExtractCallUUID(data);
        TUCall *call = BBFindCallByIdentifier([TUCallCenter sharedInstance], callUUID);

        if (call == nil || [call callStatus] != 4) {
            BBSendReply(replyController, transaction, @{
                @"error": call == nil ? @"Call not found!" : @"Call is not waiting to be answered!"
            });
            return;
        }

        [[TUCallCenter sharedInstance] answerOrJoinCall:call];
        BBSendReply(replyController, transaction, nil);
    } else if ([event isEqualToString:@"leave-call"] || [event isEqualToString:@"decline-call"]) {
        NSString *callUUID = BBExtractCallUUID(data);
        TUCall *call = BBFindCallByIdentifier([TUCallCenter sharedInstance], callUUID);
        int status = call != nil ? [call callStatus] : 0;

        if (call == nil || (status != 1 && status != 3 && status != 4)) {
            BBSendReply(replyController, transaction, @{
                @"error": call == nil ? @"Call not found!" : @"Call is not active, dialing, or ringing!"
            });
            return;
        }

        [[TUCallCenter sharedInstance] disconnectCall:call];
        BBSendReply(replyController, transaction, nil);
    } else if ([event isEqualToString:@"generate-link"]) {
        NSString *callUUID = BBExtractCallUUID(data);
        if (callUUID != nil) {
            [self generateLinkForCallUUID:callUUID attemptsLeft:40 linkRetriesLeft:2 deadline:[NSDate dateWithTimeIntervalSinceNow:15.0] transaction:transaction replyController:replyController];
        } else {
            TUConversationManager *manager = [self sharedConversationManager];
            if (manager == nil) {
                BBSendReply(replyController, transaction, @{@"error": @"TUConversationManager unavailable!"});
                return;
            }
            if ([manager respondsToSelector:@selector(generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:)]) {
                [manager generateLinkWithInvitedMemberHandles:[NSSet set] linkLifetimeScope:0 completionHandler:^(TUConversationLink *arg0, NSError *arg1) {
                    [self sendGeneratedLinkReply:arg0 error:arg1 transaction:transaction replyController:replyController];
                }];
            } else {
                BBSendReply(replyController, transaction, @{@"error": @"Failed to generate generic link!"});
            }
        }
    } else if ([event isEqualToString:@"admit-pending-member"]) {
        id rawConvUUID = data[@"conversationUUID"];
        id rawHandleUUID = data[@"handleUUID"];
        if (![rawConvUUID isKindOfClass:[NSString class]] || [(NSString *)rawConvUUID length] == 0 ||
            ![rawHandleUUID isKindOfClass:[NSString class]] || [(NSString *)rawHandleUUID length] == 0) {
            BBSendReply(replyController, transaction, @{@"error": @"conversationUUID and handleUUID are required!"});
            return;
        }
        NSString *targetConvUUID = (NSString *)rawConvUUID;
        NSString *targetHandleUUID = (NSString *)rawHandleUUID;
        TUConversationManager *manager = [self sharedConversationManager];
        TUConversation *convo = nil;

        for (TUConversation *i in [self conversationCandidatesForManager:manager]) {
            if ([[[i groupUUID] UUIDString] caseInsensitiveCompare:targetConvUUID] == NSOrderedSame) {
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

        BBSendReply(replyController, transaction, admitted ? nil : @{@"error": @"Pending member or conversation not found!"});
    } else if ([event isEqualToString:@"get-active-links"]) {
        TUConversationManager *manager = [self sharedConversationManager];
        NSArray<TUConversationLink*>* links = [[manager activatedConversationLinks] allObjects];
        
        NSMutableArray *linkArray = [NSMutableArray array];
        for (TUConversationLink* link in links) {
            NSMutableArray *handleArray = [NSMutableArray array];
            [[[link invitedMemberHandles] allObjects] enumerateObjectsUsingBlock:^(TUHandle* obj, NSUInteger idx, BOOL *stop) {
                NSDictionary *rep = [obj dictionaryRepresentation];
                if (rep != nil) {
                    [handleArray addObject:rep];
                }
            }];
            NSDictionary* linkData = @{
                @"url": [[link URL] absoluteString] ?: [NSNull null],
                @"creation_date": @([[link creationDate] timeIntervalSince1970] * 1000),
                @"expiration_date": @([[link expirationDate] timeIntervalSince1970] * 1000),
                @"group_uuid": [[link groupUUID] UUIDString] ?: [NSNull null],
                @"name": [link linkName] ?: [NSNull null],
                @"handles": handleArray ?: [NSNull null],
            };
            [linkArray addObject:linkData];
        }
        
        BBSendReply(replyController, transaction, @{@"data": @{@"links": linkArray}});
    } else if ([event isEqualToString:@"invalidate-link"]) {
        TUConversationManager *manager = [self sharedConversationManager];
        NSArray<TUConversationLink*>* links = [[manager activatedConversationLinks] allObjects];
        NSString *targetUrl = BBNonEmptyString(data[@"url"]);
        TUConversationLink *matchedLink = nil;
        for (TUConversationLink *link in links) {
            if (targetUrl != nil && [[[link URL] absoluteString] isEqualToString:targetUrl]) {
                matchedLink = link;
                break;
            }
        }
        if (matchedLink == nil) {
            BBSendReply(replyController, transaction, @{@"error": @"Link not found to invalidate!"});
            return;
        }

        __block BOOL replied = NO;
        __block TUConversationManagerXPCClient *xpcClient = nil;
        void (^finishReply)(NSDictionary *) = ^(NSDictionary *extra) {
            if (replied) return;
            replied = YES;
            xpcClient = nil;
            BBSendReply(replyController, transaction, extra);
        };

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            finishReply(@{@"error": @"Timed out invalidating link!"});
        });

        void (^onDone)(char, NSError *) = ^(char arg0, NSError *arg1) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL ok = (arg0 != 0);
                finishReply((ok && arg1 == nil) ? nil : @{@"error": arg1.localizedDescription ?: @"Failed to invalidate link!"});
            });
        };
        if ([manager respondsToSelector:@selector(invalidateLink:completionHandler:)]) {
            [manager invalidateLink:matchedLink completionHandler:onDone];
        } else {
            xpcClient = [[TUConversationManagerXPCClient alloc] init];
            if (xpcClient != nil && [xpcClient respondsToSelector:@selector(invalidateLink:completionHandler:)]) {
                [xpcClient invalidateLink:matchedLink completionHandler:onDone];
            } else {
                finishReply(@{@"error": @"Failed to invalidate link (XPC client unavailable)!"});
            }
        }
    }
}

@end

#import "BlueBubblesFaceTimeHelper+Fork.inc"

ZKSwizzleInterface(BBFT_NetworkController, NetworkController, NSObject)
@implementation BBFT_NetworkController

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port {
    ZKOrig(void, sock, host, port);
    [[BLUEBUBBLESFACETIMEHELPER sharedInstance] replayCurrentCallsToController:(NetworkController *)self];
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
