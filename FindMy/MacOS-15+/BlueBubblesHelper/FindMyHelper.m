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
@property(nonatomic, copy, nullable) NSString *activeLiveNormalizedIdentifier;
@property(nonatomic, copy, nullable) NSString *pendingLiveNormalizedIdentifier;
@property(nonatomic, strong, nullable) id activeLiveHandleObject;
@property(nonatomic) NSUInteger liveSessionGeneration;
- (nullable FindMyLocateSession *)locateSession;
- (void)startStreamingLocationsForAllFriends:(FindMyLocateSession *)session
                               focusedHandle:(nullable NSString *)focusedHandle;
- (void)handleFriendsRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                data:(nullable NSDictionary *)data;
- (void)handleStartLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                   data:(nullable NSDictionary *)data;
- (void)handleStopLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                  data:(nullable NSDictionary *)data;
- (void)handleDevicesRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier;
- (void)sendError:(NSString *)errorMessage transactionIdentifier:(nullable NSString *)transactionIdentifier;
@end

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
        [self handleDevicesRefreshForTransactionIdentifier:transactionIdentifier];
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

- (void)handleServerRegistered {
    dispatch_async(dispatch_get_main_queue(), ^{
        FindMyLocateSession *session = [self locateSession];
        if (session == nil || self.friendStreamingStarted) {
            return;
        }
        self.friendStreamingStarted = YES;
        [self startStreamingLocationsForAllFriends:session focusedHandle:nil];
    });
}

- (void)sendError:(NSString *)errorMessage transactionIdentifier:(nullable NSString *)transactionIdentifier {
    os_log_error(helperLog, "%{public}@", errorMessage);
    if (transactionIdentifier == nil) {
        return;
    }
    [[ServerConnection sharedInstance] sendMessage:@{
        @"transactionId": transactionIdentifier,
        @"error": errorMessage,
    }];
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

    if ([self.activeLocateSession respondsToSelector:@selector(startUpdatingFriendsWithInitialUpdates:completion:)]) {
        __weak typeof(self) weakSelf = self;
        [self.activeLocateSession startUpdatingFriendsWithInitialUpdates:YES completion:^{
            os_log(helperLog, "Find My friend updates started");
            dispatch_async(dispatch_get_main_queue(), ^{
                FindMyHelper *strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf.activeLocateSession == nil || strongSelf.friendStreamingStarted) {
                    return;
                }
                strongSelf.friendStreamingStarted = YES;
                [strongSelf startStreamingLocationsForAllFriends:strongSelf.activeLocateSession focusedHandle:nil];
            });
        }];
    }

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
    NSArray<NSString *> *stringKeys = @[@"handle", @"displayName", @"name", @"fullName"];
    for (NSString *key in stringKeys) {
        id val = data[key];
        if ([val isKindOfClass:[NSString class]]) {
            NSString *trimmed = [(NSString *)val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0 && ![targets containsObject:trimmed]) {
                [targets addObject:trimmed];
            }
        }
    }
    if ([data[@"handles"] isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)data[@"handles"]) {
            if ([item isKindOfClass:[NSString class]]) {
                NSString *trimmed = [(NSString *)item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length > 0 && ![targets containsObject:trimmed]) {
                    [targets addObject:trimmed];
                }
            }
        }
    }
    return targets;
}

