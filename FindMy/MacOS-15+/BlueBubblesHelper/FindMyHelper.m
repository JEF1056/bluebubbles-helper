#import "FindMyHelper.h"

#import <os/log.h>

#import "FindMyLocateSession.h"
#import "FindMyDeviceSnapshotBridge.h"
#import "FindMyDevicesDataSourceCapture.h"
#import "FindMyDevicesRefreshCoordinator.h"
#import "FindMyFriendPayload.h"
#import "FindMyFriendsRefreshCoordinator.h"
#import "FindMyPeopleFocusController.h"
#import "ServerConnection.h"

static const NSTimeInterval BBConnectionDelaySeconds = 5.0;
static const NSTimeInterval BBFriendListTimeoutSeconds = 5.0;
static const NSTimeInterval BBLocationRefreshTimeoutSeconds = 8.0;
static const NSTimeInterval BBDevicesDataSourceTimeoutSeconds = 5.0;
static const NSTimeInterval BBDevicesDataSourcePollIntervalSeconds = 0.1;
static const NSTimeInterval BBDevicesActiveRefreshTimeoutSeconds = 8.0;
static const NSTimeInterval BBDevicesActiveRefreshPollIntervalSeconds = 0.5;
static const NSTimeInterval BBLiveKeepaliveIntervalSeconds = 15.0;
static const NSTimeInterval BBLiveKeepaliveMaxTTLSeconds = 600.0;

extern void * _Nullable BlueBubblesFindMyCopyFMIPManager(void * _Nullable dataSource);
// FindMyLocate.LocatePriority raw values: 0=backgroundAppRefresh, 1=shallow, 2=live, 3=backgroundProactive.
static const long long BBShallowLocationRefreshPriority = 1;
static const long long BBLiveLocationRefreshPriority = 2;

@protocol BBFindMyLocationType <NSObject>
- (long long)locationType;
@end

@interface FindMyHelper ()
@property(nonatomic, strong, nullable) FindMyLocateSession *activeLocateSession;
@property(nonatomic, strong) NSMutableSet<FindMyFriendsRefreshCoordinator *> *activeFriendRefreshes;
@property(nonatomic, strong) NSMutableSet<FindMyDevicesRefreshCoordinator *> *activeDeviceRefreshes;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *inFlightRefreshHandleCounts;
@property(nonatomic) BOOL friendStreamingStarted;
@property(nonatomic) BOOL friendUpdatesActive;
@property(nonatomic) NSUInteger connectionGeneration;
@property(nonatomic) NSUInteger activeForcedDeviceRefreshCount;
@property(nonatomic, copy, nullable) NSString *activeLiveNormalizedIdentifier;
@property(nonatomic, copy, nullable) NSString *pendingLiveNormalizedIdentifier;
@property(nonatomic, strong, nullable) id activeLiveHandleObject;
@property(nonatomic, copy, nullable) NSArray<NSString *> *activeLiveFocusTargets;
@property(nonatomic, strong, nullable) dispatch_source_t liveKeepaliveTimer;
@property(nonatomic, strong, nullable) id<NSObject> liveActivityToken;
@property(nonatomic) NSUInteger liveSessionGeneration;
- (nullable FindMyLocateSession *)locateSession;
- (void)startStreamingLocationsForAllFriends:(FindMyLocateSession *)session
                               focusedHandle:(nullable NSString *)focusedHandle;
- (void)restoreFocusConditionsIfIdle;
- (void)stopLiveLocationSession;
- (void)startLiveKeepaliveTimerForGeneration:(NSUInteger)generation;
- (void)stopLiveKeepaliveTimer;

- (void)handleFriendsRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                data:(nullable NSDictionary *)data;
- (void)handleStartLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                   data:(nullable NSDictionary *)data;
- (void)handleStopLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                  data:(nullable NSDictionary *)data;
- (void)handleDevicesRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                data:(nullable NSDictionary *)data;
- (void)sendError:(NSString *)errorMessage transactionIdentifier:(nullable NSString *)transactionIdentifier;
@end

static NSString * _Nullable BBTrimmedString(id _Nullable value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

@implementation FindMyHelper

static os_log_t helperLog;

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _activeFriendRefreshes = [[NSMutableSet alloc] init];
        _activeDeviceRefreshes = [[NSMutableSet alloc] init];
        _inFlightRefreshHandleCounts = [[NSMutableDictionary alloc] init];
    }
    return self;
}

+ (instancetype)sharedInstance {
    static FindMyHelper *sharedHelper = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedHelper = [[self alloc] init];
        helperLog = os_log_create("BlueBubblesFindMyHelper", "helper");
    });
    return sharedHelper;
}

