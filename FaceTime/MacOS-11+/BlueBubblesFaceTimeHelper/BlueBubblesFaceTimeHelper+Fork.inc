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

@interface TUJoinConversationRequest (Fork)
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

- (NSDictionary *)callStatusPayloadForCall:(TUCall *)call {
    if (call == nil) return nil;
    id provider = [call respondsToSelector:@selector(provider)] ? [call provider] : nil;
    NSString *providerIdentifier = [provider respondsToSelector:@selector(identifier)] ? [(TUCallProvider *)provider identifier] : nil;
    BOOL isTelephonyProvider = [provider respondsToSelector:@selector(isTelephonyProvider)] && [(TUCallProvider *)provider isTelephonyProvider];
    BOOL isFaceTimeProvider = [provider respondsToSelector:@selector(isFaceTimeProvider)] && [(TUCallProvider *)provider isFaceTimeProvider];
    BOOL isHostedOnCurrentDevice = [call respondsToSelector:@selector(isHostedOnCurrentDevice)] ? [call isHostedOnCurrentDevice] : YES;
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
            if ([seenNonDisconnectedCalls count] >= 512) {
                [seenNonDisconnectedCalls removeAllObjects];
            }
            if (resolvedCallUUID != nil) [seenNonDisconnectedCalls addObject:resolvedCallUUID];
            if (uniqueProxyIdentifier != nil) [seenNonDisconnectedCalls addObject:uniqueProxyIdentifier];
        } else {
            seenBefore = (resolvedCallUUID != nil && [seenNonDisconnectedCalls containsObject:resolvedCallUUID]) ||
                         (uniqueProxyIdentifier != nil && [seenNonDisconnectedCalls containsObject:uniqueProxyIdentifier]);
        }
    }
    BOOL isIncomingSilenced = (callStatus == 6) && !isOutgoing && neverConnected && !seenBefore;

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
        @"is_sending_audio": @([call isSendingAudio]),
        @"is_sending_video": @([call isSendingVideo]),
        @"is_outgoing": @(isOutgoing),
        @"is_video": @(isVideo),
        @"is_telephony": @(isTelephony),
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

        void (^dialViaRequest)(NSString *) = ^(NSString *pregeneratedUrl) {
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
                if ([pregeneratedUrl length] > 0) {
                    response[@"url"] = pregeneratedUrl;
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

        // Non-telephony FaceTime calls must start as a link-backed Group FaceTime conversation
        // (isOneToOneModeEnabled=NO) so web link participants never trigger GKVoiceChatServiceErrorDomain 32016.
        TUConversationManager *manager = [self sharedConversationManager];
        Class joinReqClass = NSClassFromString(@"TUJoinConversationRequest");
        Class memberClass = NSClassFromString(@"TUConversationMember");
        if (!isTelephony && manager != nil && joinReqClass != Nil && memberClass != Nil &&
            [manager respondsToSelector:@selector(generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:)] &&
            [callCenter respondsToSelector:@selector(joinConversationWithConversationRequest:)]) {
            __block BOOL handled = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (handled) return;
                handled = YES;
                DLog("BLUEBUBBLESFACETIMEHELPER: pre-call link generation timed out; falling back to TUDialRequest");
                dialViaRequest(nil);
            });

            NSSet<TUHandle *> *handleSet = [NSSet setWithArray:handles];
            [manager generateLinkWithInvitedMemberHandles:handleSet linkLifetimeScope:0 completionHandler:^(TUConversationLink *link, NSError *linkError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (handled) return;
                    handled = YES;

                    NSString *linkUrl = [[link URL] absoluteString];
                    if (link != nil && [linkUrl length] > 0) {
                        NSMutableSet<TUConversationMember *> *members = [NSMutableSet setWithCapacity:[handles count]];
                        for (TUHandle *h in handles) {
                            TUConversationMember *m = [[memberClass alloc] initWithHandle:h];
                            if (m != nil) [members addObject:m];
                        }
                        TUJoinConversationRequest *joinReq = [[joinReqClass alloc] initWithConversationLink:link
                                                                                        otherInvitedHandles:[NSSet set]
                                                                                              remoteMembers:members
                                                                                         sendLetMeInRequest:NO];
                        if (joinReq != nil) {
                            joinReq.video = video;
                            joinReq.videoEnabled = video;
                            if ([joinReq respondsToSelector:@selector(setAvMode:)]) {
                                joinReq.avMode = video ? 2 : 1;
                            }
                            joinReq.wantsStagingArea = NO;
                            joinReq.showUIPrompt = NO;
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
                                // Ensure invited remote members are buzzed/rung on link-backed GFT conversations.
                                if ([manager respondsToSelector:@selector(buzzMember:conversation:)] && [members count] > 0) {
                                    NSString *joinedCallUUID = [resolvedCallUUID copy];
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                                        TUCall *liveCall = BBFindCallByIdentifier(callCenter, joinedCallUUID);
                                        TUConversation *convo = liveCall != nil && [callCenter respondsToSelector:@selector(activeConversationForCall:)]
                                            ? [callCenter activeConversationForCall:liveCall]
                                            : nil;
                                        if (convo != nil && [[convo activeRemoteParticipants] count] == 0) {
                                            for (TUConversationMember *m in members) {
                                                [manager buzzMember:m conversation:convo];
                                            }
                                        }
                                    });
                                }
                                DLog("BLUEBUBBLESFACETIMEHELPER: started link-backed GFT call %{public}@ with link %{public}@", resolvedCallUUID, linkUrl);
                                NSMutableDictionary *response = [([self callStatusPayloadForCall:call] ?: @{}) mutableCopy];
                                response[@"call_uuid"] = resolvedCallUUID ?: [NSNull null];
                                if (uniqueProxyIdentifier != nil) {
                                    response[@"unique_proxy_identifier"] = uniqueProxyIdentifier;
                                }
                                response[@"url"] = linkUrl;
                                BBSendReply(replyController, transaction, response);
                                return;
                            }
                        }
                    }

                    DLog("BLUEBUBBLESFACETIMEHELPER: link-backed GFT start failed (err=%{public}@); falling back to TUDialRequest", linkError);
                    dialViaRequest(linkUrl);
                });
            }];
            return YES;
        }

        dialViaRequest(nil);
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
                if (([targetConvUUID length] > 0 && ([cGroupUUID isEqualToString:targetConvUUID] || [cUUID isEqualToString:targetConvUUID])) ||
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
                BOOL matchesGroup = [resolvedGroupUUID length] > 0 && [lGroupUUID isEqualToString:resolvedGroupUUID];
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
                    if (ok || err == nil) anyInvalidated = YES;
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
                    onDone(NO, nil);
                }
            }
        }
        return YES;
    }
    return NO;
}

@end
