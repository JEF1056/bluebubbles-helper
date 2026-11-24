//
//  Logging.h
//  BlueBubblesHelper
//
//  Created by Samer Shihabi on 11/29/20.
//  Copyright © 2020 BlueBubbleMessaging. All rights reserved.
//
#include <os/log.h>
#ifndef Logging_h
#define Logging_h

static inline os_log_t BBLoggingGetLog(void) {
    static os_log_t log = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.bluebubbles.messaging", "DEBUG");
    });
    return log;
}

#ifdef DEBUG
#    define ELog(N, ...) os_log_with_type(BBLoggingGetLog(), OS_LOG_TYPE_ERROR, N, ##__VA_ARGS__)
#else
#    define ELog(...) /* */
#endif
#ifdef DEBUG
#    define DLog(N, ...) os_log_with_type(BBLoggingGetLog(), OS_LOG_TYPE_DEFAULT, N, ##__VA_ARGS__)
#else
#    define DLog(...) /* */
#endif

#endif /* Logging_h */