+ (void)load {
    [FindMyHelper sharedInstance];

    NSString *hostBundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (![hostBundleIdentifier isEqualToString:@"com.apple.findmy"]) {
        os_log_error(helperLog, "Refusing injection into %{public}@", hostBundleIdentifier);
        return;
    }

    NSOperatingSystemVersion operatingSystemVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
    os_log(
        helperLog,
        "Loaded on macOS %ld.%ld.%ld",
        (long)operatingSystemVersion.majorVersion,
        (long)operatingSystemVersion.minorVersion,
        (long)operatingSystemVersion.patchVersion
    );

    [[FindMyDevicesDataSourceCapture sharedInstance] installCapture];
    [[FindMyPeopleFocusController sharedInstance] installCapture];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BBConnectionDelaySeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            [[FindMyDevicesDataSourceCapture sharedInstance] installCapture];
            [[FindMyPeopleFocusController sharedInstance] installCapture];
            [[ServerConnection sharedInstance] connect];
        }
    );
}

- (void)handleServerAction:(nullable NSString *)action
     transactionIdentifier:(nullable NSString *)transactionIdentifier {
    [self handleServerAction:action data:nil transactionIdentifier:transactionIdentifier];
}

- (void)handleServerAction:(nullable NSString *)action
                      data:(nullable NSDictionary *)data
     transactionIdentifier:(nullable NSString *)transactionIdentifier {
    if ([action isEqualToString:@"refresh-findmy-friends"]) {
        [self handleFriendsRefreshForTransactionIdentifier:transactionIdentifier data:data];
        return;
    }

    if ([action isEqualToString:@"start-findmy-live-location"]) {
        [self handleStartLiveLocationForTransactionIdentifier:transactionIdentifier data:data];
        return;
    }

    if ([action isEqualToString:@"stop-findmy-live-location"]) {
        [self handleStopLiveLocationForTransactionIdentifier:transactionIdentifier data:data];
        return;
    }

    if ([action isEqualToString:@"refresh-findmy-devices"]) {
        [self handleDevicesRefreshForTransactionIdentifier:transactionIdentifier data:data];
        return;
    }

    if (action == nil) {
        os_log(helperLog, "Ignoring Private API action without a name");
        return;
    }

    NSRange findMyMarker = [action rangeOfString:@"findmy" options:NSCaseInsensitiveSearch];
    if (findMyMarker.location == NSNotFound) {
        os_log(helperLog, "Ignoring unrelated Private API action: %{public}@", action);
        return;
    }

    NSString *errorMessage = [NSString stringWithFormat:@"Find My action not implemented: %@", action];
    [self sendError:errorMessage transactionIdentifier:transactionIdentifier];
}

- (void)startFriendUpdatesForSession:(FindMyLocateSession *)session
                          generation:(NSUInteger)generation {
    if (session == nil || self.friendUpdatesActive || self.connectionGeneration != generation) {
        return;
    }
    if (![session respondsToSelector:@selector(startUpdatingFriendsWithInitialUpdates:completion:)]) {
        return;
    }
    self.friendUpdatesActive = YES;
    __weak typeof(self) weakSelf = self;
    [session startUpdatingFriendsWithInitialUpdates:YES completion:^{
        os_log(helperLog, "Find My friend updates started");
        dispatch_async(dispatch_get_main_queue(), ^{
            FindMyHelper *strongSelf = weakSelf;
            if (strongSelf == nil ||
                strongSelf.connectionGeneration != generation ||
                strongSelf.activeLocateSession != session ||
                strongSelf.friendStreamingStarted) {
                return;
            }
            strongSelf.friendStreamingStarted = YES;
            [strongSelf startStreamingLocationsForAllFriends:session focusedHandle:nil];
        });
    }];
}

- (void)handleServerRegistered {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.connectionGeneration += 1;
        NSUInteger generation = self.connectionGeneration;
        FindMyLocateSession *session = [self locateSession];
        if (session == nil) {
            return;
        }
        [self startFriendUpdatesForSession:session generation:generation];
        if (self.friendStreamingStarted) {
            return;
        }
        self.friendStreamingStarted = YES;
        [self startStreamingLocationsForAllFriends:session focusedHandle:nil];
    });
}

