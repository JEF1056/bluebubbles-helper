// Fork-only additions to BLUEBUBBLESFACETIMEHELPER, included at the bottom of
// BlueBubblesFaceTimeHelper.m so upstream merges stay minimal without touching project.pbxproj.

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
@property (nonatomic) BOOL showUIPrompt;
@property (nonatomic, readonly, getter=isValid) BOOL valid;
@end

@interface TUConversationMember (Fork)
- (instancetype)initWithHandle:(TUHandle *)handle;
- (TUHandle *)handle;
@end

@interface TUConversation (Fork)
- (NSUUID *)UUID;
- (NSUUID *)groupUUID;
- (NSSet *)activeRemoteParticipants;
- (NSSet *)activeLightweightParticipants;
- (NSSet *)remoteMembers;
- (NSSet *)pendingMembers;
- (BOOL)isOneToOneModeEnabled;
- (void)setOneToOneModeEnabled:(BOOL)enabled;
@end

@interface TUConversationParticipant : NSObject
- (BOOL)isLightweight;
- (BOOL)isLocalAccountHandle;
@end

@interface TUConversationManager (Fork)
- (void)generateLinkWithInvitedMemberHandles:(NSSet<TUHandle *> *)handles linkLifetimeScope:(NSInteger)scope completionHandler:(void (^)(TUConversationLink *, NSError *))completion;
- (void)kickMember:(TUConversationMember *)member conversation:(TUConversation *)conversation;
- (void)rejectPendingMember:(TUConversationMember *)member forConversation:(TUConversation *)conversation;
- (void)leaveConversationWithUUID:(NSUUID *)uuid;
- (void)invalidateLink:(TUConversationLink *)link completionHandler:(void (^)(BOOL, NSError *))completion;
- (void)buzzMember:(TUConversationMember *)member conversation:(TUConversation *)conversation;
@end

@interface TUConversationLink (Fork)
- (NSURL *)URL;
- (NSString *)pseudonym;
- (NSString *)unprefixedPseudonym;
- (NSUUID *)groupUUID;
@end

@interface TUJoinConversationRequest (Fork)
- (instancetype)initWithRemoteMembers:(NSSet<TUConversationMember *> *)remoteMembers;
- (instancetype)initWithConversationLink:(TUConversationLink *)link
                     otherInvitedHandles:(NSSet<TUHandle *> *)otherInvitedHandles
                           remoteMembers:(NSSet<TUConversationMember *> *)remoteMembers
                      sendLetMeInRequest:(BOOL)sendLetMeInRequest;
- (void)setAvMode:(NSUInteger)avMode;
@end

@interface TUCallCenter (Dialing)
- (void)dialWithRequest:(id)request completionWithError:(void (^)(TUCall *call, NSError *error))completion;
- (TUCall *)joinConversationWithConversationRequest:(TUJoinConversationRequest *)request;
- (void)disconnectCall:(TUCall *)call withReason:(int)reason;
- (TUCall *)callForConversationWithGroupUUID:(NSUUID *)groupUUID;
@end

@interface TUCall (Fork)
- (NSUUID *)conversationGroupUUID;
- (int)disconnectedReason;
- (NSString *)endedErrorString;
- (NSString *)endedReasonString;
@end

@interface TUConversationHandoffEligibility : NSObject
- (BOOL)isEligible;
@end

@interface BLUEBUBBLESFACETIMEHELPER (ForkConversation)
- (void)handleConversationParticipantUpdate:(TUConversation *)conversation;
- (void)syncRemoteActiveConversation:(TUConversation *)convo toController:(NetworkController *)controller;
- (void)syncRemoteActiveConversationsForManager:(TUConversationManager *)manager
                                  toController:(NetworkController *)controller
                               forceEmitActive:(BOOL)forceEmitActive
                             skippingGroupUUID:(NSString *)skipGroupUUID;
@end

@interface BBConversationHandoffDelegate : NSObject
- (void)conversationManager:(TUConversationManager *)manager
    handoffEligibilityChangedToConversation:(TUConversation *)convo
                   fromPreviousConversation:(TUConversation *)prevConvo;
- (void)conversationManager:(TUConversationManager *)manager
    handoffEligibilityChangedForConversation:(TUConversation *)convo;
- (void)conversationManager:(TUConversationManager *)manager
        conversationChanged:(TUConversation *)conversation;
- (void)conversationManager:(TUConversationManager *)manager
    activeRemoteParticipantsChangedForConversation:(TUConversation *)conversation;
- (void)conversationManager:(TUConversationManager *)manager
    activeRemoteParticipantsChangedForConversation:(TUConversation *)conversation
                               fromOldConversation:(TUConversation *)oldConversation;
- (void)conversationManager:(TUConversationManager *)manager
    stateChangedForConversation:(TUConversation *)conversation;
- (void)conversationsChangedForConversationManager:(TUConversationManager *)manager;
@end

static NSString *BBConversationGroupUUIDString(TUConversation *convo);

@implementation BBConversationHandoffDelegate

- (void)conversationManager:(TUConversationManager *)manager
    handoffEligibilityChangedToConversation:(TUConversation *)convo
                   fromPreviousConversation:(TUConversation *)prevConvo {
    if (convo != nil) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] emitHandoffEligibleConversation:convo toController:nil];
    }
    if (prevConvo != nil && prevConvo != convo) {
        NSString *prevGroupUUID = BBConversationGroupUUIDString(prevConvo);
        NSString *newGroupUUID = BBConversationGroupUUIDString(convo);
        if (prevGroupUUID != nil && (newGroupUUID == nil || [prevGroupUUID caseInsensitiveCompare:newGroupUUID] != NSOrderedSame)) {
            [[BLUEBUBBLESFACETIMEHELPER sharedInstance] syncRemoteActiveConversation:prevConvo toController:nil];
        }
    }
    if (convo == nil && manager != nil) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] syncRemoteActiveConversationsForManager:manager
                                                                               toController:nil
                                                                            forceEmitActive:NO
                                                                          skippingGroupUUID:nil];
    }
}

- (void)conversationManager:(TUConversationManager *)manager
    handoffEligibilityChangedForConversation:(TUConversation *)convo {
    TUConversation *eligible = [manager respondsToSelector:@selector(handoffEligibleConversation)]
        ? (TUConversation *)[manager handoffEligibleConversation]
        : convo;
    if (eligible != nil) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] emitHandoffEligibleConversation:eligible toController:nil];
    }
}

- (void)conversationManager:(TUConversationManager *)manager
        conversationChanged:(TUConversation *)conversation {
    (void)manager;
    if (conversation != nil) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] handleConversationParticipantUpdate:conversation];
    }
}

- (void)conversationManager:(TUConversationManager *)manager
    activeRemoteParticipantsChangedForConversation:(TUConversation *)conversation {
    (void)manager;
    if (conversation != nil) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] handleConversationParticipantUpdate:conversation];
    }
}

- (void)conversationManager:(TUConversationManager *)manager
    activeRemoteParticipantsChangedForConversation:(TUConversation *)conversation
                               fromOldConversation:(TUConversation *)oldConversation {
    (void)manager;
    (void)oldConversation;
    if (conversation != nil) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] handleConversationParticipantUpdate:conversation];
    }
}

- (void)conversationManager:(TUConversationManager *)manager
    stateChangedForConversation:(TUConversation *)conversation {
    (void)manager;
    if (conversation != nil) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] handleConversationParticipantUpdate:conversation];
    }
}

- (void)conversationsChangedForConversationManager:(TUConversationManager *)manager {
    if (manager == nil || ![manager respondsToSelector:@selector(activeConversations)]) return;
    [[BLUEBUBBLESFACETIMEHELPER sharedInstance] syncRemoteActiveConversationsForManager:manager
                                                                           toController:nil
                                                                        forceEmitActive:NO
                                                                      skippingGroupUUID:nil];
    for (TUConversation *convo in [manager activeConversations]) {
        [[BLUEBUBBLESFACETIMEHELPER sharedInstance] handleConversationParticipantUpdate:convo];
    }
}

@end

@implementation BLUEBUBBLESFACETIMEHELPER (Fork)

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
    NSString *urlString = [[link URL] absoluteString];
    if ([urlString length] > 0) {
        BBSendReply(replyController, transaction, @{@"url": urlString});
    } else {
        BBSendReply(replyController, transaction, @{@"error": error.localizedDescription ?: @"Failed to generate FaceTime link!"});
    }
}

- (void)generateLinkForCallUUID:(NSString *)callUUID
                   attemptsLeft:(NSInteger)attemptsLeft
                linkRetriesLeft:(NSInteger)linkRetriesLeft
                       deadline:(NSDate *)deadline
                    transaction:(NSString *)transaction
                replyController:(NetworkController *)replyController {
    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    TUCall *call = BBFindCallByIdentifier(callCenter, callUUID);
    if (call == nil || [call callStatus] == 6) {
        BBSendReply(replyController, transaction, @{@"error": @"Call is no longer active!"});
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
            BBSendReply(replyController, transaction, @{@"error": @"No active conversation found for call!"});
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

static void BBCountConversationParticipants(TUConversation *convo,
                                            NSUInteger *outActiveRemote,
                                            NSUInteger *outNonLightweight,
                                            NSUInteger *outLightweight) {
    NSUInteger activeRemoteCount = [convo respondsToSelector:@selector(activeRemoteParticipants)]
        ? [[convo activeRemoteParticipants] count]
        : 0;
    NSUInteger activeNonLightweightCount = 0;
    NSUInteger activeLightweightCount = [convo respondsToSelector:@selector(activeLightweightParticipants)]
        ? [[convo activeLightweightParticipants] count]
        : 0;
    NSUInteger lightweightInRemote = 0;
    if ([convo respondsToSelector:@selector(activeRemoteParticipants)]) {
        for (id participant in [convo activeRemoteParticipants]) {
            BOOL isLightweight = [participant respondsToSelector:@selector(isLightweight)] && [participant isLightweight];
            BOOL isLocal = [participant respondsToSelector:@selector(isLocalAccountHandle)] && [participant isLocalAccountHandle];
            if (isLightweight) {
                lightweightInRemote++;
            } else if (!isLocal) {
                activeNonLightweightCount++;
            }
        }
    }
    if (activeLightweightCount == 0) {
        activeLightweightCount = lightweightInRemote;
    }
    if (outActiveRemote) *outActiveRemote = activeRemoteCount;
    if (outNonLightweight) *outNonLightweight = activeNonLightweightCount;
    if (outLightweight) *outLightweight = activeLightweightCount;
}

static NSMutableDictionary<NSString *, NSNumber *> *BBNonLightweightCountsByCallUUID(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *counts = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        counts = [[NSMutableDictionary alloc] init];
    });
    return counts;
}

static void BBClearTrackedNonLightweightCountForCall(TUCall *call) {
    if (call == nil) return;
    NSString *resolvedCallUUID = BBResolvedCallUUID(call);
    NSString *uniqueProxyIdentifier = BBCallUniqueProxyIdentifier(call);
    if (resolvedCallUUID == nil && uniqueProxyIdentifier == nil) return;
    NSMutableDictionary<NSString *, NSNumber *> *counts = BBNonLightweightCountsByCallUUID();
    @synchronized(counts) {
        if (resolvedCallUUID != nil) [counts removeObjectForKey:resolvedCallUUID];
        if (uniqueProxyIdentifier != nil) [counts removeObjectForKey:uniqueProxyIdentifier];
    }
}

