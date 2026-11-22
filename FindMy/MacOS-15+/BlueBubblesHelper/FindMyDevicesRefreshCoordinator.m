#import "FindMyDevicesRefreshCoordinator.h"

#import <dlfcn.h>
#import <os/log.h>
#import <stdbool.h>
#import <stdint.h>

static __attribute__((noinline)) void BBInvokeSwiftMethod0(void *fn, void *swiftSelf) {
#if defined(__arm64__) || defined(__aarch64__)
    register void *x20 __asm__("x20") = swiftSelf;
    #if __has_feature(ptrauth_calls)
    __asm__ volatile("blraaz %[fn]" : : [fn]"r"(fn), "r"(x20) : "x0","x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","x30","v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31","memory","cc");
    #else
    __asm__ volatile("blr %[fn]" : : [fn]"r"(fn), "r"(x20) : "x0","x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","x30","v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31","memory","cc");
    #endif
#elif defined(__x86_64__)
    register void *r13 __asm__("r13") = swiftSelf;
    __asm__ volatile(
        "mov %%rsp, %%rbx\n\t"
        "and $-16, %%rsp\n\t"
        "call *%[fn]\n\t"
        "mov %%rbx, %%rsp"
        : : [fn]"r"(fn), "r"(r13) : "rax","rbx","rcx","rdx","rsi","rdi","r8","r9","r10","r11","xmm0","xmm1","xmm2","xmm3","xmm4","xmm5","xmm6","xmm7","xmm8","xmm9","xmm10","xmm11","xmm12","xmm13","xmm14","xmm15","memory","cc");
#endif
}

static __attribute__((noinline)) void BBInvokeSwiftMethodBool(void *fn, void *swiftSelf, bool flag) {
#if defined(__arm64__) || defined(__aarch64__)
    register void *x20 __asm__("x20") = swiftSelf;
    register uint64_t x0 __asm__("x0") = flag ? 1 : 0;
    #if __has_feature(ptrauth_calls)
    __asm__ volatile("blraaz %[fn]" : "+r"(x0) : [fn]"r"(fn), "r"(x20) : "x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","x30","v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31","memory","cc");
    #else
    __asm__ volatile("blr %[fn]" : "+r"(x0) : [fn]"r"(fn), "r"(x20) : "x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","x30","v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31","memory","cc");
    #endif
#elif defined(__x86_64__)
    register void *r13 __asm__("r13") = swiftSelf;
    register uint64_t rdi __asm__("rdi") = flag ? 1 : 0;
    __asm__ volatile(
        "mov %%rsp, %%rbx\n\t"
        "and $-16, %%rsp\n\t"
        "call *%[fn]\n\t"
        "mov %%rbx, %%rsp"
        : "+r"(rdi) : [fn]"r"(fn), "r"(r13) : "rax","rbx","rcx","rdx","rsi","r8","r9","r10","r11","xmm0","xmm1","xmm2","xmm3","xmm4","xmm5","xmm6","xmm7","xmm8","xmm9","xmm10","xmm11","xmm12","xmm13","xmm14","xmm15","memory","cc");
#endif
}

