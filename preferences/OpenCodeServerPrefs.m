#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <string.h>
#include <unistd.h>

@class PSSpecifier;
@interface PSListController : UIViewController
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (void)setSpecifiers:(NSMutableArray *)specifiers;
@end
@interface PSTableCell : NSObject
+ (NSInteger)cellTypeFromString:(NSString *)name;
@end
@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(NSInteger)cell edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@property (nonatomic) SEL buttonAction;
@end

static NSString *const ConfigPath = @"/var/mobile/.config/opencode-ios/settings.conf";

@interface OpenCodeServerPrefsListController : PSListController
@property (nonatomic, strong) NSMutableArray *items;
@end

@implementation OpenCodeServerPrefsListController

- (NSDictionary *)settings {
    NSString *text = [NSString stringWithContentsOfFile:ConfigPath encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange separator = [line rangeOfString:@"="];
        if (separator.location != NSNotFound && separator.location > 0) {
            values[[line substringToIndex:separator.location]] = [line substringFromIndex:separator.location + 1];
        }
    }
    return values;
}

- (BOOL)writeSetting:(NSString *)key enabled:(BOOL)enabled {
    NSMutableDictionary *values = [[self settings] mutableCopy];
    values[key] = enabled ? @"1" : @"0";
    NSMutableString *text = [NSMutableString string];
    for (NSString *name in [[values allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [text appendFormat:@"%@=%@\n", name, values[name]];
    }
    NSString *directory = [ConfigPath stringByDeletingLastPathComponent];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) return NO;
    if (![text writeToFile:ConfigPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) return NO;
    return chmod([ConfigPath fileSystemRepresentation], 0600) == 0;
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runAction:(NSString *)action specifier:(PSSpecifier *)specifier {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const char *args[] = {"/var/jb/bin/sh", "/var/jb/usr/bin/opencode-server", [action UTF8String], NULL};
        extern char **environ;
        pid_t pid = 0;
        int rc = posix_spawn(&pid, args[0], NULL, NULL, (char *const *)args, environ);
        int status = 0;
        if (rc == 0 && waitpid(pid, &status, 0) < 0) rc = -1;
        BOOL ok = rc == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (specifier) [self reloadSpecifier:specifier];
            [self alert:ok ? @"OpenCode Server" : @"Server action failed" message:ok ? @"The action completed." : @"The server could not complete the action. Check the installation and server logs."];
        });
    });
}

- (NSNumber *)readValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *value = [self settings][key];
    return @([value ?: ([key isEqualToString:@"AUTO_START"] ? @"1" : @"0") boolValue]);
}

