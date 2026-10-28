#import <Cocoa/Cocoa.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSDictionary *cloudAction(NSDictionary *settings, NSString *action, NSString *revision) {
    if (![settings[@"enabled"] boolValue]) return @{@"status":@"disabled"};
    NSString *helper = settings[@"helper"], *configuration = settings[@"config"];
    if (![helper isKindOfClass:NSString.class] || ![configuration isKindOfClass:NSString.class]) return @{@"status":@"unavailable"};
    NSTask *task = [NSTask new]; NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/caffeinate"];
    NSMutableArray *arguments = [NSMutableArray arrayWithArray:@[@"-i", helper, action, configuration]];
    if (revision) [arguments addObject:revision];
    task.arguments = arguments; task.standardOutput = pipe; task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return @{@"status":@"unavailable"};
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit];
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : @{@"status":@"unavailable"};
}

static BOOL cloudBefore(NSDictionary *settings) {
    NSDictionary *result = cloudAction(settings, @"before", nil);
    if ([result[@"status"] isEqualToString:@"conflict"]) {
        [NSApplication sharedApplication]; NSAlert *alert = [NSAlert new];
        alert.messageText = @"Choose a save / Выбери сохранение";
        alert.informativeText = @"The devices have different progress. Both copies remain in iCloud history. / На устройствах разный прогресс; обе копии сохранятся в истории.";
        [alert addButtonWithTitle:@"Cancel / Отмена"];
        NSArray *choices = result[@"choices"];
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new]; NSDateFormatter *formatter = [NSDateFormatter new]; formatter.dateFormat = @"dd.MM HH:mm";
        for (NSDictionary *choice in choices) {
            NSDate *date = [iso dateFromString:choice[@"created"]];
            [alert addButtonWithTitle:[NSString stringWithFormat:@"%@ · %@", choice[@"device"], date ? [formatter stringFromDate:date] : choice[@"created"]]];
        }
        NSInteger index = [alert runModal] - NSAlertFirstButtonReturn - 1;
        if (index < 0 || index >= choices.count) return NO;
        result = cloudAction(settings, @"resolve", choices[index][@"id"]);
    }
    if ([result[@"status"] isEqualToString:@"unavailable"]) {
        [NSApplication sharedApplication]; NSAlert *alert = [NSAlert new];
        alert.messageText = @"iCloud unavailable / iCloud недоступен";
        alert.informativeText = @"The local save is safe. Wait for iCloud, or play locally and sync next time. / Локальное сохранение на месте. Дождись iCloud или играй локально.";
        [alert addButtonWithTitle:@"Cancel / Отмена"]; [alert addButtonWithTitle:@"Play locally / Играть локально"];
        return [alert runModal] == NSAlertSecondButtonReturn;
    }
    return YES;
}

int main(int argc, char **launchArguments) {
    @autoreleasepool {
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
            alert.messageText = @"Zelda app not found / Приложение Zelda не найдено";
            alert.informativeText = [@"Expected path / Путь: " stringByAppendingString:game];
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
        if (argc > 1 && !strcmp(launchArguments[1], "--check")) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:args options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return 0;
        }
        NSDictionary *cloud = [config isKindOfClass:NSDictionary.class] ? config[@"cloud_saves"] : nil;
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
            alert.messageText = @"Save kept on Mac / Сохранение осталось на Mac";
            alert.informativeText = [result[@"status"] isEqualToString:@"conflict"] ? @"Cloud versions diverged; choose a copy on the next launch. / Версии разошлись; выбери копию при следующем запуске." : @"iCloud sync will retry on the next launch. / Синхронизация iCloud повторится при следующем запуске.";
            [alert addButtonWithTitle:@"ОК"]; [alert runModal];
        }
        return process.terminationStatus;
    }
}
