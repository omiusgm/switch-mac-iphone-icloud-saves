#import <Cocoa/Cocoa.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>

static NSString *const cloudProgressMessage = @"Подготавливаем сохранение iCloud…";
static NSString *const cloudQuitMessage = @"Завершаем работу с iCloud…";

@interface CloudQuitGuard : NSObject <NSApplicationDelegate>
@property (nonatomic, copy) void (^showQuitStatus)(void);
@property (nonatomic) BOOL quitRequested;
@property (nonatomic) BOOL replyPending;
@property (nonatomic) NSTimeInterval replyDeadline;
@end

@implementation CloudQuitGuard
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    self.quitRequested = YES;
    if (!self.replyPending) {
        self.replyPending = YES;
        self.replyDeadline = NSProcessInfo.processInfo.systemUptime + 8;
    }
    self.showQuitStatus();
    return NSTerminateLater;
}
@end

static NSPanel *cloudProgressPanel(NSProgressIndicator *indicator, NSTextField *message) {
    const CGFloat inset = 22;
    indicator.style = NSProgressIndicatorStyleSpinning;
    indicator.controlSize = NSControlSizeSmall;
    indicator.indeterminate = YES;
    indicator.displayedWhenStopped = YES;
    [indicator sizeToFit];

    message.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    [message sizeToFit];
    CGFloat width = inset + NSWidth(indicator.frame) + 12 + NSWidth(message.frame) + inset;
    CGFloat height = 64;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.title = @"Zelda";
    panel.hidesOnDeactivate = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    [indicator setFrameOrigin:NSMakePoint(inset, (height - NSHeight(indicator.frame)) / 2)];
    [message setFrameOrigin:NSMakePoint(NSMaxX(indicator.frame) + 12, (height - NSHeight(message.frame)) / 2)];
    [panel.contentView addSubview:indicator];
    [panel.contentView addSubview:message];
    [panel center];
    return panel;
}

static NSData *readCloudOutput(NSTask *task, NSPipe *pipe) {
    NSFileHandle *reader = pipe.fileHandleForReading;
    NSData *data = [reader readDataToEndOfFileAndReturnError:NULL];
    [reader closeAndReturnError:NULL];
    [task waitUntilExit];
    return data;
}

static void announceStatus(NSPanel *panel, NSString *message) {
    NSAccessibilityPostNotificationWithUserInfo(panel, NSAccessibilityAnnouncementRequestedNotification, @{
        NSAccessibilityAnnouncementKey: message,
        NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
    });
}

static NSData *waitForCloudHelper(NSTask *task, NSPipe *pipe, BOOL showProgress, BOOL *quitRequested) {
    __block NSData *data = nil;
    dispatch_group_t reading = dispatch_group_create();
    dispatch_group_async(reading, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        data = readCloudOutput(task, pipe);
    });

    // Quick operations return without initializing AppKit or flashing a window.
    dispatch_time_t showAfter = dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC);
    if (dispatch_group_wait(reading, showAfter) == 0) return data;

    NSApplication *app = [NSApplication sharedApplication];
    id<NSApplicationDelegate> previousDelegate = app.delegate;
    CloudQuitGuard *guard = [CloudQuitGuard new];
    app.delegate = guard;

    __block NSPanel *panel = nil;
    NSProgressIndicator *indicator = [NSProgressIndicator new];
    NSTextField *message = [NSTextField labelWithString:cloudProgressMessage];
    void (^showPanel)(NSString *) = ^(NSString *status) {
        if (panel && [message.stringValue isEqualToString:status]) return;
        if (!panel) {
            panel = cloudProgressPanel(indicator, message);
            [indicator startAnimation:nil];
        }
        message.stringValue = status;
        [panel orderFrontRegardless];
        announceStatus(panel, status);
    };
    guard.showQuitStatus = ^{ showPanel(cloudQuitMessage); };
    void (^closePanel)(void) = ^{
        [indicator stopAnimation:nil];
        [panel close];
        panel = nil;
    };

    if (showProgress && dispatch_group_wait(reading, DISPATCH_TIME_NOW) != 0) showPanel(cloudProgressMessage);

    NSTimer *timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *tick) {
        BOOL finished = dispatch_group_wait(reading, DISPATCH_TIME_NOW) == 0;
        if (finished) {
            [tick invalidate];
            closePanel();
            if (guard.replyPending) {
                guard.replyPending = NO;
                [app replyToApplicationShouldTerminate:YES];
            }
            [app stop:nil];
            // -stop: takes effect after the event loop processes another event.
            NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
            [app postEvent:wake atStart:YES];
        } else if (guard.replyPending && NSProcessInfo.processInfo.systemUptime >= guard.replyDeadline) {
            // Release the system quit/logout request rather than hold it indefinitely.
            // The launcher remains visible and exits after the writer finishes.
            guard.replyPending = NO;
            [app replyToApplicationShouldTerminate:NO];
        }
    }];
    NSRunLoop *runLoop = NSRunLoop.mainRunLoop;
    [runLoop addTimer:timer forMode:NSRunLoopCommonModes];
    [runLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
    [app run];
    [timer invalidate];
    dispatch_group_wait(reading, DISPATCH_TIME_FOREVER);
    closePanel();
    app.delegate = previousDelegate;
    *quitRequested = guard.quitRequested;
    return data;
}

