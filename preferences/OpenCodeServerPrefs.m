#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <errno.h>
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
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath;
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

typedef NS_ENUM(NSInteger, OpenCodeServerState) {
    OpenCodeServerStateUnknown,
    OpenCodeServerStateRunning,
    OpenCodeServerStateStarting,
    OpenCodeServerStateNotResponding,
    OpenCodeServerStateStopped,
    OpenCodeServerStateUnavailable,
    OpenCodeServerStateStartingAction,
    OpenCodeServerStateStoppingAction,
    OpenCodeServerStateRestartingAction,
};

static NSString *const ConfigPath = @"/var/mobile/.config/opencode-ios/settings.conf";

@interface OpenCodeServerPrefsListController : PSListController
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic, strong) NSDate *unhealthySince;
@property (nonatomic, strong) PSSpecifier *serverSwitchSpecifier;
@property (nonatomic, strong) PSSpecifier *serverStatusSpecifier;
@property (nonatomic, copy) NSString *serverActionError;
@property (nonatomic) OpenCodeServerState serverState;
@property (nonatomic) BOOL serverStatusKnown;
@property (nonatomic) BOOL serverActionInFlight;
@property (nonatomic) BOOL statusProbeInFlight;
@property (nonatomic) BOOL viewIsVisible;
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

- (void)reloadServerRows {
    if (!self.viewIsVisible) return;
    if (self.serverSwitchSpecifier) [self reloadSpecifier:self.serverSwitchSpecifier];
    if (self.serverStatusSpecifier) [self reloadSpecifier:self.serverStatusSpecifier];
}

- (BOOL)serverIsBusy {
    return self.serverActionInFlight || self.serverState == OpenCodeServerStateUnknown ||
        self.serverState == OpenCodeServerStateStarting ||
        self.serverState == OpenCodeServerStateStartingAction ||
        self.serverState == OpenCodeServerStateStoppingAction ||
        self.serverState == OpenCodeServerStateRestartingAction;
}

- (BOOL)serverIsRunning {
    return self.serverState == OpenCodeServerStateRunning ||
        self.serverState == OpenCodeServerStateStarting ||
        self.serverState == OpenCodeServerStateNotResponding ||
        self.serverState == OpenCodeServerStateStartingAction ||
        self.serverState == OpenCodeServerStateRestartingAction;
}

- (NSNumber *)serverSwitchValue:(PSSpecifier *)specifier {
    return @(self.serverIsRunning);
}

- (NSString *)serverStatusValue:(PSSpecifier *)specifier {
    NSString *current = nil;
    switch (self.serverState) {
        case OpenCodeServerStateRunning: current = @"Running"; break;
        case OpenCodeServerStateStarting:
        case OpenCodeServerStateStartingAction: current = @"Starting…"; break;
        case OpenCodeServerStateNotResponding: current = @"Not responding"; break;
        case OpenCodeServerStateStopped: current = @"Stopped"; break;
        case OpenCodeServerStateStoppingAction: current = @"Stopping…"; break;
        case OpenCodeServerStateRestartingAction: current = @"Restarting…"; break;
        case OpenCodeServerStateUnavailable: current = @"Status unavailable"; break;
        case OpenCodeServerStateUnknown: current = @"Checking…"; break;
    }
    if (self.serverActionError.length && current.length) {
        return [NSString stringWithFormat:@"%@ — %@", self.serverActionError, current];
    }
    return current ?: @"Status unavailable";
}

- (NSString *)runProbe {
    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) != 0) return nil;

    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    BOOL actionsReady = (rc == 0);
    if (rc == 0) rc = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    if (rc == 0) rc = posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    if (rc == 0) rc = posix_spawn_file_actions_addclose(&actions, descriptors[1]);

    char *arguments[] = {"/var/jb/bin/sh", "/var/jb/usr/bin/opencode-server", "probe", NULL};
    extern char **environ;
    pid_t pid = 0;
    if (rc == 0) rc = posix_spawn(&pid, arguments[0], &actions, NULL, arguments, environ);
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (rc != 0) {
        close(descriptors[0]);
        return nil;
    }

    char output[128] = {0};
    size_t used = 0;
    while (used < sizeof(output) - 1) {
        ssize_t count = read(descriptors[0], output + used, sizeof(output) - 1 - used);
        if (count > 0) {
            used += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }
    close(descriptors[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return nil;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return nil;

    NSString *result = [[NSString alloc] initWithBytes:output length:used encoding:NSUTF8StringEncoding];
    result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([result isEqualToString:@"RUNNING"] || [result isEqualToString:@"STARTING"] ||
        [result isEqualToString:@"NOT_RESPONDING"] || [result isEqualToString:@"STOPPED"] ||
        [result isEqualToString:@"UNAVAILABLE"]) return result;
    return nil;
}

- (void)applyProbeResult:(NSString *)result {
    if ([result isEqualToString:@"RUNNING"]) {
        self.unhealthySince = nil;
        self.serverState = OpenCodeServerStateRunning;
    } else if ([result isEqualToString:@"STARTING"] || [result isEqualToString:@"NOT_RESPONDING"]) {
        if (!self.unhealthySince) self.unhealthySince = [NSDate date];
        self.serverState = [[NSDate date] timeIntervalSinceDate:self.unhealthySince] < 30.0
            ? OpenCodeServerStateStarting : OpenCodeServerStateNotResponding;
    } else if ([result isEqualToString:@"STOPPED"]) {
        self.unhealthySince = nil;
        self.serverState = OpenCodeServerStateStopped;
    } else {
        self.unhealthySince = nil;
        self.serverState = OpenCodeServerStateUnavailable;
    }
}

- (void)refreshServerStatus {
    if (self.serverActionInFlight || self.statusProbeInFlight) return;
    self.statusProbeInFlight = YES;
    if (!self.serverStatusKnown) [self reloadServerRows];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *result = [self runProbe];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusProbeInFlight = NO;
            if (!self.serverActionInFlight) {
                if (result) [self applyProbeResult:result];
                else {
                    self.serverState = OpenCodeServerStateUnavailable;
                    self.unhealthySince = nil;
                }
            }
            self.serverStatusKnown = YES;
            [self reloadServerRows];
        });
    });
}

