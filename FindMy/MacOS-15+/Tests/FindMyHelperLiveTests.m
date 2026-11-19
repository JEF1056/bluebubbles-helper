#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "FindMyFriendPayload.h"
#import "FindMyHelper.h"
#import "FindMyLocateSession.h"
#import "FindMyPeopleFocusController.h"
#import "GCDAsyncSocket.h"
#import "ServerConnection.h"

@interface FMLHandle : NSObject
@property(nonatomic, copy) NSString *identifier;
@end

@implementation FMLHandle
@end

@interface BBMockLiveLocation : NSObject
@property(nonatomic) double altitude;
@property(nonatomic, copy) NSString *coarseAddressLabel;
@property(nonatomic) double horizontalAccuracy;
@property(nonatomic, copy) NSArray *labels;
@property(nonatomic) double latitude;
@property(nonatomic) long long locationType;
@property(nonatomic) double longitude;
@property(nonatomic) double speed;
@property(nonatomic) double timestamp;
@property(nonatomic) double verticalAccuracy;
@end

@implementation BBMockLiveLocation
@end

static NSMutableArray<NSDictionary *> *BBRecordedStarts = nil;
static NSMutableArray<NSDictionary *> *BBRecordedStops = nil;
static NSArray *BBMockCachedFriends = nil;
static NSMutableDictionary<NSString *, id> *BBMockCachedLocations = nil;
static FindMyLocationUpdateCallback BBLiveCallback = nil;
static BOOL BBUseAsyncDelayedFriendResolution = NO;

@implementation FindMyLocateSession

- (void)setLocationUpdateCallback:(nullable FindMyLocationUpdateCallback)callback {
    BBLiveCallback = [callback copy];
}

- (void)startUpdatingFriendsWithInitialUpdates:(BOOL)includeInitialUpdates completion:(FindMyCompletion)completion {
    completion();
}

- (void)startMonitoringActiveLocationSharingDeviceChangeWithCompletion:(FindMyCompletion)completion {
    completion();
}

- (nullable NSArray *)cachedFriendsSharingLocationsWithMe {
    return BBUseAsyncDelayedFriendResolution ? @[] : (BBMockCachedFriends ?: @[]);
}

- (void)getFriendsSharingLocationsWithMeWithCompletion:(FindMyFriendsCompletion)completion {
    NSArray *friends = BBMockCachedFriends ?: @[];
    if (BBUseAsyncDelayedFriendResolution) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            completion(friends);
        });
        return;
    }
    completion(friends);
}

- (nullable id)cachedLocationForHandle:(id)locationHandle includeAddress:(BOOL)includeAddress {
    NSString *identifier = [FindMyFriendPayload identifierForHandle:locationHandle];
    return identifier == nil ? nil : BBMockCachedLocations[identifier];
}

- (void)startRefreshingLocationForHandles:(NSArray *)locationHandles
                                  priority:(long long)priority
                               isFromGroup:(BOOL)isFromGroup
                            reverseGeocode:(BOOL)reverseGeocode
                                completion:(FindMyCompletion)completion {
    NSMutableArray<NSString *> *ids = [[NSMutableArray alloc] init];
    for (id handle in locationHandles) {
        NSString *identifier = [FindMyFriendPayload identifierForHandle:handle];
        if (identifier != nil) {
            [ids addObject:identifier];
        }
    }
    [BBRecordedStarts addObject:@{
        @"handles": ids,
        @"priority": @(priority),
        @"reverseGeocode": @(reverseGeocode),
    }];
    completion();
}

- (void)stopRefreshingLocationForHandles:(NSArray *)locationHandles
                                 priority:(long long)priority
                              isFromGroup:(BOOL)isFromGroup
                               completion:(FindMyCompletion)completion {
    NSMutableArray<NSString *> *ids = [[NSMutableArray alloc] init];
    for (id handle in locationHandles) {
        NSString *identifier = [FindMyFriendPayload identifierForHandle:handle];
        if (identifier != nil) {
            [ids addObject:identifier];
        }
    }
    [BBRecordedStops addObject:@{
        @"handles": ids,
        @"priority": @(priority),
    }];
    completion();
}