- (void)handleServerDisconnected {
    void (^cleanup)(void) = ^{
        self.connectionGeneration += 1;
        [self stopLiveLocationSession];
        self.friendStreamingStarted = NO;
        self.friendUpdatesActive = NO;
        FindMyLocateSession *session = self.activeLocateSession;
        if (session != nil) {
            NSArray *cachedFriends = nil;
            if ([session respondsToSelector:@selector(cachedFriendsSharingLocationsWithMe)]) {
                cachedFriends = [session cachedFriendsSharingLocationsWithMe];
            } else if ([session respondsToSelector:@selector(cachedFriendsSharingLocationWithMe)]) {
                cachedFriends = [session cachedFriendsSharingLocationWithMe];
            }
            if ([cachedFriends isKindOfClass:[NSArray class]] && cachedFriends.count > 0 &&
                [session respondsToSelector:@selector(stopRefreshingLocationForHandles:priority:isFromGroup:completion:)]) {
                NSMutableArray *handles = [[NSMutableArray alloc] initWithCapacity:cachedFriends.count];
                for (id friendRecord in cachedFriends) {
                    id handle = [FindMyFriendPayload handleForFriendRecord:friendRecord] ?: friendRecord;
                    if (handle != nil) {
                        [handles addObject:handle];
                    }
                }
                if (handles.count > 0) {
                    [session stopRefreshingLocationForHandles:handles
                                                     priority:BBShallowLocationRefreshPriority
                                                  isFromGroup:NO
                                                   completion:^{}];
                }
            }
            SEL stopUpdatingSel = NSSelectorFromString(@"stopUpdatingFriendsWithCompletion:");
            if ([session respondsToSelector:stopUpdatingSel]) {
                void (*imp)(id, SEL, void (^)(void)) =
                    (void (*)(id, SEL, void (^)(void)))[session methodForSelector:stopUpdatingSel];
                imp(session, stopUpdatingSel, ^{});
            }
        }
        [[FindMyPeopleFocusController sharedInstance] restoreBackgroundRefreshConditions];
    };
    if ([NSThread isMainThread]) {
        cleanup();
    } else {
        dispatch_async(dispatch_get_main_queue(), cleanup);
    }
}

- (void)sendTransactionResponse:(nullable NSString *)transactionIdentifier payload:(NSDictionary *)payload {
    if (transactionIdentifier == nil) {
        return;
    }
    NSMutableDictionary *message = [payload mutableCopy];
    message[@"transactionId"] = transactionIdentifier;
    [[ServerConnection sharedInstance] sendMessage:message];
}

- (void)adjustInFlightRefreshCountForIdentifier:(nullable NSString *)identifier delta:(NSInteger)delta {
    if (identifier.length == 0 || delta == 0) {
        return;
    }
    @synchronized (self.inFlightRefreshHandleCounts) {
        NSInteger next = [self.inFlightRefreshHandleCounts[identifier] integerValue] + delta;
        if (next <= 0) {
            [self.inFlightRefreshHandleCounts removeObjectForKey:identifier];
        } else {
            self.inFlightRefreshHandleCounts[identifier] = @(next);
        }
    }
}

- (void)sendError:(NSString *)errorMessage transactionIdentifier:(nullable NSString *)transactionIdentifier {
    os_log_error(helperLog, "%{public}@", errorMessage);
    [self sendTransactionResponse:transactionIdentifier payload:@{@"error": errorMessage}];
}

- (nullable FindMyLocateSession *)locateSession {
    if (self.activeLocateSession != nil) {
        return self.activeLocateSession;
    }

    Class locateSessionClass = NSClassFromString(@"FindMyLocateSession");
    if (locateSessionClass == nil) {
        NSError *frameworkLoadError = nil;
        NSBundle *wrapperFramework = [NSBundle
            bundleWithPath:@"/System/Library/PrivateFrameworks/FindMyLocateObjCWrapper.framework"];
        if (![wrapperFramework loadAndReturnError:&frameworkLoadError]) {
            os_log_error(helperLog, "Unable to load FindMyLocateObjCWrapper: %{public}@", frameworkLoadError);
        }
        locateSessionClass = NSClassFromString(@"FindMyLocateSession");
    }

    if (locateSessionClass == nil) {
        os_log_error(helperLog, "FindMyLocateSession is unavailable");
        return nil;
    }

    self.activeLocateSession = [[locateSessionClass alloc] init];

    if ([self.activeLocateSession respondsToSelector:@selector(setLocationUpdateCallback:)]) {
        __weak typeof(self) weakSelf = self;
        [self.activeLocateSession setLocationUpdateCallback:^(id _Nullable location, id handle) {
            FindMyHelper *strongSelf = weakSelf;
            NSString *handleIdentifier = [FindMyFriendPayload identifierForHandle:handle];
            BOOL isLiveLocation = location != nil &&
                [location respondsToSelector:@selector(locationType)] &&
                [(id<BBFindMyLocationType>)location locationType] == 2;
            NSNumber *isLocatingOverride = nil;
            if (strongSelf != nil && handleIdentifier != nil) {
                NSString *normalizedIdentifier = handleIdentifier.lowercaseString;
                @synchronized (strongSelf.inFlightRefreshHandleCounts) {
                    if (isLiveLocation) {
                        [strongSelf.inFlightRefreshHandleCounts removeObjectForKey:normalizedIdentifier];
                        isLocatingOverride = @NO;
                    } else if ([strongSelf.inFlightRefreshHandleCounts[normalizedIdentifier] integerValue] > 0) {
                        isLocatingOverride = @YES;
                    }
                }
            }
            NSDictionary *locationPayload = [FindMyFriendPayload locationPayloadForLocation:location
                                                                                     handle:handle
                                                                       isLocatingInProgress:isLocatingOverride];
            if (locationPayload == nil) {
                return;
            }
            id coordinates = locationPayload[@"coordinates"];
            if (![coordinates isKindOfClass:[NSArray class]]) {
                return;
            }
            [[ServerConnection sharedInstance] sendMessage:@{
                @"event": @"new-findmy-location",
                @"data": @[locationPayload],
            }];
        }];
    }

    [self startFriendUpdatesForSession:self.activeLocateSession generation:self.connectionGeneration];

    if ([self.activeLocateSession respondsToSelector:@selector(startMonitoringActiveLocationSharingDeviceChangeWithCompletion:)]) {
        [self.activeLocateSession startMonitoringActiveLocationSharingDeviceChangeWithCompletion:^{
            os_log(helperLog, "Find My active-device monitoring started");
        }];
    }

    return self.activeLocateSession;
}

