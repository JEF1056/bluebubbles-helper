#import "FindMyFriendsRefreshCoordinator.h"

#import <os/log.h>

#import "FindMyFriendPayload.h"

// FindMyLocate.LocatePriority raw values: 0=backgroundAppRefresh, 1=shallow, 2=live, 3=backgroundProactive.
static const long long BBLocationRefreshPriority = 1;
static const long long BBFocusedLocationRefreshPriority = 2;

@interface FindMyFriendsRefreshCoordinator ()
@property(nonatomic, strong) id<FindMyLocateSessionProtocol> session;
@property(nonatomic, copy, nullable) NSString *transactionIdentifier;
@property(nonatomic, copy, nullable) NSString *focusedHandle;
@property(nonatomic) BOOL targetedOnly;
@property(nonatomic) NSTimeInterval friendListTimeout;
@property(nonatomic) NSTimeInterval locationRefreshTimeout;
@property(nonatomic, copy) FindMyFriendsRefreshResponseHandler responseHandler;
@property(nonatomic) BOOL friendListResolved;
@end

@implementation FindMyFriendsRefreshCoordinator

static os_log_t refreshLog;

+ (void)initialize {
    if (self == [FindMyFriendsRefreshCoordinator class]) {
        refreshLog = os_log_create("BlueBubblesFindMyHelper", "friends-refresh");
    }
}

- (instancetype)initWithSession:(id<FindMyLocateSessionProtocol>)session
           transactionIdentifier:(nullable NSString *)transactionIdentifier
                   focusedHandle:(nullable NSString *)focusedHandle
                    targetedOnly:(BOOL)targetedOnly
               friendListTimeout:(NSTimeInterval)friendListTimeout
          locationRefreshTimeout:(NSTimeInterval)locationRefreshTimeout
                 responseHandler:(FindMyFriendsRefreshResponseHandler)responseHandler {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _session = session;
    _transactionIdentifier = [transactionIdentifier copy];
    NSString *trimmedFocus = [focusedHandle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _focusedHandle = trimmedFocus.length > 0 ? [trimmedFocus copy] : nil;
    _targetedOnly = targetedOnly && _focusedHandle != nil;
    _friendListTimeout = friendListTimeout;
    _locationRefreshTimeout = locationRefreshTimeout;
    _responseHandler = [responseHandler copy];
    return self;
}

- (NSArray *)cachedFriends {
    NSArray *cachedFriends = nil;
    if ([self.session respondsToSelector:@selector(cachedFriendsSharingLocationWithMe)]) {
        cachedFriends = [self.session cachedFriendsSharingLocationWithMe];
    }
    if (cachedFriends == nil && [self.session respondsToSelector:@selector(cachedFriendsSharingLocationsWithMe)]) {
        cachedFriends = [self.session cachedFriendsSharingLocationsWithMe];
    }
    return [cachedFriends isKindOfClass:[NSArray class]] ? cachedFriends : @[];
}

- (NSArray *)prioritizedFriendRecords:(NSArray *)friendRecords {
    if (self.focusedHandle == nil) {
        return friendRecords;
    }

    NSMutableArray *focusedRecords = [[NSMutableArray alloc] init];
    NSMutableArray *remainingRecords = [[NSMutableArray alloc] initWithCapacity:friendRecords.count];
    for (id friendRecord in friendRecords) {
        id locationHandle = [FindMyFriendPayload handleForFriendRecord:friendRecord];
        NSString *friendIdentifier = [FindMyFriendPayload identifierForHandle:locationHandle];
        if (friendIdentifier != nil && [friendIdentifier caseInsensitiveCompare:self.focusedHandle] == NSOrderedSame) {
            [focusedRecords addObject:friendRecord];
        } else if (!self.targetedOnly) {
            [remainingRecords addObject:friendRecord];
        }
    }

    if (self.targetedOnly) {
        return focusedRecords;
    }
    if (focusedRecords.count == 0) {
        return friendRecords;
    }
    [focusedRecords addObjectsFromArray:remainingRecords];
    return focusedRecords;
}

- (void)refreshAndSendLocationsForFriends:(NSArray *)friendRecords friendListTimedOut:(BOOL)friendListTimedOut {
    NSMutableDictionary<NSString *, NSDictionary *> *locationsByFriendIdentifier = [[NSMutableDictionary alloc] init];
    NSMutableSet<NSString *> *pendingFriendIdentifiers = [[NSMutableSet alloc] init];
    NSMutableArray<void (^)(void)> *completeLocationRefreshBlocks = [[NSMutableArray alloc] init];
    dispatch_group_t locationRefreshGroup = dispatch_group_create();
    __block NSUInteger unidentifiedFriendCount = 0;
    __block id focusedLocationHandle = nil;

    NSArray *orderedFriendRecords = [self prioritizedFriendRecords:friendRecords];
    for (id friendRecord in orderedFriendRecords) {
        id locationHandle = [FindMyFriendPayload handleForFriendRecord:friendRecord];
        NSString *friendIdentifier = [FindMyFriendPayload identifierForHandle:locationHandle];
        if (friendIdentifier == nil) {
            unidentifiedFriendCount += 1;
            continue;
        }

        NSDictionary *cachedLocationPayload = [FindMyFriendPayload
            locationPayloadForLocation:[FindMyFriendPayload cachedLocationForHandle:locationHandle session:self.session]
                                 handle:locationHandle
                   isLocatingInProgress:@YES];
        if (cachedLocationPayload == nil) {
            unidentifiedFriendCount += 1;
            continue;
        }

        __block BOOL shouldRefreshLocation = NO;
        @synchronized (pendingFriendIdentifiers) {
            if (locationsByFriendIdentifier[friendIdentifier] == nil) {
                locationsByFriendIdentifier[friendIdentifier] = cachedLocationPayload;
                [pendingFriendIdentifiers addObject:friendIdentifier];
                shouldRefreshLocation = YES;
            }
        }
        if (!shouldRefreshLocation) {
            continue;
        }

        dispatch_group_enter(locationRefreshGroup);
        __block BOOL locationRefreshCompleted = NO;
        void (^completeLocationRefresh)(void) = ^{
            @synchronized (pendingFriendIdentifiers) {
                if (locationRefreshCompleted) {
                    return;
                }
                locationRefreshCompleted = YES;

                NSDictionary *refreshedLocationPayload = [FindMyFriendPayload
                    locationPayloadForLocation:[FindMyFriendPayload cachedLocationForHandle:locationHandle session:self.session]
                                         handle:locationHandle
                           isLocatingInProgress:nil];
                if (refreshedLocationPayload != nil) {
                    locationsByFriendIdentifier[friendIdentifier] = refreshedLocationPayload;
                }
                [pendingFriendIdentifiers removeObject:friendIdentifier];
            }
            dispatch_group_leave(locationRefreshGroup);
        };
        [completeLocationRefreshBlocks addObject:completeLocationRefresh];

        BOOL isFocusedFriend = self.focusedHandle != nil &&
            [friendIdentifier caseInsensitiveCompare:self.focusedHandle] == NSOrderedSame;
        BOOL useFocusedPriority = isFocusedFriend && !self.preserveFocusedLiveRefresh;
        long long refreshPriority = useFocusedPriority ? BBFocusedLocationRefreshPriority : BBLocationRefreshPriority;
        if (useFocusedPriority) {
            focusedLocationHandle = locationHandle;
        }
        [FindMyFriendPayload startRefreshingSession:self.session
                                            handles:@[locationHandle]
                                           priority:refreshPriority
                                         completion:completeLocationRefresh];
    }

    __block BOOL responseSent = NO;
    BOOL (^sendResponseOnce)(void) = ^BOOL {
        NSDictionary *response = nil;
        @synchronized (pendingFriendIdentifiers) {
            if (responseSent) {
                return NO;
            }
            responseSent = YES;
            response = [FindMyFriendPayload
                responseForTransactionIdentifier:self.transactionIdentifier
                     locationsByFriendIdentifier:locationsByFriendIdentifier
                        pendingFriendIdentifiers:pendingFriendIdentifiers
                              friendListTimedOut:friendListTimedOut
                       unidentifiedFriendCount:unidentifiedFriendCount];
        }
        self.responseHandler(response);
        if (focusedLocationHandle != nil &&
            [self.session respondsToSelector:@selector(stopRefreshingLocationForHandles:priority:isFromGroup:completion:)]) {
            // Drop the temporary priority-2 stream so targeted polls do not leak live battery drain.
            [self.session stopRefreshingLocationForHandles:@[focusedLocationHandle]
                                                priority:BBFocusedLocationRefreshPriority
                                             isFromGroup:NO
                                              completion:^{}];
        }
        return YES;
    };

    dispatch_group_notify(locationRefreshGroup, dispatch_get_main_queue(), ^{
        sendResponseOnce();
    });

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.locationRefreshTimeout * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            NSUInteger pendingFriendCount = 0;
            @synchronized (pendingFriendIdentifiers) {
                pendingFriendCount = pendingFriendIdentifiers.count;
            }
            if (!sendResponseOnce()) {
                return;
            }
            os_log(refreshLog, "Friend location deadline reached with %lu pending", (unsigned long)pendingFriendCount);
            for (void (^completeLocationRefresh)(void) in completeLocationRefreshBlocks) {
                completeLocationRefresh();
            }
        }
    );
}