@end

@interface BBLiveRecordingSocket : GCDAsyncSocket
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *sentMessages;
@end

@implementation BBLiveRecordingSocket

- (instancetype)init {
    self = [super initWithDelegate:nil delegateQueue:dispatch_get_main_queue()];
    if (self != nil) {
        _sentMessages = [[NSMutableArray alloc] init];
    }
    return self;
}

- (BOOL)isDisconnected {
    return NO;
}

- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag {
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([message isKindOfClass:[NSDictionary class]]) {
        [self.sentMessages addObject:message];
    }
}

@end

static void BBAssert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static BOOL BBWaitUntil(BOOL (^condition)(void), NSTimeInterval timeoutSeconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

@interface BBMockSegmentedControl : NSObject
@property(nonatomic) NSInteger selectedSegmentIndex;
@property(nonatomic, copy) NSArray<NSString *> *titles;
@property(nonatomic) NSUInteger sentControlEventsCount;
@end

@implementation BBMockSegmentedControl
- (NSUInteger)numberOfSegments {
    return self.titles.count;
}
- (nullable NSString *)titleForSegmentAtIndex:(NSUInteger)segment {
    return segment < self.titles.count ? self.titles[segment] : nil;
}
- (void)sendActionsForControlEvents:(NSUInteger)controlEvents {
    (void)controlEvents;
    self.sentControlEventsCount += 1;
}
@end

@interface BBMockFMSideBarViewController : NSObject {
@public
    BBMockSegmentedControl *segmentedControl;
    id mediator;
}
@property(nonatomic) NSUInteger indexChangedCallCount;
@property(nonatomic, strong, nullable) id view;
@end

@implementation BBMockFMSideBarViewController
- (void)indexChangedWithSender:(id)sender {
    (void)sender;
    self.indexChangedCallCount += 1;
}
@end

@interface BBMockFMEmbeddedTabBarItem : NSObject {
@public
    BOOL isSelected;
    id button;
}
@property(nonatomic) NSUInteger tappedCount;
@end

@implementation BBMockFMEmbeddedTabBarItem
- (void)onButtonTapped {
    isSelected = YES;
    self.tappedCount += 1;
}
@end

@interface BBMockFMEmbeddedTabBar : NSObject {
@public
    BBMockFMEmbeddedTabBarItem *peopleTabItem;
}
@end

@implementation BBMockFMEmbeddedTabBar
@end

@interface BBMockFMConditionProvider : NSObject {
@public
    BOOL isWindowVisible;
    BOOL isFrontmostWindow;
}
@end

@implementation BBMockFMConditionProvider
@end

@interface BBMockPeopleMediator : NSObject {
@public
    BBMockFMConditionProvider *conditionProvider;
}
@end

@implementation BBMockPeopleMediator
@end

@interface BBMockLabel : NSObject
@property(nonatomic, copy) NSString *text;
@end

@implementation BBMockLabel
@end

@interface BBMockTableViewCell : NSObject
@property(nonatomic, copy, nullable) NSString *accessibilityLabel;
@property(nonatomic, strong, nullable) BBMockLabel *textLabel;
@property(nonatomic, strong, nullable) BBMockLabel *detailTextLabel;
@property(nonatomic, copy) NSArray *subviews;
@end

@implementation BBMockTableViewCell
@end

@interface BBMockTableViewDelegate : NSObject
@property(nonatomic, strong, nullable) NSIndexPath *willSelectPath;
@property(nonatomic, strong, nullable) NSIndexPath *didSelectPath;
@property(nonatomic) NSUInteger didSelectCount;
@end

@implementation BBMockTableViewDelegate
- (nullable NSIndexPath *)tableView:(id)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    self.willSelectPath = indexPath;
    return indexPath;
}
- (void)tableView:(id)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    self.didSelectPath = indexPath;
    self.didSelectCount += 1;
}
@end

