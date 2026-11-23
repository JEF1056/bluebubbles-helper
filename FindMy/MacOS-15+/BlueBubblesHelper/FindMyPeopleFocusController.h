#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FindMyPeopleFocusController : NSObject

@property (nonatomic, weak, nullable, readonly) id peopleDataSource;
@property (nonatomic, weak, nullable, readonly) id peopleTableView;

+ (instancetype)sharedInstance;
- (void)installCapture;
- (void)restoreBackgroundRefreshConditions;

- (void)scheduleFocusPeopleTabAndSelectTargets:(NSArray<NSString *> *)targets;
- (BOOL)focusPeopleTabAndSelectTargets:(NSArray<NSString *> *)targets
                         inRootObjects:(nullable NSArray *)rootObjects;

- (nullable id)discoverMediatorInRootObjects:(nullable NSArray *)rootObjects;
- (BOOL)startFMFLiveLocationForTargets:(NSArray<NSString *> *)targets;
- (BOOL)stopFMFLiveLocationForTargets:(NSArray<NSString *> *)targets;
- (BOOL)keepaliveFMFLiveLocationForTargets:(NSArray<NSString *> *)targets;
- (BOOL)triggerFMFShallowRefresh;

+ (BOOL)string:(nullable NSString *)candidate matchesTarget:(nullable NSString *)target;

@end

NS_ASSUME_NONNULL_END
