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

static NSString *BBExtractCallUUID(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    id val = data[@"callUUID"];
    if (![val isKindOfClass:[NSString class]]) val = data[@"call_uuid"];
    return ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) ? val : nil;
}

static void BBSendReply(NetworkController *controller, NSString *transaction, NSDictionary *extra) {
    if (transaction == nil) return;
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:(extra ?: @{})];
    payload[@"transactionId"] = transaction;
    [(controller ?: [NetworkController sharedInstance]) sendMessage:payload];
}

@interface BLUEBUBBLESFACETIMEHELPER : NSObject
+ (instancetype)sharedInstance;
- (void)callStatusChanged:(NSNotification *)notification;
- (void)handleMessage:(NetworkController *)controller message:(NSString *)message;
@end

@interface BLUEBUBBLESFACETIMEHELPER (Fork)
- (NSDictionary *)callStatusPayloadForCall:(TUCall *)call;
- (TUConversationManager *)sharedConversationManager;
- (void)sendGeneratedLinkReply:(TUConversationLink *)link error:(NSError *)error transaction:(NSString *)transaction replyController:(NetworkController *)replyController;
- (void)generateLinkForCallUUID:(NSString *)callUUID attemptsLeft:(NSInteger)attemptsLeft linkRetriesLeft:(NSInteger)linkRetriesLeft deadline:(NSDate *)deadline transaction:(NSString *)transaction replyController:(NetworkController *)replyController;
- (NSArray<TUConversation *> *)conversationCandidatesForManager:(TUConversationManager *)manager;
- (NSDictionary *)conversationDebugDictionary:(TUConversation *)convo;
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
    // The data is in the form of a json string, so we need to convert it to a NSDictionary
    // for some reason the data is sometimes duplicated, so account for that
    NSRange range = [message rangeOfString:@"}\n{"];
    if(range.location != NSNotFound) {
        message = [message substringWithRange:NSMakeRange(0, range.location + 1)];
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
        NSString *callUUID = [data[@"callUUID"] isKindOfClass:[NSString class]] ? data[@"callUUID"] : nil;
        TUCall *call = callUUID != nil ? [[TUCallCenter sharedInstance] callWithCallUUID:callUUID] : nil;
        
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
        NSString *callUUID = BBExtractCallUUID(data);
        TUCall *call = callUUID != nil ? [[TUCallCenter sharedInstance] callWithCallUUID:callUUID] : nil;
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
                [manager generateLinkWithInvitedMemberHandles:@[] linkLifetimeScope:0 completionHandler:^(TUConversationLink *arg0, NSError *arg1) {
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

        BBSendReply(replyController, transaction, admitted ? nil : @{@"error": @"Pending member or conversation not found!"});
    } else if ([event isEqualToString:@"get-active-links"]) {
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
        NSString *targetUrl = data[@"url"];
        BOOL invalidated = NO;
        void (^onDone)(char, NSError *) = ^(char arg0, NSError *arg1) {
            BBSendReply(replyController, transaction, nil);
        };
        
        for (TUConversationLink* link in links) {
            if ([[[link URL] absoluteString] isEqualToString:targetUrl]) {
                if ([manager respondsToSelector:@selector(invalidateLink:completionHandler:)]) {
                    [manager invalidateLink:link completionHandler:onDone];
                } else {
                    [[[TUConversationManagerXPCClient alloc] init] invalidateLink:link completionHandler:onDone];
                }
                invalidated = YES;
                break;
            }
        }
        if (!invalidated) {
            BBSendReply(replyController, transaction, @{@"error": @"Link not found to invalidate!"});
        }
    }
}

@end

#import "BlueBubblesFaceTimeHelper+Fork.inc"


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