@interface BBMockTableView : NSObject
@property(nonatomic, weak, nullable) id dataSource;
@property(nonatomic, weak, nullable) id delegate;
@property(nonatomic, copy) NSArray<NSArray<BBMockTableViewCell *> *> *sections;
@property(nonatomic, strong, nullable) NSIndexPath *selectedIndexPath;
@property(nonatomic) NSInteger lastScrollPosition;
@end

@implementation BBMockTableView
- (NSInteger)numberOfSections {
    return (NSInteger)self.sections.count;
}
- (NSInteger)numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || (NSUInteger)section >= self.sections.count) {
        return 0;
    }
    return (NSInteger)self.sections[(NSUInteger)section].count;
}
- (nullable id)cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger sec = [indexPath indexAtPosition:0];
    NSUInteger row = [indexPath indexAtPosition:1];
    if (sec >= self.sections.count || row >= self.sections[sec].count) {
        return nil;
    }
    return self.sections[sec][row];
}
- (void)selectRowAtIndexPath:(nullable NSIndexPath *)indexPath
                    animated:(BOOL)animated
              scrollPosition:(NSInteger)scrollPosition {
    (void)animated;
    self.selectedIndexPath = indexPath;
    self.lastScrollPosition = scrollPosition;
}
@end

@interface BBMockUIWindow : NSObject
@property(nonatomic, strong, nullable) id rootViewController;
@property(nonatomic, copy) NSArray *subviews;
@end

@implementation BBMockUIWindow
@end

@interface BBMockSplitViewController : NSObject
@property(nonatomic, copy) NSArray *viewControllers;
@property(nonatomic, copy) NSArray *childViewControllers;
@end

@implementation BBMockSplitViewController
@end

@interface BBMockFMPeopleListDataSource : NSObject {
@public
    id tableView;
    id delegate;
}
@end

@implementation BBMockFMPeopleListDataSource
- (NSInteger)tableView:(id)tv numberOfRowsInSection:(NSInteger)section {
    return [(BBMockTableView *)tv numberOfRowsInSection:section];
}
@end

static id BBMockSharedUIApplicationInstance = nil;

static id BBMockUIApplicationSharedApplication(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return BBMockSharedUIApplicationInstance;
}

static NSArray *BBMockUIApplicationWindows(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return objc_getAssociatedObject(self, "bbWindows") ?: @[];
}

static void BBRegisterMockUIApplicationClassIfNeeded(void) {
    if (NSClassFromString(@"UIApplication") != Nil) {
        return;
    }
    Class uiAppCls = objc_allocateClassPair([NSObject class], "UIApplication", 0);
    class_addMethod(object_getClass(uiAppCls),
                    @selector(sharedApplication),
                    (IMP)BBMockUIApplicationSharedApplication,
                    "@@:");
    class_addMethod(uiAppCls,
                    @selector(windows),
                    (IMP)BBMockUIApplicationWindows,
                    "@@:");
    objc_registerClassPair(uiAppCls);
}

static BBMockTableViewCell *BBMakePersonCell(NSString *name, NSString *detail, NSString *accessibilityLabel) {
    BBMockTableViewCell *cell = [[BBMockTableViewCell alloc] init];
    BBMockLabel *textLabel = [[BBMockLabel alloc] init];
    textLabel.text = name;
    BBMockLabel *detailLabel = [[BBMockLabel alloc] init];
    detailLabel.text = detail;
    cell.textLabel = textLabel;
    cell.detailTextLabel = detailLabel;
    cell.accessibilityLabel = accessibilityLabel;
    return cell;
}

