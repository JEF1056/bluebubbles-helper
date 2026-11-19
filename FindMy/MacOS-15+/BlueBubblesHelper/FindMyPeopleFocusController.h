#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FindMyPeopleFocusController : NSObject

@property (nonatomic, weak, nullable, readonly) id peopleDataSource;
@property (nonatomic, weak, nullable, readonly) id peopleTableView;

+ (instancetype)sharedInstance;
- (void)installCapture;

- (void)scheduleFocusPeopleTabAndSelectTargets:(NSArray<NSString *> *)targets;
- (BOOL)focusPeopleTabAndSelectTargets:(NSArray<NSString *> *)targets
                         inRootObjects:(nullable NSArray *)rootObjects;

+ (BOOL)string:(nullable NSString *)candidate matchesTarget:(nullable NSString *)target;

@end

NS_ASSUME_NONNULL_END