static NSDictionary *validatedCloudReport(NSTask *task, NSData *data, NSString *action) {
    NSDictionary *unavailable = @{@"status":@"unavailable"};
    if (!data || task.terminationReason != NSTaskTerminationReasonExit || task.terminationStatus != 0) return unavailable;
    id report = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![report isKindOfClass:NSDictionary.class]) return unavailable;
    id status = report[@"status"];
    NSArray *allowed = @{
        @"before":@[@"ready", @"imported", @"empty", @"conflict"],
        @"resolve":@[@"resolved", @"conflict"],
        @"after":@[@"empty", @"published", @"remote-update", @"conflict"]
    }[action];
    if (![status isKindOfClass:NSString.class] || ![allowed containsObject:status]) return unavailable;
    if ([action isEqualToString:@"before"] && [status isEqualToString:@"conflict"]) {
        id choices = report[@"choices"];
        if (![choices isKindOfClass:NSArray.class] || [choices count] == 0 || [choices count] > 32) return unavailable;
        for (id choice in choices) {
            if (![choice isKindOfClass:NSDictionary.class] || ![choice[@"id"] isKindOfClass:NSString.class] ||
                [choice[@"id"] length] == 0 || ![choice[@"device"] isKindOfClass:NSString.class] ||
                ![choice[@"created"] isKindOfClass:NSString.class]) return unavailable;
        }
    }
    return report;
}

static NSDictionary *cloudAction(NSDictionary *settings, NSString *action, NSString *revision) {
    if (![settings[@"enabled"] boolValue]) return @{@"status":@"disabled"};
    NSString *helper = settings[@"helper"], *configuration = settings[@"config"];
    if (![helper isKindOfClass:NSString.class] || ![configuration isKindOfClass:NSString.class]) return @{@"status":@"unavailable"};
    NSTask *task = [NSTask new]; NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/caffeinate"];
    NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[@"-i", helper, action, configuration]];
    if (revision) [arguments addObject:revision];
    task.arguments = arguments; task.standardOutput = pipe; task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    id activity = [processInfo beginActivityWithOptions:NSActivitySuddenTerminationDisabled | NSActivityAutomaticTerminationDisabled
        reason:@"Wait for iCloud save operation"];
    if (![task launchAndReturnError:NULL]) {
        [processInfo endActivity:activity];
        return @{@"status":@"unavailable"};
    }
    BOOL quitRequested = NO;
    NSData *data = waitForCloudHelper(task, pipe, [action isEqualToString:@"before"], &quitRequested);
    [processInfo endActivity:activity];
    if (quitRequested) return @{@"status":@"cancelled"};
    return validatedCloudReport(task, data, action);
}

static BOOL cloudBefore(NSDictionary *settings) {
    NSDictionary *result = cloudAction(settings, @"before", nil);
    if ([result[@"status"] isEqualToString:@"conflict"]) {
        [NSApplication sharedApplication]; NSAlert *alert = [NSAlert new];
        alert.messageText = @"Какое сохранение продолжить?";
        alert.informativeText = @"На Mac и iPhone появились разные изменения. Все копии останутся в истории iCloud.";
        [alert addButtonWithTitle:@"Отмена"];
        NSArray *choices = result[@"choices"];
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new]; NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"dd.MM HH:mm";
        for (NSDictionary *choice in choices) {
            NSDate *date = [iso dateFromString:choice[@"created"]];
            [alert addButtonWithTitle:[NSString stringWithFormat:@"%@ · %@", choice[@"device"], date ? [formatter stringFromDate:date] : choice[@"created"]]];
        }
        NSInteger index = [alert runModal] - NSAlertFirstButtonReturn - 1;
        if (index < 0 || index >= choices.count) return NO;
        result = cloudAction(settings, @"resolve", choices[index][@"id"]);
        if ([result[@"status"] isEqualToString:@"conflict"]) {
            NSAlert *retry = [NSAlert new];
            retry.messageText = @"Сохранения iCloud снова разошлись";
            retry.informativeText = @"Запустите Zelda ещё раз, чтобы выбрать актуальное сохранение.";
            [retry addButtonWithTitle:@"ОК"];
            [retry runModal];
            return NO;
        }
    }
    if ([result[@"status"] isEqualToString:@"cancelled"]) return NO;
    if ([result[@"status"] isEqualToString:@"unavailable"]) {
        [NSApplication sharedApplication]; NSAlert *alert = [NSAlert new];
        alert.messageText = @"iCloud пока недоступен";
        alert.informativeText = @"Сохранение на этом Mac сохранено. Можно дождаться iCloud или играть с локальной копией. Новые изменения будут отправлены при следующем запуске.";
        [alert addButtonWithTitle:@"Отмена"]; [alert addButtonWithTitle:@"Играть локально"];
        return [alert runModal] == NSAlertSecondButtonReturn;
    }
    return YES;
}

