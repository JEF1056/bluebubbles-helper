#import "FindMyPeopleFocusController.h"

#import <Contacts/Contacts.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>

extern CFTypeRef _Nullable BlueBubblesFindMyCopyPeopleRowsMetadata(void * _Nullable dataSource);

static os_log_t focusLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.bluebubbles.findmyhelper", "peoplefocus");
    });
    return logger;
}

static NSUInteger const BBFocusMaxRetries = 12;
static NSTimeInterval const BBFocusRetryIntervalSeconds = 0.15;
static NSUInteger const BBFocusMaxTreeNodes = 4096;
static NSUInteger const BBControlEventTouchUpInside = (1UL << 6);
static NSUInteger const BBControlEventValueChanged = (1UL << 12);
static NSInteger const BBUITableViewScrollPositionMiddle = 2;

@protocol BBFindMyUIKitProxy <NSObject>
@optional
+ (nullable id)sharedApplication;
+ (nullable NSIndexPath *)indexPathForRow:(NSInteger)row inSection:(NSInteger)section;

- (nullable NSSet *)connectedScenes;
- (nullable NSArray *)windows;
- (nullable id)keyWindow;
- (nullable id)rootViewController;
- (nullable id)presentedViewController;
- (nullable NSArray *)childViewControllers;
- (nullable NSArray *)viewControllers;
- (BOOL)isViewLoaded;
- (nullable id)view;
- (nullable NSArray *)subviews;

- (NSInteger)selectedSegmentIndex;
- (void)setSelectedSegmentIndex:(NSInteger)selectedSegmentIndex;
- (NSUInteger)numberOfSegments;
- (nullable NSString *)titleForSegmentAtIndex:(NSUInteger)segment;
- (void)sendActionsForControlEvents:(NSUInteger)controlEvents;
- (void)indexChangedWithSender:(id)sender;
- (void)onButtonTapped;

- (nullable id)dataSource;
- (nullable id)delegate;
- (NSInteger)numberOfSections;
- (NSInteger)numberOfRowsInSection:(NSInteger)section;
- (nullable id)cellForRowAtIndexPath:(NSIndexPath *)indexPath;
- (nullable NSArray *)visibleCells;
- (nullable NSIndexPath *)indexPathForCell:(id)cell;
- (void)selectRowAtIndexPath:(nullable NSIndexPath *)indexPath
                    animated:(BOOL)animated
              scrollPosition:(NSInteger)scrollPosition;
- (nullable NSIndexPath *)tableView:(id)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)tableView:(id)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;

- (nullable NSString *)accessibilityLabel;
- (nullable id)textLabel;
- (nullable id)detailTextLabel;
- (nullable NSString *)text;
@end

@interface FindMyPeopleFocusController ()

@property (nonatomic, weak, nullable, readwrite) id peopleDataSource;
@property (nonatomic, weak, nullable, readwrite) id peopleTableView;
@property (nonatomic, assign) NSUInteger focusGeneration;

- (void)recordPeopleDataSource:(id)dataSource tableView:(nullable id)tableView;

@end

static NSMutableDictionary<NSString *, NSValue *> *BBPeopleNumberOfRowsOriginalIMPs(void) {
    static NSMutableDictionary<NSString *, NSValue *> *impMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        impMap = [[NSMutableDictionary alloc] init];
    });
    return impMap;
}

static NSInteger (*BBOriginalNumberOfRowsIMPForClass(Class cls))(id, SEL, id, NSInteger) {
    NSMutableDictionary<NSString *, NSValue *> *impMap = BBPeopleNumberOfRowsOriginalIMPs();
    Class cursor = cls;
    @synchronized (impMap) {
        while (cursor != Nil) {
            NSValue *boxed = impMap[NSStringFromClass(cursor)];
            if (boxed != nil) {
                return (NSInteger (*)(id, SEL, id, NSInteger))[boxed pointerValue];
            }
            cursor = class_getSuperclass(cursor);
        }
    }
    return NULL;
}

static NSInteger BBHookedPeopleNumberOfRowsInSection(id self, SEL _cmd, id tableView, NSInteger section) {
    [[FindMyPeopleFocusController sharedInstance] recordPeopleDataSource:self tableView:tableView];

    NSInteger (*originalIMP)(id, SEL, id, NSInteger) = BBOriginalNumberOfRowsIMPForClass(object_getClass(self));
    if (originalIMP != NULL) {
        return originalIMP(self, _cmd, tableView, section);
    }
    return 0;
}

static id _Nullable BBIvarObjectValue(id object, const char *ivarName) {
    if (object == nil || ivarName == NULL) {
        return nil;
    }
    Class cursor = object_getClass(object);
    while (cursor != Nil) {
        Ivar ivar = class_getInstanceVariable(cursor, ivarName);
        if (ivar != NULL) {
            const char *encoding = ivar_getTypeEncoding(ivar);
            if (encoding != NULL && encoding[0] == '@') {
                return object_getIvar(object, ivar);
            }
            return nil;
        }
        cursor = class_getSuperclass(cursor);
    }
    return nil;
}

