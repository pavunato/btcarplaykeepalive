#import <Foundation/Foundation.h>

void CSLogImpl(const char *tag, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
