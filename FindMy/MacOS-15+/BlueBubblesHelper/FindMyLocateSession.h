#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FindMyCompletion)(void);
typedef void (^FindMyFriendsCompletion)(NSArray * _Nullable friendRecords);
typedef void (^FindMyLocationUpdateCallback)(id _Nullable location, id handle);

@protocol FindMyLocateSessionProtocol <NSObject>

@optional

- (nullable id)cachedLocationForHandle:(id)locationHandle;
- (nullable id)cachedLocationForHandle:(id)locationHandle includeAddress:(BOOL)includeAddress;
- (nullable NSArray *)cachedFriendsSharingLocationWithMe;
- (nullable NSArray *)cachedFriendsSharingLocationsWithMe;
- (void)getFriendsSharingLocationsWithMeWithCompletion:(FindMyFriendsCompletion)completion;
- (void)setLocationUpdateCallback:(nullable FindMyLocationUpdateCallback)callback;
- (void)startMonitoringActiveLocationSharingDeviceChangeWithCompletion:(FindMyCompletion)completion;
- (void)startRefreshingLocationForHandles:(NSArray *)locationHandles
                                  priority:(long long)priority
                               isFromGroup:(BOOL)isFromGroup
                                completion:(FindMyCompletion)completion;
- (void)startRefreshingLocationForHandles:(NSArray *)locationHandles
                                  priority:(long long)priority
                               isFromGroup:(BOOL)isFromGroup
                            reverseGeocode:(BOOL)reverseGeocode
                                completion:(FindMyCompletion)completion;
- (void)stopRefreshingLocationForHandles:(NSArray *)locationHandles
                                 priority:(long long)priority
                              isFromGroup:(BOOL)isFromGroup
                               completion:(FindMyCompletion)completion;
- (void)startUpdatingFriendsWithInitialUpdates:(BOOL)includeInitialUpdates
                                    completion:(FindMyCompletion)completion;

@end

@interface FindMyLocateSession : NSObject <FindMyLocateSessionProtocol>
@end

NS_ASSUME_NONNULL_END