static BOOL BBReadBoolIvar(id object, const char *ivarName, BOOL *outValue) {
    if (object == nil || ivarName == NULL) {
        return NO;
    }
    Class cursor = object_getClass(object);
    while (cursor != Nil) {
        Ivar ivar = class_getInstanceVariable(cursor, ivarName);
        if (ivar != NULL) {
            const char *encoding = ivar_getTypeEncoding(ivar);
            ptrdiff_t offset = ivar_getOffset(ivar);
            if (offset > 0 && (encoding == NULL || encoding[0] == 'B' || encoding[0] == 'c' || encoding[0] == '\0')) {
                if (outValue != NULL) {
                    *outValue = *(BOOL *)((uint8_t *)(__bridge void *)object + offset);
                }
                return YES;
            }
            return NO;
        }
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

static BOOL BBSetBoolIvarIfFalse(id object, const char *ivarName) {
    if (object == nil || ivarName == NULL) {
        return NO;
    }
    Class cursor = object_getClass(object);
    while (cursor != Nil) {
        Ivar ivar = class_getInstanceVariable(cursor, ivarName);
        if (ivar != NULL) {
            const char *encoding = ivar_getTypeEncoding(ivar);
            ptrdiff_t offset = ivar_getOffset(ivar);
            if (offset > 0 && (encoding == NULL || encoding[0] == 'B' || encoding[0] == 'c' || encoding[0] == '\0')) {
                BOOL *flagPtr = (BOOL *)((uint8_t *)(__bridge void *)object + offset);
                if (!(*flagPtr)) {
                    *flagPtr = YES;
                    return YES;
                }
            }
            return NO;
        }
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

static NSIndexPath *BBMakeIndexPath(NSInteger section, NSInteger row) {
    if (section < 0 || row < 0) {
        return [NSIndexPath indexPathWithIndex:0];
    }
    if ([(id)[NSIndexPath class] respondsToSelector:@selector(indexPathForRow:inSection:)]) {
        NSIndexPath *path = [(id<BBFindMyUIKitProxy>)[NSIndexPath class] indexPathForRow:row inSection:section];
        if (path != nil) {
            return path;
        }
    }
    NSUInteger indexes[2] = {(NSUInteger)section, (NSUInteger)row};
    return [NSIndexPath indexPathWithIndexes:indexes length:2];
}

static NSString *BBStripSchemePrefix(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = trimmed.lowercaseString;
    if ([lower hasPrefix:@"mailto:"]) {
        return [[trimmed substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([lower hasPrefix:@"tel:"]) {
        return [[trimmed substringFromIndex:4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return trimmed;
}

static NSString *BBCollapseWhitespace(NSString *value) {
    NSArray<NSString *> *parts = [value componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *nonEmpty = [[NSMutableArray alloc] initWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [nonEmpty addObject:part];
        }
    }
    return [nonEmpty componentsJoinedByString:@" "];
}

static NSString *BBDigitsOnly(NSString *value) {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [[value componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
}

static BOOL BBHasLetters(NSString *value) {
    return [value rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;
}

@implementation FindMyPeopleFocusController

+ (instancetype)sharedInstance {
    static FindMyPeopleFocusController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[FindMyPeopleFocusController alloc] init];
    });
    return shared;
}

- (void)recordPeopleDataSource:(id)dataSource tableView:(nullable id)tableView {
    if (dataSource != nil) {
        self.peopleDataSource = dataSource;
    }
    if (tableView != nil) {
        self.peopleTableView = tableView;
    }
}

- (void)installCapture {
    static NSMutableSet<NSString *> *installedClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installedClasses = [[NSMutableSet alloc] init];
    });

    NSArray<NSString *> *candidateClassNames = @[
        @"FindMy.FMPeopleListDataSource",
        @"_TtC6FindMy22FMPeopleListDataSource",
        @"FMPeopleListDataSource",
    ];
    SEL targetSelector = @selector(tableView:numberOfRowsInSection:);

    @synchronized (installedClasses) {
        for (NSString *className in candidateClassNames) {
            Class targetClass = NSClassFromString(className);
            if (targetClass == Nil) {
                continue;
            }
            NSString *resolvedName = NSStringFromClass(targetClass);
            if ([installedClasses containsObject:resolvedName]) {
                continue;
            }
            Method method = class_getInstanceMethod(targetClass, targetSelector);
            if (method == NULL) {
                continue;
            }

            IMP originalIMP = method_getImplementation(method);
            NSMutableDictionary<NSString *, NSValue *> *impMap = BBPeopleNumberOfRowsOriginalIMPs();
            @synchronized (impMap) {
                impMap[resolvedName] = [NSValue valueWithPointer:(void *)originalIMP];
            }
            method_setImplementation(method, (IMP)BBHookedPeopleNumberOfRowsInSection);
            [installedClasses addObject:resolvedName];
        }
    }
}

+ (BOOL)string:(nullable NSString *)candidate matchesTarget:(nullable NSString *)target {
    return [self string:candidate matchesTarget:target allowFuzzySubstring:YES];
}

+ (BOOL)string:(nullable NSString *)candidate
     matchesTarget:(nullable NSString *)target
allowFuzzySubstring:(BOOL)allowFuzzySubstring {
    if (candidate.length == 0 || target.length == 0) {
        return NO;
    }

    NSString *cleanCandidate = BBCollapseWhitespace(BBStripSchemePrefix(candidate));
    NSString *cleanTarget = BBCollapseWhitespace(BBStripSchemePrefix(target));
    if (cleanCandidate.length == 0 || cleanTarget.length == 0) {
        return NO;
    }

    NSStringCompareOptions nameCompareOptions = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    if ([cleanCandidate compare:cleanTarget options:nameCompareOptions] == NSOrderedSame) {
        return YES;
    }

    // Phone matching: match formatted vs E.164/local digits without cross-matching non-phone strings.
    if (![cleanCandidate containsString:@"@"] &&
        ![cleanTarget containsString:@"@"] &&
        !BBHasLetters(cleanCandidate) &&
        !BBHasLetters(cleanTarget)) {
        NSString *candidateDigits = BBDigitsOnly(cleanCandidate);
        NSString *targetDigits = BBDigitsOnly(cleanTarget);
        if (candidateDigits.length >= 7 && targetDigits.length >= 7) {
            if ([candidateDigits isEqualToString:targetDigits]) {
                return YES;
            }
            NSUInteger minLen = MIN(candidateDigits.length, targetDigits.length);
            if (minLen >= 10 && ([candidateDigits hasSuffix:targetDigits] || [targetDigits hasSuffix:candidateDigits])) {
                return YES;
            }
        }
    }

    // Compound cell accessibility labels often join fields with newlines, commas, or bullet separators.
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"\n,\u2022\u00b7"];
    NSArray<NSString *> *components = [cleanCandidate componentsSeparatedByCharactersInSet:separators];
    if (components.count > 1) {
        for (NSString *component in components) {
            NSString *trimmedPart = [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmedPart.length > 0 && [self string:trimmedPart matchesTarget:cleanTarget allowFuzzySubstring:NO]) {
                return YES;
            }
        }
    }

    if (allowFuzzySubstring && cleanTarget.length >= 3 && BBHasLetters(cleanTarget) && ![cleanTarget containsString:@"@"]) {
        if ([cleanCandidate rangeOfString:cleanTarget options:nameCompareOptions].location != NSNotFound) {
            return YES;
        }
    }

    return NO;
}

- (NSArray<NSString *> *)sanitizedTargets:(NSArray<NSString *> *)targets {
    NSMutableArray<NSString *> *cleaned = [[NSMutableArray alloc] initWithCapacity:targets.count];
    NSMutableSet<NSString *> *seen = [[NSMutableSet alloc] initWithCapacity:targets.count];
    for (id item in targets) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *trimmed = BBCollapseWhitespace(BBStripSchemePrefix((NSString *)item));
        if (trimmed.length == 0) {
            continue;
        }
        NSString *key = trimmed.lowercaseString;
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [cleaned addObject:trimmed];
        }
    }
    return cleaned;
}

- (void)scheduleFocusPeopleTabAndSelectTargets:(NSArray<NSString *> *)targets {
    NSArray<NSString *> *cleanedTargets = [self sanitizedTargets:targets];
    if (cleanedTargets.count == 0) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self installCapture];
        self.focusGeneration += 1;
        NSUInteger generation = self.focusGeneration;
        [self attemptFocusWithTargets:cleanedTargets generation:generation remainingRetries:BBFocusMaxRetries];
    });
}

- (void)attemptFocusWithTargets:(NSArray<NSString *> *)targets
                     generation:(NSUInteger)generation
               remainingRetries:(NSUInteger)remainingRetries {
    if (generation != self.focusGeneration) {
        return;
    }

    if ([self focusPeopleTabAndSelectTargets:targets inRootObjects:nil]) {
        return;
    }

    // Avoid dangling timers in headless Foundation unit tests when UIKit is not loaded.
    if (NSClassFromString(@"UIApplication") == Nil || remainingRetries == 0) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(BBFocusRetryIntervalSeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            FindMyPeopleFocusController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf attemptFocusWithTargets:targets generation:generation remainingRetries:(remainingRetries - 1)];
        }
    );
}