- (void)performServerAction:(NSString *)action {
    if (self.serverActionInFlight) return;
    self.serverActionInFlight = YES;
    self.serverActionError = nil;
    if ([action isEqualToString:@"start"]) self.serverState = OpenCodeServerStateStartingAction;
    else if ([action isEqualToString:@"stop"]) self.serverState = OpenCodeServerStateStoppingAction;
    else self.serverState = OpenCodeServerStateRestartingAction;
    [self reloadServerRows];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *arguments[] = {"/var/jb/bin/sh", "/var/jb/usr/bin/opencode-server", (char *)[action UTF8String], NULL};
        extern char **environ;
        pid_t pid = 0;
        int rc = posix_spawn(&pid, arguments[0], NULL, NULL, arguments, environ);
        int status = 0;
        if (rc == 0) {
            while (waitpid(pid, &status, 0) < 0) {
                if (errno != EINTR) { rc = -1; break; }
            }
        }
        BOOL ok = rc == 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.serverActionInFlight = NO;
            if (!ok) {
                self.serverActionError = [action isEqualToString:@"start"] ? @"Start failed" :
                    ([action isEqualToString:@"stop"] ? @"Stop failed" : @"Restart failed");
            }
            [self reloadServerRows];
            [self refreshServerStatus];
        });
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.viewIsVisible = YES;
    if (!self.statusTimer) {
        self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self
            selector:@selector(statusTimerDidFire:) userInfo:nil repeats:YES];
    }
    [self refreshServerStatus];
}

- (void)statusTimerDidFire:(NSTimer *)timer {
    [self refreshServerStatus];
}

- (void)viewWillDisappear:(BOOL)animated {
    self.viewIsVisible = NO;
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    [super viewWillDisappear:animated];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *role = [specifier propertyForKey:@"role"];
    if ([role isEqualToString:@"serverStatus"]) {
        if ([self serverIsBusy]) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        } else {
            cell.accessoryView = nil;
        }
    } else if ([role isEqualToString:@"serverSwitch"]) {
        BOOL enabled = self.serverStatusKnown && !self.serverActionInFlight;
        cell.userInteractionEnabled = enabled;
        cell.contentView.alpha = enabled ? 1.0 : 0.55;
    } else {
        cell.contentView.alpha = 1.0;
    }
    return cell;
}

- (NSNumber *)readValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *value = [self settings][key];
    return @([value ?: ([key isEqualToString:@"AUTO_START"] ? @"1" : @"0") boolValue]);
}

- (void)setValue:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    BOOL enabled = [value boolValue];
    if ([key isEqualToString:@"SERVER_RUNNING"]) {
        if (!self.serverStatusKnown || self.serverActionInFlight) return;
        if (enabled == self.serverIsRunning) return;
        [self performServerAction:enabled ? @"start" : @"stop"];
        return;
    }
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
    if ([action isEqualToString:@"restart"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Stop active work?" message:@"Active OpenCode runs will stop. Conversation history stays saved." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self performServerAction:action]; }]];
        [self presentViewController:alert animated:YES completion:nil];
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

- (PSSpecifier *)serverSwitch {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"OpenCode Server" target:self set:@selector(setValue:specifier:) get:@selector(serverSwitchValue:) detail:Nil cell:[PSTableCell cellTypeFromString:@"PSSwitchCell"] edit:Nil];
    [specifier setProperty:@"SERVER_RUNNING" forKey:@"key"];
    [specifier setProperty:@"serverSwitch" forKey:@"role"];
    return specifier;
}

- (PSSpecifier *)serverStatus {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"Current server status" target:self set:NULL get:@selector(serverStatusValue:) detail:Nil cell:[PSTableCell cellTypeFromString:@"PSTitleValueCell"] edit:Nil];
    [specifier setProperty:@"serverStatus" forKey:@"role"];
    return specifier;
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
        self.serverSwitchSpecifier = [self serverSwitch];
        self.serverStatusSpecifier = [self serverStatus];
        self.items = [@[[PSSpecifier groupSpecifierWithName:@"Server"], self.serverSwitchSpecifier, self.serverStatusSpecifier, [self buttonNamed:@"Restart Server" action:@"restart"], network, [self switchNamed:@"Expose to local network" key:@"LAN"], [self switchNamed:@"Expose to Tailscale" key:@"TAILSCALE"], [self copyButton:@"Copy Wi-Fi URL" network:@"LAN"], [self copyButton:@"Copy Tailscale URL" network:@"TAILSCALE"], [PSSpecifier groupSpecifierWithName:@"Startup"], [self switchNamed:@"Start at jailbreak boot" key:@"AUTO_START"]] mutableCopy];
        [self setSpecifiers:self.items];
    }
    return self.items;
}
@end