- (void)startStreamingLocationsForAllFriends:(FindMyLocateSession *)session
                               focusedHandle:(nullable NSString *)focusedHandle {
    NSString *trimmedFocus = [focusedHandle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *normalizedFocus = trimmedFocus.length > 0 ? trimmedFocus : self.activeLiveNormalizedIdentifier;

    void (^refreshHandles)(NSArray * _Nullable) = ^(NSArray * _Nullable friendRecords) {
        if (![friendRecords isKindOfClass:[NSArray class]] || friendRecords.count == 0) {
            return;
        }
        NSMutableArray *focusedHandles = [[NSMutableArray alloc] init];
        NSMutableArray *remainingHandles = [[NSMutableArray alloc] initWithCapacity:friendRecords.count];
        for (id friendRecord in friendRecords) {
            id handle = [FindMyFriendPayload handleForFriendRecord:friendRecord] ?: friendRecord;
            NSString *identifier = [FindMyFriendPayload identifierForHandle:handle];
            if (handle != nil && identifier != nil) {
                if (normalizedFocus != nil && [identifier caseInsensitiveCompare:normalizedFocus] == NSOrderedSame) {
                    [focusedHandles addObject:handle];
                } else {
                    [remainingHandles addObject:handle];
                }
            }
        }
        [FindMyFriendPayload startRefreshingSession:session handles:focusedHandles priority:BBLiveLocationRefreshPriority completion:nil];
        [FindMyFriendPayload startRefreshingSession:session handles:remainingHandles priority:BBShallowLocationRefreshPriority completion:nil];
    };

    if ([session respondsToSelector:@selector(getFriendsSharingLocationsWithMeWithCompletion:)]) {
        [session getFriendsSharingLocationsWithMeWithCompletion:^(NSArray * _Nullable friendRecords) {
            dispatch_async(dispatch_get_main_queue(), ^{
                refreshHandles(friendRecords);
            });
        }];
    } else if ([session respondsToSelector:@selector(cachedFriendsSharingLocationsWithMe)]) {
        refreshHandles([session cachedFriendsSharingLocationsWithMe]);
    }
}

- (nullable id)findHandleObjectForIdentifier:(NSString *)identifier inFriendRecords:(nullable NSArray *)friendRecords {
    if (![friendRecords isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (id friendRecord in friendRecords) {
        id handle = [FindMyFriendPayload handleForFriendRecord:friendRecord] ?: friendRecord;
        NSString *candidate = [FindMyFriendPayload identifierForHandle:handle];
        if (candidate != nil && [candidate caseInsensitiveCompare:identifier] == NSOrderedSame) {
            return handle;
        }
    }
    return nil;
}

- (void)resolveHandleObjectForIdentifier:(NSString *)identifier
                                 session:(FindMyLocateSession *)session
                              completion:(void (^)(id _Nullable handleObject))completion {
    NSArray *cachedFriends = nil;
    if ([session respondsToSelector:@selector(cachedFriendsSharingLocationsWithMe)]) {
        cachedFriends = [session cachedFriendsSharingLocationsWithMe];
    } else if ([session respondsToSelector:@selector(cachedFriendsSharingLocationWithMe)]) {
        cachedFriends = [session cachedFriendsSharingLocationWithMe];
    }
    id cachedHandle = [self findHandleObjectForIdentifier:identifier inFriendRecords:cachedFriends];
    if (cachedHandle != nil) {
        completion(cachedHandle);
        return;
    }

    if ([session respondsToSelector:@selector(getFriendsSharingLocationsWithMeWithCompletion:)]) {
        [session getFriendsSharingLocationsWithMeWithCompletion:^(NSArray * _Nullable friendRecords) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([self findHandleObjectForIdentifier:identifier inFriendRecords:friendRecords]);
            });
        }];
        return;
    }

    completion(nil);
}

