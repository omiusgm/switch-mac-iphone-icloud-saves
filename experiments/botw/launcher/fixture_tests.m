#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>

static NSUInteger panelsShown, panelsHidden, announcements, applicationCalls, alerts;
static BOOL panelShown;
static NSModalResponse nextResponse = NSAlertFirstButtonReturn;
static NSString *testHome, *marker, *fixtureRoot, *fixtureScenario;
static BOOL (*originalLaunch)(NSTask *, SEL, NSError **);
static void (*originalReply)(NSApplication *, SEL, BOOL);
static void (*originalClose)(NSPanel *, SEL);

static void recordMarker(NSString *suffix) {
    assert([@"ok" writeToFile:[marker stringByAppendingString:suffix] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
}

static BOOL fixtureLaunch(NSTask *task, SEL selector, NSError **error) {
    if (task.arguments.count > 1 && [task.arguments[1] isEqualToString:@"/usr/bin/open"]) {
        assert([fixtureScenario isEqualToString:@"lifecycle-first"]);
        task.arguments = @[@"-i", [fixtureRoot stringByAppendingPathComponent:@"fixture.sh"], @"game", @"lifecycle"];
    }
    assert([task.executableURL.path isEqualToString:@"/usr/bin/caffeinate"]);
    assert(task.arguments.count >= 2 && [task.arguments[0] isEqualToString:@"-i"]);
    NSString *helper = task.arguments[1];
    assert([helper isEqualToString:[fixtureRoot stringByAppendingPathComponent:@"fixture.sh"]] ||
           ([fixtureScenario isEqualToString:@"missing-helper"] && [helper isEqualToString:[fixtureRoot stringByAppendingPathComponent:@"missing-executable"]]));
    if ([fixtureScenario isEqualToString:@"launch-failure"]) {
        task.executableURL = [NSURL fileURLWithPath:[fixtureRoot stringByAppendingPathComponent:@"missing-task-executable"]];
    }
    return originalLaunch(task, selector, error);
}

static void fixtureReply(NSApplication *app, SEL selector, BOOL terminate) {
    assert([NSThread isMainThread]);
    if (terminate) {
        assert([fixtureScenario isEqualToString:@"quit"] && !panelShown);
        assert([NSFileManager.defaultManager fileExistsAtPath:marker]);
        recordMarker(@".reply-yes");
    } else {
        assert([fixtureScenario isEqualToString:@"quit-timeout"] && panelShown);
        assert(![NSFileManager.defaultManager fileExistsAtPath:marker]);
        recordMarker(@".reply-no");
    }
    originalReply(app, selector, terminate);
}

@interface NSApplication (OffscreenFixture)
+ (NSApplication *)fixtureSharedApplication;
@end

@implementation NSApplication (OffscreenFixture)
+ (NSApplication *)fixtureSharedApplication {
    applicationCalls++;
    NSApplication *app = [self sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
    return app;
}
@end

static NSString *fixtureHomeDirectory(void) {
    return testHome;
}

static void fixtureAnnouncement(id element, NSAccessibilityNotificationName notification, NSDictionary *info) {
    assert([NSThread isMainThread] && panelShown && [element isKindOfClass:NSPanel.class]);
    assert([notification isEqualToString:NSAccessibilityAnnouncementRequestedNotification]);
    assert([info[NSAccessibilityAnnouncementKey] length] > 0);
    announcements++;
}

#define sharedApplication fixtureSharedApplication
#define NSHomeDirectory fixtureHomeDirectory
#define NSAccessibilityPostNotificationWithUserInfo fixtureAnnouncement
#define main zeldaLauncherMain
#include "profile_launcher.m"
#undef main
#undef NSAccessibilityPostNotificationWithUserInfo
#undef NSHomeDirectory
#undef sharedApplication

static void showOffscreen(NSPanel *panel, SEL selector) {
    (void)selector;
    assert([NSThread isMainThread]);
    assert((panel.styleMask & NSWindowStyleMaskNonactivatingPanel) != 0);
    assert([panel.contentView.subviews.firstObject isKindOfClass:NSProgressIndicator.class]);
    NSTextField *message = panel.contentView.subviews.lastObject;
    assert(NSContainsRect(panel.contentView.bounds, message.frame));
    if (panelShown) {
        assert([message.stringValue isEqualToString:cloudQuitMessage]);
        recordMarker(@".quit-shown");
        return;
    }
    assert([message.stringValue isEqualToString:cloudProgressMessage]);
    if ([marker hasSuffix:@"/slow.marker"]) assert(![NSFileManager.defaultManager fileExistsAtPath:marker]);
    panelShown = YES;
    panelsShown++;
    recordMarker(@".shown");
    if ([fixtureScenario hasPrefix:@"quit"]) {
        [NSTimer scheduledTimerWithTimeInterval:0.10 repeats:NO block:^(NSTimer *tick) {
            (void)tick;
            [NSApp terminate:nil];
        }];
    }
}

static void hideOffscreen(NSPanel *panel, SEL selector) {
    assert([NSThread isMainThread]);
    if (panelShown) {
        if ([marker hasSuffix:@"/slow.marker"]) assert([NSFileManager.defaultManager fileExistsAtPath:marker]);
        panelShown = NO;
        panelsHidden++;
    }
    originalClose(panel, selector);
}

static NSModalResponse alertOffscreen(NSAlert *alert, SEL selector) {
    (void)selector;
    assert([NSThread isMainThread] && !panelShown);
    assert(alert.messageText.length > 0);
    if ([fixtureScenario isEqualToString:@"missing-game-check"]) {
        assert([alert.messageText isEqualToString:@"Не найдено приложение Zelda"]);
        assert([alert.informativeText hasSuffix:@"Applications/Breath of the Wild.app"]);
    }
    alerts++;
    return nextResponse;
}

static void installOffscreenFixtures(void) {
    SEL launch = @selector(launchAndReturnError:);
    Class concreteTask = [NSTask new].class;
    Method launchMethod = class_getInstanceMethod(concreteTask, launch);
    originalLaunch = (void *)method_getImplementation(launchMethod);
    class_replaceMethod(concreteTask, launch, (IMP)fixtureLaunch, method_getTypeEncoding(launchMethod));

    SEL reply = @selector(replyToApplicationShouldTerminate:);
    Method replyMethod = class_getInstanceMethod(NSApplication.class, reply);
    originalReply = (void *)method_getImplementation(replyMethod);
    class_replaceMethod(NSApplication.class, reply, (IMP)fixtureReply, method_getTypeEncoding(replyMethod));

    Class panel = NSPanel.class;
    SEL show = @selector(orderFrontRegardless), hide = @selector(close), alert = @selector(runModal);
    class_replaceMethod(panel, show, (IMP)showOffscreen, method_getTypeEncoding(class_getInstanceMethod(panel, show)));
    Method closeMethod = class_getInstanceMethod(panel, hide);
    originalClose = (void *)method_getImplementation(closeMethod);
    class_replaceMethod(panel, hide, (IMP)hideOffscreen, method_getTypeEncoding(closeMethod));
    class_replaceMethod(NSAlert.class, alert, (IMP)alertOffscreen, method_getTypeEncoding(class_getInstanceMethod(NSAlert.class, alert)));
}

static void render(NSString *root, NSAppearanceName appearance, NSString *filename) {
    [NSApplication fixtureSharedApplication];
    NSPanel *panel = cloudProgressPanel([NSProgressIndicator new], [NSTextField labelWithString:cloudProgressMessage]);
    panel.appearance = [NSAppearance appearanceNamed:appearance];
    NSView *frame = panel.contentView.superview;
    [frame layoutSubtreeIfNeeded];
    NSRect bounds = frame.bounds;
    NSBitmapImageRep *bitmap = [frame bitmapImageRepForCachingDisplayInRect:bounds];
    [frame cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    assert(png.length > 0 && [png writeToFile:[root stringByAppendingPathComponent:filename] atomically:YES]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        NSString *root = @(argv[1]), *scenario = @(argv[2]);
        if ([scenario isEqualToString:@"preview"]) {
            render(root, NSAppearanceNameAqua, @"preview-light.png");
            render(root, NSAppearanceNameDarkAqua, @"preview-dark.png");
            return 0;
        }

        fixtureRoot = root;
        fixtureScenario = scenario;
        installOffscreenFixtures();
        marker = [root stringByAppendingPathComponent:[scenario stringByAppendingString:@".marker"]];
        [NSFileManager.defaultManager removeItemAtPath:marker error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:[marker stringByAppendingString:@".shown"] error:NULL];
        setenv("ZELDA_TEST_MARKER", marker.fileSystemRepresentation, 1);
        NSString *helper = [root stringByAppendingPathComponent:@"fixture.sh"];
        NSMutableDictionary *settings = [@{@"enabled":@YES, @"helper":helper, @"config":scenario} mutableCopy];

        NSUInteger expectedPanels = 0, expectedAlerts = 0;
        BOOL lifecycle = [scenario hasPrefix:@"lifecycle-"];
        if (lifecycle || [scenario isEqualToString:@"check"] || [scenario isEqualToString:@"missing-game-check"]) {
            testHome = [root stringByAppendingPathComponent:lifecycle ? @"lifecycle-home" : scenario];
            if (lifecycle) settings[@"config"] = @"lifecycle";
            NSString *configPath = [testHome stringByAppendingPathComponent:@"Library/Application Support/BOTW-iCloud/setup.json"];
            NSFileManager *files = NSFileManager.defaultManager;
            assert([files createDirectoryAtPath:configPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]);
            NSData *config = [NSJSONSerialization dataWithJSONObject:@{@"cloud_saves":settings} options:0 error:NULL];
            assert([config writeToFile:configPath atomically:YES]);
            BOOL gameExists = lifecycle || [scenario isEqualToString:@"check"];
            if (gameExists) {
                NSString *info = [testHome stringByAppendingPathComponent:@"Applications/Breath of the Wild.app/Contents/Info.plist"];
                assert([files createDirectoryAtPath:info.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]);
                assert([@{@"CFBundleIdentifier":@"org.macnativegames.botw"} writeToFile:info atomically:YES]);
            }
            char *arguments[] = {"launcher", "--check", NULL};
            if (lifecycle) {
                BOOL first = [scenario isEqualToString:@"lifecycle-first"];
                assert(zeldaLauncherMain(1, arguments) == (first ? 0 : 1));
                if (!first) assert(alerts == 1 && panelsShown == 0);
                assert(!panelShown);
                fprintf(stderr, "PASS %s\n", scenario.UTF8String);
                return 0;
            }
            assert(zeldaLauncherMain(2, arguments) == (gameExists ? 0 : 1));
            expectedAlerts = gameExists ? 0 : 1;
            assert(applicationCalls == expectedAlerts);
        } else if ([scenario hasPrefix:@"lock-"]) {
            testHome = [root stringByAppendingPathComponent:scenario];
            NSString *support = [testHome stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames/BotW"];
            NSString *path = [support stringByAppendingPathComponent:@"launcher-session.lock"];
            NSFileManager *files = NSFileManager.defaultManager;
            assert([files createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:NULL]);
            [files removeItemAtPath:path error:NULL];
            if ([scenario isEqualToString:@"lock-public"]) {
                assert([files createFileAtPath:path contents:nil attributes:nil]);
                assert(chmod(path.fileSystemRepresentation, 0666) == 0);
            } else if ([scenario isEqualToString:@"lock-hardlink"]) {
                NSString *target = [support stringByAppendingPathComponent:@"lock-target"];
                [files removeItemAtPath:target error:NULL];
                assert([files createFileAtPath:target contents:nil attributes:nil]);
                assert(chmod(target.fileSystemRepresentation, 0600) == 0);
                assert(link(target.fileSystemRepresentation, path.fileSystemRepresentation) == 0);
            } else {
                assert(!"unknown lock scenario");
            }
            assert(lockLauncherSession(testHome) == -1 && errno == EPERM);
        } else if ([scenario isEqualToString:@"disabled"]) {
            settings[@"enabled"] = @NO;
            assert(cloudBefore(settings));
            assert(applicationCalls == 0);
        } else if ([@[@"fast", @"valid-empty", @"valid-imported"] containsObject:scenario]) {
            assert(cloudBefore(settings));
            assert(applicationCalls == 0);
        } else if ([scenario isEqualToString:@"slow"]) {
            assert(cloudBefore(settings));
            expectedPanels = 1;
        } else if ([scenario isEqualToString:@"malformed"]) {
            assert(!cloudBefore(settings));
            expectedPanels = 1;
            expectedAlerts = 1;
        } else if ([scenario isEqualToString:@"missing-helper"]) {
            settings[@"helper"] = [root stringByAppendingPathComponent:@"missing-executable"];
            assert(!cloudBefore(settings));
            expectedAlerts = 1;
        } else if ([@[@"launch-failure", @"nonzero-json", @"signalled-json", @"missing-status", @"empty-status",
                     @"unknown-status", @"wrong-status", @"bad-choice"] containsObject:scenario]) {
            assert(!cloudBefore(settings));
            expectedAlerts = 1;
        } else if ([scenario hasPrefix:@"quit"]) {
            assert(!cloudBefore(settings));
            assert([scenario isEqualToString:@"quit-timeout"]);  // Quit within the grace period terminates via AppKit.
            assert([NSFileManager.defaultManager fileExistsAtPath:[marker stringByAppendingString:@".reply-no"]]);
            assert([NSFileManager.defaultManager fileExistsAtPath:marker]);
            assert(!panelShown && panelsShown == 1 && panelsHidden == 1 && announcements == 2 && alerts == 0);
            fprintf(stderr, "PASS %s\n", scenario.UTF8String);
            return 0;
        } else if ([scenario isEqualToString:@"offline"]) {
            nextResponse = NSAlertSecondButtonReturn;
            assert(cloudBefore(settings));
            expectedPanels = 1;
            expectedAlerts = 1;
        } else if ([scenario isEqualToString:@"cancel"]) {
            assert(!cloudBefore(settings));
            expectedPanels = 1;
            expectedAlerts = 1;
        } else if ([scenario isEqualToString:@"choose"]) {
            nextResponse = NSAlertSecondButtonReturn;
            assert(cloudBefore(settings));
            assert([[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"fixture-mac\n"]);
            expectedPanels = 1;
            expectedAlerts = 1;
        } else if ([scenario isEqualToString:@"choose-conflict"]) {
            nextResponse = NSAlertSecondButtonReturn;
            assert(!cloudBefore(settings));
            expectedPanels = 1;
            expectedAlerts = 2;
        } else if ([scenario isEqualToString:@"post"]) {
            assert([cloudAction(settings, @"after", nil)[@"status"] isEqualToString:@"published"]);
        } else if ([scenario isEqualToString:@"bad-post"]) {
            assert([cloudAction(settings, @"after", nil)[@"status"] isEqualToString:@"unavailable"]);
        } else {
            assert(!"unknown scenario");
        }
        assert(!panelShown && panelsShown == expectedPanels && panelsHidden == expectedPanels);
        assert(announcements == expectedPanels && alerts == expectedAlerts);
        fprintf(stderr, "PASS %s (panels=%lu alerts=%lu)\n", scenario.UTF8String, (unsigned long)panelsShown, (unsigned long)alerts);
        return 0;
    }
}