static void BBTestPeopleFocusAndHelperIntegration(
    FindMyHelper *helper,
    BBLiveRecordingSocket *socket
) {
    // 7. Direct unit tests for handle/phone/email/diacritic display name matching.
    BBAssert([FindMyPeopleFocusController string:@"Alice@Example.com" matchesTarget:@"alice@example.com"],
             @"email match must be case-insensitive");
    BBAssert([FindMyPeopleFocusController string:@"+1 (555) 123-4567" matchesTarget:@"5551234567"],
             @"E.164 phone must match 10-digit local phone");
    BBAssert([FindMyPeopleFocusController string:@"tel:555-123-4567" matchesTarget:@"+15551234567"],
             @"10-digit tel: phone must match E.164 phone");
    BBAssert([FindMyPeopleFocusController string:@"José Álvarez" matchesTarget:@"jose alvarez"],
             @"diacritic-insensitive display name matching must work");
    BBAssert(![FindMyPeopleFocusController string:@"5551234" matchesTarget:@"9995551234"],
             @"7-digit phone must not falsely suffix-match a different 10-digit phone");
    BBAssert(![FindMyPeopleFocusController string:@"Bob Builder" matchesTarget:@"alice@example.com"],
             @"unrelated name must not match email");

    // 8. UI tree test: Devices tab (1) -> People tab (0), FMEmbeddedTabBar, FMConditionProvider, Section 2 selection.
    BBMockFMConditionProvider *conditionProvider = [[BBMockFMConditionProvider alloc] init];
    conditionProvider->isWindowVisible = NO;
    conditionProvider->isFrontmostWindow = NO;

    BBMockPeopleMediator *mediator = [[BBMockPeopleMediator alloc] init];
    mediator->conditionProvider = conditionProvider;

    BBMockSegmentedControl *segmentedControl = [[BBMockSegmentedControl alloc] init];
    segmentedControl.titles = @[@"People", @"Devices", @"Items"];
    segmentedControl.selectedSegmentIndex = 1; // Starts on Devices tab!

    BBMockFMSideBarViewController *sideBarVC = [[BBMockFMSideBarViewController alloc] init];
    sideBarVC->segmentedControl = segmentedControl;
    sideBarVC->mediator = mediator;

    BBMockFMEmbeddedTabBarItem *peopleTabItem = [[BBMockFMEmbeddedTabBarItem alloc] init];
    peopleTabItem->isSelected = NO;
    BBMockFMEmbeddedTabBar *embeddedTabBar = [[BBMockFMEmbeddedTabBar alloc] init];
    embeddedTabBar->peopleTabItem = peopleTabItem;

    BBMockTableViewDelegate *tableDelegate = [[BBMockTableViewDelegate alloc] init];
    BBMockTableView *tableView = [[BBMockTableView alloc] init];
    tableView.delegate = tableDelegate;
    tableView.sections = @[
        @[BBMakePersonCell(@"Me", @"My Location", @"Me")],
        @[],
        @[
            BBMakePersonCell(@"Bob Builder", @"bob@example.com", @"Bob Builder, 2 mi away"),
            BBMakePersonCell(@"Alice Appleseed", @"+1 (555) 234-5678", @"Alice Appleseed, Live"),
        ],
    ];

    BBMockFMPeopleListDataSource *peopleDS = [[BBMockFMPeopleListDataSource alloc] init];
    peopleDS->tableView = tableView;
    peopleDS->delegate = tableDelegate;
    tableView.dataSource = peopleDS;

    BBMockSplitViewController *splitVC = [[BBMockSplitViewController alloc] init];
    splitVC.viewControllers = @[sideBarVC];
    sideBarVC.view = embeddedTabBar;

    BBMockUIWindow *window = [[BBMockUIWindow alloc] init];
    window.rootViewController = splitVC;
    window.subviews = @[tableView];

    FindMyPeopleFocusController *focusController = [FindMyPeopleFocusController sharedInstance];
    BOOL focused = [focusController focusPeopleTabAndSelectTargets:@[@"5552345678"] inRootObjects:@[window]];
    BBAssert(focused, @"focus controller must switch to People tab and select matching friend");
    BBAssert(segmentedControl.selectedSegmentIndex == 0, @"segmentedControl must switch from Devices (1) to People (0)");
    BBAssert(sideBarVC.indexChangedCallCount == 1, @"FMSideBarViewController indexChangedWithSender: must be called");
    BBAssert(peopleTabItem.tappedCount == 1 && peopleTabItem->isSelected,
             @"FMEmbeddedTabBar.peopleTabItem onButtonTapped must be invoked when unselected");
    BBAssert(conditionProvider->isWindowVisible && conditionProvider->isFrontmostWindow,
             @"background visibility flags must allow FindMy refresh without stealing OS focus");
    BBAssert(tableDelegate.didSelectCount == 1, @"tableView:didSelectRowAtIndexPath: must fire");
    BBAssert([tableView.selectedIndexPath indexAtPosition:0] == 2 &&
             [tableView.selectedIndexPath indexAtPosition:1] == 1,
             @"Alice (section 2, row 1) must be selected");

    // 9. End-to-end FindMyHelper wiring with live UIApplication stub:
    //    - targeted refresh-findmy-friends with handles:[...] focuses People tab + selects Bob
    //    - untargeted refresh-findmy-friends does NOT switch away from Devices tab
    //    - start-findmy-live-location switches to People tab + selects Bob while keeping priority 2
    BBRegisterMockUIApplicationClassIfNeeded();
    Class uiAppClass = NSClassFromString(@"UIApplication");
    BBMockSharedUIApplicationInstance = [[uiAppClass alloc] init];
    objc_setAssociatedObject(BBMockSharedUIApplicationInstance, "bbWindows", @[window], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 9a. Untargeted refresh-findmy-friends must NOT hijack tab/selection.
    segmentedControl.selectedSegmentIndex = 1;
    sideBarVC.indexChangedCallCount = 0;
    tableDelegate.didSelectCount = 0;
    tableView.selectedIndexPath = nil;
    [socket.sentMessages removeAllObjects];
    [helper handleServerAction:@"refresh-findmy-friends" data:nil transactionIdentifier:@"tx-untargeted-refresh"];
    BBAssert(BBWaitUntil(^BOOL { return socket.sentMessages.count >= 1; }, 0.5),
             @"untargeted refresh-findmy-friends must complete");
    BBAssert(segmentedControl.selectedSegmentIndex == 1 && tableDelegate.didSelectCount == 0,
             @"untargeted refresh-findmy-friends must not hijack active tab or row selection");

    // 9b. Targeted refresh-findmy-friends with `handles` array must switch to People & select Bob.
    [BBRecordedStarts removeAllObjects];
    [socket.sentMessages removeAllObjects];
    [helper handleServerAction:@"refresh-findmy-friends"
                          data:@{@"handles": @[@"bob@example.com"]}
         transactionIdentifier:@"tx-targeted-handles-refresh"];
    BBAssert(BBWaitUntil(^BOOL {
        return socket.sentMessages.count >= 1 && tableDelegate.didSelectCount >= 1;
    }, 0.5), @"targeted refresh-findmy-friends with handles must focus People tab and complete refresh");
    BBAssert(segmentedControl.selectedSegmentIndex == 0, @"targeted refresh must switch to People tab");
    BBAssert([tableView.selectedIndexPath indexAtPosition:0] == 2 &&
             [tableView.selectedIndexPath indexAtPosition:1] == 0,
             @"Bob (section 2, row 0) must be selected for targeted refresh");
    BBAssert([BBRecordedStarts.firstObject[@"priority"] isEqual:@2],
             @"targeted refresh with handles must run with focused priority 2");

    // 9c. start-findmy-live-location must switch from Devices -> People & select Alice while starting live session (priority 2).
    segmentedControl.selectedSegmentIndex = 1;
    sideBarVC.indexChangedCallCount = 0;
    tableDelegate.didSelectCount = 0;
    tableView.selectedIndexPath = nil;
    [BBRecordedStarts removeAllObjects];
    [socket.sentMessages removeAllObjects];
    [helper handleServerAction:@"start-findmy-live-location"
                          data:@{@"handle": @"alice@example.com", @"displayName": @"Alice Appleseed"}
         transactionIdentifier:@"tx-live-focus"];
    BBAssert(BBWaitUntil(^BOOL {
        return BBRecordedStarts.count >= 1 && socket.sentMessages.count >= 1 && tableDelegate.didSelectCount >= 1;
    }, 0.5), @"start-findmy-live-location must focus People tab, select Alice, and start live refresh");
    BBAssert(segmentedControl.selectedSegmentIndex == 0, @"start-findmy-live-location must switch to People tab");
    BBAssert([tableView.selectedIndexPath indexAtPosition:0] == 2 &&
             [tableView.selectedIndexPath indexAtPosition:1] == 1,
             @"Alice (section 2, row 1) must be selected for start-findmy-live-location");
    BBAssert([BBRecordedStarts.firstObject[@"priority"] isEqual:@2],
             @"start-findmy-live-location must still use live priority 2");

    // 9d. Polling Alice while Alice is already live must use priority 1 and not stop priority 2.
    [BBRecordedStarts removeAllObjects];
    [BBRecordedStops removeAllObjects];
    [socket.sentMessages removeAllObjects];
    [helper handleServerAction:@"refresh-findmy-friends"
                          data:@{@"handle": @"alice@example.com"}
         transactionIdentifier:@"tx-poll-while-live"];
    BBAssert(BBWaitUntil(^BOOL { return socket.sentMessages.count >= 1; }, 0.5),
             @"poll while live must complete");
    BBAssert([BBRecordedStarts.firstObject[@"priority"] isEqual:@1],
             @"polling an already-live handle must use priority 1 instead of leaking priority 2");
    BBAssert(BBRecordedStops.count == 0,
             @"polling an already-live handle must not stop the active priority-2 live stream");

    // Verify streaming callback still works after UI focus.
    [socket.sentMessages removeAllObjects];
    BBMockLiveLocation *liveUpdate = [[BBMockLiveLocation alloc] init];
    liveUpdate.latitude = 37.3349;
    liveUpdate.longitude = -122.0090;
    liveUpdate.locationType = 2;
    liveUpdate.timestamp = 1700000020.0;
    FMLHandle *aliceHandle = [[FMLHandle alloc] init];
    aliceHandle.identifier = @"alice@example.com";
    BBMockCachedLocations[@"alice@example.com"] = liveUpdate;
    BBLiveCallback(liveUpdate, aliceHandle);
    BBAssert(BBWaitUntil(^BOOL { return socket.sentMessages.count == 1; }, 0.5),
             @"live update callback must still stream after UI focus");
    BBAssert([socket.sentMessages.firstObject[@"event"] isEqualToString:@"new-findmy-location"],
             @"callback must emit new-findmy-location");

    BBMockSharedUIApplicationInstance = nil;
}

int main(void) {
    @autoreleasepool {
        BBRecordedStarts = [[NSMutableArray alloc] init];
        BBRecordedStops = [[NSMutableArray alloc] init];
        BBMockCachedLocations = [[NSMutableDictionary alloc] init];

        FMLHandle *alice = [[FMLHandle alloc] init];
        alice.identifier = @"alice@example.com";
        FMLHandle *bob = [[FMLHandle alloc] init];
        bob.identifier = @"bob@example.com";
        BBMockCachedFriends = @[alice, bob];

        BBMockLiveLocation *aliceCached = [[BBMockLiveLocation alloc] init];
        aliceCached.latitude = 37.3349;
        aliceCached.longitude = -122.0090;
        aliceCached.timestamp = 1700000000.0;
        aliceCached.locationType = 1;
        aliceCached.horizontalAccuracy = 65.0;
        BBMockCachedLocations[@"alice@example.com"] = aliceCached;

        BBLiveRecordingSocket *socket = [[BBLiveRecordingSocket alloc] init];
        [[ServerConnection sharedInstance] setValue:socket forKey:@"socket"];

        FindMyHelper *helper = [FindMyHelper sharedInstance];

        // 1. Start live location for Alice -> priority 2 (.live), reverseGeocode YES, cached snapshot returned
        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"ALICE@example.com"}
             transactionIdentifier:@"tx-live-1"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStarts.count >= 1 && socket.sentMessages.count >= 1;
        }, 0.5), @"start-findmy-live-location must start refresh and reply");

        NSDictionary *startAlice = BBRecordedStarts.firstObject;
        BBAssert([startAlice[@"handles"] isEqual:@[@"alice@example.com"]], @"start must target alice");
        BBAssert([startAlice[@"priority"] isEqual:@2], @"live start must use LocatePriority.live (2)");
        BBAssert([startAlice[@"reverseGeocode"] isEqual:@YES], @"live start must enable reverseGeocode");
        BBAssert(BBLiveCallback != nil, @"locationUpdateCallback must be installed");

        // 2. Simulate pushed shallow then live callback -> live callback clears locating override (is_locating_in_progress: false)
        [socket.sentMessages removeAllObjects];
        BBMockLiveLocation *aliceLive = [[BBMockLiveLocation alloc] init];
        aliceLive.latitude = 37.3352;
        aliceLive.longitude = -122.0094;
        aliceLive.timestamp = 1700000005.25;
        aliceLive.locationType = 2;
        aliceLive.horizontalAccuracy = 4.5;
        aliceLive.verticalAccuracy = 3.0;
        aliceLive.speed = 2.4;
        aliceLive.altitude = 18.0;
        aliceLive.coarseAddressLabel = @"Cupertino, CA";
        BBLiveCallback(aliceLive, alice);

        BBAssert(socket.sentMessages.count == 1, @"locationUpdateCallback must stream immediately");
        NSDictionary *pushedEvent = socket.sentMessages.firstObject;
        BBAssert([pushedEvent[@"event"] isEqualToString:@"new-findmy-location"], @"must emit new-findmy-location");
        NSDictionary *pushedPayload = [pushedEvent[@"data"] firstObject];
        BBAssert([pushedPayload[@"status"] isEqualToString:@"live"], @"status must be live");
        BBAssert([pushedPayload[@"location_type"] isEqual:@2], @"location_type must be 2");
        BBAssert([pushedPayload[@"horizontal_accuracy"] isEqual:@4.5], @"horizontal_accuracy must match");
        BBAssert([pushedPayload[@"speed"] isEqual:@2.4], @"speed must match");
        BBAssert([pushedPayload[@"altitude"] isEqual:@18.0], @"altitude must match");
        BBAssert([pushedPayload[@"last_updated"] isEqual:@1700000005250], @"last_updated must be ms");
        BBAssert([pushedPayload[@"is_locating_in_progress"] isEqual:@NO],
                 @"is_locating_in_progress must be false once live updates arrive");

        // 3. Switch live location to Bob -> cleanly stops Alice before starting Bob
        [BBRecordedStarts removeAllObjects];
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"bob@example.com"}
             transactionIdentifier:@"tx-live-2"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStops.count >= 1 && BBRecordedStarts.count >= 1 && socket.sentMessages.count >= 1;
        }, 0.5), @"switching live friend must stop prior live handle and start new one");
        BBAssert([BBRecordedStops.firstObject[@"handles"] isEqual:@[@"alice@example.com"]],
                 @"prior live handle alice must be stopped");
        BBAssert([BBRecordedStops.firstObject[@"priority"] isEqual:@2],
                 @"live stop must pass priority 2");
        BBAssert([BBRecordedStarts.firstObject[@"handles"] isEqual:@[@"bob@example.com"]],
                 @"new live handle bob must be started");

        // 4. Stale stop for Alice while Bob is active must be ignored
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"stop-findmy-live-location"
                              data:@{@"handle": @"alice@example.com"}
             transactionIdentifier:@"tx-stop-stale"];
        BBAssert(BBWaitUntil(^BOOL { return socket.sentMessages.count >= 1; }, 0.5),
                 @"stale stop must still acknowledge transaction");
        BBAssert(BBRecordedStops.count == 0, @"stale stop for alice must not stop active bob live session");
        BBAssert([socket.sentMessages.firstObject[@"stopped"] isEqual:@NO], @"stale stop must report stopped: false");

        // 5. Stop for Bob stops Bob cleanly
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"stop-findmy-live-location"
                              data:@{@"handle": @"bob@example.com"}
             transactionIdentifier:@"tx-stop-bob"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStops.count == 1 && socket.sentMessages.count == 1;
        }, 0.5), @"stop for bob must stop refreshing and reply");
        BBAssert([BBRecordedStops.firstObject[@"handles"] isEqual:@[@"bob@example.com"]],
                 @"stop must pass bob handle");
        BBAssert([socket.sentMessages.firstObject[@"stopped"] isEqual:@YES], @"stop must report stopped: true");

        // 6. Race test: start(Alice) -> start(Bob) with async handle resolution -> stop(Alice) arrives mid-resolution
        //    stop(Alice) must NOT bump generation or kill pending start(Bob).
        [BBRecordedStarts removeAllObjects];
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"alice@example.com"}
             transactionIdentifier:@"tx-race-alice"];
        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStarts.count == 1 && socket.sentMessages.count == 1;
        }, 0.5), @"race setup start alice must finish");

        [BBRecordedStarts removeAllObjects];
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        BBUseAsyncDelayedFriendResolution = YES;

        [helper handleServerAction:@"start-findmy-live-location"
                              data:@{@"handle": @"bob@example.com"}
             transactionIdentifier:@"tx-race-bob"];
        [helper handleServerAction:@"stop-findmy-live-location"
                              data:@{@"handle": @"alice@example.com"}
             transactionIdentifier:@"tx-race-stop-alice"];

        BBAssert(BBWaitUntil(^BOOL {
            return BBRecordedStarts.count >= 1 && socket.sentMessages.count >= 2;
        }, 0.5), @"bob live start must still succeed when stop(alice) lands during async resolution");
        BBUseAsyncDelayedFriendResolution = NO;

        NSDictionary *stopAliceRaceReply = nil;
        NSDictionary *startBobRaceReply = nil;
        for (NSDictionary *msg in socket.sentMessages) {
            if ([msg[@"transactionId"] isEqualToString:@"tx-race-stop-alice"]) stopAliceRaceReply = msg;
            if ([msg[@"transactionId"] isEqualToString:@"tx-race-bob"]) startBobRaceReply = msg;
        }
        BBAssert(stopAliceRaceReply != nil && [stopAliceRaceReply[@"stopped"] isEqual:@NO],
                 @"stale stop(alice) mid-resolution must return stopped: false");
        BBAssert([stopAliceRaceReply[@"activeHandle"] isEqualToString:@"bob@example.com"],
                 @"stale stop(alice) must report pending bob handle");
        BBAssert(startBobRaceReply != nil && [startBobRaceReply[@"live"] isEqual:@YES],
                 @"start(bob) must complete with live: true instead of superseded");
        BBAssert(startBobRaceReply[@"superseded"] == nil, @"start(bob) must not be superseded");

        // Cleanly stop Bob before UI focus / refresh integration tests.
        [BBRecordedStops removeAllObjects];
        [socket.sentMessages removeAllObjects];
        [helper handleServerAction:@"stop-findmy-live-location"
                              data:@{@"handle": @"bob@example.com"}
             transactionIdentifier:@"tx-race-cleanup-bob"];
        BBAssert(BBWaitUntil(^BOOL { return BBRecordedStops.count == 1 && socket.sentMessages.count == 1; }, 0.5),
                 @"cleanup stop for bob must complete");

        BBTestPeopleFocusAndHelperIntegration(helper, socket);

        NSLog(@"PASS: FindMyHelperLiveTests");
    }
    return 0;
}
