#import "FindMyFriendPayload.h"

#import <math.h>

@protocol BBFindMyLocation <NSObject>
- (double)altitude;
- (id)coarseAddressLabel;
- (double)horizontalAccuracy;
- (id)labels;
- (double)latitude;
- (long long)locationType;
- (double)longitude;
- (double)speed;
- (double)timestamp;
- (double)verticalAccuracy;
@end

@implementation FindMyFriendPayload

+ (nullable id)valueForSelector:(SEL)selector onObject:(nullable id)object {
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [object performSelector:selector];
#pragma clang diagnostic pop
}

+ (nullable NSString *)nonEmptyString:(nullable id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString *trimmedString = [(NSString *)value
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmedString.length > 0 ? trimmedString : nil;
}

+ (nullable NSString *)firstStringInArray:(nullable id)value {
    if (![value isKindOfClass:[NSArray class]]) {
        return nil;
    }

    for (id label in (NSArray *)value) {
        NSString *nonEmptyLabel = [self nonEmptyString:label];
        if (nonEmptyLabel != nil) {
            return nonEmptyLabel;
        }
    }

    return nil;
}

+ (id)numberForFiniteValue:(double)value {
    return isfinite(value) ? @(value) : [NSNull null];
}

+ (NSString *)statusForLocationType:(long long)locationType {
    if (locationType == 2) {
        return @"live";
    }
    if (locationType == 0) {
        return @"legacy";
    }
    return @"shallow";
}

+ (nullable NSString *)identifierForHandle:(nullable id)handle {
    SEL identifierSelector = NSSelectorFromString(@"identifier");
    NSString *primaryIdentifier = [self nonEmptyString:[self valueForSelector:identifierSelector onObject:handle]];
    if (primaryIdentifier != nil) {
        return primaryIdentifier;
    }

    SEL comparisonIdentifierSelector = NSSelectorFromString(@"comparisonIdentifier");
    return [self nonEmptyString:[self valueForSelector:comparisonIdentifierSelector onObject:handle]];
}

+ (nullable NSNumber *)boolValueForSelector:(SEL)selector onObject:(nullable id)object {
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = [signature methodReturnType];
    if (returnType == NULL || (returnType[0] != 'B' && returnType[0] != 'c')) {
        return nil;
    }

    BOOL result = NO;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:object];
    [invocation setSelector:selector];
    [invocation invoke];
    [invocation getReturnValue:&result];
    return @(result);
}

+ (BOOL)isLocatingInProgressForLocation:(nullable id)location
                                 handle:(nullable id)handle
                     isLocatingOverride:(nullable NSNumber *)isLocatingOverride {
    if (isLocatingOverride != nil) {
        return [isLocatingOverride boolValue];
    }

    NSArray<NSString *> *positiveSelectors = @[@"isLocatingInProgress", @"locatingInProgress", @"isLocating"];
    for (id target in @[location ?: [NSNull null], handle ?: [NSNull null]]) {
        if (target == [NSNull null]) {
            continue;
        }
        for (NSString *selectorName in positiveSelectors) {
            NSNumber *value = [self boolValueForSelector:NSSelectorFromString(selectorName) onObject:target];
            if (value != nil) {
                return [value boolValue];
            }
        }
    }

    NSNumber *locationFinished = [self boolValueForSelector:NSSelectorFromString(@"locationFinished") onObject:location];
    if (locationFinished != nil) {
        return ![locationFinished boolValue];
    }

    return NO;
}

+ (nullable NSDictionary *)locationPayloadForLocation:(nullable id)location handle:(nullable id)handle {
    return [self locationPayloadForLocation:location handle:handle isLocatingInProgress:nil];
}