- (void)handleStartLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                   data:(nullable NSDictionary *)data {
    NSString *rawHandle = [data[@"handle"] isKindOfClass:[NSString class]] ? data[@"handle"] : nil;
    if (rawHandle == nil && [data[@"handles"] isKindOfClass:[NSArray class]]) {
        id first = [(NSArray *)data[@"handles"] firstObject];
        if ([first isKindOfClass:[NSString class]]) {
            rawHandle = first;
        }
    }
    NSString *trimmedHandle = [rawHandle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedHandle.length == 0) {
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
                if (transactionIdentifier != nil) {
                    [[ServerConnection sharedInstance] sendMessage:@{
                        @"transactionId": transactionIdentifier,
                        @"live": @NO,
                        @"superseded": @YES,
                        @"handle": trimmedHandle,
                        @"locations": @[],
                    }];
                }
                return;
            }
            if (targetHandleObject == nil) {
                if ([strongSelf.pendingLiveNormalizedIdentifier isEqualToString:normalizedTarget]) {
                    strongSelf.pendingLiveNormalizedIdentifier = nil;
                }
                [strongSelf sendError:[NSString stringWithFormat:@"Find My friend handle not found: %@", trimmedHandle]
                transactionIdentifier:transactionIdentifier];
                return;
            }

            if ([strongSelf.pendingLiveNormalizedIdentifier isEqualToString:normalizedTarget]) {
                strongSelf.pendingLiveNormalizedIdentifier = nil;
            }
            strongSelf.activeLiveNormalizedIdentifier = normalizedTarget;
            strongSelf.activeLiveHandleObject = targetHandleObject;

            @synchronized (strongSelf.inFlightRefreshHandleCounts) {
                NSInteger count = [strongSelf.inFlightRefreshHandleCounts[normalizedTarget] integerValue];
                strongSelf.inFlightRefreshHandleCounts[normalizedTarget] = @(count + 1);
            }

            __block BOOL inFlightCountCleared = NO;
            void (^clearInFlightCount)(void) = ^{
                @synchronized (strongSelf.inFlightRefreshHandleCounts) {
                    if (inFlightCountCleared) {
                        return;
                    }
                    inFlightCountCleared = YES;
                    NSInteger count = [strongSelf.inFlightRefreshHandleCounts[normalizedTarget] integerValue];
                    if (count <= 1) {
                        [strongSelf.inFlightRefreshHandleCounts removeObjectForKey:normalizedTarget];
                    } else {
                        strongSelf.inFlightRefreshHandleCounts[normalizedTarget] = @(count - 1);
                    }
                }
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
            if (canonicalHandle.length > 0 && ![focusTargets containsObject:canonicalHandle]) {
                NSArray<NSString *> *updatedTargets = [focusTargets arrayByAddingObject:canonicalHandle];
                [[FindMyPeopleFocusController sharedInstance] scheduleFocusPeopleTabAndSelectTargets:updatedTargets];
            }

            if (transactionIdentifier != nil) {
                NSString *responseHandle = canonicalHandle ?: trimmedHandle;
                [[ServerConnection sharedInstance] sendMessage:@{
                    @"transactionId": transactionIdentifier,
                    @"live": @YES,
                    @"handle": responseHandle,
                    @"locations": cachedPayload != nil ? @[cachedPayload] : @[],
                }];
            }
        }];
    });
}

- (void)handleStopLiveLocationForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                  data:(nullable NSDictionary *)data {
    NSString *rawHandle = [data[@"handle"] isKindOfClass:[NSString class]] ? data[@"handle"] : nil;
    NSString *trimmedHandle = [rawHandle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *normalizedTarget = trimmedHandle.length > 0 ? trimmedHandle.lowercaseString : nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        FindMyLocateSession *session = self.activeLocateSession;
        NSString *currentLiveIdentifier = self.activeLiveNormalizedIdentifier ?: self.pendingLiveNormalizedIdentifier;

        if (normalizedTarget != nil &&
            currentLiveIdentifier != nil &&
            ![currentLiveIdentifier isEqualToString:normalizedTarget]) {
            if (transactionIdentifier != nil) {
                [[ServerConnection sharedInstance] sendMessage:@{
                    @"transactionId": transactionIdentifier,
                    @"stopped": @NO,
                    @"handle": trimmedHandle,
                    @"activeHandle": currentLiveIdentifier,
                }];
            }
            return;
        }

        self.liveSessionGeneration += 1;
        id handleToStop = self.activeLiveHandleObject;
        NSString *stoppedIdentifier = currentLiveIdentifier ?: normalizedTarget;
        self.activeLiveHandleObject = nil;
        self.activeLiveNormalizedIdentifier = nil;
        self.pendingLiveNormalizedIdentifier = nil;

        [self stopLiveRefreshForHandleObject:handleToStop normalizedIdentifier:stoppedIdentifier session:session];

        if (transactionIdentifier != nil) {
            [[ServerConnection sharedInstance] sendMessage:@{
                @"transactionId": transactionIdentifier,
                @"stopped": @(handleToStop != nil),
                @"handle": stoppedIdentifier ?: [NSNull null],
            }];
        }
    });
}