- (void)handleConversationParticipantUpdate:(TUConversation *)conversation {
    if (conversation == nil) return;
    [self syncRemoteActiveConversation:conversation toController:nil];

    if (![conversation respondsToSelector:@selector(groupUUID)]) return;
    NSUUID *groupUUID = [conversation groupUUID];
    if (groupUUID == nil) return;

    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    if (callCenter == nil || ![callCenter respondsToSelector:@selector(callForConversationWithGroupUUID:)]) return;
    TUCall *call = [callCenter callForConversationWithGroupUUID:groupUUID];
    if (call == nil) return;

    int callStatus = [call callStatus];
    if (callStatus == 6) {
        BBClearTrackedNonLightweightCountForCall(call);
        return;
    }
    if (![call isOutgoing] || callStatus != 1) return;

    NSString *callUUID = BBResolvedCallUUID(call);
    if (callUUID == nil) return;

    NSUInteger activeNonLightweightCount = 0;
    BBCountConversationParticipants(conversation, NULL, &activeNonLightweightCount, NULL);

    NSMutableDictionary<NSString *, NSNumber *> *counts = BBNonLightweightCountsByCallUUID();
    BOOL changed = NO;
    @synchronized(counts) {
        NSNumber *prev = counts[callUUID];
        if (prev == nil || [prev unsignedIntegerValue] != activeNonLightweightCount) {
            if ([counts count] >= 512) {
                [counts removeAllObjects];
            }
            counts[callUUID] = @(activeNonLightweightCount);
            changed = YES;
        }
    }
    if (!changed) return;

    NSDictionary *payload = [self callStatusPayloadForCall:call];
    if (payload == nil) return;
    if (![payload[@"active_non_lightweight_participants_count"] isEqual:@(activeNonLightweightCount)]) {
        NSMutableDictionary *mutablePayload = [payload mutableCopy];
        mutablePayload[@"active_non_lightweight_participants_count"] = @(activeNonLightweightCount);
        payload = mutablePayload;
    }
    [[NetworkController sharedInstance] sendMessage:@{@"event": @"ft-call-status-changed", @"data": payload}];
}

static NSArray<NSString *> *BBRemoteAddressesForConversation(TUConversation *convo) {
    if (convo == nil) return @[];
    NSMutableArray<NSString *> *addresses = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *localHandleValue = nil;
    if ([convo respondsToSelector:@selector(localMember)]) {
        id localMember = [(id)convo localMember];
        if ([localMember respondsToSelector:@selector(handle)]) {
            NSString *v = [[localMember handle] value];
            if ([v length] > 0) localHandleValue = [v lowercaseString];
        }
    }
    void (^addValue)(NSString *) = ^(NSString *val) {
        if (![val isKindOfClass:[NSString class]]) return;
        NSString *trimmed = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed length] == 0) return;
        NSString *lower = [trimmed lowercaseString];
        if (localHandleValue != nil && [lower isEqualToString:localHandleValue]) return;
        if (![seen containsObject:lower]) {
            [seen addObject:lower];
            [addresses addObject:trimmed];
        }
    };
    if ([convo respondsToSelector:@selector(remoteMembers)]) {
        for (id member in [convo remoteMembers]) {
            BOOL isLocal = [member respondsToSelector:@selector(isLocalAccountHandle)] && [member isLocalAccountHandle];
            if (isLocal) continue;
            if ([member respondsToSelector:@selector(handle)]) {
                addValue([[member handle] value]);
            }
        }
    }
    if ([addresses count] == 0 && [convo respondsToSelector:@selector(activeRemoteParticipants)]) {
        for (id participant in [convo activeRemoteParticipants]) {
            BOOL isLocal = [participant respondsToSelector:@selector(isLocalAccountHandle)] && [participant isLocalAccountHandle];
            if (isLocal) continue;
            if ([participant respondsToSelector:@selector(handle)]) {
                addValue([[participant handle] value]);
            }
        }
    }
    return addresses;
}

static os_log_t BBSelfViewLog(void) {
    static os_log_t log = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.bluebubbles.messaging", "FaceTimeHelper");
    });
    return log;
}

static BOOL BBSelfViewHidingEnabled = YES;
static BOOL BBSelfViewTreeLoggedForCall = NO;
static dispatch_source_t BBSelfViewPollTimer = nil;