static __attribute__((noinline)) void BBInvokeSwiftMethodNilCompletion(void *fn, void *swiftSelf) {
#if defined(__arm64__) || defined(__aarch64__)
    register void *x20 __asm__("x20") = swiftSelf;
    register uint64_t x0 __asm__("x0") = 0;
    register uint64_t x1 __asm__("x1") = 0;
    #if __has_feature(ptrauth_calls)
    __asm__ volatile("blraaz %[fn]" : "+r"(x0), "+r"(x1) : [fn]"r"(fn), "r"(x20) : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","x30","v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31","memory","cc");
    #else
    __asm__ volatile("blr %[fn]" : "+r"(x0), "+r"(x1) : [fn]"r"(fn), "r"(x20) : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","x30","v0","v1","v2","v3","v4","v5","v6","v7","v16","v17","v18","v19","v20","v21","v22","v23","v24","v25","v26","v27","v28","v29","v30","v31","memory","cc");
    #endif
#elif defined(__x86_64__)
    register void *r13 __asm__("r13") = swiftSelf;
    register uint64_t rdi __asm__("rdi") = 0;
    register uint64_t rsi __asm__("rsi") = 0;
    __asm__ volatile(
        "mov %%rsp, %%rbx\n\t"
        "and $-16, %%rsp\n\t"
        "call *%[fn]\n\t"
        "mov %%rbx, %%rsp"
        : "+r"(rdi), "+r"(rsi) : [fn]"r"(fn), "r"(r13) : "rax","rbx","rcx","rdx","r8","r9","r10","r11","xmm0","xmm1","xmm2","xmm3","xmm4","xmm5","xmm6","xmm7","xmm8","xmm9","xmm10","xmm11","xmm12","xmm13","xmm14","xmm15","memory","cc");
#endif
}

static BOOL BBDeviceMatchesTarget(NSDictionary *device, NSString *targetDeviceId) {
    if (![device isKindOfClass:[NSDictionary class]] || targetDeviceId.length == 0) {
        return NO;
    }
    for (NSString *key in @[@"identifier", @"discoveryIdentifier", @"baIdentifier"]) {
        id value = device[key];
        if ([value isKindOfClass:[NSString class]] &&
            [(NSString *)value caseInsensitiveCompare:targetDeviceId] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary * _Nullable BBPrimaryLocationForDevice(NSDictionary *device) {
    id loc = device[@"location"];
    if ([loc isKindOfClass:[NSDictionary class]]) {
        return loc;
    }
    id crowdLoc = device[@"crowdSourcedLocation"];
    if ([crowdLoc isKindOfClass:[NSDictionary class]]) {
        return crowdLoc;
    }
    return nil;
}

static BOOL BBLocationIsFresher(NSDictionary * _Nullable latestLoc, NSDictionary * _Nullable baselineLoc) {
    if (latestLoc == nil) {
        return NO;
    }
    if (baselineLoc == nil) {
        return YES;
    }
    NSNumber *latestTs = [latestLoc[@"timeStamp"] isKindOfClass:[NSNumber class]] ? latestLoc[@"timeStamp"] : nil;
    NSNumber *baselineTs = [baselineLoc[@"timeStamp"] isKindOfClass:[NSNumber class]] ? baselineLoc[@"timeStamp"] : nil;
    if (latestTs != nil && (baselineTs == nil || latestTs.doubleValue > baselineTs.doubleValue + 0.001)) {
        return YES;
    }
    NSNumber *latestAcc = [latestLoc[@"horizontalAccuracy"] isKindOfClass:[NSNumber class]] ? latestLoc[@"horizontalAccuracy"] : nil;
    NSNumber *baselineAcc = [baselineLoc[@"horizontalAccuracy"] isKindOfClass:[NSNumber class]] ? baselineLoc[@"horizontalAccuracy"] : nil;
    if (latestAcc != nil && (baselineAcc == nil || latestAcc.doubleValue < baselineAcc.doubleValue - 0.001)) {
        return YES;
    }
    return NO;
}

static BOOL BBSnapshotIsFresher(NSDictionary *latestSnapshot, NSDictionary *baselineSnapshot, NSString * _Nullable deviceId) {
    NSArray *latestDevices = [latestSnapshot[@"devices"] isKindOfClass:[NSArray class]] ? latestSnapshot[@"devices"] : nil;
    NSArray *baselineDevices = [baselineSnapshot[@"devices"] isKindOfClass:[NSArray class]] ? baselineSnapshot[@"devices"] : nil;
    if (latestDevices.count == 0) {
        return NO;
    }

    if (deviceId.length > 0) {
        NSDictionary *latestTarget = nil;
        NSDictionary *baselineTarget = nil;
        for (NSDictionary *d in latestDevices) {
            if (BBDeviceMatchesTarget(d, deviceId)) {
                latestTarget = d;
                break;
            }
        }
        if (latestTarget == nil) {
            return NO;
        }
        for (NSDictionary *d in baselineDevices) {
            if (BBDeviceMatchesTarget(d, deviceId)) {
                baselineTarget = d;
                break;
            }
        }
        if (baselineTarget == nil) {
            return YES;
        }
        return BBLocationIsFresher(BBPrimaryLocationForDevice(latestTarget), BBPrimaryLocationForDevice(baselineTarget));
    }

    NSMutableDictionary<NSString *, NSDictionary *> *baselineById = [[NSMutableDictionary alloc] initWithCapacity:baselineDevices.count];
    for (NSDictionary *d in baselineDevices) {
        NSString *ident = [d[@"identifier"] isKindOfClass:[NSString class]] ? d[@"identifier"] : nil;
        if (ident.length > 0) {
            baselineById[ident.lowercaseString] = d;
        }
    }
    for (NSDictionary *d in latestDevices) {
        NSString *ident = [d[@"identifier"] isKindOfClass:[NSString class]] ? d[@"identifier"] : nil;
        if (ident.length == 0) {
            continue;
        }
        NSDictionary *base = baselineById[ident.lowercaseString];
        if (base == nil && BBPrimaryLocationForDevice(d) != nil) {
            return YES;
        }
        if (base != nil && BBLocationIsFresher(BBPrimaryLocationForDevice(d), BBPrimaryLocationForDevice(base))) {
            return YES;
        }
    }
    return NO;
}

@interface FindMyDevicesRefreshCoordinator ()
@property(nonatomic, copy, nullable) NSString *transactionIdentifier;
@property(nonatomic) NSTimeInterval dataSourceTimeout;
@property(nonatomic) NSTimeInterval pollInterval;
@property(nonatomic, copy, nullable) NSString *deviceId;
@property(nonatomic) BOOL force;
@property(nonatomic) NSTimeInterval activeRefreshTimeout;
@property(nonatomic) NSTimeInterval activePollInterval;
@property(nonatomic, copy) FindMyDevicesDataSourceProvider dataSourceProvider;
@property(nonatomic, copy) FindMyDevicesSnapshotProvider snapshotProvider;
@property(nonatomic, copy, nullable) FindMyDevicesRefreshTrigger refreshTrigger;
@property(nonatomic, copy) FindMyDevicesRefreshResponseHandler responseHandler;
@property(nonatomic, strong, nullable) NSDate *deadline;
@property(nonatomic, strong, nullable) NSDate *activeRefreshDeadline;
@property(nonatomic) BOOL responseSent;
@end

@implementation FindMyDevicesRefreshCoordinator

+ (BOOL)triggerFMIPManagerRefresh:(nullable id)fmipManager {
    if (fmipManager == nil) {
        return NO;
    }
    void *fmipHandle = dlopen("/System/Library/PrivateFrameworks/FMIPCore.framework/FMIPCore", RTLD_NOLOAD);
    if (fmipHandle == NULL) {
        return NO;
    }

    void *updateActiveFn = dlsym(fmipHandle, "$s8FMIPCore11FMIPManagerC25updateLastActiveTimestampyyF");
    void *pauseThrottleFn = dlsym(fmipHandle, "$s8FMIPCore11FMIPManagerC38pauseThrottleOfflineLocationRefreshing0C0ySb_tF");
    void *forceRefreshFn = dlsym(fmipHandle, "$s8FMIPCore11FMIPManagerC20forceStartRefreshingyyF");
    void *refreshBeaconsFn = dlsym(fmipHandle, "$s8FMIPCore11FMIPManagerC14refreshBeacons10completionyyycSg_tF");

    void *selfPtr = (__bridge void *)fmipManager;
    BOOL invoked = NO;
    if (updateActiveFn != NULL) {
        BBInvokeSwiftMethod0(updateActiveFn, selfPtr);
        invoked = YES;
    }
    if (pauseThrottleFn != NULL) {
        BBInvokeSwiftMethodBool(pauseThrottleFn, selfPtr, false);
        invoked = YES;
    }
    if (forceRefreshFn != NULL) {
        BBInvokeSwiftMethod0(forceRefreshFn, selfPtr);
        invoked = YES;
    }
    if (refreshBeaconsFn != NULL) {
        BBInvokeSwiftMethodNilCompletion(refreshBeaconsFn, selfPtr);
        invoked = YES;
    }
    dlclose(fmipHandle);
    return invoked;
}

+ (void)restoreFMIPManagerRefreshThrottle:(nullable id)fmipManager {
    if (fmipManager == nil) {
        return;
    }
    void *fmipHandle = dlopen("/System/Library/PrivateFrameworks/FMIPCore.framework/FMIPCore", RTLD_NOLOAD);
    if (fmipHandle == NULL) {
        return;
    }
    void *pauseThrottleFn = dlsym(fmipHandle, "$s8FMIPCore11FMIPManagerC38pauseThrottleOfflineLocationRefreshing0C0ySb_tF");
    if (pauseThrottleFn != NULL) {
        BBInvokeSwiftMethodBool(pauseThrottleFn, (__bridge void *)fmipManager, true);
    }
    dlclose(fmipHandle);
}

- (instancetype)initWithTransactionIdentifier:(nullable NSString *)transactionIdentifier
                             dataSourceTimeout:(NSTimeInterval)dataSourceTimeout
                                  pollInterval:(NSTimeInterval)pollInterval
                            dataSourceProvider:(FindMyDevicesDataSourceProvider)dataSourceProvider
                              snapshotProvider:(FindMyDevicesSnapshotProvider)snapshotProvider
                               responseHandler:(FindMyDevicesRefreshResponseHandler)responseHandler {
    return [self initWithTransactionIdentifier:transactionIdentifier
                             dataSourceTimeout:dataSourceTimeout
                                  pollInterval:pollInterval
                                      deviceId:nil
                                         force:NO
                          activeRefreshTimeout:0
                            activePollInterval:0
                            dataSourceProvider:dataSourceProvider
                              snapshotProvider:snapshotProvider
                                refreshTrigger:nil
                               responseHandler:responseHandler];
}

- (instancetype)initWithTransactionIdentifier:(nullable NSString *)transactionIdentifier
                             dataSourceTimeout:(NSTimeInterval)dataSourceTimeout
                                  pollInterval:(NSTimeInterval)pollInterval
                                      deviceId:(nullable NSString *)deviceId
                                         force:(BOOL)force
                          activeRefreshTimeout:(NSTimeInterval)activeRefreshTimeout
                            activePollInterval:(NSTimeInterval)activePollInterval
                            dataSourceProvider:(FindMyDevicesDataSourceProvider)dataSourceProvider
                              snapshotProvider:(FindMyDevicesSnapshotProvider)snapshotProvider
                                refreshTrigger:(nullable FindMyDevicesRefreshTrigger)refreshTrigger
                               responseHandler:(FindMyDevicesRefreshResponseHandler)responseHandler {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _transactionIdentifier = [transactionIdentifier copy];
    _dataSourceTimeout = dataSourceTimeout;
    _pollInterval = pollInterval;
    _deviceId = [deviceId copy];
    _force = force;
    _activeRefreshTimeout = activeRefreshTimeout;
    _activePollInterval = activePollInterval > 0 ? activePollInterval : 0.5;
    _dataSourceProvider = [dataSourceProvider copy];
    _snapshotProvider = [snapshotProvider copy];
    _refreshTrigger = [refreshTrigger copy];
    _responseHandler = [responseHandler copy];
    return self;
}

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self start];
        });
        return;
    }

    self.deadline = [NSDate dateWithTimeIntervalSinceNow:self.dataSourceTimeout];
    [self attemptSnapshot];
}