// Keep one launcher in charge of this profile from before-sync through after-sync.
static int lockLauncherSession(NSString *home) {
    NSString *support = [home stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames/BotW"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:NULL]) {
        errno = EIO;
        return -1;
    }
    NSString *path = [support stringByAppendingPathComponent:@"launcher-session.lock"];
    int session = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
    if (session < 0) return -1;
    struct stat file;
    int lockError;
    if (fstat(session, &file) < 0) {
        lockError = errno;
    } else if (!S_ISREG(file.st_mode) || file.st_uid != geteuid() || file.st_nlink != 1 || (file.st_mode & 07777) != 0600) {
        lockError = EPERM;
    } else {
        if (flock(session, LOCK_EX | LOCK_NB) == 0) return session;
        lockError = errno;
    }
    close(session);
    errno = lockError;
    return -1;
}

static void showSessionFailure(int lockError) {
    [NSApplication sharedApplication];
    NSAlert *alert = [NSAlert new];
    if (lockError == EWOULDBLOCK) {
        alert.messageText = @"Zelda уже запускается или открыта";
        alert.informativeText = @"Дождитесь завершения синхронизации или вернитесь в открытую игру.";
    } else {
        alert.messageText = @"Не удалось запустить Zelda";
        alert.informativeText = @"Не удалось получить доступ к папке запуска Zelda.";
    }
    [alert addButtonWithTitle:@"ОК"];
    [alert runModal];
}

static int runGame(NSArray<NSString *> *args, NSDictionary *cloud) {
    if (cloud && !cloudBefore(cloud)) return 1;
    NSTask *process = [NSTask new];
    process.executableURL = [NSURL fileURLWithPath:args[0]];
    process.arguments = [args subarrayWithRange:NSMakeRange(1, args.count - 1)];
    NSError *error = nil;
    if (![process launchAndReturnError:&error]) return 1;
    [process waitUntilExit];
    NSDictionary *result = cloud ? cloudAction(cloud, @"after", nil) : nil;
    if ([result[@"status"] isEqualToString:@"unavailable"] || [result[@"status"] isEqualToString:@"conflict"]) {
        [NSApplication sharedApplication]; NSAlert *alert = [NSAlert new];
        alert.messageText = @"Сохранение осталось на Mac";
        alert.informativeText = [result[@"status"] isEqualToString:@"conflict"] ? @"Копии в iCloud разошлись. При следующем запуске можно выбрать, какой прогресс продолжить." : @"Не удалось завершить синхронизацию iCloud. Повторим при следующем запуске игры.";
        [alert addButtonWithTitle:@"ОК"]; [alert runModal];
    }
    return process.terminationStatus;
}

int main(int argc, char **launchArguments) {
    @autoreleasepool {
        BOOL check = argc > 1 && !strcmp(launchArguments[1], "--check");
        NSString *home = NSHomeDirectory();
        NSMutableDictionary *environment = [@{@"TOTK_SLOT_OWNER":@"user", @"TOTK_SLOT_PURPOSE":@"player"} mutableCopy];
        NSString *settings = NSProcessInfo.processInfo.environment[@"BOTW_SETUP_CONFIG"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"BOTWSetupConfig"];
        if (!settings) settings = [home stringByAppendingPathComponent:@"Library/Application Support/BOTW-iCloud/setup.json"];
        NSData *data = [NSData dataWithContentsOfFile:settings];
        id config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *game = [config isKindOfClass:NSDictionary.class] && [config[@"app"] isKindOfClass:NSString.class] ? config[@"app"] : [home stringByAppendingPathComponent:@"Applications/Breath of the Wild.app"];
        if ([config isKindOfClass:NSDictionary.class]) {
            id profile = config[@"launch_env"];
            if ([profile isKindOfClass:NSDictionary.class]) {
                for (id key in profile) if ([key isKindOfClass:NSString.class] && [profile[key] isKindOfClass:NSString.class]) environment[key] = profile[key];
            }
        }
        NSString *infoPath = [game stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if (![info[@"CFBundleIdentifier"] isEqualToString:@"org.macnativegames.botw"]) {
            [NSApplication sharedApplication];
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Не найдено приложение Zelda";
            alert.informativeText = [@"Ожидаемый путь: " stringByAppendingString:game];
            [alert addButtonWithTitle:@"ОК"];
            [alert runModal];
            return 1;
        }
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[@"/usr/bin/caffeinate",@"-i",@"/usr/bin/open",@"-W"]];
        for (NSString *key in [[environment allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            [args addObject:@"--env"];
            [args addObject:[NSString stringWithFormat:@"%@=%@",key,environment[key]]];
        }
        [args addObject:game];
        if (check) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:args options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return 0;
        }
        NSDictionary *cloud = [config isKindOfClass:NSDictionary.class] ? config[@"cloud_saves"] : nil;
        int session = lockLauncherSession(home);
        if (session < 0) {
            showSessionFailure(errno);
            return 1;
        }
        int result = runGame(args, cloud);
        close(session);
        return result;
    }
}