- (void)stopLiveRefreshForHandleObject:(id)handleObject
                  normalizedIdentifier:(nullable NSString *)normalizedIdentifier
                               session:(nullable FindMyLocateSession *)session {
    if (normalizedIdentifier != nil) {
        @synchronized (self.inFlightRefreshHandleCounts) {
            [self.inFlightRefreshHandleCounts removeObjectForKey:normalizedIdentifier];
        }
    }
    if (handleObject == nil || session == nil) {
        return;
    }
    if ([session respondsToSelector:@selector(stopRefreshingLocationForHandles:priority:isFromGroup:completion:)]) {
        [session stopRefreshingLocationForHandles:@[handleObject]
                                         priority:BBLiveLocationRefreshPriority
                                      isFromGroup:NO
                                       completion:^{
            os_log(helperLog, "Stopped Find My live refresh for %{public}@", normalizedIdentifier ?: @"handle");
        }];
    }
}

- (NSArray<NSString *> *)focusTargetsFromData:(nullable NSDictionary *)data {
    if (![data isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    NSMutableArray<NSString *> *targets = [[NSMutableArray alloc] init];
    void (^addTarget)(id) = ^(id value) {
        NSString *trimmed = BBTrimmedString(value);
        if (trimmed != nil && ![targets containsObject:trimmed]) {
            [targets addObject:trimmed];
        }
    };
    for (NSString *key in @[@"handle", @"displayName", @"name", @"fullName"]) {
        addTarget(data[key]);
    }
    if ([data[@"handles"] isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)data[@"handles"]) {
            addTarget(item);
        }
    }
    return targets;
}

- (void)handleStartLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                   data:(nullable NSDictionary *)data {
    NSString *trimmedHandle = BBTrimmedString(data[@"handle"]);
    if (trimmedHandle == nil && [data[@"handles"] isKindOfClass:[NSArray class]]) {
        trimmedHandle = BBTrimmedString([(NSArray *)data[@"handles"] firstObject]);
    }
    if (trimmedHandle == nil) {
        [self sendError:@"Missing handle for start-findmy-live-location" transactionIdentifier:transactionIdentifier];
        return;
    }

    NSArray<NSString *> *focusTargets = [self focusTargetsFromData:data];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[FindMyPeopleFocusController sharedInstance] scheduleFocusPeopleTabAndSelectTargets:focusTargets];

        FindMyLocateSession *session = [self locateSession];
        if (session == nil) {
            [self sendError:@"FindMyLocateSession is unavailable" transactionIdentifier:transactionIdentifier];
            return;
        }

        self.liveSessionGeneration += 1;
        NSUInteger sessionGen = self.liveSessionGeneration;
        NSString *normalizedTarget = trimmedHandle.lowercaseString;
        self.pendingLiveNormalizedIdentifier = normalizedTarget;
        for (FindMyFriendsRefreshCoordinator *coordinator in self.activeFriendRefreshes) {
            if ([coordinator.focusedHandle.lowercaseString isEqualToString:normalizedTarget]) {
                coordinator.preserveFocusedLiveRefresh = YES;
            }
        }

        if (self.activeLiveHandleObject != nil &&
            self.activeLiveNormalizedIdentifier != nil &&
            ![self.activeLiveNormalizedIdentifier isEqualToString:normalizedTarget]) {
            id priorHandle = self.activeLiveHandleObject;
            NSString *priorIdentifier = self.activeLiveNormalizedIdentifier;
            self.activeLiveHandleObject = nil;
            self.activeLiveNormalizedIdentifier = nil;
            [self stopLiveRefreshForHandleObject:priorHandle normalizedIdentifier:priorIdentifier session:session];
        }

        __weak typeof(self) weakSelf = self;
        [self resolveHandleObjectForIdentifier:trimmedHandle
                                       session:session
                                    completion:^(id _Nullable targetHandleObject) {
            FindMyHelper *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            if (sessionGen != strongSelf.liveSessionGeneration) {
                [strongSelf restoreFocusConditionsIfIdle];
                [strongSelf sendTransactionResponse:transactionIdentifier payload:@{
                    @"live": @NO,
                    @"superseded": @YES,
                    @"handle": trimmedHandle,
                    @"locations": @[],
                }];
                return;
            }
            if (targetHandleObject == nil) {
                if ([strongSelf.pendingLiveNormalizedIdentifier isEqualToString:normalizedTarget]) {
                    strongSelf.pendingLiveNormalizedIdentifier = nil;
                }
                [strongSelf restoreFocusConditionsIfIdle];
                [strongSelf sendError:[NSString stringWithFormat:@"Find My friend handle not found: %@", trimmedHandle]
                transactionIdentifier:transactionIdentifier];
                return;
            }

            if ([strongSelf.pendingLiveNormalizedIdentifier isEqualToString:normalizedTarget]) {
                strongSelf.pendingLiveNormalizedIdentifier = nil;
            }
            strongSelf.activeLiveNormalizedIdentifier = normalizedTarget;
            strongSelf.activeLiveHandleObject = targetHandleObject;

            [strongSelf adjustInFlightRefreshCountForIdentifier:normalizedTarget delta:1];

            __block BOOL inFlightCountCleared = NO;
            void (^clearInFlightCount)(void) = ^{
                @synchronized (strongSelf.inFlightRefreshHandleCounts) {
                    if (inFlightCountCleared) {
                        return;
                    }
                    inFlightCountCleared = YES;
                }
                [strongSelf adjustInFlightRefreshCountForIdentifier:normalizedTarget delta:-1];
            };

            id cachedLocation = [FindMyFriendPayload cachedLocationForHandle:targetHandleObject session:session];
            BOOL cachedIsLive = cachedLocation != nil &&
                [cachedLocation respondsToSelector:@selector(locationType)] &&
                [(id<BBFindMyLocationType>)cachedLocation locationType] == 2;
            NSDictionary *cachedPayload = [FindMyFriendPayload
                locationPayloadForLocation:cachedLocation
                                    handle:targetHandleObject
                      isLocatingInProgress:cachedIsLive ? @NO : @YES];

            [FindMyFriendPayload startRefreshingSession:session
                                                handles:@[targetHandleObject]
                                               priority:BBLiveLocationRefreshPriority
                                             completion:clearInFlightCount];

            // Safety valve so locating indicator does not stay stuck if Apple's completion hangs.
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BBLocationRefreshTimeoutSeconds * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                clearInFlightCount
            );

            NSString *canonicalHandle = [FindMyFriendPayload identifierForHandle:targetHandleObject];
            NSArray<NSString *> *resolvedTargets = focusTargets;
            if (canonicalHandle.length > 0 && ![focusTargets containsObject:canonicalHandle]) {
                resolvedTargets = [focusTargets arrayByAddingObject:canonicalHandle];
                [[FindMyPeopleFocusController sharedInstance] scheduleFocusPeopleTabAndSelectTargets:resolvedTargets];
            }
            strongSelf.activeLiveFocusTargets = resolvedTargets;
            [strongSelf startLiveKeepaliveTimerForGeneration:sessionGen];

            [strongSelf sendTransactionResponse:transactionIdentifier payload:@{
                @"live": @YES,
                @"handle": canonicalHandle ?: trimmedHandle,
                @"locations": cachedPayload != nil ? @[cachedPayload] : @[],
            }];
        }];
    });
}

