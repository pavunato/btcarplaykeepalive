#import <Foundation/Foundation.h>
#import "BTKLog.h"
#import <os/log.h>
#import <stdarg.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static os_log_t BTKLogHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.pavunato.btcarplaykeepalive", "tweak");
    });
    return handle;
}

static NSString *BTKLogPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *candidate = @"/var/mobile/Library/Logs/btcarplaykeepalive.log";
        NSString *directory = candidate.stringByDeletingLastPathComponent;
        path = (access(directory.fileSystemRepresentation, W_OK) == 0)
                   ? candidate
                   : [NSTemporaryDirectory() stringByAppendingPathComponent:
                                      @"btcarplaykeepalive.log"];
    });
    return path;
}

static void BTKAppend(NSString *line) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.pavunato.btcarplaykeepalive.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        NSString *path = BTKLogPath();
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0644);
        if (fd < 0) return;
        struct stat info = {0};
        if (fstat(fd, &info) == 0 && info.st_size >= 1024 * 1024) ftruncate(fd, 0);
        fchmod(fd, 0644);
        FILE *file = fdopen(fd, "a");
        if (!file) {
            close(fd);
            return;
        }
        fputs(line.UTF8String ?: "", file);
        fputc('\n', file);
        fclose(file);
    });
}

BOOL CSVerboseEnabled(void) {
    const char *value = getenv("BTK_VERBOSE");
    return value && *value && *value != '0';
}

void CSLogImpl(const char *tag, const char *fmt, ...) {
    if (!CSVerboseEnabled()) return;
    va_list args;
    va_start(args, fmt);
    char *body = NULL;
    if (vasprintf(&body, fmt, args) < 0) body = NULL;
    va_end(args);
    if (!body) return;

    const char *process = NSProcessInfo.processInfo.processName.UTF8String ?: "?";
    os_log(BTKLogHandle(), "[%{public}s/%{public}s] %{public}s", tag ?: "btk", process, body);
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                       dateStyle:NSDateFormatterShortStyle
                                                       timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"%@ [%s/%s] %s", stamp ?: @"?",
                                                tag ?: "btk", process, body];
    BTKAppend(line);
    free(body);
}

void CSLogTimingImpl(const char *tag, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char *body = NULL;
    if (vasprintf(&body, fmt, args) < 0) body = NULL;
    va_end(args);
    if (!body) return;
    CSLogImpl(tag, "%s", body);
    free(body);
}