- (void)attemptSnapshot {
    if (self.responseSent) {
        return;
    }

    id dataSource = self.dataSourceProvider();
    if (dataSource != nil) {
        NSDictionary *baselineSnapshot = self.snapshotProvider(dataSource);
        if (self.force && self.activeRefreshTimeout > 0 && self.refreshTrigger != nil &&
            self.refreshTrigger(dataSource, self.deviceId, self.force)) {
            self.activeRefreshDeadline = [NSDate dateWithTimeIntervalSinceNow:self.activeRefreshTimeout];
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.activePollInterval * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    [self pollActiveRefreshWithDataSource:dataSource baseline:baselineSnapshot];
                }
            );
            return;
        }
        [self sendResponse:baselineSnapshot];
        return;
    }

    if (self.deadline.timeIntervalSinceNow <= 0) {
        [self sendResponse:@{
            @"error": @"Find My Devices data source did not become available before the refresh timeout",
        }];
        return;
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.pollInterval * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            [self attemptSnapshot];
        }
    );
}

- (void)pollActiveRefreshWithDataSource:(id)fallbackDataSource baseline:(NSDictionary *)baselineSnapshot {
    if (self.responseSent) {
        return;
    }

    id currentDataSource = self.dataSourceProvider() ?: fallbackDataSource;
    NSDictionary *latestSnapshot = self.snapshotProvider(currentDataSource);
    if (BBSnapshotIsFresher(latestSnapshot, baselineSnapshot, self.deviceId) ||
        self.activeRefreshDeadline.timeIntervalSinceNow <= 0) {
        [self sendResponse:latestSnapshot];
        return;
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.activePollInterval * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            [self pollActiveRefreshWithDataSource:currentDataSource baseline:baselineSnapshot];
        }
    );
}

- (void)sendResponse:(NSDictionary *)snapshot {
    if (self.responseSent) {
        return;
    }
    self.responseSent = YES;

    NSMutableDictionary *response = [[NSMutableDictionary alloc] initWithDictionary:snapshot];
    response[@"transactionId"] = self.transactionIdentifier ?: [NSNull null];
    self.responseHandler([response copy]);
}

@end