+ (nullable NSString *)shortAddressFromPlaceMark:(nullable id)placeMark {
    if (placeMark == nil) {
        return nil;
    }
    NSString *locality = [self nonEmptyString:[self valueForSelector:NSSelectorFromString(@"locality") onObject:placeMark]];
    NSString *state = [self nonEmptyString:[self valueForSelector:NSSelectorFromString(@"stateCode") onObject:placeMark]]
        ?: [self nonEmptyString:[self valueForSelector:NSSelectorFromString(@"administrativeArea") onObject:placeMark]];
    if (locality != nil && state != nil) {
        return [NSString stringWithFormat:@"%@, %@", locality, state];
    }
    return locality ?: state;
}

+ (nullable NSString *)longAddressFromPlaceMark:(nullable id)placeMark {
    if (placeMark == nil) {
        return nil;
    }
    id formattedLines = [self valueForSelector:NSSelectorFromString(@"formattedAddressLines") onObject:placeMark];
    if ([formattedLines isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *parts = [[NSMutableArray alloc] init];
        for (id line in (NSArray *)formattedLines) {
            NSString *cleanLine = [self nonEmptyString:line];
            if (cleanLine != nil) {
                [parts addObject:cleanLine];
            }
        }
        if (parts.count > 0) {
            return [parts componentsJoinedByString:@", "];
        }
    }
    NSString *street = [self nonEmptyString:[self valueForSelector:NSSelectorFromString(@"streetAddress") onObject:placeMark]]
        ?: [self nonEmptyString:[self valueForSelector:NSSelectorFromString(@"streetName") onObject:placeMark]];
    NSString *shortLocality = [self shortAddressFromPlaceMark:placeMark];
    if (street != nil && shortLocality != nil) {
        return [NSString stringWithFormat:@"%@, %@", street, shortLocality];
    }
    return street ?: shortLocality;
}

+ (nullable NSDictionary *)locationPayloadForLocation:(nullable id)location
                                                handle:(nullable id)handle
                                  isLocatingInProgress:(nullable NSNumber *)isLocatingOverride {
    NSString *friendIdentifier = [self identifierForHandle:handle];
    if (friendIdentifier == nil) {
        return nil;
    }

    BOOL isLocatingInProgress = [self isLocatingInProgressForLocation:location
                                                               handle:handle
                                                   isLocatingOverride:isLocatingOverride];

    if (location == nil) {
        return @{
            @"handle": friendIdentifier,
            @"coordinates": [NSNull null],
            @"long_address": [NSNull null],
            @"short_address": [NSNull null],
            @"subtitle": [NSNull null],
            @"title": [NSNull null],
            @"last_updated": [NSNull null],
            @"is_locating_in_progress": @(isLocatingInProgress),
            @"status": @"legacy",
            @"location_type": [NSNull null],
            @"horizontal_accuracy": [NSNull null],
            @"vertical_accuracy": [NSNull null],
            @"speed": [NSNull null],
            @"altitude": [NSNull null],
        };
    }

    id<BBFindMyLocation> findMyLocation = (id<BBFindMyLocation>)location;
    BOOL providesCoordinates = [findMyLocation respondsToSelector:@selector(latitude)] &&
        [findMyLocation respondsToSelector:@selector(longitude)];
    id coordinates = [NSNull null];
    if (providesCoordinates) {
        double latitude = [findMyLocation latitude];
        double longitude = [findMyLocation longitude];
        if (isfinite(latitude) && isfinite(longitude)) {
            coordinates = @[@(latitude), @(longitude)];
        }
    }

    double timestampSeconds = [findMyLocation respondsToSelector:@selector(timestamp)]
        ? [findMyLocation timestamp] : 0;
    BOOL providesLocationType = [findMyLocation respondsToSelector:@selector(locationType)];
    long long locationType = providesLocationType ? [findMyLocation locationType] : 0;
    id placeMark = [self valueForSelector:NSSelectorFromString(@"address") onObject:findMyLocation];
    NSString *coarseAddress = [self nonEmptyString:
        [self valueForSelector:@selector(coarseAddressLabel) onObject:findMyLocation]];
    NSString *longAddress = [self longAddressFromPlaceMark:placeMark] ?: coarseAddress;
    NSString *shortAddress = coarseAddress ?: [self shortAddressFromPlaceMark:placeMark] ?: longAddress;
    NSString *subtitle = shortAddress ?: longAddress;
    NSString *firstLocationLabel = [self firstStringInArray:
        [self valueForSelector:@selector(labels) onObject:findMyLocation]];

    return @{
        @"handle": friendIdentifier,
        @"coordinates": coordinates,
        @"long_address": longAddress ?: [NSNull null],
        @"short_address": shortAddress ?: [NSNull null],
        @"subtitle": subtitle ?: [NSNull null],
        @"title": firstLocationLabel ?: [NSNull null],
        @"last_updated": timestampSeconds > 0 && isfinite(timestampSeconds)
            ? @(llround(timestampSeconds * 1000.0)) : [NSNull null],
        @"is_locating_in_progress": @(isLocatingInProgress),
        @"status": [self statusForLocationType:locationType],
        @"location_type": providesLocationType ? @(locationType) : [NSNull null],
        @"horizontal_accuracy": [findMyLocation respondsToSelector:@selector(horizontalAccuracy)]
            ? [self numberForFiniteValue:[findMyLocation horizontalAccuracy]] : [NSNull null],
        @"vertical_accuracy": [findMyLocation respondsToSelector:@selector(verticalAccuracy)]
            ? [self numberForFiniteValue:[findMyLocation verticalAccuracy]] : [NSNull null],
        @"speed": [findMyLocation respondsToSelector:@selector(speed)]
            ? [self numberForFiniteValue:[findMyLocation speed]] : [NSNull null],
        @"altitude": [findMyLocation respondsToSelector:@selector(altitude)]
            ? [self numberForFiniteValue:[findMyLocation altitude]] : [NSNull null],
    };
}

+ (NSDictionary *)responseForTransactionIdentifier:(nullable NSString *)transactionIdentifier
                       locationsByFriendIdentifier:(NSDictionary<NSString *, NSDictionary *> *)locationsByFriendIdentifier
                          pendingFriendIdentifiers:(NSSet<NSString *> *)pendingFriendIdentifiers
                               friendListTimedOut:(BOOL)friendListTimedOut
                        unidentifiedFriendCount:(NSUInteger)unidentifiedFriendCount {
    NSArray<NSString *> *sortedFriendIdentifiers = [[locationsByFriendIdentifier allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary *> *orderedLocations = [[NSMutableArray alloc]
        initWithCapacity:sortedFriendIdentifiers.count];
    for (NSString *friendIdentifier in sortedFriendIdentifiers) {
        NSDictionary *locationPayload = locationsByFriendIdentifier[friendIdentifier];
        if (locationPayload != nil) {
            if ([pendingFriendIdentifiers containsObject:friendIdentifier] &&
                ![locationPayload[@"is_locating_in_progress"] isEqual:@YES]) {
                NSMutableDictionary *mutablePayload = [locationPayload mutableCopy];
                mutablePayload[@"is_locating_in_progress"] = @YES;
                locationPayload = mutablePayload;
            }
            [orderedLocations addObject:locationPayload];
        }
    }

    NSArray<NSString *> *timedOutFriendIdentifiers = [[pendingFriendIdentifiers allObjects]
        sortedArrayUsingSelector:@selector(compare:)];
    BOOL responseIsPartial = friendListTimedOut || timedOutFriendIdentifiers.count > 0;

    return @{
        @"transactionId": transactionIdentifier ?: [NSNull null],
        @"locations": orderedLocations,
        @"partial": @(responseIsPartial),
        @"friendListTimedOut": @(friendListTimedOut),
        @"timedOutHandles": timedOutFriendIdentifiers,
        @"skippedFriends": @(unidentifiedFriendCount),
    };
}

@end