- (void)handleStopLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                  data:(nullable NSDictionary *)data {
    NSString *trimmedHandle = BBTrimmedString(data[@"handle"]);
    NSString *normalizedTarget = trimmedHandle.lowercaseString;

    dispatch_async(dispatch_get_main_queue(), ^{
        FindMyLocateSession *session = self.activeLocateSession;
        NSString *currentLiveIdentifier = self.activeLiveNormalizedIdentifier ?: self.pendingLiveNormalizedIdentifier;

        if (normalizedTarget != nil &&
            currentLiveIdentifier != nil &&
            ![currentLiveIdentifier isEqualToString:normalizedTarget]) {
            [self sendTransactionResponse:transactionIdentifier payload:@{
                @"stopped": @NO,
                @"handle": trimmedHandle,
                @"activeHandle": currentLiveIdentifier,
            }];
            return;
        }

        self.liveSessionGeneration += 1;
        [self stopLiveKeepaliveTimer];
        id handleToStop = self.activeLiveHandleObject;
        NSString *stoppedIdentifier = currentLiveIdentifier ?: normalizedTarget;
        self.activeLiveHandleObject = nil;
        self.activeLiveNormalizedIdentifier = nil;
        self.pendingLiveNormalizedIdentifier = nil;
        self.activeLiveFocusTargets = nil;

        [self stopLiveRefreshForHandleObject:handleToStop normalizedIdentifier:stoppedIdentifier session:session];
        [self restoreFocusConditionsIfIdle];

        [self sendTransactionResponse:transactionIdentifier payload:@{
            @"stopped": @(handleToStop != nil),
            @"handle": stoppedIdentifier ?: [NSNull null],
        }];
    });
}