- (void)resolveFriendList:(nullable NSArray *)requestedFriends timedOut:(BOOL)timedOut {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.friendListResolved) {
            return;
        }
        self.friendListResolved = YES;

        NSArray *friendRecords = [requestedFriends isKindOfClass:[NSArray class]]
            ? requestedFriends : [self cachedFriends];
        [self refreshAndSendLocationsForFriends:friendRecords friendListTimedOut:timedOut];
    });
}

- (void)start {
    if (self.targetedOnly && self.focusedHandle != nil) {
        NSArray *cachedTarget = [self prioritizedFriendRecords:[self cachedFriends]];
        if (cachedTarget.count > 0) {
            [self resolveFriendList:cachedTarget timedOut:NO];
            return;
        }
    }

    if (![self.session respondsToSelector:@selector(getFriendsSharingLocationsWithMeWithCompletion:)]) {
        [self resolveFriendList:[self cachedFriends] timedOut:NO];
        return;
    }

    [self.session getFriendsSharingLocationsWithMeWithCompletion:^(NSArray *requestedFriends) {
        [self resolveFriendList:requestedFriends timedOut:NO];
    }];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.friendListTimeout * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            if (self.friendListResolved) {
                return;
            }
            os_log(refreshLog, "Friend list deadline reached; using cached friends");
            [self resolveFriendList:[self cachedFriends] timedOut:YES];
        }
    );
}

@end