- (BOOL)focusPeopleTabAndSelectTargets:(NSArray<NSString *> *)targets {
    return [self focusPeopleTabAndSelectTargets:targets inRootObjects:nil];
}

- (BOOL)focusPeopleTabAndSelectTargets:(NSArray<NSString *> *)targets
                         inRootObjects:(nullable NSArray *)rootObjects {
    NSArray<NSString *> *cleanedTargets = [self sanitizedTargets:targets];
    if (cleanedTargets.count == 0) {
        return NO;
    }

    [self installCapture];

    NSMutableArray *roots = [[NSMutableArray alloc] init];
    if (rootObjects != nil) {
        [roots addObjectsFromArray:rootObjects];
    } else {
        Class uiAppClass = NSClassFromString(@"UIApplication");
        if (uiAppClass != Nil && [(id)uiAppClass respondsToSelector:@selector(sharedApplication)]) {
            id uiApp = [(id<BBFindMyUIKitProxy>)uiAppClass sharedApplication];
            if (uiApp != nil) {
                if ([uiApp respondsToSelector:@selector(connectedScenes)]) {
                    NSSet *scenes = [(id<BBFindMyUIKitProxy>)uiApp connectedScenes];
                    for (id scene in scenes) {
                        if ([scene respondsToSelector:@selector(windows)]) {
                            NSArray *sceneWindows = [(id<BBFindMyUIKitProxy>)scene windows];
                            if ([sceneWindows isKindOfClass:[NSArray class]]) {
                                [roots addObjectsFromArray:sceneWindows];
                            }
                        }
                    }
                }
                if ([uiApp respondsToSelector:@selector(windows)]) {
                    NSArray *appWindows = [(id<BBFindMyUIKitProxy>)uiApp windows];
                    if ([appWindows isKindOfClass:[NSArray class]]) {
                        [roots addObjectsFromArray:appWindows];
                    }
                }
                if ([uiApp respondsToSelector:@selector(keyWindow)]) {
                    id keyWin = [(id<BBFindMyUIKitProxy>)uiApp keyWindow];
                    if (keyWin != nil) {
                        [roots addObject:keyWin];
                    }
                }
            }
        }
    }

    NSMutableArray *sideBarVCs = [[NSMutableArray alloc] init];
    NSMutableArray *embeddedTabBars = [[NSMutableArray alloc] init];
    NSMutableArray *segmentedControls = [[NSMutableArray alloc] init];
    NSMutableArray *candidateTableViews = [[NSMutableArray alloc] init];

    [self collectUIObjectsFromRoots:roots
                         sideBarVCs:sideBarVCs
                    embeddedTabBars:embeddedTabBars
                  segmentedControls:segmentedControls
                candidateTableViews:candidateTableViews];

    BOOL switchedTab = [self switchToPeopleTabWithSideBarVCs:sideBarVCs
                                              embeddedTabBars:embeddedTabBars
                                            segmentedControls:segmentedControls];
    if (switchedTab) {
        os_log(focusLog(), "Switched Find My UI to People tab");
    }

    for (id sideBarVC in sideBarVCs) {
        id mediator = BBIvarObjectValue(sideBarVC, "mediator");
        [self ensureBackgroundRefreshConditionsForMediator:mediator];
    }

    // Expand phone/email targets via Contacts when FindMy already holds authorization,
    // since People list cells display resolved contact names rather than raw handles.
    if ([CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts] == CNAuthorizationStatusAuthorized) {
        CNContactStore *store = [[CNContactStore alloc] init];
        NSArray<id<CNKeyDescriptor>> *keys = @[
            [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName],
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactNicknameKey,
        ];
        NSMutableArray<NSString *> *augmented = [[NSMutableArray alloc] initWithArray:cleanedTargets];
        NSMutableSet<NSString *> *seenLower = [[NSMutableSet alloc] init];
        for (NSString *t in cleanedTargets) {
            [seenLower addObject:t.lowercaseString];
        }
        for (NSString *target in cleanedTargets) {
            NSPredicate *predicate = [target containsString:@"@"]
                ? [CNContact predicateForContactsMatchingEmailAddress:target]
                : (BBDigitsOnly(target).length >= 7
                    ? [CNContact predicateForContactsMatchingPhoneNumber:[CNPhoneNumber phoneNumberWithStringValue:target]]
                    : nil);
            if (predicate == nil) {
                continue;
            }
            NSArray<CNContact *> *contacts = [store unifiedContactsMatchingPredicate:predicate keysToFetch:keys error:nil];
            for (CNContact *contact in contacts) {
                NSString *fullName = [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName];
                for (NSString *candidate in @[fullName ?: @"", contact.nickname ?: @""]) {
                    NSString *clean = BBCollapseWhitespace(candidate);
                    if (clean.length > 0 && ![seenLower containsObject:clean.lowercaseString]) {
                        [seenLower addObject:clean.lowercaseString];
                        [augmented addObject:clean];
                    }
                }
            }
        }
        cleanedTargets = augmented;
    }

    if ([self selectMatchingPersonInCapturedDataSourceWithTargets:cleanedTargets candidateTableViews:candidateTableViews]) {
        return YES;
    }

    return [self selectMatchingPersonInTableViews:candidateTableViews targets:cleanedTargets];
}