- (void)handleFriendsRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                data:(nullable NSDictionary *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        FindMyLocateSession *session = [self locateSession];
        if (session == nil) {
            [self sendError:@"FindMyLocateSession is unavailable" transactionIdentifier:transactionIdentifier];
            return;
        }

        NSString *focusedHandle = BBTrimmedString(data[@"handle"]);
        if (focusedHandle == nil && [data[@"handles"] isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)data[@"handles"]) {
                focusedHandle = BBTrimmedString(item);
                if (focusedHandle != nil) {
                    break;
                }
            }
        }
        NSArray<NSString *> *focusTargets = [self focusTargetsFromData:data];
        BOOL targetedOnly = focusedHandle != nil || focusTargets.count > 0;
        if (targetedOnly && focusTargets.count > 0) {
            [[FindMyPeopleFocusController sharedInstance] scheduleFocusPeopleTabAndSelectTargets:focusTargets];
        }
        NSString *normalizedFocusKey = focusedHandle.lowercaseString;
        [self adjustInFlightRefreshCountForIdentifier:normalizedFocusKey delta:1];

        __weak typeof(self) weakSelf = self;
        __block __weak FindMyFriendsRefreshCoordinator *weakCoordinator = nil;
        FindMyFriendsRefreshCoordinator *coordinator = [[FindMyFriendsRefreshCoordinator alloc]
            initWithSession:session
            transactionIdentifier:transactionIdentifier
            focusedHandle:focusedHandle
            targetedOnly:targetedOnly
            friendListTimeout:BBFriendListTimeoutSeconds
            locationRefreshTimeout:BBLocationRefreshTimeoutSeconds
            responseHandler:^(NSDictionary *response) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[ServerConnection sharedInstance] sendMessage:response];
                    FindMyHelper *strongSelf = weakSelf;
                    if (strongSelf != nil) {
                        [strongSelf adjustInFlightRefreshCountForIdentifier:normalizedFocusKey delta:-1];
                        if (weakCoordinator != nil) {
                            [strongSelf.activeFriendRefreshes removeObject:weakCoordinator];
                        }
                        [strongSelf restoreFocusConditionsIfIdle];
                        if (!strongSelf.friendStreamingStarted) {
                            strongSelf.friendStreamingStarted = YES;
                            [strongSelf startStreamingLocationsForAllFriends:session focusedHandle:nil];
                        }
                    }
                });
            }];
        if (normalizedFocusKey != nil &&
            ([normalizedFocusKey isEqualToString:self.activeLiveNormalizedIdentifier] ||
             [normalizedFocusKey isEqualToString:self.pendingLiveNormalizedIdentifier])) {
            coordinator.preserveFocusedLiveRefresh = YES;
        }
        weakCoordinator = coordinator;
        [self.activeFriendRefreshes addObject:coordinator];
        [coordinator start];
    });
}

- (void)handleDevicesRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                data:(nullable NSDictionary *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        FindMyDevicesDataSourceCapture *dataSourceCapture = [FindMyDevicesDataSourceCapture sharedInstance];
        [dataSourceCapture installCapture];

        NSString *deviceId = BBTrimmedString(data[@"deviceId"]);
        BOOL force = [data[@"force"] respondsToSelector:@selector(boolValue)] ? [data[@"force"] boolValue] : NO;

        __weak typeof(self) weakSelf = self;
        __block __weak FindMyDevicesRefreshCoordinator *weakCoordinator = nil;
        __block BOOL triggeredForceRefresh = NO;
        FindMyDevicesRefreshCoordinator *coordinator = [[FindMyDevicesRefreshCoordinator alloc]
            initWithTransactionIdentifier:transactionIdentifier
            dataSourceTimeout:BBDevicesDataSourceTimeoutSeconds
            pollInterval:BBDevicesDataSourcePollIntervalSeconds
            deviceId:deviceId
            force:force
            activeRefreshTimeout:BBDevicesActiveRefreshTimeoutSeconds
            activePollInterval:BBDevicesActiveRefreshPollIntervalSeconds
            dataSourceProvider:^id _Nullable {
                [dataSourceCapture installCapture];
                return dataSourceCapture.devicesDataSource;
            }
            snapshotProvider:^NSDictionary *(id dataSource) {
                return [FindMyDeviceSnapshotBridge snapshotForDataSource:dataSource];
            }
            refreshTrigger:^BOOL(id dataSource, NSString * _Nullable __unused targetDeviceId, BOOL forceRefresh) {
                void *managerPtr = BlueBubblesFindMyCopyFMIPManager((__bridge void *)dataSource);
                if (managerPtr == NULL) {
                    return NO;
                }
                id manager = CFBridgingRelease(managerPtr);
                BOOL triggered = [FindMyDevicesRefreshCoordinator triggerFMIPManagerRefresh:manager];
                FindMyHelper *strongSelf = weakSelf;
                if (triggered && forceRefresh && strongSelf != nil) {
                    strongSelf.activeForcedDeviceRefreshCount += 1;
                    triggeredForceRefresh = YES;
                }
                return triggered;
            }
            responseHandler:^(NSDictionary *response) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    FindMyHelper *strongSelf = weakSelf;
                    BOOL shouldRestoreThrottle = NO;
                    if (triggeredForceRefresh) {
                        triggeredForceRefresh = NO;
                        if (strongSelf != nil) {
                            if (strongSelf.activeForcedDeviceRefreshCount > 0) {
                                strongSelf.activeForcedDeviceRefreshCount -= 1;
                            }
                            shouldRestoreThrottle = (strongSelf.activeForcedDeviceRefreshCount == 0);
                        }
                    }
                    if (shouldRestoreThrottle && dataSourceCapture.devicesDataSource != nil) {
                        void *managerPtr = BlueBubblesFindMyCopyFMIPManager((__bridge void *)dataSourceCapture.devicesDataSource);
                        if (managerPtr != NULL) {
                            id manager = CFBridgingRelease(managerPtr);
                            [FindMyDevicesRefreshCoordinator restoreFMIPManagerRefreshThrottle:manager];
                        }
                    }
                    [[ServerConnection sharedInstance] sendMessage:response];
                    if (strongSelf != nil && weakCoordinator != nil) {
                        [strongSelf.activeDeviceRefreshes removeObject:weakCoordinator];
                    }
                });
            }];
        weakCoordinator = coordinator;
        [self.activeDeviceRefreshes addObject:coordinator];
        [coordinator start];
    });
}

