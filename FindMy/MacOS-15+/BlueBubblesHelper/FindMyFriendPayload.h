#import <Foundation/Foundation.h>

#import "FindMyLocateSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface FindMyFriendPayload : NSObject

+ (nullable id)valueForSelector:(SEL)selector onObject:(nullable id)object;
+ (nullable id)handleForFriendRecord:(nullable id)friendRecord;
+ (nullable id)cachedLocationForHandle:(nullable id)locationHandle
                               session:(nullable id<FindMyLocateSessionProtocol>)session;
+ (void)startRefreshingSession:(nullable id<FindMyLocateSessionProtocol>)session
                       handles:(NSArray *)handles
                      priority:(long long)priority
                    completion:(nullable FindMyCompletion)completion;

+ (nullable NSString *)identifierForHandle:(nullable id)handle;

+ (nullable NSDictionary *)locationPayloadForLocation:(nullable id)location
                                                handle:(nullable id)handle;

+ (nullable NSDictionary *)locationPayloadForLocation:(nullable id)location
                                                handle:(nullable id)handle
                                  isLocatingInProgress:(nullable NSNumber *)isLocatingOverride;

+ (NSDictionary *)responseForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                       locationsByFriendIdentifier:(NSDictionary<NSString *, NSDictionary *> *)locationsByFriendIdentifier
                          pendingFriendIdentifiers:(NSSet<NSString *> *)pendingFriendIdentifiers
                               friendListTimedOut:(BOOL)friendListTimedOut
                        unidentifiedFriendCount:(NSUInteger)unidentifiedFriendCount;

@end

NS_ASSUME_NONNULL_END