static NSHashTable<NSView *> *BBHiddenSelfViews(void) {
    static NSHashTable<NSView *> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSHashTable<CALayer *> *BBHiddenSelfLayers(void) {
    static NSHashTable<CALayer *> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static BOOL BBIsSelfViewClassName(NSString *clsName) {
    if ([clsName length] == 0) return NO;
    BOOL hasLocalSelfPreview =
        ([clsName rangeOfString:@"Local" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([clsName rangeOfString:@"Self" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([clsName rangeOfString:@"Preview" options:NSCaseInsensitiveSearch].location != NSNotFound);
    if (!hasLocalSelfPreview) return NO;
    return ([clsName rangeOfString:@"Video" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
           ([clsName rangeOfString:@"Participant" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL BBIsSelfLayerClassName(NSString *clsName) {
    if ([clsName length] == 0) return NO;
    return ([clsName rangeOfString:@"PreviewLayer" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
           ([clsName rangeOfString:@"LocalVideo" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static void BBCheckSingleLayer(CALayer *layer, NSUInteger depth, NSMutableString *treeOut, BOOL hide, NSUInteger *matchedCount) {
    if (layer == nil) return;
    NSString *clsName = NSStringFromClass([layer class]) ?: @"";
    if (treeOut != nil) {
        for (NSUInteger i = 0; i < depth; i++) [treeOut appendString:@"  "];
        [treeOut appendFormat:@"[L] %@ frame=%@ hidden=%d opacity=%.2f\n",
            clsName, NSStringFromRect(NSRectFromCGRect(layer.frame)), layer.hidden, layer.opacity];
    }
    if (BBIsSelfLayerClassName(clsName)) {
        if (matchedCount != NULL) (*matchedCount)++;
        if (hide) {
            if (!layer.hidden) layer.hidden = YES;
            if (layer.opacity > 0.0f) layer.opacity = 0.0f;
            [BBHiddenSelfLayers() addObject:layer];
        } else if ([BBHiddenSelfLayers() containsObject:layer]) {
            layer.hidden = NO;
            layer.opacity = 1.0f;
            [BBHiddenSelfLayers() removeObject:layer];
        }
    }
}

static void BBCheckUnhostedLayers(CALayer *layer, NSUInteger depth, NSMutableString *treeOut, BOOL hide, NSUInteger *matchedCount) {
    if (layer == nil || depth > 32) return;
    BBCheckSingleLayer(layer, depth, treeOut, hide, matchedCount);
    for (CALayer *sublayer in [layer.sublayers copy]) {
        id del = sublayer.delegate;
        if (del == nil || ![del isKindOfClass:[NSView class]]) {
            BBCheckUnhostedLayers(sublayer, depth + 1, treeOut, hide, matchedCount);
        }
    }
}

static void BBCheckUnhostedUILayers(CALayer *layer, NSUInteger depth, NSMutableString *treeOut, BOOL hide, NSUInteger *matchedCount) {
    if (layer == nil || depth > 32) return;
    BBCheckSingleLayer(layer, depth, treeOut, hide, matchedCount);
    Class uiViewCls = NSClassFromString(@"UIView");
    for (CALayer *sublayer in [layer.sublayers copy]) {
        id del = sublayer.delegate;
        if (del == nil || (uiViewCls != Nil && ![del isKindOfClass:uiViewCls])) {
            BBCheckUnhostedUILayers(sublayer, depth + 1, treeOut, hide, matchedCount);
        }
    }
}

static void BBAppendLayerTree(CALayer *layer, NSUInteger depth, NSMutableString *treeOut, BOOL hide, NSUInteger *matchedCount) {
    if (layer == nil || depth > 32) return;
    BBCheckSingleLayer(layer, depth, treeOut, hide, matchedCount);
    for (CALayer *sublayer in [layer.sublayers copy]) {
        BBAppendLayerTree(sublayer, depth + 1, treeOut, hide, matchedCount);
    }
}

static void BBWalkViewTree(NSView *view, NSUInteger depth, NSMutableString *treeOut, BOOL hide, NSUInteger *matchedCount) {
    if (view == nil || depth > 32) return;
    NSString *clsName = NSStringFromClass([view class]) ?: @"";
    if (treeOut != nil) {
        for (NSUInteger i = 0; i < depth; i++) [treeOut appendString:@"  "];
        [treeOut appendFormat:@"[V] %@ frame=%@ hidden=%d alpha=%.2f\n",
            clsName, NSStringFromRect(view.frame), view.hidden, view.alphaValue];
    }
    if (BBIsSelfViewClassName(clsName)) {
        if (matchedCount != NULL) (*matchedCount)++;
        if (hide) {
            if (!view.hidden) view.hidden = YES;
            if (view.alphaValue > 0.0) view.alphaValue = 0.0;
            [BBHiddenSelfViews() addObject:view];
        } else if ([BBHiddenSelfViews() containsObject:view]) {
            view.hidden = NO;
            view.alphaValue = 1.0;
            [BBHiddenSelfViews() removeObject:view];
        }
    }
    if (view.layer != nil) {
        BBCheckUnhostedLayers(view.layer, depth + 1, treeOut, hide, matchedCount);
    }
    for (NSView *subview in [view.subviews copy]) {
        BBWalkViewTree(subview, depth + 1, treeOut, hide, matchedCount);
    }
}

static void BBWalkUIViewTree(id uiView, NSUInteger depth, NSMutableString *treeOut, BOOL hide, NSUInteger *matchedCount) {
    if (uiView == nil || depth > 24) return;
    NSString *clsName = NSStringFromClass([uiView class]) ?: @"";
    CALayer *layer = [uiView respondsToSelector:@selector(layer)]
        ? ((CALayer * (*)(id, SEL))objc_msgSend)(uiView, @selector(layer))
        : nil;
    BOOL isHidden = [uiView respondsToSelector:@selector(isHidden)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(uiView, @selector(isHidden))
        : NO;
    CGFloat alpha = [uiView respondsToSelector:@selector(alpha)]
        ? ((CGFloat (*)(id, SEL))objc_msgSend)(uiView, @selector(alpha))
        : 1.0;

    if (treeOut != nil) {
        for (NSUInteger i = 0; i < depth; i++) [treeOut appendString:@"  "];
        NSString *rectStr = layer ? NSStringFromRect(NSRectFromCGRect(layer.frame)) : @"{?}";
        [treeOut appendFormat:@"[UIV] %@ frame=%@ hidden=%d alpha=%.2f\n", clsName, rectStr, isHidden, alpha];
    }
    if (BBIsSelfViewClassName(clsName)) {
        if (matchedCount != NULL) (*matchedCount)++;
        if (hide) {
            if (!isHidden && [uiView respondsToSelector:@selector(setHidden:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(uiView, @selector(setHidden:), YES);
            }
            if (alpha > 0.0 && [uiView respondsToSelector:@selector(setAlpha:)]) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(uiView, @selector(setAlpha:), 0.0);
            }
            [BBHiddenSelfViews() addObject:uiView];
        } else if ([BBHiddenSelfViews() containsObject:uiView]) {
            if ([uiView respondsToSelector:@selector(setHidden:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(uiView, @selector(setHidden:), NO);
            }
            if ([uiView respondsToSelector:@selector(setAlpha:)]) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(uiView, @selector(setAlpha:), 1.0);
            }
            [BBHiddenSelfViews() removeObject:uiView];
        }
    }
    if (layer != nil) {
        BBCheckUnhostedUILayers(layer, depth + 1, treeOut, hide, matchedCount);
    }
    if ([uiView respondsToSelector:@selector(subviews)]) {
        NSArray *subs = ((NSArray * (*)(id, SEL))objc_msgSend)(uiView, @selector(subviews));
        for (id sub in [subs copy]) {
            BBWalkUIViewTree(sub, depth + 1, treeOut, hide, matchedCount);
        }
    }
}

static NSUInteger BBApplySelfViewHidingOnMain(BOOL hide, BOOL forceLogTree) {
    BOOL shouldLog = (forceLogTree || !BBSelfViewTreeLoggedForCall);
    NSMutableString *treeOut = shouldLog ? [NSMutableString string] : nil;
    NSUInteger matchedCount = 0;

    if (NSApp != nil) {
        for (NSWindow *win in [[NSApp windows] copy]) {
            NSView *contentView = win.contentView;
            if (contentView == nil) continue;
            if (treeOut != nil) {
                [treeOut appendFormat:@"[W] %@ visible=%d frame=%@\n",
                    NSStringFromClass([win class]), win.isVisible, NSStringFromRect(win.frame)];
            }
            BBWalkViewTree(contentView, 1, treeOut, hide, &matchedCount);
        }
    }

    // FaceTime.app on macOS is Mac Catalyst (UIKit): walk UIApplication windows/scenes as well.
    Class uiAppCls = NSClassFromString(@"UIApplication");
    if (uiAppCls != Nil && [uiAppCls respondsToSelector:@selector(sharedApplication)]) {
        id uiApp = ((id (*)(Class, SEL))objc_msgSend)(uiAppCls, @selector(sharedApplication));
        NSMutableSet *seenWindows = [NSMutableSet set];
        if (uiApp != nil && [uiApp respondsToSelector:@selector(connectedScenes)]) {
            NSSet *scenes = ((NSSet * (*)(id, SEL))objc_msgSend)(uiApp, @selector(connectedScenes));
            for (id scene in [scenes copy]) {
                if ([scene respondsToSelector:@selector(windows)]) {
                    NSArray *wins = ((NSArray * (*)(id, SEL))objc_msgSend)(scene, @selector(windows));
                    for (id uiWin in [wins copy]) {
                        if (uiWin != nil) [seenWindows addObject:uiWin];
                    }
                }
            }
        }
        if (uiApp != nil && [uiApp respondsToSelector:@selector(windows)]) {
            NSArray *wins = ((NSArray * (*)(id, SEL))objc_msgSend)(uiApp, @selector(windows));
            for (id uiWin in [wins copy]) {
                if (uiWin != nil) [seenWindows addObject:uiWin];
            }
        }
        for (id uiWin in seenWindows) {
            if (treeOut != nil) {
                [treeOut appendFormat:@"[UIW] %@\n", NSStringFromClass([uiWin class])];
            }
            BBWalkUIViewTree(uiWin, 1, treeOut, hide, &matchedCount);
        }
    }
    if (shouldLog && [treeOut length] > 0) {
        BBSelfViewTreeLoggedForCall = YES;
        const NSUInteger chunkSize = 800;
        NSUInteger len = [treeOut length];
        for (NSUInteger offset = 0; offset < len; offset += chunkSize) {
            NSUInteger thisLen = MIN(chunkSize, len - offset);
            NSString *chunk = [treeOut substringWithRange:NSMakeRange(offset, thisLen)];
            os_log_with_type(BBSelfViewLog(), OS_LOG_TYPE_DEFAULT,
                "BLUEBUBBLESFACETIMEHELPER: selfViewTree (matched=%lu, part=%lu): %{public}@",
                (unsigned long)matchedCount, (unsigned long)(offset / chunkSize), chunk);
        }
    }
    return matchedCount;
}

static BOOL BBHasAnyActiveCall(void) {
    TUCallCenter *cc = [TUCallCenter sharedInstance];
    if (cc == nil || ![cc respondsToSelector:@selector(currentCalls)]) return NO;
    for (TUCall *c in [cc currentCalls]) {
        if (c != nil && [c callStatus] != 6) return YES;
    }
    return NO;
}

static void BBUpdateSelfViewMonitorForCallActive(BOOL isActive) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (isActive) {
            BBApplySelfViewHidingOnMain(BBSelfViewHidingEnabled, NO);
            if (BBSelfViewPollTimer == nil) {
                dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
                dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), (uint64_t)(1 * NSEC_PER_SEC), (uint64_t)(100 * NSEC_PER_MSEC));
                dispatch_source_set_event_handler(timer, ^{
                    if (!BBHasAnyActiveCall()) {
                        if (BBSelfViewPollTimer != nil) {
                            dispatch_source_cancel(BBSelfViewPollTimer);
                            BBSelfViewPollTimer = nil;
                        }
                        BBSelfViewTreeLoggedForCall = NO;
                        [BBHiddenSelfViews() removeAllObjects];
                        [BBHiddenSelfLayers() removeAllObjects];
                        return;
                    }
                    BBApplySelfViewHidingOnMain(BBSelfViewHidingEnabled, NO);
                });
                BBSelfViewPollTimer = timer;
                dispatch_resume(timer);
            }
        } else if (!BBHasAnyActiveCall()) {
            if (BBSelfViewPollTimer != nil) {
                dispatch_source_cancel(BBSelfViewPollTimer);
                BBSelfViewPollTimer = nil;
            }
            BBSelfViewTreeLoggedForCall = NO;
            [BBHiddenSelfViews() removeAllObjects];
            [BBHiddenSelfLayers() removeAllObjects];
        }
    });
}

- (NSDictionary *)callStatusPayloadForCall:(TUCall *)call {
    if (call == nil) return nil;
    id provider = [call respondsToSelector:@selector(provider)] ? [call provider] : nil;
    NSString *providerIdentifier = [provider respondsToSelector:@selector(identifier)] ? [(TUCallProvider *)provider identifier] : nil;
    BOOL isTelephonyProvider = [provider respondsToSelector:@selector(isTelephonyProvider)] && [(TUCallProvider *)provider isTelephonyProvider];
    BOOL isFaceTimeProvider = [provider respondsToSelector:@selector(isFaceTimeProvider)] && [(TUCallProvider *)provider isFaceTimeProvider];
    BOOL isHostedOnCurrentDevice = [call respondsToSelector:@selector(isHostedOnCurrentDevice)] ? [call isHostedOnCurrentDevice] : YES;
    BOOL isEndpointOnCurrentDevice = [call respondsToSelector:@selector(isEndpointOnCurrentDevice)] ? [call isEndpointOnCurrentDevice] : isHostedOnCurrentDevice;
    BOOL isTelephony = isTelephonyProvider || (!isFaceTimeProvider && !isHostedOnCurrentDevice);
    BOOL isVideo = [call respondsToSelector:@selector(isVideo)] ? [call isVideo] : [call isSendingVideo];

    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    TUConversationManager *manager = [self sharedConversationManager];
    TUConversation *convo = [callCenter respondsToSelector:@selector(activeConversationForCall:)] ? [callCenter activeConversationForCall:call] : nil;
    NSUUID *groupUUID = [call respondsToSelector:@selector(conversationGroupUUID)] ? [call conversationGroupUUID] : nil;
    if (convo == nil && groupUUID != nil && [manager respondsToSelector:@selector(activeConversationWithGroupUUID:)]) {
        convo = [manager activeConversationWithGroupUUID:groupUUID];
    }

    NSString *convGroupUUIDStr = [groupUUID UUIDString] ?: [[convo groupUUID] UUIDString];
    NSString *convUUIDStr = [convo respondsToSelector:@selector(UUID)] ? [[convo UUID] UUIDString] : nil;
    NSString *convLinkStr = [[[convo link] URL] absoluteString];
    NSUInteger activeRemoteCount = 0;
    NSUInteger activeNonLightweightCount = 0;
    NSUInteger activeLightweightCount = 0;
    BBCountConversationParticipants(convo, &activeRemoteCount, &activeNonLightweightCount, &activeLightweightCount);
    NSUInteger remoteMembersCount = [convo respondsToSelector:@selector(remoteMembers)] ? [[convo remoteMembers] count] : 0;
    NSUInteger pendingMembersCount = [convo respondsToSelector:@selector(pendingMembers)] ? [[convo pendingMembers] count] : 0;
    BOOL convHasJoined = [convo respondsToSelector:@selector(hasJoined)] ? [convo hasJoined] : NO;
    BOOL isOneToOneMode = [convo respondsToSelector:@selector(isOneToOneModeEnabled)] ? [convo isOneToOneModeEnabled] : NO;

    NSString *resolvedCallUUID = BBResolvedCallUUID(call);
    NSString *uniqueProxyIdentifier = BBCallUniqueProxyIdentifier(call);
    int callStatus = [call callStatus];
    BOOL isOutgoing = [call isOutgoing];
    int filteredOutReason = [call respondsToSelector:@selector(filteredOutReason)] ? [call filteredOutReason] : 0;
    BOOL neverConnected = [call respondsToSelector:@selector(dateConnected)] ? ([call dateConnected] == nil) : YES;

    static NSMutableSet<NSString *> *seenNonDisconnectedCalls = nil;
    static dispatch_once_t seenOnce;
    dispatch_once(&seenOnce, ^{
        seenNonDisconnectedCalls = [[NSMutableSet alloc] init];
    });
    BOOL seenBefore = NO;
    @synchronized(seenNonDisconnectedCalls) {
        if (callStatus != 6) {
            if (resolvedCallUUID != nil) [seenNonDisconnectedCalls addObject:resolvedCallUUID];
            if (uniqueProxyIdentifier != nil) [seenNonDisconnectedCalls addObject:uniqueProxyIdentifier];
        } else {
            seenBefore = (resolvedCallUUID != nil && [seenNonDisconnectedCalls containsObject:resolvedCallUUID]) ||
                         (uniqueProxyIdentifier != nil && [seenNonDisconnectedCalls containsObject:uniqueProxyIdentifier]);
            if (resolvedCallUUID != nil) [seenNonDisconnectedCalls removeObject:resolvedCallUUID];
            if (uniqueProxyIdentifier != nil) [seenNonDisconnectedCalls removeObject:uniqueProxyIdentifier];
        }
    }
    if (callStatus == 6) {
        BBClearTrackedNonLightweightCountForCall(call);
    }
    BBUpdateSelfViewMonitorForCallActive(callStatus != 6);
    BOOL isIncomingSilenced = (callStatus == 6) && !isOutgoing && neverConnected && !seenBefore;
    NSArray<NSString *> *addresses = BBRemoteAddressesForConversation(convo);
    BOOL isGroup = (remoteMembersCount > 1) || ([addresses count] > 1);

    return @{
        @"audio_mode": [call audioMode] ?: [NSNull null],
        @"call_status": @(callStatus),
        @"call_uuid": resolvedCallUUID ?: [NSNull null],
        @"unique_proxy_identifier": uniqueProxyIdentifier ?: [NSNull null],
        @"is_conversation": @([call isConversation]),
        @"disconnected_reason": @([call disconnectedReason]),
        @"ended_error": [call endedErrorString] ?: [NSNull null],
        @"ended_reason": [call endedReasonString] ?: [NSNull null],
        @"filtered_out_reason": @(filteredOutReason),
        @"is_incoming_silenced": @(isIncomingSilenced),
        @"handle": [[call handle] dictionaryRepresentation] ?: [NSNull null],
        @"addresses": addresses,
        @"is_group": @(isGroup),
        @"is_sending_audio": @([call isSendingAudio]),
        @"is_sending_video": @([call isSendingVideo]),
        @"is_outgoing": @(isOutgoing),
        @"is_video": @(isVideo),
        @"is_telephony": @(isTelephony),
        @"is_hosted_on_current_device": @(isHostedOnCurrentDevice),
        @"is_endpoint_on_current_device": @(isEndpointOnCurrentDevice),
        @"provider_identifier": providerIdentifier ?: [NSNull null],
        @"conversation_group_uuid": convGroupUUIDStr ?: [NSNull null],
        @"conversation_uuid": convUUIDStr ?: [NSNull null],
        @"conversation_link": convLinkStr ?: [NSNull null],
        @"active_remote_participants_count": @(activeRemoteCount),
        @"active_non_lightweight_participants_count": @(activeNonLightweightCount),
        @"active_lightweight_participants_count": @(activeLightweightCount),
        @"remote_members_count": @(remoteMembersCount),
        @"pending_members_count": @(pendingMembersCount),
        @"conversation_has_joined": @(convHasJoined),
        @"is_one_to_one_mode": @(isOneToOneMode),
    };
}

- (NSArray<TUConversation *> *)conversationCandidatesForManager:(TUConversationManager *)manager {
    NSMutableArray<TUConversation *> *conversations = [[NSMutableArray alloc] init];
    NSMutableSet<NSString *> *seen = [[NSMutableSet alloc] init];

    void (^addConversation)(TUConversation *) = ^(TUConversation *convo) {
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

- (NSDictionary *)conversationDebugDictionary:(TUConversation *)convo {
    NSMutableArray *pendingMembers = [[NSMutableArray alloc] init];
    for (TUConversationMember *member in [convo pendingMembers]) {
        [pendingMembers addObject:@{
            @"handleUUID": [[[member handle] value] description] ?: [NSNull null],
            @"description": [member description] ?: [NSNull null],
            @"joinedFromLetMeIn": @([member joinedFromLetMeIn]),
            @"dateReceivedLetMeIn": [member dateReceivedLetMeIn] ? @([[member dateReceivedLetMeIn] timeIntervalSince1970] * 1000) : [NSNull null],
        }];
    }

    NSUInteger activeRemoteCount = 0;
    NSUInteger activeNonLightweightCount = 0;
    NSUInteger activeLightweightCount = 0;
    BBCountConversationParticipants(convo, &activeRemoteCount, &activeNonLightweightCount, &activeLightweightCount);

    return @{
        @"uuid": [[convo UUID] UUIDString] ?: [NSNull null],
        @"groupUUID": [[convo groupUUID] UUIDString] ?: [NSNull null],
        @"link": [[[convo link] URL] absoluteString] ?: [NSNull null],
        @"state": @([convo state]),
        @"pendingConversation": @([convo isPendingConversation]),
        @"hasJoined": @([convo hasJoined]),
        @"hasReceivedLetMeInRequest": @([convo hasReceivedLetMeInRequest]),
        @"letMeInRequestState": @([convo letMeInRequestState]),
        @"pendingMemberCount": @([[convo pendingMembers] count]),
        @"remoteMemberCount": @([[convo remoteMembers] count]),
        @"activeRemoteParticipantCount": @(activeRemoteCount),
        @"activeLightweightParticipantCount": @(activeLightweightCount),
        @"activeNonLightweightParticipantCount": @(activeNonLightweightCount),
        @"pendingMembers": pendingMembers,
    };
}

static TUHandle *BBHandoffHandleForConversation(TUConversation *convo) {
    if (convo == nil) return nil;
    if ([convo respondsToSelector:@selector(remoteMembers)]) {
        for (id member in [convo remoteMembers]) {
            if ([member respondsToSelector:@selector(handle)]) {
                TUHandle *h = [member handle];
                if (h != nil) return h;
            }
        }
    }
    if ([convo respondsToSelector:@selector(activeRemoteParticipants)]) {
        for (id participant in [convo activeRemoteParticipants]) {
            BOOL isLocal = [participant respondsToSelector:@selector(isLocalAccountHandle)] && [participant isLocalAccountHandle];
            if (!isLocal && [participant respondsToSelector:@selector(handle)]) {
                TUHandle *h = [participant handle];
                if (h != nil) return h;
            }
        }
    }
    if ([convo respondsToSelector:@selector(participantHandles)]) {
        for (id h in [convo participantHandles]) {
            if ([h respondsToSelector:@selector(dictionaryRepresentation)]) {
                return (TUHandle *)h;
            }
        }
    }
    if ([convo respondsToSelector:@selector(initiator)]) {
        TUHandle *h = [convo initiator];
        if (h != nil) return h;
    }
    return nil;
}

static NSMutableSet<NSString *> *BBRemoteActiveGroupUUIDs(void) {
    static NSMutableSet<NSString *> *tracked = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tracked = [[NSMutableSet alloc] init];
    });
    return tracked;
}

static NSString *BBConversationGroupUUIDString(TUConversation *convo) {
    if (convo == nil) return nil;
    NSString *groupUUID = [convo respondsToSelector:@selector(groupUUID)] ? [[convo groupUUID] UUIDString] : nil;
    if ([groupUUID length] == 0 && [convo respondsToSelector:@selector(UUID)]) {
        groupUUID = [[convo UUID] UUIDString];
    }
    return [groupUUID length] > 0 ? groupUUID : nil;
}

static BOOL BBConversationIsRemoteActive(TUConversation *convo) {
    if (convo == nil) return NO;
    if ([convo respondsToSelector:@selector(isFromStorage)] && [(id)convo isFromStorage]) return NO;
    BOOL otherActive = [convo respondsToSelector:@selector(isAnyOtherAccountDeviceActive)] && [(id)convo isAnyOtherAccountDeviceActive];
    if (!otherActive) return NO;
    BOOL hasJoined = [convo respondsToSelector:@selector(hasJoined)] && [convo hasJoined];
    return !hasJoined;
}

static BOOL BBConversationHasActiveLocalCall(NSString *groupUUIDStr) {
    if ([groupUUIDStr length] == 0) return NO;
    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    if (callCenter == nil || ![callCenter respondsToSelector:@selector(callForConversationWithGroupUUID:)]) return NO;
    NSUUID *nsGroupUUID = [[NSUUID alloc] initWithUUIDString:groupUUIDStr];
    if (nsGroupUUID == nil) return NO;
    TUCall *call = [callCenter callForConversationWithGroupUUID:nsGroupUUID];
    return (call != nil && [call callStatus] != 6);
}

- (NSDictionary *)syntheticRemoteCallPayloadForConversation:(TUConversation *)convo
                                               groupUUID:(NSString *)groupUUID
                                              callStatus:(int)callStatus {
    if ([groupUUID length] == 0) return nil;
    TUHandle *handle = BBHandoffHandleForConversation(convo);
    NSDictionary *handleDict = [handle respondsToSelector:@selector(dictionaryRepresentation)] ? [handle dictionaryRepresentation] : nil;
    NSArray<NSString *> *addresses = BBRemoteAddressesForConversation(convo);
    NSUInteger remoteMembersCount = (convo != nil && [convo respondsToSelector:@selector(remoteMembers)]) ? [[convo remoteMembers] count] : 0;
    BOOL isGroup = (remoteMembersCount > 1) || ([addresses count] > 1);
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"is_handoff_eligible": @YES,
        @"conversation_group_uuid": groupUUID,
        @"call_uuid": groupUUID,
        @"handle": handleDict ?: [NSNull null],
        @"addresses": addresses,
        @"is_group": @(isGroup),
        @"is_endpoint_on_current_device": @NO,
        @"is_hosted_on_current_device": @NO,
        @"call_status": @(callStatus),
    }];
    if (convo != nil && [convo respondsToSelector:@selector(UUID)] && [convo UUID] != nil) {
        payload[@"conversation_uuid"] = [[convo UUID] UUIDString];
    }
    if (convo != nil && [convo respondsToSelector:@selector(isVideo)]) {
        payload[@"is_video"] = @([(id)convo isVideo]);
    }
    return payload;
}

- (void)syncRemoteActiveConversation:(TUConversation *)convo toController:(NetworkController *)controller {
    NSString *groupUUID = BBConversationGroupUUIDString(convo);
    if (groupUUID == nil) return;

    BOOL hasLocalCall = BBConversationHasActiveLocalCall(groupUUID);
    BOOL isRemoteActive = BBConversationIsRemoteActive(convo) && !hasLocalCall;
    BOOL hasJoined = [convo respondsToSelector:@selector(hasJoined)] && [convo hasJoined];

    BOOL shouldEmitActive = NO;
    BOOL shouldEmitEnded = NO;
    NSMutableSet<NSString *> *tracked = BBRemoteActiveGroupUUIDs();
    @synchronized(tracked) {
        if (isRemoteActive) {
            if (![tracked containsObject:groupUUID]) {
                if ([tracked count] >= 512) [tracked removeAllObjects];
                [tracked addObject:groupUUID];
                shouldEmitActive = YES;
            }
        } else if ([tracked containsObject:groupUUID]) {
            [tracked removeObject:groupUUID];
            if (!hasJoined && !hasLocalCall) {
                shouldEmitEnded = YES;
            }
        }
    }

    NetworkController *target = controller ?: [NetworkController sharedInstance];
    if (shouldEmitActive) {
        NSDictionary *payload = [self syntheticRemoteCallPayloadForConversation:convo groupUUID:groupUUID callStatus:1];
        if (payload != nil) {
            [target sendMessage:@{@"event": @"ft-call-status-changed", @"data": payload}];
        }
    } else if (shouldEmitEnded) {
        NSDictionary *payload = [self syntheticRemoteCallPayloadForConversation:convo groupUUID:groupUUID callStatus:6];
        if (payload != nil) {
            [target sendMessage:@{@"event": @"ft-call-status-changed", @"data": payload}];
        }
    }
}

- (void)syncRemoteActiveConversationsForManager:(TUConversationManager *)manager
                                  toController:(NetworkController *)controller
                               forceEmitActive:(BOOL)forceEmitActive
                             skippingGroupUUID:(NSString *)skipGroupUUID {
    if (manager == nil || ![manager respondsToSelector:@selector(activeConversations)]) return;

    NSMutableDictionary<NSString *, TUConversation *> *activeRemoteNow = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *joinedOrLocalNow = [NSMutableSet set];
    for (TUConversation *convo in [manager activeConversations]) {
        NSString *groupUUID = BBConversationGroupUUIDString(convo);
        if (groupUUID == nil) continue;
        BOOL hasLocalCall = BBConversationHasActiveLocalCall(groupUUID);
        BOOL hasJoined = [convo respondsToSelector:@selector(hasJoined)] && [convo hasJoined];
        if (hasJoined || hasLocalCall) {
            [joinedOrLocalNow addObject:groupUUID];
            continue;
        }
        if (BBConversationIsRemoteActive(convo)) {
            activeRemoteNow[groupUUID] = convo;
        }
    }

    NSMutableArray<TUConversation *> *toEmitActive = [NSMutableArray array];
    NSMutableArray<NSString *> *toEmitEnded = [NSMutableArray array];
    NSMutableSet<NSString *> *tracked = BBRemoteActiveGroupUUIDs();
    @synchronized(tracked) {
        for (NSString *groupUUID in activeRemoteNow) {
            BOOL wasTracked = [tracked containsObject:groupUUID];
            if ([tracked count] >= 512) [tracked removeAllObjects];
            [tracked addObject:groupUUID];
            BOOL skipped = skipGroupUUID != nil && [groupUUID caseInsensitiveCompare:skipGroupUUID] == NSOrderedSame;
            if ((forceEmitActive || !wasTracked) && !skipped) {
                [toEmitActive addObject:activeRemoteNow[groupUUID]];
            }
        }
        for (NSString *trackedUUID in [tracked allObjects]) {
            if (activeRemoteNow[trackedUUID] == nil) {
                if (skipGroupUUID != nil && [trackedUUID caseInsensitiveCompare:skipGroupUUID] == NSOrderedSame) {
                    continue;
                }
                [tracked removeObject:trackedUUID];
                if (![joinedOrLocalNow containsObject:trackedUUID] && !BBConversationHasActiveLocalCall(trackedUUID)) {
                    [toEmitEnded addObject:trackedUUID];
                }
            }
        }
    }

    NetworkController *target = controller ?: [NetworkController sharedInstance];
    for (TUConversation *convo in toEmitActive) {
        NSDictionary *payload = [self syntheticRemoteCallPayloadForConversation:convo
                                                                      groupUUID:BBConversationGroupUUIDString(convo)
                                                                     callStatus:1];
        if (payload != nil) {
            [target sendMessage:@{@"event": @"ft-call-status-changed", @"data": payload}];
        }
    }
    for (NSString *endedGroupUUID in toEmitEnded) {
        NSDictionary *payload = [self syntheticRemoteCallPayloadForConversation:nil
                                                                      groupUUID:endedGroupUUID
                                                                     callStatus:6];
        if (payload != nil) {
            [target sendMessage:@{@"event": @"ft-call-status-changed", @"data": payload}];
        }
    }
}

- (void)emitHandoffEligibleConversation:(TUConversation *)convo toController:(NetworkController *)controller {
    if (convo == nil) return;
    id eligibility = [convo respondsToSelector:@selector(handoffEligibility)] ? [(id)convo handoffEligibility] : nil;
    if (eligibility != nil && [eligibility respondsToSelector:@selector(isEligible)] && ![eligibility isEligible]) {
        return;
    }
    NSString *groupUUID = BBConversationGroupUUIDString(convo);
    if (groupUUID == nil) return;

    NSMutableSet<NSString *> *tracked = BBRemoteActiveGroupUUIDs();
    @synchronized(tracked) {
        if ([tracked count] >= 512) [tracked removeAllObjects];
        [tracked addObject:groupUUID];
    }

    NSDictionary *payload = [self syntheticRemoteCallPayloadForConversation:convo groupUUID:groupUUID callStatus:1];
    if (payload == nil) return;
    NetworkController *target = controller ?: [NetworkController sharedInstance];
    [target sendMessage:@{@"event": @"ft-call-status-changed", @"data": payload}];
}

- (void)replayHandoffEligibleConversationToController:(NetworkController *)controller {
    TUConversationManager *manager = [self sharedConversationManager];
    if (manager == nil) return;

    NSString *emittedHandoffGroupUUID = nil;
    if ([manager respondsToSelector:@selector(handoffEligibleConversation)]) {
        TUConversation *convo = (TUConversation *)[manager handoffEligibleConversation];
        if (convo != nil) {
            id eligibility = [convo respondsToSelector:@selector(handoffEligibility)] ? [(id)convo handoffEligibility] : nil;
            if (eligibility == nil || ![eligibility respondsToSelector:@selector(isEligible)] || [eligibility isEligible]) {
                emittedHandoffGroupUUID = BBConversationGroupUUIDString(convo);
                [self emitHandoffEligibleConversation:convo toController:controller];
            }
        }
    }

    [self syncRemoteActiveConversationsForManager:manager
                                     toController:controller
                                  forceEmitActive:YES
                                skippingGroupUUID:emittedHandoffGroupUUID];
}

- (TUCall *)findReadyPulledCallInCallCenter:(TUCallCenter *)callCenter
                                   callUUID:(NSString *)callUUID
                      conversationGroupUUID:(NSString *)convGroupUUID {
    if (callCenter == nil || ![callCenter respondsToSelector:@selector(currentCalls)]) return nil;
    TUCall *fallbackCall = nil;
    for (TUCall *c in [callCenter currentCalls]) {
        if (c == nil || [c callStatus] != 1) continue;
        BOOL endpointHere = [c respondsToSelector:@selector(isEndpointOnCurrentDevice)] && [c isEndpointOnCurrentDevice];
        if (!endpointHere) continue;

        if (callUUID != nil) {
            NSString *cUUID = [c respondsToSelector:@selector(callUUID)] ? BBNonEmptyString([c callUUID]) : nil;
            NSString *cUPI = BBCallUniqueProxyIdentifier(c);
            if ([cUUID isEqualToString:callUUID] || [cUPI isEqualToString:callUUID]) {
                return c;
            }
        }
        if (convGroupUUID != nil) {
            NSString *cGroupUUID = [c respondsToSelector:@selector(conversationGroupUUID)]
                ? [[c conversationGroupUUID] UUIDString]
                : ([c respondsToSelector:@selector(callGroupUUID)] ? [[c callGroupUUID] UUIDString] : nil);
            if (cGroupUUID != nil && [cGroupUUID caseInsensitiveCompare:convGroupUUID] == NSOrderedSame) {
                return c;
            }
        }
        if (fallbackCall == nil && callUUID == nil && convGroupUUID == nil) {
            fallbackCall = c;
        }
    }
    return fallbackCall;
}

- (void)pollForPulledCallWithUUID:(NSString *)callUUID
            conversationGroupUUID:(NSString *)convGroupUUID
                         deadline:(NSDate *)deadline
                      transaction:(NSString *)transaction
                  replyController:(NetworkController *)replyController {
    TUCallCenter *callCenter = [TUCallCenter sharedInstance];
    TUCall *readyCall = [self findReadyPulledCallInCallCenter:callCenter callUUID:callUUID conversationGroupUUID:convGroupUUID];
    if (readyCall != nil) {
        NSString *resolvedUUID = BBResolvedCallUUID(readyCall);
        BBSendReply(replyController, transaction, @{
            @"data": @{@"call_uuid": resolvedUUID ?: [NSNull null]},
        });
        return;
    }

    if (deadline != nil && [deadline timeIntervalSinceNow] > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self pollForPulledCallWithUUID:callUUID
                      conversationGroupUUID:convGroupUUID
                                   deadline:deadline
                                transaction:transaction
                            replyController:replyController];
        });
        return;
    }

    BBSendReply(replyController, transaction, @{
        @"error": @"Timed out waiting for pulled call to become active on this Mac!",
    });
}

- (BOOL)handleForkMessage:(NetworkController *)replyController event:(NSString *)event data:(NSDictionary *)data transaction:(NSString *)transaction {
    if ([event isEqualToString:@"set-muted"]) {
        NSString *callUUID = BBExtractCallUUID(data);
        TUCall *call = BBFindCallByIdentifier([TUCallCenter sharedInstance], callUUID);
        if (call == nil) {
            BBSendReply(replyController, transaction, @{@"error": @"Call not found!"});
            return YES;
        }

        id mutedVal = [data isKindOfClass:[NSDictionary class]] ? data[@"muted"] : nil;
        if (mutedVal == nil || mutedVal == [NSNull null] || ![mutedVal respondsToSelector:@selector(boolValue)]) {
            BBSendReply(replyController, transaction, @{@"error": @"Missing muted flag!"});
            return YES;
        }

        BOOL muted = [mutedVal boolValue];
        [call setUplinkMuted:muted];
        BBSendReply(replyController, transaction, @{@"muted": @(muted)});
        return YES;
    } else if ([event isEqualToString:@"set-self-view-hidden"]) {
        id hiddenVal = [data isKindOfClass:[NSDictionary class]] ? data[@"hidden"] : nil;
        if (hiddenVal == nil || hiddenVal == [NSNull null] || ![hiddenVal respondsToSelector:@selector(boolValue)]) {
            BBSendReply(replyController, transaction, @{@"error": @"Missing hidden flag!"});
            return YES;
        }
        BOOL hidden = [hiddenVal boolValue];
        BOOL logTree = [data isKindOfClass:[NSDictionary class]] && [data[@"logTree"] respondsToSelector:@selector(boolValue)] && [data[@"logTree"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            BBSelfViewHidingEnabled = hidden;
            NSUInteger matched = BBApplySelfViewHidingOnMain(hidden, logTree);
            BBSendReply(replyController, transaction, @{
                @"hidden": @(hidden),
                @"matchedCount": @(matched),
            });
        });
        return YES;
    } else if ([event isEqualToString:@"admit-any-pending-member"]) {
        TUConversationManager *manager = [self sharedConversationManager];
        NSString *targetConvUUID = BBNonEmptyString(data[@"conversationUUID"]) ?: BBNonEmptyString(data[@"groupUUID"]);
        NSMutableArray *admittedMembers = [[NSMutableArray alloc] init];
        NSMutableArray<NSString *> *admittedParticipants = [[NSMutableArray alloc] init];

        for (TUConversation *convo in [self conversationCandidatesForManager:manager]) {
            if (targetConvUUID != nil) {
                NSString *cGroupUUID = [[convo groupUUID] UUIDString];
                NSString *cUUID = [convo respondsToSelector:@selector(UUID)] ? [[convo UUID] UUIDString] : nil;
                BOOL matchesGroup = cGroupUUID != nil && [cGroupUUID caseInsensitiveCompare:targetConvUUID] == NSOrderedSame;
                BOOL matchesUUID = cUUID != nil && [cUUID caseInsensitiveCompare:targetConvUUID] == NSOrderedSame;
                if (!matchesGroup && !matchesUUID) continue;
            }
            for (TUConversationMember *member in [convo pendingMembers]) {
                DLog("BLUEBUBBLESFACETIMEHELPER: approving pending member %{public}@", member);
                [manager approvePendingMember:member forConversation:convo];
                NSString *handleUUID = BBNonEmptyString([[[member handle] value] description]);
                [admittedMembers addObject:@{
                    @"conversationUUID": [[convo groupUUID] UUIDString] ?: [NSNull null],
                    @"handleUUID": handleUUID ?: [NSNull null],
                }];
                if (handleUUID != nil && ![admittedParticipants containsObject:handleUUID]) {
                    [admittedParticipants addObject:handleUUID];
                }
            }
        }

        BBSendReply(replyController, transaction, @{
            @"data": @{
                @"admittedCount": @([admittedMembers count]),
                @"admittedMembers": admittedMembers,
                @"admittedParticipants": admittedParticipants,
            },
        });
        return YES;
    } else if ([event isEqualToString:@"get-conversation-state"]) {
        TUConversationManager *manager = [self sharedConversationManager];
        NSMutableArray *conversations = [[NSMutableArray alloc] init];
        for (TUConversation *convo in [self conversationCandidatesForManager:manager]) {
            [conversations addObject:[self conversationDebugDictionary:convo]];
        }

        BBSendReply(replyController, transaction, @{
            @"data": @{
                @"conversationCount": @([conversations count]),
                @"conversations": conversations,
            },
        });
        return YES;
    } else if ([event isEqualToString:@"play-dtmf"]) {
        NSString *callUUID = BBExtractCallUUID(data);
        TUCall *call = BBFindCallByIdentifier([TUCallCenter sharedInstance], callUUID);
        if (call == nil) {
            BBSendReply(replyController, transaction, @{@"error": @"Call not found!"});
            return YES;
        }

        id rawDigit = [data isKindOfClass:[NSDictionary class]] ? data[@"digit"] : nil;
        NSString *digit = [rawDigit isKindOfClass:[NSString class]] ? [(NSString *)rawDigit uppercaseString] : nil;
        if ([digit length] != 1 || [@"0123456789*#ABCD" rangeOfString:digit].location == NSNotFound) {
            BBSendReply(replyController, transaction, @{@"error": @"Invalid DTMF digit!"});
            return YES;
        }

        if ([call respondsToSelector:@selector(supportsDTMFTones)] && ![call supportsDTMFTones]) {
            BBSendReply(replyController, transaction, @{@"played": @NO, @"fallback": @"bridge"});
            return YES;
        }

        BOOL (^invokeDtmf)(id, SEL, BOOL) = ^BOOL(id target, SEL sel, BOOL hasCallArg) {
            if (![target respondsToSelector:sel]) return NO;
            NSMethodSignature *sig = [target methodSignatureForSelector:sel];
            NSUInteger expectedArgs = hasCallArg ? 4 : 3;
            if (sig == nil || [sig numberOfArguments] != expectedArgs) return NO;

            const char *argType = [sig getArgumentTypeAtIndex:2];
            if (argType == NULL) return NO;

            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:target];
            [inv setSelector:sel];

            unichar uc = [digit characterAtIndex:0];
            unsigned char u8 = (unsigned char)uc;
            if (argType[0] == '@') {
                NSString *arg = digit;
                [inv setArgument:&arg atIndex:2];
            } else if (argType[0] == 'S' || argType[0] == 's') {
                [inv setArgument:&uc atIndex:2];
            } else if (argType[0] == 'C' || argType[0] == 'c') {
                [inv setArgument:&u8 atIndex:2];
            } else {
                return NO;
            }

            if (hasCallArg) {
                TUCall *callArg = call;
                [inv setArgument:&callArg atIndex:3];
            }
            [inv invoke];
            return YES;
        };

        TUCallCenter *callCenter = [TUCallCenter sharedInstance];
        BOOL played = invokeDtmf(callCenter, NSSelectorFromString(@"playDTMFToneForKey:call:"), YES) ||
                      invokeDtmf(call, NSSelectorFromString(@"playDTMFToneForKey:"), NO) ||
                      invokeDtmf(callCenter, NSSelectorFromString(@"playDTMFTone:forCall:"), YES);

        if (played) {
            BBSendReply(replyController, transaction, @{@"played": @YES});
        } else {
            BBSendReply(replyController, transaction, @{@"played": @NO, @"fallback": @"bridge"});
        }
        return YES;
    } else if ([event isEqualToString:@"start-call"]) {
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
            BBSendReply(replyController, transaction, @{@"error": @"No valid addresses provided!"});
            return YES;
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
            BBSendReply(replyController, transaction, @{@"error": @"Requested call provider is unavailable!"});
            return YES;
        }

        void (^dialViaRequest)(void) = ^{
            Class dialReqClass = NSClassFromString(@"TUDialRequest");
            TUDialRequest *request = dialReqClass != Nil ? [[dialReqClass alloc] initWithProvider:provider] : nil;
            if (request == nil) {
                BBSendReply(replyController, transaction, @{@"error": @"TUDialRequest is unavailable!"});
                return;
            }

            if ([handles count] == 1) {
                request.handle = [handles firstObject];
            } else {
                request.handles = [NSSet setWithArray:handles];
            }
            request.video = isTelephony ? NO : video;
            if ([request respondsToSelector:@selector(setShowUIPrompt:)]) {
                [request setShowUIPrompt:NO];
            }

            if (![request isValid]) {
                BBSendReply(replyController, transaction, @{@"error": @"Invalid dial request!"});
                return;
            }

            void (^finishDial)(TUCall *, NSError *) = ^(TUCall *call, NSError *dialError) {
                if (dialError != nil || call == nil) {
                    BBSendReply(replyController, transaction, @{
                        @"error": dialError.localizedDescription ?: @"Failed to start call!"
                    });
                    return;
                }
                NSMutableDictionary *response = [([self callStatusPayloadForCall:call] ?: @{}) mutableCopy];
                NSString *resolvedCallUUID = BBResolvedCallUUID(call);
                NSString *uniqueProxyIdentifier = BBCallUniqueProxyIdentifier(call);
                if ([request respondsToSelector:@selector(uniqueProxyIdentifier)]) {
                    NSString *reqUPI = BBNonEmptyString([(id)request uniqueProxyIdentifier]);
                    if (resolvedCallUUID == nil) resolvedCallUUID = reqUPI;
                    if (uniqueProxyIdentifier == nil) uniqueProxyIdentifier = reqUPI;
                }
                response[@"call_uuid"] = resolvedCallUUID ?: [NSNull null];
                if (uniqueProxyIdentifier != nil) {
                    response[@"unique_proxy_identifier"] = uniqueProxyIdentifier;
                }
                BBSendReply(replyController, transaction, response);
            };

            if ([callCenter respondsToSelector:@selector(dialWithRequest:completionWithError:)]) {
                [callCenter dialWithRequest:request completionWithError:finishDial];
            } else {
                [callCenter dialWithRequest:request completion:^(TUCall *call) {
                    finishDial(call, nil);
                }];
            }
        };

        // Group FaceTime (2+ handles) joins directly with remoteMembers (no link, no buzzMember).
        // 1:1 FaceTime (audio/video) and Telephony dial directly via TUDialRequest.
        Class joinReqClass = NSClassFromString(@"TUJoinConversationRequest");
        Class memberClass = NSClassFromString(@"TUConversationMember");
        if (!isTelephony && [handles count] > 1 && joinReqClass != Nil && memberClass != Nil &&
            [joinReqClass instancesRespondToSelector:@selector(initWithRemoteMembers:)] &&
            [callCenter respondsToSelector:@selector(joinConversationWithConversationRequest:)]) {
            NSMutableSet<TUConversationMember *> *members = [NSMutableSet setWithCapacity:[handles count]];
            for (TUHandle *h in handles) {
                TUConversationMember *m = [[memberClass alloc] initWithHandle:h];
                if (m != nil) [members addObject:m];
            }
            TUJoinConversationRequest *joinReq = [[joinReqClass alloc] initWithRemoteMembers:members];
            if (joinReq != nil) {
                joinReq.video = video;
                joinReq.videoEnabled = video;
                if ([joinReq respondsToSelector:@selector(setAvMode:)]) {
                    joinReq.avMode = video ? 2 : 1;
                }
                if ([joinReq respondsToSelector:@selector(setWantsStagingArea:)]) {
                    joinReq.wantsStagingArea = NO;
                }
                if ([joinReq respondsToSelector:@selector(setShowUIPrompt:)]) {
                    joinReq.showUIPrompt = NO;
                }
                TUCall *call = [callCenter joinConversationWithConversationRequest:joinReq];
                if (call != nil) {
                    NSString *resolvedCallUUID = BBResolvedCallUUID(call);
                    NSString *uniqueProxyIdentifier = BBCallUniqueProxyIdentifier(call);
                    if ([joinReq respondsToSelector:NSSelectorFromString(@"uniqueProxyIdentifierUUID")]) {
                        id reqUUID = [joinReq valueForKey:@"uniqueProxyIdentifierUUID"];
                        NSString *reqUPI = [reqUUID isKindOfClass:[NSUUID class]] ? BBNonEmptyString([(NSUUID *)reqUUID UUIDString]) : nil;
                        if (resolvedCallUUID == nil) resolvedCallUUID = reqUPI;
                        if (uniqueProxyIdentifier == nil) uniqueProxyIdentifier = reqUPI;
                    }
                    DLog("BLUEBUBBLESFACETIMEHELPER: started direct group FaceTime call %{public}@ (%lu handles)", resolvedCallUUID, (unsigned long)[handles count]);
                    NSMutableDictionary *response = [([self callStatusPayloadForCall:call] ?: @{}) mutableCopy];
                    response[@"call_uuid"] = resolvedCallUUID ?: [NSNull null];
                    if (uniqueProxyIdentifier != nil) {
                        response[@"unique_proxy_identifier"] = uniqueProxyIdentifier;
                    }
                    BBSendReply(replyController, transaction, response);
                    return YES;
                }
            }
        }

        dialViaRequest();
        return YES;
    } else if ([event isEqualToString:@"end-and-invalidate-call"]) {
        NSString *callUUID = BBExtractCallUUID(data);
        NSString *targetUrl = [data isKindOfClass:[NSDictionary class]] && [data[@"url"] isKindOfClass:[NSString class]] ? data[@"url"] : nil;
        NSString *targetConvUUID = [data isKindOfClass:[NSDictionary class]] && [data[@"conversationUUID"] isKindOfClass:[NSString class]]
            ? data[@"conversationUUID"]
            : ([data isKindOfClass:[NSDictionary class]] && [data[@"groupUUID"] isKindOfClass:[NSString class]] ? data[@"groupUUID"] : nil);

        TUCallCenter *callCenter = [TUCallCenter sharedInstance];
        TUConversationManager *manager = [self sharedConversationManager];
        TUCall *call = BBFindCallByIdentifier(callCenter, callUUID);

        if (call == nil && [targetConvUUID length] > 0 && [callCenter respondsToSelector:@selector(callForConversationWithGroupUUID:)]) {
            NSUUID *groupNSUUID = [[NSUUID alloc] initWithUUIDString:targetConvUUID];
            if (groupNSUUID != nil) {
                call = [callCenter callForConversationWithGroupUUID:groupNSUUID];
            }
        }

        TUConversation *convo = call != nil && [callCenter respondsToSelector:@selector(activeConversationForCall:)]
            ? [callCenter activeConversationForCall:call]
            : nil;
        if (convo == nil && manager != nil) {
            for (TUConversation *candidate in [self conversationCandidatesForManager:manager]) {
                NSString *cGroupUUID = [[candidate groupUUID] UUIDString];
                NSString *cUUID = [candidate respondsToSelector:@selector(UUID)] ? [[candidate UUID] UUIDString] : nil;
                NSString *cUrl = [[[candidate link] URL] absoluteString];
                BOOL matchGroup = [cGroupUUID length] > 0 && [cGroupUUID caseInsensitiveCompare:targetConvUUID] == NSOrderedSame;
                BOOL matchUUID = [cUUID length] > 0 && [cUUID caseInsensitiveCompare:targetConvUUID] == NSOrderedSame;
                if (([targetConvUUID length] > 0 && (matchGroup || matchUUID)) ||
                    ([targetUrl length] > 0 && [cUrl isEqualToString:targetUrl])) {
                    convo = candidate;
                    break;
                }
            }
        }

        NSUInteger kickedCount = 0;
        NSMutableSet<NSString *> *kickedHandles = [NSMutableSet set];
        if (convo != nil && manager != nil) {
            if ([manager respondsToSelector:@selector(kickMember:conversation:)]) {
                for (TUConversationMember *member in [[convo remoteMembers] copy]) {
                    [manager kickMember:member conversation:convo];
                    kickedCount++;
                    NSString *hv = [[member handle] value];
                    if ([hv length] > 0) [kickedHandles addObject:hv];
                }
                Class memberClass = NSClassFromString(@"TUConversationMember");
                if (memberClass != Nil) {
                    for (id participant in [[convo activeRemoteParticipants] copy]) {
                        TUHandle *ph = [participant respondsToSelector:@selector(handle)] ? [participant handle] : nil;
                        NSString *hv = [ph value];
                        if (ph != nil && ([hv length] == 0 || ![kickedHandles containsObject:hv])) {
                            TUConversationMember *m = [[memberClass alloc] initWithHandle:ph];
                            if (m != nil) {
                                [manager kickMember:m conversation:convo];
                                kickedCount++;
                            }
                        }
                    }
                }
            }
            if ([manager respondsToSelector:@selector(rejectPendingMember:forConversation:)]) {
                for (TUConversationMember *pending in [[convo pendingMembers] copy]) {
                    [manager rejectPendingMember:pending forConversation:convo];
                }
            }
            if ([manager respondsToSelector:@selector(leaveConversationWithUUID:)]) {
                NSUUID *leaveUUID = ([convo respondsToSelector:@selector(UUID)] ? [convo UUID] : nil) ?: [convo groupUUID];
                if (leaveUUID != nil) {
                    [manager leaveConversationWithUUID:leaveUUID];
                }
            }
        }

        if (call != nil && [call callStatus] != 6) {
            if ([callCenter respondsToSelector:@selector(disconnectCall:withReason:)]) {
                [callCenter disconnectCall:call withReason:0];
            } else {
                [callCenter disconnectCall:call];
            }
        }

        NSMutableArray<TUConversationLink *> *linksToInvalidate = [NSMutableArray array];
        TUConversationLink *convoLink = [convo link];
        if (convoLink != nil) [linksToInvalidate addObject:convoLink];

        NSString *convoLinkUrl = [[[convoLink URL] absoluteString] copy];
        NSString *resolvedUrl = [targetUrl length] > 0 ? targetUrl : convoLinkUrl;
        NSString *resolvedGroupUUID = [targetConvUUID length] > 0 ? targetConvUUID : [[convo groupUUID] UUIDString];

        if (manager != nil) {
            for (TUConversationLink *link in [[manager activatedConversationLinks] allObjects]) {
                NSString *lUrl = [[link URL] absoluteString];
                NSString *lGroupUUID = [[link groupUUID] UUIDString];
                BOOL matchesUrl = [resolvedUrl length] > 0 && [lUrl isEqualToString:resolvedUrl];
                BOOL matchesGroup = [resolvedGroupUUID length] > 0 && [lGroupUUID caseInsensitiveCompare:resolvedGroupUUID] == NSOrderedSame;
                if ((matchesUrl || matchesGroup) && ![linksToInvalidate containsObject:link]) {
                    [linksToInvalidate addObject:link];
                }
            }
        }

        if ([linksToInvalidate count] == 0) {
            BBSendReply(replyController, transaction, @{
                @"ended": @YES,
                @"kicked_count": @(kickedCount),
                @"invalidated_link": @NO,
            });
            return YES;
        }

        __block NSUInteger remainingLinks = [linksToInvalidate count];
        __block BOOL anyInvalidated = NO;
        __block BOOL replied = NO;
        NSMutableArray *retainedClients = [NSMutableArray array];
        void (^finishReply)(void) = ^{
            if (replied) return;
            replied = YES;
            [retainedClients removeAllObjects];
            BBSendReply(replyController, transaction, @{
                @"ended": @YES,
                @"kicked_count": @(kickedCount),
                @"invalidated_link": @(anyInvalidated),
            });
        };

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            finishReply();
        });

        for (TUConversationLink *link in linksToInvalidate) {
            __block TUConversationManagerXPCClient *xpcClient = nil;
            void (^onDone)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (xpcClient != nil) {
                        [retainedClients removeObject:xpcClient];
                        xpcClient = nil;
                    }
                    if (ok && err == nil) anyInvalidated = YES;
                    remainingLinks--;
                    if (remainingLinks == 0) finishReply();
                });
            };
            if ([manager respondsToSelector:@selector(invalidateLink:completionHandler:)]) {
                [manager invalidateLink:link completionHandler:onDone];
            } else {
                xpcClient = [[TUConversationManagerXPCClient alloc] init];
                if (xpcClient != nil) {
                    [retainedClients addObject:xpcClient];
                    [xpcClient invalidateLink:link completionHandler:onDone];
                } else {
                    onDone(NO, [NSError errorWithDomain:@"BlueBubbles" code:1 userInfo:@{NSLocalizedDescriptionKey: @"XPC client unavailable"}]);
                }
            }
        }
        return YES;
    } else if ([event isEqualToString:@"pull-call"]) {
        NSString *callUUID = BBExtractCallUUID(data);
        NSString *convGroupUUID = [data isKindOfClass:[NSDictionary class]]
            ? (BBNonEmptyString(data[@"conversation_group_uuid"])
                ?: BBNonEmptyString(data[@"conversationGroupUUID"])
                ?: BBNonEmptyString(data[@"groupUUID"]))
            : nil;

        TUCallCenter *callCenter = [TUCallCenter sharedInstance];
        if (callCenter == nil) {
            BBSendReply(replyController, transaction, @{@"error": @"TUCallCenter is unavailable!"});
            return YES;
        }

        TUCall *call = BBFindCallByIdentifier(callCenter, callUUID);
        if (call == nil && convGroupUUID != nil && [callCenter respondsToSelector:@selector(callForConversationWithGroupUUID:)]) {
            NSUUID *gUUID = [[NSUUID alloc] initWithUUIDString:convGroupUUID];
            if (gUUID != nil) {
                call = [callCenter callForConversationWithGroupUUID:gUUID];
            }
        }

        BOOL isEndpointOnMac = call != nil &&
            ([call respondsToSelector:@selector(isEndpointOnCurrentDevice)]
                ? [call isEndpointOnCurrentDevice]
                : ([call respondsToSelector:@selector(isHostedOnCurrentDevice)] ? [call isHostedOnCurrentDevice] : YES));

        if (call != nil && isEndpointOnMac && [call callStatus] == 1) {
            BBSendReply(replyController, transaction, @{
                @"data": @{@"call_uuid": BBResolvedCallUUID(call) ?: callUUID ?: [NSNull null]},
            });
            return YES;
        }

        if (call != nil && !isEndpointOnMac) {
            if (![callCenter respondsToSelector:@selector(pullHostedCallsFromPairedHostDevice)]) {
                BBSendReply(replyController, transaction, @{@"error": @"pullHostedCallsFromPairedHostDevice is unavailable!"});
                return YES;
            }
            [callCenter pullHostedCallsFromPairedHostDevice];
        } else {
            TUConversationManager *manager = [self sharedConversationManager];
            BOOL (^convoMatchesTarget)(TUConversation *) = ^BOOL(TUConversation *candidate) {
                if (candidate == nil) return NO;
                if (convGroupUUID == nil) return YES;
                NSString *cGroupUUID = [candidate respondsToSelector:@selector(groupUUID)] ? [[candidate groupUUID] UUIDString] : nil;
                NSString *cUUID = [candidate respondsToSelector:@selector(UUID)] ? [[candidate UUID] UUIDString] : nil;
                BOOL matchesGroup = cGroupUUID != nil && [cGroupUUID caseInsensitiveCompare:convGroupUUID] == NSOrderedSame;
                BOOL matchesUUID = cUUID != nil && [cUUID caseInsensitiveCompare:convGroupUUID] == NSOrderedSame;
                return matchesGroup || matchesUUID;
            };

            TUConversation *handoffConvo = (manager != nil && [manager respondsToSelector:@selector(handoffEligibleConversation)])
                ? (TUConversation *)[manager handoffEligibleConversation]
                : nil;
            if (handoffConvo != nil && convoMatchesTarget(handoffConvo)) {
                if ([callCenter respondsToSelector:@selector(continueHandoffEligibleConversation)]) {
                    [callCenter continueHandoffEligibleConversation];
                } else {
                    id eligibility = [handoffConvo respondsToSelector:@selector(handoffEligibility)] ? [(id)handoffConvo handoffEligibility] : nil;
                    id joinReq = (eligibility != nil && [manager respondsToSelector:@selector(joinRequestForApplicableConversationWithHandoffEligibility:)])
                        ? [manager joinRequestForApplicableConversationWithHandoffEligibility:eligibility]
                        : nil;
                    if (joinReq != nil && [callCenter respondsToSelector:@selector(joinConversationWithRequest:)]) {
                        [callCenter joinConversationWithRequest:joinReq];
                    } else if (joinReq != nil && [callCenter respondsToSelector:@selector(joinConversationWithConversationRequest:)]) {
                        [callCenter joinConversationWithConversationRequest:joinReq];
                    } else if (joinReq != nil && [manager respondsToSelector:@selector(joinConversationWithRequest:)]) {
                        [manager joinConversationWithRequest:joinReq];
                    } else {
                        BBSendReply(replyController, transaction, @{@"error": @"Handoff continuation is unavailable!"});
                        return YES;
                    }
                }
            } else {
                TUConversation *remoteConvo = nil;
                if (manager != nil && [manager respondsToSelector:@selector(activeConversations)]) {
                    for (TUConversation *candidate in [manager activeConversations]) {
                        if (BBConversationIsRemoteActive(candidate) && convoMatchesTarget(candidate)) {
                            remoteConvo = candidate;
                            break;
                        }
                    }
                }
                if (remoteConvo == nil) {
                    NSString *errMsg = (handoffConvo != nil && convGroupUUID != nil)
                        ? @"Requested conversation is not handoff eligible!"
                        : @"No eligible call or conversation to pull!";
                    BBSendReply(replyController, transaction, @{@"error": errMsg});
                    return YES;
                }

                if (convGroupUUID == nil) {
                    convGroupUUID = BBConversationGroupUUIDString(remoteConvo);
                }

                Class joinReqClass = NSClassFromString(@"TUJoinConversationRequest");
                TUJoinConversationRequest *joinReq = (joinReqClass != Nil && [joinReqClass instancesRespondToSelector:@selector(initWithConversation:)])
                    ? [[joinReqClass alloc] initWithConversation:remoteConvo]
                    : nil;
                if (joinReq == nil) {
                    BBSendReply(replyController, transaction, @{@"error": @"TUJoinConversationRequest is unavailable!"});
                    return YES;
                }
                BOOL isVideo = [remoteConvo respondsToSelector:@selector(isVideo)] ? [(id)remoteConvo isVideo] : NO;
                if ([joinReq respondsToSelector:@selector(setVideo:)]) joinReq.video = isVideo;
                if ([joinReq respondsToSelector:@selector(setVideoEnabled:)]) joinReq.videoEnabled = isVideo;
                if ([joinReq respondsToSelector:@selector(setAvMode:)]) joinReq.avMode = isVideo ? 2 : 1;
                if ([joinReq respondsToSelector:@selector(setWantsStagingArea:)]) joinReq.wantsStagingArea = NO;
                if ([joinReq respondsToSelector:@selector(setShowUIPrompt:)]) joinReq.showUIPrompt = NO;

                if ([manager respondsToSelector:@selector(joinConversationWithRequest:)]) {
                    [manager joinConversationWithRequest:joinReq];
                } else if ([callCenter respondsToSelector:@selector(joinConversationWithRequest:)]) {
                    [callCenter joinConversationWithRequest:joinReq];
                } else if ([callCenter respondsToSelector:@selector(joinConversationWithConversationRequest:)]) {
                    [callCenter joinConversationWithConversationRequest:joinReq];
                } else {
                    BBSendReply(replyController, transaction, @{@"error": @"joinConversationWithRequest: is unavailable!"});
                    return YES;
                }
            }
        }

        [self pollForPulledCallWithUUID:callUUID
                  conversationGroupUUID:convGroupUUID
                               deadline:[NSDate dateWithTimeIntervalSinceNow:10.0]
                            transaction:transaction
                        replyController:replyController];
        return YES;
    } else if ([event isEqualToString:@"push-call"]) {
        TUCallCenter *callCenter = [TUCallCenter sharedInstance];
        if (callCenter != nil && [callCenter respondsToSelector:@selector(pushRelayingCallsToHost)]) {
            [callCenter pushRelayingCallsToHost];
            BBSendReply(replyController, transaction, @{@"data": @{@"pushed": @YES}});
        } else {
            BBSendReply(replyController, transaction, @{@"error": @"pushRelayingCallsToHost is unavailable!"});
        }
        return YES;
    } else if ([event isEqualToString:@"remove-facetime-link"]) {
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSString *rawTargetUrl = [data isKindOfClass:[NSDictionary class]] ? BBNonEmptyString(data[@"url"]) : nil;
        NSString *rawTargetPseudonym = [data isKindOfClass:[NSDictionary class]] ? BBNonEmptyString(data[@"pseudonym"]) : nil;
        NSString *targetUrl = rawTargetUrl != nil ? BBNonEmptyString([rawTargetUrl stringByTrimmingCharactersInSet:ws]) : nil;
        NSString *targetPseudonym = rawTargetPseudonym != nil ? BBNonEmptyString([rawTargetPseudonym stringByTrimmingCharactersInSet:ws]) : nil;

        NSString *(^extractPseudonymFromUrl)(NSString *) = ^NSString *(NSString *urlStr) {
            if ([urlStr length] == 0) return nil;
            NSRange pRange = [urlStr rangeOfString:@"p="];
            if (pRange.location == NSNotFound) return nil;
            NSString *rest = [urlStr substringFromIndex:(pRange.location + pRange.length)];
            NSRange ampRange = [rest rangeOfString:@"&"];
            return ampRange.location == NSNotFound ? rest : [rest substringToIndex:ampRange.location];
        };
        if (targetPseudonym == nil && targetUrl != nil) {
            targetPseudonym = BBNonEmptyString(extractPseudonymFromUrl(targetUrl));
        }

        if (targetUrl == nil && targetPseudonym == nil) {
            BBSendReply(replyController, transaction, @{
                @"error": @"url or pseudonym is required to remove a FaceTime link!",
                @"removed": @NO,
                @"removed_count": @0,
                @"skipped_active_count": @0,
            });
            return YES;
        }

        TUConversationManager *manager = [self sharedConversationManager];
        if (manager == nil) {
            BBSendReply(replyController, transaction, @{
                @"removed": @NO,
                @"removed_count": @0,
                @"skipped_active_count": @0,
            });
            return YES;
        }

        // Never delete a link that has an active conversation or participants.
        NSMutableSet<NSString *> *activeUrls = [NSMutableSet set];
        NSMutableSet<NSString *> *activePseudonyms = [NSMutableSet set];
        NSMutableSet<NSString *> *activeGroupUUIDs = [NSMutableSet set];

        void (^recordActiveConversation)(TUConversation *) = ^(TUConversation *convo) {
            if (convo == nil) return;
            NSString *gUUID = [convo respondsToSelector:@selector(groupUUID)] ? [[convo groupUUID] UUIDString] : nil;
            if ([gUUID length] > 0) [activeGroupUUIDs addObject:[gUUID lowercaseString]];

            TUConversationLink *cLink = [convo respondsToSelector:@selector(link)] ? [convo link] : nil;
            if (cLink != nil) {
                NSString *cUrl = [cLink respondsToSelector:@selector(URL)] ? [[cLink URL] absoluteString] : nil;
                if ([cUrl length] > 0) [activeUrls addObject:[cUrl lowercaseString]];
                NSString *cPseudo = [cLink respondsToSelector:@selector(pseudonym)] ? BBNonEmptyString([cLink pseudonym]) : nil;
                if (cPseudo != nil) [activePseudonyms addObject:[cPseudo lowercaseString]];
                NSString *cUnprefixed = [cLink respondsToSelector:@selector(unprefixedPseudonym)] ? BBNonEmptyString([cLink unprefixedPseudonym]) : nil;
                if (cUnprefixed != nil) [activePseudonyms addObject:[cUnprefixed lowercaseString]];
                NSString *cUrlPseudo = extractPseudonymFromUrl(cUrl);
                if (cUrlPseudo != nil) [activePseudonyms addObject:[cUrlPseudo lowercaseString]];
            }
        };

        if ([manager respondsToSelector:@selector(activeConversations)]) {
            for (TUConversation *convo in [manager activeConversations]) {
                recordActiveConversation(convo);
            }
        }
        TUCallCenter *callCenter = [TUCallCenter sharedInstance];
        if (callCenter != nil && [callCenter respondsToSelector:@selector(currentCalls)]) {
            for (TUCall *call in [callCenter currentCalls]) {
                if (call == nil || [call callStatus] == 6) continue;
                if ([callCenter respondsToSelector:@selector(activeConversationForCall:)]) {
                    recordActiveConversation([callCenter activeConversationForCall:call]);
                }
            }
        }

        NSArray<TUConversationLink *> *activatedLinks = [manager respondsToSelector:@selector(activatedConversationLinks)]
            ? [[manager activatedConversationLinks] allObjects]
            : @[];

        NSMutableArray<TUConversationLink *> *linksToRemove = [NSMutableArray array];
        NSUInteger skippedActiveCount = 0;

        for (TUConversationLink *link in activatedLinks) {
            NSString *lUrl = [link respondsToSelector:@selector(URL)] ? [[link URL] absoluteString] : nil;
            NSString *lPseudo = [link respondsToSelector:@selector(pseudonym)] ? BBNonEmptyString([link pseudonym]) : nil;
            NSString *lUnprefixed = [link respondsToSelector:@selector(unprefixedPseudonym)] ? BBNonEmptyString([link unprefixedPseudonym]) : nil;
            NSString *lUrlPseudo = extractPseudonymFromUrl(lUrl);
            NSString *lGroupUUID = [link respondsToSelector:@selector(groupUUID)] ? [[link groupUUID] UUIDString] : nil;

            BOOL matchesTarget = NO;
            if (targetUrl != nil && lUrl != nil &&
                [lUrl caseInsensitiveCompare:targetUrl] == NSOrderedSame) {
                matchesTarget = YES;
            }
            if (!matchesTarget && targetPseudonym != nil) {
                if ((lPseudo != nil && [lPseudo caseInsensitiveCompare:targetPseudonym] == NSOrderedSame) ||
                    (lUnprefixed != nil && [lUnprefixed caseInsensitiveCompare:targetPseudonym] == NSOrderedSame) ||
                    (lUrlPseudo != nil && [lUrlPseudo caseInsensitiveCompare:targetPseudonym] == NSOrderedSame)) {
                    matchesTarget = YES;
                }
            }
            if (!matchesTarget) continue;

            BOOL isActive =
                (lUrl != nil && [activeUrls containsObject:[lUrl lowercaseString]]) ||
                (lPseudo != nil && [activePseudonyms containsObject:[lPseudo lowercaseString]]) ||
                (lUnprefixed != nil && [activePseudonyms containsObject:[lUnprefixed lowercaseString]]) ||
                (lUrlPseudo != nil && [activePseudonyms containsObject:[lUrlPseudo lowercaseString]]) ||
                (lGroupUUID != nil && [activeGroupUUIDs containsObject:[lGroupUUID lowercaseString]]);
            if (isActive) {
                skippedActiveCount++;
                continue;
            }

            if (![linksToRemove containsObject:link]) {
                [linksToRemove addObject:link];
            }
        }

        if ([linksToRemove count] == 0) {
            BBSendReply(replyController, transaction, @{
                @"removed": @NO,
                @"removed_count": @0,
                @"skipped_active_count": @(skippedActiveCount),
            });
            return YES;
        }

        __block NSUInteger remainingLinks = [linksToRemove count];
        __block NSUInteger removedCount = 0;
        __block BOOL replied = NO;
        NSMutableArray *retainedClients = [NSMutableArray array];
        void (^finishReply)(void) = ^{
            if (replied) return;
            replied = YES;
            [retainedClients removeAllObjects];
            BBSendReply(replyController, transaction, @{
                @"removed": @(removedCount > 0),
                @"removed_count": @(removedCount),
                @"skipped_active_count": @(skippedActiveCount),
            });
        };

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            finishReply();
        });

        for (TUConversationLink *link in linksToRemove) {
            __block TUConversationManagerXPCClient *xpcClient = nil;
            void (^onDone)(BOOL, NSError *) = ^(BOOL ok, NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (xpcClient != nil) {
                        [retainedClients removeObject:xpcClient];
                        xpcClient = nil;
                    }
                    if (ok && err == nil) removedCount++;
                    remainingLinks--;
                    if (remainingLinks == 0) finishReply();
                });
            };
            if ([manager respondsToSelector:@selector(invalidateLink:completionHandler:)]) {
                [manager invalidateLink:link completionHandler:onDone];
            } else {
                xpcClient = [[TUConversationManagerXPCClient alloc] init];
                if (xpcClient != nil && [xpcClient respondsToSelector:@selector(invalidateLink:completionHandler:)]) {
                    [retainedClients addObject:xpcClient];
                    [xpcClient invalidateLink:link completionHandler:onDone];
                } else {
                    onDone(NO, [NSError errorWithDomain:@"BlueBubbles" code:1 userInfo:@{NSLocalizedDescriptionKey: @"XPC client unavailable"}]);
                }
            }
        }
        return YES;
    }
    return NO;
}

@end