- (void)setValue:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    BOOL enabled = [value boolValue];
    if ([key isEqualToString:@"AUTO_START"]) {
        [self runAction:enabled ? @"enable" : @"disable" specifier:specifier];
        return;
    }
    if (![key isEqualToString:@"LAN"] && ![key isEqualToString:@"TAILSCALE"]) return;
    [self reloadSpecifier:specifier];
    NSString *network = [key isEqualToString:@"LAN"] ? @"your Wi-Fi network" : @"your Tailscale network";
    NSString *message = enabled ? [NSString stringWithFormat:@"Anyone on %@ can access OpenCode without a password. Enable access?", network] : [NSString stringWithFormat:@"Stop accepting connections from %@?", network];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Change network access?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { [self reloadSpecifier:specifier]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:enabled ? @"Enable" : @"Disable" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        if (![self writeSetting:key enabled:enabled]) [self alert:@"Could not save setting" message:@"OpenCode could not write its configuration file."];
        [self reloadSpecifier:specifier];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)button:(PSSpecifier *)specifier {
    NSString *action = [specifier propertyForKey:@"actionName"];
    if ([action isEqualToString:@"restart"] || [action isEqualToString:@"stop"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stop active work?" message:@"Active OpenCode runs will stop. Conversation history stays saved." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:[action isEqualToString:@"restart"] ? @"Restart" : @"Stop" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self runAction:action specifier:nil]; }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self runAction:action specifier:nil];
    }
}

- (void)copyURL:(PSSpecifier *)specifier {
    BOOL tailscale = [[specifier propertyForKey:@"network"] isEqualToString:@"TAILSCALE"];
    NSDictionary *settings = [self settings];
    if (![settings[tailscale ? @"TAILSCALE" : @"LAN"] boolValue]) {
        [self alert:@"Network access is off" message:@"Enable the corresponding network access switch first."];
        return;
    }
    struct ifaddrs *addresses = NULL;
    NSString *address = nil;
    if (getifaddrs(&addresses) == 0) {
        for (struct ifaddrs *entry = addresses; entry; entry = entry->ifa_next) {
            if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
            struct sockaddr_in *v4 = (struct sockaddr_in *)entry->ifa_addr;
            uint32_t ip = ntohl(v4->sin_addr.s_addr);
            // Carrier IPv4 can also be in 100.64.0.0/10 (for example
            // pdp_ip0). Tailscale on iOS assigns its address to utunN, so
            // require both the tunnel interface and the Tailscale range.
            BOOL isTailscaleTunnel = entry->ifa_name && strncmp(entry->ifa_name, "utun", 4) == 0;
            BOOL match = tailscale
                ? (isTailscaleTunnel && (ip & 0xffc00000U) == 0x64400000U)
                : (strcmp(entry->ifa_name, "en0") == 0);
            if (match) { char buf[INET_ADDRSTRLEN]; if (inet_ntop(AF_INET, &v4->sin_addr, buf, sizeof(buf))) address = [NSString stringWithUTF8String:buf]; break; }
        }
        freeifaddrs(addresses);
    }
    if (!address) { [self alert:@"Address unavailable" message:@"Connect to the selected network and try again."]; return; }
    NSInteger port = [settings[@"PORT"] integerValue];
    if (port < 1024 || port > 65535) port = 4096;
    [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"http://%@:%ld/", address, (long)port];
    [self alert:@"URL copied" message:@"The OpenCode address is on the clipboard."];
}

- (PSSpecifier *)buttonNamed:(NSString *)name action:(NSString *)action {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:Nil cell:[PSTableCell cellTypeFromString:@"PSButtonCell"] edit:Nil];
    [s setProperty:action forKey:@"actionName"];
    s.buttonAction = @selector(button:);
    return s;
}

- (PSSpecifier *)switchNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:@selector(setValue:specifier:) get:@selector(readValue:) detail:Nil cell:[PSTableCell cellTypeFromString:@"PSSwitchCell"] edit:Nil];
    [s setProperty:key forKey:@"key"];
    return s;
}

- (PSSpecifier *)copyButton:(NSString *)name network:(NSString *)network {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL detail:Nil cell:[PSTableCell cellTypeFromString:@"PSButtonCell"] edit:Nil];
    [s setProperty:network forKey:@"network"];
    s.buttonAction = @selector(copyURL:);
    return s;
}

- (NSMutableArray *)specifiers {
    if (!self.items) {
        PSSpecifier *network = [PSSpecifier groupSpecifierWithName:@"Network Access"];
        [network setProperty:@"OpenCode has no password. Enable access only on networks you trust." forKey:@"footerText"];
        self.items = [@[[PSSpecifier groupSpecifierWithName:@"Server"], [self buttonNamed:@"Check Server Access" action:@"check"], [self buttonNamed:@"Start Server" action:@"start"], [self buttonNamed:@"Stop Server" action:@"stop"], [self buttonNamed:@"Restart Server" action:@"restart"], network, [self switchNamed:@"Expose to local network" key:@"LAN"], [self switchNamed:@"Expose to Tailscale" key:@"TAILSCALE"], [self copyButton:@"Copy Wi-Fi URL" network:@"LAN"], [self copyButton:@"Copy Tailscale URL" network:@"TAILSCALE"], [PSSpecifier groupSpecifierWithName:@"Startup"], [self switchNamed:@"Start at jailbreak boot" key:@"AUTO_START"]] mutableCopy];
        [self setSpecifiers:self.items];
    }
    return self.items;
}
@end
