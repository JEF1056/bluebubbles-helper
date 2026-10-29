#import "FindMyHelper.h"

#import <os/log.h>

#import "FindMyLocateSession.h"
#import "FindMyDeviceSnapshotBridge.h"
#import "FindMyDevicesDataSourceCapture.h"
#import "FindMyDevicesRefreshCoordinator.h"
#import "FindMyFriendPayload.h"
#import "FindMyFriendsRefreshCoordinator.h"
#import "ServerConnection.h"

static const NSTimeInterval BBConnectionDelaySeconds = 5.0;
static const NSTimeInterval BBFriendListTimeoutSeconds = 5.0;
static const NSTimeInterval BBLocationRefreshTimeoutSeconds = 8.0;
static const NSTimeInterval BBDevicesDataSourceTimeoutSeconds = 5.0;
static const NSTimeInterval BBDevicesDataSourcePollIntervalSeconds = 0.1;
static const long long BBLiveLocationRefreshPriority = 1000;

@interface FindMyHelper ()
@property(nonatomic, strong, nullable) FindMyLocateSession *activeLocateSession;
@property(nonatomic, strong) NSMutableSet<FindMyFriendsRefreshCoordinator *> *activeFriendRefreshes;
@property(nonatomic, strong) NSMutableSet<FindMyDevicesRefreshCoordinator *> *activeDeviceRefreshes;
- (nullable FindMyLocateSession *)locateSession;
- (void)handleFriendsRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier;
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

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BBConnectionDelaySeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            [[FindMyDevicesDataSourceCapture sharedInstance] installCapture];
            [[ServerConnection sharedInstance] connect];
        }
    );
}

- (void)handleServerAction:(nullable NSString *)action
     transactionIdentifier:(nullable NSString *)transactionIdentifier {
    if ([action isEqualToString:@"refresh-findmy-friends"]) {
        [self handleFriendsRefreshForTransactionIdentifier:transactionIdentifier];
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
        [self.activeLocateSession setLocationUpdateCallback:^(id _Nullable location, id handle) {
            NSDictionary *locationPayload = [FindMyFriendPayload locationPayloadForLocation:location handle:handle];
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
        [self.activeLocateSession startUpdatingFriendsWithInitialUpdates:YES completion:^{
            os_log(helperLog, "Find My friend updates started");
        }];
    }

    if ([self.activeLocateSession respondsToSelector:@selector(startMonitoringActiveLocationSharingDeviceChangeWithCompletion:)]) {
        [self.activeLocateSession startMonitoringActiveLocationSharingDeviceChangeWithCompletion:^{
            os_log(helperLog, "Find My active-device monitoring started");
        }];
    }

    return self.activeLocateSession;
}

- (void)startStreamingLocationsForAllFriends:(FindMyLocateSession *)session {
    void (^refreshHandles)(NSArray * _Nullable) = ^(NSArray * _Nullable friendRecords) {
        if (![friendRecords isKindOfClass:[NSArray class]] || friendRecords.count == 0) {
            return;
        }
        NSMutableArray *handles = [[NSMutableArray alloc] initWithCapacity:friendRecords.count];
        SEL handleSelector = NSSelectorFromString(@"handle");
        for (id friendRecord in friendRecords) {
            id handle = friendRecord;
            if ([friendRecord respondsToSelector:handleSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id extracted = [friendRecord performSelector:handleSelector];
#pragma clang diagnostic pop
                if (extracted != nil) {
                    handle = extracted;
                }
            }
            if (handle != nil && [FindMyFriendPayload identifierForHandle:handle] != nil) {
                [handles addObject:handle];
            }
        }
        if (handles.count == 0) {
            return;
        }
        if ([session respondsToSelector:@selector(startRefreshingLocationForHandles:priority:isFromGroup:reverseGeocode:completion:)]) {
            [session startRefreshingLocationForHandles:handles
                                              priority:BBLiveLocationRefreshPriority
                                           isFromGroup:NO
                                        reverseGeocode:YES
                                            completion:^{}];
        } else if ([session respondsToSelector:@selector(startRefreshingLocationForHandles:priority:isFromGroup:completion:)]) {
            [session startRefreshingLocationForHandles:handles
                                              priority:BBLiveLocationRefreshPriority
                                           isFromGroup:NO
                                            completion:^{}];
        }
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

- (void)handleFriendsRefreshForTransactionIdentifier:(nullable NSString *)transactionIdentifier {
    FindMyLocateSession *session = [self locateSession];
    if (session == nil) {
        [self sendError:@"FindMyLocateSession is unavailable" transactionIdentifier:transactionIdentifier];
        return;
    }

    __weak typeof(self) weakSelf = self;
    __block __weak FindMyFriendsRefreshCoordinator *weakCoordinator = nil;
    FindMyFriendsRefreshCoordinator *coordinator = [[FindMyFriendsRefreshCoordinator alloc]
        initWithSession:session
        transactionIdentifier:transactionIdentifier
        friendListTimeout:BBFriendListTimeoutSeconds
        locationRefreshTimeout:BBLocationRefreshTimeoutSeconds
        responseHandler:^(NSDictionary *response) {
            [[ServerConnection sharedInstance] sendMessage:response];
            FindMyHelper *strongSelf = weakSelf;
            if (strongSelf != nil) {
                if (weakCoordinator != nil) {
                    [strongSelf.activeFriendRefreshes removeObject:weakCoordinator];
                }
                [strongSelf startStreamingLocationsForAllFriends:session];
            }
        }];
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