- (void)handleFriendsRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                                                data:(nullable NSDictionary *)data {
    FindMyLocateSession *session = [self locateSession];
    if (session == nil) {
        [self sendError:@"FindMyLocateSession is unavailable" transactionIdentifier:transactionIdentifier];
        return;
    }

    NSString *rawHandle = [data[@"handle"] isKindOfClass:[NSString class]] ? data[@"handle"] : nil;
    if (rawHandle == nil && [data[@"handles"] isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)data[@"handles"]) {
            if ([item isKindOfClass:[NSString class]]) {
                NSString *candidate = [(NSString *)item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (candidate.length > 0) {
                    rawHandle = candidate;
                    break;
                }
            }
        }
    }
    NSString *trimmedHandle = [rawHandle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *focusedHandle = trimmedHandle.length > 0 ? trimmedHandle : nil;
    NSArray<NSString *> *focusTargets = [self focusTargetsFromData:data];
    BOOL targetedOnly = focusedHandle != nil || focusTargets.count > 0;
    if (targetedOnly && focusTargets.count > 0) {
        [[FindMyPeopleFocusController sharedInstance] scheduleFocusPeopleTabAndSelectTargets:focusTargets];
    }
    NSString *normalizedFocusKey = focusedHandle.lowercaseString;
    if (normalizedFocusKey != nil) {
        @synchronized (self.inFlightRefreshHandleCounts) {
            NSInteger count = [self.inFlightRefreshHandleCounts[normalizedFocusKey] integerValue];
            self.inFlightRefreshHandleCounts[normalizedFocusKey] = @(count + 1);
        }
    }

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
            [[ServerConnection sharedInstance] sendMessage:response];
            FindMyHelper *strongSelf = weakSelf;
            if (strongSelf != nil) {
                if (normalizedFocusKey != nil) {
                    @synchronized (strongSelf.inFlightRefreshHandleCounts) {
                        NSInteger count = [strongSelf.inFlightRefreshHandleCounts[normalizedFocusKey] integerValue];
                        if (count <= 1) {
                            [strongSelf.inFlightRefreshHandleCounts removeObjectForKey:normalizedFocusKey];
                        } else {
                            strongSelf.inFlightRefreshHandleCounts[normalizedFocusKey] = @(count - 1);
                        }
                    }
                }
                if (weakCoordinator != nil) {
                    [strongSelf.activeFriendRefreshes removeObject:weakCoordinator];
                }
                if (!strongSelf.friendStreamingStarted) {
                    strongSelf.friendStreamingStarted = YES;
                    [strongSelf startStreamingLocationsForAllFriends:session focusedHandle:nil];
                }
            }
        }];
    if (normalizedFocusKey != nil &&
        ([normalizedFocusKey isEqualToString:self.activeLiveNormalizedIdentifier] ||
         [normalizedFocusKey isEqualToString:self.pendingLiveNormalizedIdentifier])) {
        coordinator.preserveFocusedLiveRefresh = YES;
    }
    weakCoordinator = coordinator;
    [self.activeFriendRefreshes addObject:coordinator];
    [coordinator start];
}

- (void)handleDevicesRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier {
    FindMyDevicesDataSourceCapture *dataSourceCapture = [FindMyDevicesDataSourceCapture sharedInstance];
    [dataSourceCapture installCapture];

    __weak typeof(self) weakSelf = self;
    __block __weak FindMyDevicesRefreshCoordinator *weakCoordinator = nil;
    FindMyDevicesRefreshCoordinator *coordinator = [[FindMyDevicesRefreshCoordinator alloc]
        initWithTransactionIdentifier:transactionIdentifier
        dataSourceTimeout:BBDevicesDataSourceTimeoutSeconds
        pollInterval:BBDevicesDataSourcePollIntervalSeconds
        dataSourceProvider:^id _Nullable {
            [dataSourceCapture installCapture];
            return dataSourceCapture.devicesDataSource;
        }
        snapshotProvider:^NSDictionary *(id dataSource) {
            return [FindMyDeviceSnapshotBridge snapshotForDataSource:dataSource];
        }
        responseHandler:^(NSDictionary *response) {
            [[ServerConnection sharedInstance] sendMessage:response];
            FindMyHelper *strongSelf = weakSelf;
            if (strongSelf != nil && weakCoordinator != nil) {
                [strongSelf.activeDeviceRefreshes removeObject:weakCoordinator];
            }
        }];
    weakCoordinator = coordinator;
    [self.activeDeviceRefreshes addObject:coordinator];
    [coordinator start];
}

@end