- (void)stopLiveLocationSession {
    self.liveSessionGeneration += 1;
    [self stopLiveKeepaliveTimer];
    id handleToStop = self.activeLiveHandleObject;
    NSString *stoppedIdentifier = self.activeLiveNormalizedIdentifier ?: self.pendingLiveNormalizedIdentifier;
    self.activeLiveHandleObject = nil;
    self.activeLiveNormalizedIdentifier = nil;
    self.pendingLiveNormalizedIdentifier = nil;
    self.activeLiveFocusTargets = nil;
    [self stopLiveRefreshForHandleObject:handleToStop
                    normalizedIdentifier:stoppedIdentifier
                                 session:self.activeLocateSession];
}

- (void)startLiveKeepaliveTimerForGeneration:(NSUInteger)generation {
    [self stopLiveKeepaliveTimer];
    if (NSClassFromString(@"UIApplication") == Nil) {
        return;
    }

    // Prevent macOS App Nap from throttling background FindMy honing while a person is actively focused.
    self.liveActivityToken = [[NSProcessInfo processInfo]
        beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                          reason:@"BlueBubbles Find My live location honing"];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t intervalNs = (uint64_t)(BBLiveKeepaliveIntervalSeconds * NSEC_PER_SEC);
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
        intervalNs,
        (uint64_t)(1.0 * NSEC_PER_SEC)
    );
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        FindMyHelper *strongSelf = weakSelf;
        if (strongSelf == nil ||
            strongSelf.liveSessionGeneration != generation ||
            strongSelf.activeLiveHandleObject == nil) {
            [strongSelf stopLiveKeepaliveTimer];
            return;
        }
        // Keep the person selected in FindMy.app and visibility flags active so FindMy keeps acquiring accurate fixes.
        if (strongSelf.activeLiveFocusTargets.count > 0) {
            [[FindMyPeopleFocusController sharedInstance]
                scheduleFocusPeopleTabAndSelectTargets:strongSelf.activeLiveFocusTargets];
        }
        FindMyLocateSession *session = strongSelf.activeLocateSession;
        if (session != nil) {
            [FindMyFriendPayload startRefreshingSession:session
                                                handles:@[strongSelf.activeLiveHandleObject]
                                               priority:BBLiveLocationRefreshPriority
                                             completion:^{}];
        }
    });
    self.liveKeepaliveTimer = timer;
    dispatch_resume(timer);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BBLiveKeepaliveMaxTTLSeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            FindMyHelper *strongSelf = weakSelf;
            if (strongSelf == nil ||
                strongSelf.liveSessionGeneration != generation ||
                strongSelf.activeLiveHandleObject == nil) {
                return;
            }
            os_log(helperLog, "Find My live location TTL reached; stopping session");
            [strongSelf stopLiveLocationSession];
            [strongSelf restoreFocusConditionsIfIdle];
        }
    );
}

- (void)stopLiveKeepaliveTimer {
    if (self.liveKeepaliveTimer != nil) {
        dispatch_source_cancel(self.liveKeepaliveTimer);
        self.liveKeepaliveTimer = nil;
    }
    if (self.liveActivityToken != nil) {
        [[NSProcessInfo processInfo] endActivity:self.liveActivityToken];
        self.liveActivityToken = nil;
    }
}

- (void)restoreFocusConditionsIfIdle {
    if (self.activeLiveHandleObject == nil &&
        self.pendingLiveNormalizedIdentifier == nil &&
        self.activeFriendRefreshes.count == 0) {
        [self stopLiveKeepaliveTimer];
        [[FindMyPeopleFocusController sharedInstance] restoreBackgroundRefreshConditions];
    }
}

@end