- (void)collectUIObjectsFromRoots:(NSArray *)roots
                       sideBarVCs:(NSMutableArray *)sideBarVCs
                  embeddedTabBars:(NSMutableArray *)embeddedTabBars
                segmentedControls:(NSMutableArray *)segmentedControls
              candidateTableViews:(NSMutableArray *)candidateTableViews {
    NSMutableArray *queue = [[NSMutableArray alloc] initWithArray:roots];
    NSMutableSet<NSValue *> *visited = [[NSMutableSet alloc] init];
    Class segmentedControlClass = NSClassFromString(@"UISegmentedControl");
    Class tableViewClass = NSClassFromString(@"UITableView");

    NSUInteger index = 0;
    while (index < queue.count && visited.count < BBFocusMaxTreeNodes) {
        id obj = queue[index++];
        if (obj == nil) {
            continue;
        }
        NSValue *ptrKey = [NSValue valueWithPointer:(__bridge const void *)obj];
        if ([visited containsObject:ptrKey]) {
            continue;
        }
        [visited addObject:ptrKey];

        NSString *className = NSStringFromClass([obj class]);
        if ([className containsString:@"FMSideBarViewController"]) {
            [sideBarVCs addObject:obj];
        } else if ([className containsString:@"FMEmbeddedTabBar"] && ![className containsString:@"Item"]) {
            [embeddedTabBars addObject:obj];
        } else if ([className containsString:@"FMPeopleListDataSource"]) {
            [self recordPeopleDataSource:obj tableView:BBIvarObjectValue(obj, "tableView")];
        }

        if ((segmentedControlClass != Nil && [obj isKindOfClass:segmentedControlClass]) ||
            ([obj respondsToSelector:@selector(selectedSegmentIndex)] &&
             [obj respondsToSelector:@selector(setSelectedSegmentIndex:)] &&
             [obj respondsToSelector:@selector(numberOfSegments)])) {
            [segmentedControls addObject:obj];
        }

        if ([obj respondsToSelector:@selector(dataSource)]) {
            id dataSource = [(id<BBFindMyUIKitProxy>)obj dataSource];
            if (dataSource != nil && [NSStringFromClass([dataSource class]) containsString:@"FMPeopleListDataSource"]) {
                [self recordPeopleDataSource:dataSource tableView:obj];
            }
        }

        if ((tableViewClass != Nil && [obj isKindOfClass:tableViewClass]) ||
            ([obj respondsToSelector:@selector(selectRowAtIndexPath:animated:scrollPosition:)] &&
             [obj respondsToSelector:@selector(numberOfSections)] &&
             [obj respondsToSelector:@selector(numberOfRowsInSection:)])) {
            [candidateTableViews addObject:obj];
        }

        if ([obj respondsToSelector:@selector(rootViewController)]) {
            id rootVC = [(id<BBFindMyUIKitProxy>)obj rootViewController];
            if (rootVC != nil) {
                [queue addObject:rootVC];
            }
        }
        if ([obj respondsToSelector:@selector(presentedViewController)]) {
            id presentedVC = [(id<BBFindMyUIKitProxy>)obj presentedViewController];
            if (presentedVC != nil) {
                [queue addObject:presentedVC];
            }
        }
        if ([obj respondsToSelector:@selector(childViewControllers)]) {
            NSArray *children = [(id<BBFindMyUIKitProxy>)obj childViewControllers];
            if ([children isKindOfClass:[NSArray class]]) {
                [queue addObjectsFromArray:children];
            }
        }
        if ([obj respondsToSelector:@selector(viewControllers)]) {
            NSArray *vcs = [(id<BBFindMyUIKitProxy>)obj viewControllers];
            if ([vcs isKindOfClass:[NSArray class]]) {
                [queue addObjectsFromArray:vcs];
            }
        }
        if ([obj respondsToSelector:@selector(view)]) {
            BOOL viewLoaded = ![obj respondsToSelector:@selector(isViewLoaded)] || [(id<BBFindMyUIKitProxy>)obj isViewLoaded];
            if (viewLoaded) {
                id view = [(id<BBFindMyUIKitProxy>)obj view];
                if (view != nil) {
                    [queue addObject:view];
                }
            }
        }
        if ([obj respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = [(id<BBFindMyUIKitProxy>)obj subviews];
            if ([subviews isKindOfClass:[NSArray class]]) {
                [queue addObjectsFromArray:subviews];
            }
        }
    }
}

- (BOOL)switchToPeopleTabWithSideBarVCs:(NSArray *)sideBarVCs
                        embeddedTabBars:(NSArray *)embeddedTabBars
                      segmentedControls:(NSArray *)segmentedControls {
    BOOL switched = NO;

    for (id sideBarVC in sideBarVCs) {
        id segmentedControl = BBIvarObjectValue(sideBarVC, "segmentedControl");
        if (segmentedControl == nil && [sideBarVC respondsToSelector:@selector(view)]) {
            id sideBarView = [(id<BBFindMyUIKitProxy>)sideBarVC view];
            if (sideBarView != nil) {
                segmentedControl = [self findFirstSegmentedControlInView:sideBarView];
            }
        }
        if (segmentedControl != nil &&
            [segmentedControl respondsToSelector:@selector(selectedSegmentIndex)] &&
            [segmentedControl respondsToSelector:@selector(setSelectedSegmentIndex:)]) {
            if ([(id<BBFindMyUIKitProxy>)segmentedControl selectedSegmentIndex] != 0) {
                [(id<BBFindMyUIKitProxy>)segmentedControl setSelectedSegmentIndex:0];
                if ([sideBarVC respondsToSelector:@selector(indexChangedWithSender:)]) {
                    [(id<BBFindMyUIKitProxy>)sideBarVC indexChangedWithSender:segmentedControl];
                } else if ([segmentedControl respondsToSelector:@selector(sendActionsForControlEvents:)]) {
                    [(id<BBFindMyUIKitProxy>)segmentedControl sendActionsForControlEvents:BBControlEventValueChanged];
                }
                switched = YES;
            }
        }
    }

    for (id tabBar in embeddedTabBars) {
        id peopleTabItem = BBIvarObjectValue(tabBar, "peopleTabItem");
        if (peopleTabItem == nil) {
            continue;
        }
        BOOL isSelected = NO;
        BOOL hasSelectedIvar = BBReadBoolIvar(peopleTabItem, "isSelected", &isSelected);
        if ((hasSelectedIvar && !isSelected) || (!hasSelectedIvar && !switched)) {
            if ([peopleTabItem respondsToSelector:@selector(onButtonTapped)]) {
                [(id<BBFindMyUIKitProxy>)peopleTabItem onButtonTapped];
                switched = YES;
            } else {
                id button = BBIvarObjectValue(peopleTabItem, "button");
                if (button != nil && [button respondsToSelector:@selector(sendActionsForControlEvents:)]) {
                    [(id<BBFindMyUIKitProxy>)button sendActionsForControlEvents:BBControlEventTouchUpInside];
                    switched = YES;
                }
            }
        }
    }

    if (!switched && sideBarVCs.count == 0 && embeddedTabBars.count == 0) {
        for (id segmentedControl in segmentedControls) {
            if (![segmentedControl respondsToSelector:@selector(numberOfSegments)] ||
                ![segmentedControl respondsToSelector:@selector(titleForSegmentAtIndex:)] ||
                ![segmentedControl respondsToSelector:@selector(selectedSegmentIndex)] ||
                ![segmentedControl respondsToSelector:@selector(setSelectedSegmentIndex:)]) {
                continue;
            }
            if ([(id<BBFindMyUIKitProxy>)segmentedControl numberOfSegments] < 2) {
                continue;
            }
            NSString *firstTitle = [(id<BBFindMyUIKitProxy>)segmentedControl titleForSegmentAtIndex:0];
            if (firstTitle != nil &&
                [firstTitle compare:@"People" options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch] == NSOrderedSame &&
                [(id<BBFindMyUIKitProxy>)segmentedControl selectedSegmentIndex] != 0) {
                [(id<BBFindMyUIKitProxy>)segmentedControl setSelectedSegmentIndex:0];
                if ([segmentedControl respondsToSelector:@selector(sendActionsForControlEvents:)]) {
                    [(id<BBFindMyUIKitProxy>)segmentedControl sendActionsForControlEvents:BBControlEventValueChanged];
                }
                switched = YES;
                break;
            }
        }
    }

    return switched;
}

- (nullable id)findFirstSegmentedControlInView:(id)rootView {
    NSMutableArray *queue = [[NSMutableArray alloc] initWithObjects:rootView, nil];
    NSUInteger idx = 0;
    while (idx < queue.count && idx < 512) {
        id view = queue[idx++];
        if ([view respondsToSelector:@selector(selectedSegmentIndex)] &&
            [view respondsToSelector:@selector(setSelectedSegmentIndex:)] &&
            [view respondsToSelector:@selector(numberOfSegments)]) {
            return view;
        }
        if ([view respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = [(id<BBFindMyUIKitProxy>)view subviews];
            if ([subviews isKindOfClass:[NSArray class]]) {
                [queue addObjectsFromArray:subviews];
            }
        }
    }
    return nil;
}

- (void)ensureBackgroundRefreshConditionsForMediator:(nullable id)mediator {
    if (mediator == nil) {
        return;
    }
    id conditionProvider = BBIvarObjectValue(mediator, "conditionProvider");
    [self ensureBackgroundRefreshConditionsForConditionProvider:conditionProvider];
}

- (void)ensureBackgroundRefreshConditionsForConditionProvider:(nullable id)conditionProvider {
    if (conditionProvider == nil) {
        return;
    }
    BBSetBoolIvarIfFalse(conditionProvider, "isWindowVisible");
    BBSetBoolIvarIfFalse(conditionProvider, "isFrontmostWindow");
}

- (BOOL)selectMatchingPersonInCapturedDataSourceWithTargets:(NSArray<NSString *> *)targets
                                        candidateTableViews:(NSArray *)candidateTableViews {
    id dataSource = self.peopleDataSource;
    if (dataSource == nil) {
        return NO;
    }

    NSDictionary *metadata = CFBridgingRelease(BlueBubblesFindMyCopyPeopleRowsMetadata((__bridge void *)dataSource));
    if (![metadata isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    [self ensureBackgroundRefreshConditionsForConditionProvider:metadata[@"conditionProvider"]];

    id tableView = metadata[@"tableView"] ?: self.peopleTableView;
    if (tableView == nil) {
        for (id candidateTV in candidateTableViews) {
            if ([candidateTV respondsToSelector:@selector(dataSource)] &&
                [(id<BBFindMyUIKitProxy>)candidateTV dataSource] == dataSource) {
                tableView = candidateTV;
                break;
            }
        }
    }
    if (tableView == nil) {
        return NO;
    }

    NSMutableArray<NSString *> *expandedTargets = [[NSMutableArray alloc] initWithArray:targets];
    NSMutableSet<NSString *> *seenTargets = [[NSMutableSet alloc] init];
    for (NSString *t in targets) {
        [seenTargets addObject:t.lowercaseString];
    }

    NSArray *friendGroups = [metadata[@"friends"] isKindOfClass:[NSArray class]] ? metadata[@"friends"] : @[];
    for (NSArray *friendTokens in friendGroups) {
        if (![friendTokens isKindOfClass:[NSArray class]]) {
            continue;
        }
        BOOL friendMatched = NO;
        for (id token in friendTokens) {
            if (![token isKindOfClass:[NSString class]]) {
                continue;
            }
            for (NSString *target in targets) {
                if ([FindMyPeopleFocusController string:(NSString *)token matchesTarget:target allowFuzzySubstring:NO]) {
                    friendMatched = YES;
                    break;
                }
            }
            if (friendMatched) {
                break;
            }
        }
        if (friendMatched) {
            for (id token in friendTokens) {
                if (![token isKindOfClass:[NSString class]]) {
                    continue;
                }
                NSString *cleanToken = BBCollapseWhitespace((NSString *)token);
                if (cleanToken.length > 0 && ![seenTargets containsObject:cleanToken.lowercaseString]) {
                    [seenTargets addObject:cleanToken.lowercaseString];
                    [expandedTargets addObject:cleanToken];
                }
            }
        }
    }

    NSArray *rows = [metadata[@"rows"] isKindOfClass:[NSArray class]] ? metadata[@"rows"] : @[];
    if (rows.count == 0) {
        return NO;
    }

    // Search Friends section (2) before Notification Requests (1) and Me (0).
    NSArray *orderedRows = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger secA = [a[@"section"] integerValue];
        NSInteger secB = [b[@"section"] integerValue];
        NSInteger rankA = (secA == 2) ? 0 : (secA == 1 ? 1 : 2);
        NSInteger rankB = (secB == 2) ? 0 : (secB == 1 ? 1 : 2);
        if (rankA != rankB) {
            return rankA < rankB ? NSOrderedAscending : NSOrderedDescending;
        }
        NSInteger rowA = [a[@"row"] integerValue];
        NSInteger rowB = [b[@"row"] integerValue];
        return rowA < rowB ? NSOrderedAscending : (rowA > rowB ? NSOrderedDescending : NSOrderedSame);
    }];

    for (NSNumber *fuzzyFlag in @[@NO, @YES]) {
        BOOL allowFuzzy = fuzzyFlag.boolValue;
        for (NSDictionary *rowInfo in orderedRows) {
            NSInteger section = [rowInfo[@"section"] integerValue];
            NSInteger row = [rowInfo[@"row"] integerValue];
            NSArray *tokens = [rowInfo[@"tokens"] isKindOfClass:[NSArray class]] ? rowInfo[@"tokens"] : @[];

            BOOL matched = NO;
            for (id token in tokens) {
                if (![token isKindOfClass:[NSString class]]) {
                    continue;
                }
                for (NSString *target in expandedTargets) {
                    if ([FindMyPeopleFocusController string:(NSString *)token matchesTarget:target allowFuzzySubstring:allowFuzzy]) {
                        matched = YES;
                        break;
                    }
                }
                if (matched) {
                    break;
                }
            }

            if (matched && [self tableView:tableView supportsSection:section row:row]) {
                NSIndexPath *indexPath = BBMakeIndexPath(section, row);
                return [self selectTableView:tableView
                                 atIndexPath:indexPath
                            fallbackDelegate:metadata[@"delegate"]];
            }
        }
    }

    return NO;
}

- (BOOL)selectMatchingPersonInTableViews:(NSArray *)tableViews targets:(NSArray<NSString *> *)targets {
    NSMutableArray *orderedTableViews = [[NSMutableArray alloc] init];
    if (self.peopleTableView != nil) {
        [orderedTableViews addObject:self.peopleTableView];
    }
    for (id tv in tableViews) {
        if (![orderedTableViews containsObject:tv]) {
            [orderedTableViews addObject:tv];
        }
    }

    for (id tableView in orderedTableViews) {
        if (![tableView respondsToSelector:@selector(numberOfSections)] ||
            ![tableView respondsToSelector:@selector(numberOfRowsInSection:)]) {
            continue;
        }
        NSInteger numSections = [(id<BBFindMyUIKitProxy>)tableView numberOfSections];
        if (numSections <= 0) {
            continue;
        }

        // Prioritize section 2 (Friends in FindMy) first when >= 3 sections exist.
        NSMutableArray<NSNumber *> *sectionOrder = [[NSMutableArray alloc] initWithCapacity:(NSUInteger)numSections];
        if (numSections >= 3) {
            [sectionOrder addObject:@2];
        }
        for (NSInteger sec = 0; sec < numSections; sec++) {
            if (numSections >= 3 && sec == 2) {
                continue;
            }
            [sectionOrder addObject:@(sec)];
        }

        for (NSNumber *fuzzyFlag in @[@NO, @YES]) {
            BOOL allowFuzzy = fuzzyFlag.boolValue;
            for (NSNumber *sectionNumber in sectionOrder) {
                NSInteger section = sectionNumber.integerValue;
                NSInteger numRows = [(id<BBFindMyUIKitProxy>)tableView numberOfRowsInSection:section];
                for (NSInteger row = 0; row < numRows; row++) {
                    NSIndexPath *indexPath = BBMakeIndexPath(section, row);
                    id cell = [tableView respondsToSelector:@selector(cellForRowAtIndexPath:)]
                        ? [(id<BBFindMyUIKitProxy>)tableView cellForRowAtIndexPath:indexPath]
                        : nil;
                    if (cell == nil) {
                        continue;
                    }
                    NSArray<NSString *> *cellStrings = [self collectStringsFromCell:cell];
                    for (NSString *candidate in cellStrings) {
                        for (NSString *target in targets) {
                            if ([FindMyPeopleFocusController string:candidate matchesTarget:target allowFuzzySubstring:allowFuzzy]) {
                                return [self selectTableView:tableView atIndexPath:indexPath fallbackDelegate:nil];
                            }
                        }
                    }
                }
            }
        }
    }

    return NO;
}

- (NSArray<NSString *> *)collectStringsFromCell:(id)cell {
    NSMutableArray<NSString *> *strings = [[NSMutableArray alloc] init];
    if ([cell respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *label = [(id<BBFindMyUIKitProxy>)cell accessibilityLabel];
        if ([label isKindOfClass:[NSString class]] && label.length > 0) {
            [strings addObject:label];
        }
    }
    if ([cell respondsToSelector:@selector(textLabel)]) {
        id textLabel = [(id<BBFindMyUIKitProxy>)cell textLabel];
        if ([textLabel respondsToSelector:@selector(text)]) {
            NSString *text = [(id<BBFindMyUIKitProxy>)textLabel text];
            if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                [strings addObject:text];
            }
        }
    }
    if ([cell respondsToSelector:@selector(detailTextLabel)]) {
        id detailLabel = [(id<BBFindMyUIKitProxy>)cell detailTextLabel];
        if ([detailLabel respondsToSelector:@selector(text)]) {
            NSString *text = [(id<BBFindMyUIKitProxy>)detailLabel text];
            if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                [strings addObject:text];
            }
        }
    }

    NSMutableArray *queue = [[NSMutableArray alloc] initWithObjects:cell, nil];
    NSUInteger idx = 0;
    while (idx < queue.count && idx < 128) {
        id view = queue[idx++];
        if (view != cell) {
            if ([view respondsToSelector:@selector(accessibilityLabel)]) {
                NSString *label = [(id<BBFindMyUIKitProxy>)view accessibilityLabel];
                if ([label isKindOfClass:[NSString class]] && label.length > 0) {
                    [strings addObject:label];
                }
            }
            if ([view respondsToSelector:@selector(text)]) {
                NSString *text = [(id<BBFindMyUIKitProxy>)view text];
                if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                    [strings addObject:text];
                }
            }
        }
        if ([view respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = [(id<BBFindMyUIKitProxy>)view subviews];
            if ([subviews isKindOfClass:[NSArray class]]) {
                [queue addObjectsFromArray:subviews];
            }
        }
    }

    return strings;
}

- (BOOL)tableView:(id)tableView supportsSection:(NSInteger)section row:(NSInteger)row {
    if (section < 0 || row < 0) {
        return NO;
    }
    if ([tableView respondsToSelector:@selector(numberOfSections)]) {
        if (section >= [(id<BBFindMyUIKitProxy>)tableView numberOfSections]) {
            return NO;
        }
    }
    if ([tableView respondsToSelector:@selector(numberOfRowsInSection:)]) {
        if (row >= [(id<BBFindMyUIKitProxy>)tableView numberOfRowsInSection:section]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)selectTableView:(id)tableView
            atIndexPath:(NSIndexPath *)indexPath
       fallbackDelegate:(nullable id)fallbackDelegate {
    id delegate = [tableView respondsToSelector:@selector(delegate)]
        ? [(id<BBFindMyUIKitProxy>)tableView delegate]
        : nil;
    if (delegate == nil) {
        delegate = fallbackDelegate;
    }

    NSIndexPath *resolvedIndexPath = indexPath;
    if (delegate != nil && [delegate respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)]) {
        NSIndexPath *candidatePath = [(id<BBFindMyUIKitProxy>)delegate tableView:tableView willSelectRowAtIndexPath:indexPath];
        if (candidatePath != nil) {
            resolvedIndexPath = candidatePath;
        }
    }

    if ([tableView respondsToSelector:@selector(selectRowAtIndexPath:animated:scrollPosition:)]) {
        [(id<BBFindMyUIKitProxy>)tableView selectRowAtIndexPath:resolvedIndexPath
                                                      animated:NO
                                                scrollPosition:BBUITableViewScrollPositionMiddle];
    }

    if (delegate != nil && [delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        [(id<BBFindMyUIKitProxy>)delegate tableView:tableView didSelectRowAtIndexPath:resolvedIndexPath];
    }

    os_log(focusLog(), "Selected person row in Find My People tableView");
    return YES;
}

@end
