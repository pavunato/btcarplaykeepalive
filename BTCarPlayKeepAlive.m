#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "BTKPreferencesShim.h"
#import "BTKLog.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <errno.h>
#import <notify.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <string.h>
#import <unistd.h>

static NSString *const kBTKPreferencesPath =
    @"/var/mobile/Library/Preferences/com.pavunato.btcarplaykeepalive.plist";
static NSString *const kBTKConfigChangedNotification =
    @"com.pavunato.btcarplaykeepalive/changed";
static NSString *const kBTKActivityNotification =
    @"com.pavunato.btcarplaykeepalive/activity";
static NSString *const kBTKCarPlayPresenceNotification =
    @"com.pavunato.btcarplaykeepalive/carplay-presence";

#pragma mark - Configuration

static NSDictionary *gBTKPreferencesCache;
static BOOL gBTKPreferencesLoaded;

static NSObject *BTKPreferencesLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static void BTKObservePreferences(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static int token;
        notify_register_dispatch(kBTKConfigChangedNotification.UTF8String, &token,
                                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                                 ^(__unused int notificationToken) {
            @synchronized (BTKPreferencesLock()) {
                gBTKPreferencesCache = nil;
                gBTKPreferencesLoaded = NO;
            }
        });
    });
}

static NSDictionary *BTKLoadRootLocked(void) {
    if (!gBTKPreferencesLoaded) {
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kBTKPreferencesPath];
        gBTKPreferencesCache = [root isKindOfClass:NSDictionary.class] ? [root copy] : @{};
        gBTKPreferencesLoaded = YES;
    }
    return gBTKPreferencesCache;
}

static NSDictionary *BTKLoadRoot(void) {
    BTKObservePreferences();
    @synchronized (BTKPreferencesLock()) {
        return BTKLoadRootLocked();
    }
}

static BOOL BTKWriteRootLocked(NSDictionary *root) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root
                                                                format:NSPropertyListBinaryFormat_v1_0
                                                               options:0
                                                                 error:&error];
    if (!data || ![data writeToFile:kBTKPreferencesPath options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[BTCarPlayKeepAlive] preference write failed: %@", error);
        CSLogImpl("btcarplay", "preference write failed: %s",
                  error.localizedDescription.UTF8String ?: "unknown error");
        return NO;
    }
    chmod(kBTKPreferencesPath.fileSystemRepresentation, 0644);
    gBTKPreferencesCache = [root copy];
    gBTKPreferencesLoaded = YES;
    notify_post(kBTKConfigChangedNotification.UTF8String);
    return YES;
}

static BOOL BTKDeviceEnabled(NSString *deviceID) {
    if (deviceID.length == 0) return NO;
    @synchronized (BTKPreferencesLock()) {
        NSDictionary *devices = BTKLoadRoot()[@"devices"];
        NSDictionary *entry = [devices isKindOfClass:NSDictionary.class] ? devices[deviceID] : nil;
        return [entry isKindOfClass:NSDictionary.class] &&
               [entry[@"stayConnectedWhileCarPlay"] boolValue];
    }
}
static void BTKRemoveLegacyVisualSettings(NSMutableDictionary *root) {
    NSMutableDictionary *devices = [root[@"devices"] mutableCopy];
    if (![devices isKindOfClass:NSDictionary.class]) return;
    BOOL legacyHideWiFi = NO;
    BOOL legacyHideHotspot = NO;
    for (NSString *key in devices.allKeys) {
        NSMutableDictionary *entry = [devices[key] mutableCopy];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        legacyHideWiFi |= [entry[@"hideNativeCarPlayWiFi"] boolValue];
        legacyHideHotspot |= [entry[@"hideBTKHotspotIndicator"] boolValue];
        [entry removeObjectForKey:@"hideNativeCarPlayWiFi"];
        [entry removeObjectForKey:@"hideBTKHotspotIndicator"];
        if (entry.count) devices[key] = entry;
        else [devices removeObjectForKey:key];
    }
    if (!root[@"hideNativeCarPlayWiFi"] && legacyHideWiFi) root[@"hideNativeCarPlayWiFi"] = @YES;
    if (!root[@"hideBTKHotspotIndicator"] && legacyHideHotspot) root[@"hideBTKHotspotIndicator"] = @YES;
    if (devices.count) root[@"devices"] = devices;
    else [root removeObjectForKey:@"devices"];
}

static BOOL BTKHideWiFiEnabled(void) {
    NSDictionary *root = BTKLoadRoot();
    if (root[@"hideNativeCarPlayWiFi"] != nil) return [root[@"hideNativeCarPlayWiFi"] boolValue];
    for (NSDictionary *entry in [root[@"devices"] allValues]) {
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"hideNativeCarPlayWiFi"] boolValue]) return YES;
    }
    return NO;
}

static void BTKSetHideWiFiEnabled(BOOL enabled) {
    BTKObservePreferences();
    @synchronized (BTKPreferencesLock()) {
        NSMutableDictionary *root = [BTKLoadRootLocked() mutableCopy];
        BTKRemoveLegacyVisualSettings(root);
        if (enabled) root[@"hideNativeCarPlayWiFi"] = @YES;
        else [root removeObjectForKey:@"hideNativeCarPlayWiFi"];
        BTKWriteRootLocked(root);
    }
}

static BOOL BTKHotspotHidden(void) {
    NSDictionary *root = BTKLoadRoot();
    if (root[@"hideBTKHotspotIndicator"] != nil) return [root[@"hideBTKHotspotIndicator"] boolValue];
    for (NSDictionary *entry in [root[@"devices"] allValues]) {
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"hideBTKHotspotIndicator"] boolValue]) return YES;
    }
    return NO;
}

static void BTKSetHotspotHidden(BOOL hidden) {
    BTKObservePreferences();
    @synchronized (BTKPreferencesLock()) {
        NSMutableDictionary *root = [BTKLoadRootLocked() mutableCopy];
        BTKRemoveLegacyVisualSettings(root);
        if (hidden) root[@"hideBTKHotspotIndicator"] = @YES;
        else [root removeObjectForKey:@"hideBTKHotspotIndicator"];
        BTKWriteRootLocked(root);
    }
}
#pragma mark - Bluetooth device identity

static id BTKCallObject(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *BTKDeviceID(id device) {
    if (!device) return nil;

    // The Settings-side BTSDeviceClassic and the BluetoothManager-side device
    // both expose the identifier on the audited iPhone 11. Prefer it so the
    // key is identical across the two processes; use address and aclUID only
    // as guarded fallbacks for OS/device variants that omit identifier.
    id identifierObject = BTKCallObject(device, @selector(identifier));
    NSString *identifier = [identifierObject isKindOfClass:NSString.class] ? identifierObject : nil;
    if (identifier.length > 0) {
        return [NSString stringWithFormat:@"identifier:%@", [identifier lowercaseString]];
    }

    id addressObject = BTKCallObject(device, @selector(address));
    NSString *address = [addressObject isKindOfClass:NSString.class] ? addressObject : nil;
    if (address.length > 0) {
        return [NSString stringWithFormat:@"address:%@", [address lowercaseString]];
    }

    id aclUIDObject = BTKCallObject(device, @selector(aclUID));
    NSString *aclUID = [aclUIDObject isKindOfClass:NSString.class] ? aclUIDObject : nil;
    if (aclUID.length > 0) {
        return [NSString stringWithFormat:@"aclUID:%@", [aclUID lowercaseString]];
    }
    return nil;
}

static NSArray<NSString *> *BTKDeviceIDs(id device) {
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (NSString *key in @[ @"identifier", @"address", @"aclUID" ]) {
        id value = BTKCallObject(device, NSSelectorFromString(key));
        if (![value isKindOfClass:NSString.class] || [value length] == 0) continue;
        NSString *normalized = [value lowercaseString];
        NSString *candidate = [NSString stringWithFormat:@"%@:%@", key, normalized];
        if (![keys containsObject:candidate]) [keys addObject:candidate];
        // Releases prior to 0.2.0 wrote the ACL fallback with this prefix.
        if ([key isEqualToString:@"aclUID"]) {
            NSString *legacyCandidate = [NSString stringWithFormat:@"acl:%@", normalized];
            if (![keys containsObject:legacyCandidate]) [keys addObject:legacyCandidate];
        }
    }
    return keys;
}

static BOOL BTKDeviceObjectEnabled(id device) {
    for (NSString *candidate in BTKDeviceIDs(device)) {
        if (BTKDeviceEnabled(candidate)) return YES;
    }
    return NO;
}

static BOOL BTKAnyDeviceIDEnabled(NSArray<NSString *> *deviceIDs) {
    for (NSString *deviceID in deviceIDs) {
        if (BTKDeviceEnabled(deviceID)) return YES;
    }
    return NO;
}

static void BTKSetDeviceEnabledForIDs(NSArray<NSString *> *deviceIDs,
                                      NSString *primaryDeviceID, BOOL enabled) {
    if (primaryDeviceID.length == 0) return;
    BTKObservePreferences();
    @synchronized (BTKPreferencesLock()) {
        NSMutableDictionary *root = [BTKLoadRootLocked() mutableCopy];
        NSMutableDictionary *devices = [root[@"devices"] isKindOfClass:NSDictionary.class]
                                            ? [root[@"devices"] mutableCopy]
                                            : [NSMutableDictionary new];
        if (enabled) {
            NSMutableDictionary *entry = [devices[primaryDeviceID] isKindOfClass:NSDictionary.class]
                                          ? [devices[primaryDeviceID] mutableCopy]
                                          : [NSMutableDictionary new];
            entry[@"stayConnectedWhileCarPlay"] = @YES;
            devices[primaryDeviceID] = entry;
        } else {
            for (NSString *deviceID in deviceIDs) {
                NSMutableDictionary *entry = [devices[deviceID] mutableCopy];
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                [entry removeObjectForKey:@"stayConnectedWhileCarPlay"];
                if (entry.count) devices[deviceID] = entry;
                else [devices removeObjectForKey:deviceID];
            }
        }
        if (devices.count) root[@"devices"] = devices;
        else [root removeObjectForKey:@"devices"];
        BTKWriteRootLocked(root);
    }
}

static id BTKBluetoothManager(void) {
    Class managerClass = objc_getClass("BluetoothManager");
    SEL sharedSelector = @selector(sharedInstance);
    if (!managerClass || ![managerClass respondsToSelector:sharedSelector]) return nil;
    return ((id (*)(Class, SEL))objc_msgSend)(managerClass, sharedSelector);
}

#pragma mark - Preferences UI

static id (*gOriginalDynamicDeviceSpecifiers)(id, SEL);

static BOOL BTKSwizzleInstanceMethod(Class cls, SEL selector, IMP replacement,
                                      IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !replacement) return NO;
    // Materialize an inherited method on the target class before replacing it.
    class_addMethod(cls, selector, method_getImplementation(method),
                    method_getTypeEncoding(method));
    method = class_getInstanceMethod(cls, selector);
    if (method_getImplementation(method) == replacement) return NO;
    *original = method_setImplementation(method, replacement);
    return YES;
}

static id BTKReadValue(id self, SEL selector, PSSpecifier *specifier);
static void BTKSetValue(id self, SEL selector, id value, PSSpecifier *specifier);
static void BTKRespringAction(id self, SEL selector);

static id BTKReadValue(id self, SEL selector, PSSpecifier *specifier) {
    NSString *deviceID = [specifier propertyForKey:@"btkDeviceID"];
    NSArray<NSString *> *deviceIDs = [specifier propertyForKey:@"btkDeviceIDs"];
    if (![deviceIDs isKindOfClass:NSArray.class]) deviceIDs = deviceID.length ? @[ deviceID ] : @[];
    if ([specifier propertyForKey:@"btkHideWiFi"]) return @(BTKHideWiFiEnabled());
    if ([specifier propertyForKey:@"btkHotspotHide"]) return @(BTKHotspotHidden());
    return @(BTKAnyDeviceIDEnabled(deviceIDs));
}

static void BTKSetValue(id self, SEL selector, id value, PSSpecifier *specifier) {
    NSString *deviceID = [specifier propertyForKey:@"btkDeviceID"];
    NSArray<NSString *> *deviceIDs = [specifier propertyForKey:@"btkDeviceIDs"];
    if (![deviceIDs isKindOfClass:NSArray.class]) deviceIDs = deviceID.length ? @[ deviceID ] : @[];
    if ([specifier propertyForKey:@"btkHideWiFi"]) {
        BTKSetHideWiFiEnabled([value boolValue]);
        return;
    }
    if ([specifier propertyForKey:@"btkHotspotHide"]) {
        BTKSetHotspotHidden([value boolValue]);
        return;
    }
    BTKSetDeviceEnabledForIDs(deviceIDs, deviceID, [value boolValue]);
}
static void BTKRespringAction(id self, SEL selector) {
    Class actionClass = NSClassFromString(@"SBSRelaunchAction");
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL actionSelector = @selector(actionWithReason:options:targetURL:);
    SEL sharedServiceSelector = @selector(sharedService);
    SEL sendActionsSelector = @selector(sendActions:withResult:);
    if (!actionClass || !serviceClass || ![actionClass respondsToSelector:actionSelector] ||
        ![serviceClass respondsToSelector:sharedServiceSelector]) {
        CSLogImpl("btcarplay", "respring unavailable; SBSRelaunchAction/FBSSystemService missing");
        return;
    }
    id action = ((id (*)(Class, SEL, NSString *, NSUInteger, NSURL *))objc_msgSend)(
        actionClass, actionSelector, @"BTCarPlayKeepAlive", 4, nil);
    if (!action) return;
    id service = ((id (*)(Class, SEL))objc_msgSend)(serviceClass, sharedServiceSelector);
    if (!service || ![service respondsToSelector:sendActionsSelector]) {
        CSLogImpl("btcarplay", "respring unavailable; FBSSystemService selector missing");
        return;
    }
    ((void (*)(id, SEL, NSSet *, id))objc_msgSend)(
        service, sendActionsSelector, [NSSet setWithObject:action], nil);
    CSLogImpl("btcarplay", "requested respring through SBSRelaunchAction");
}
static id BTKDeviceFromController(id controller) {
    // BTSDeviceConfigController is loaded lazily by Settings and is absent from
    // the standalone Preferences image inventory. Probe only object-valued KVC
    // keys and accept an object that exposes the audited BluetoothDevice API.
    NSArray<NSString *> *keys = @[ @"device", @"_device", @"bluetoothDevice",
                                   @"accessory", @"accessoryDevice", @"config", @"_config" ];
    for (NSString *key in keys) {
        id candidate = nil;
        @try { candidate = [controller valueForKey:key]; } @catch (__unused NSException *exception) {}
        if (!candidate) continue;
        CSLogImpl("btcarplay", "device controller key=%s object=%s",
                  key.UTF8String, object_getClassName(candidate));
        if ([candidate respondsToSelector:@selector(address)] ||
            [candidate respondsToSelector:@selector(aclUID)] ||
            [candidate respondsToSelector:@selector(identifier)]) return candidate;
    }
    return nil;
}

static NSArray *BTKAppendSettingToDeviceSpecifiers(id self, NSArray *original) {
    if (![original isKindOfClass:NSArray.class]) return original;
    id device = BTKDeviceFromController(self);
    NSString *deviceID = BTKDeviceID(device);
    CSLogImpl("btcarplay", "device detail controller=%s device=%s id=%s",
              object_getClassName(self), object_getClassName(device ?: [NSObject new]),
              deviceID.UTF8String ?: "<none>");
    if (deviceID.length == 0) {
        return original;
    }

    for (PSSpecifier *specifier in original) {
        if ([[specifier propertyForKey:@"btkDeviceID"] isEqualToString:deviceID]) return original;
    }

    // BTSDeviceConfigController stores the list it returns in PSListController's
    // specifiers ivar. Returning a separate copy leaves the table using the
    // unmodified stored list, so the switch never appears on screen.
    BOOL editsStoredList = [original isKindOfClass:NSMutableArray.class];
    NSMutableArray *updated = editsStoredList ? (NSMutableArray *)original : [original mutableCopy];
    CSLogImpl("btcarplay", "device specifier list class=%s count=%lu mutable=%d",
              object_getClassName(original), (unsigned long)original.count, editsStoredList);
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"CarPlay Connection"];
    [group setProperty:@"When enabled, BT CarPlay KeepAlive sends a tiny packet on the active Bluetooth/PAN interface while a CarPlay scene is active. It does not keep the connection alive when CarPlay is disconnected."
                forKey:@"footerText"];
    [updated addObject:group];

    PSSpecifier *switchSpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"Stay Connected While CarPlay"
                                        target:self
                                           set:@selector(btkSetValue:specifier:)
                                           get:@selector(btkReadValue:)
                                        detail:Nil
                                          cell:PSSwitchCell
                                          edit:Nil];
    [switchSpecifier setProperty:deviceID forKey:@"btkDeviceID"];
    [switchSpecifier setProperty:BTKDeviceIDs(device) forKey:@"btkDeviceIDs"];
    [updated addObject:switchSpecifier];
    PSSpecifier *hideSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Hide Native CarPlay Wi-Fi + Cellular (Global)"
                                                                    target:self
                                                                       set:@selector(btkSetValue:specifier:)
                                                                       get:@selector(btkReadValue:)
                                                                    detail:Nil
                                                                      cell:PSSwitchCell
                                                                      edit:Nil];
    [hideSpecifier setProperty:deviceID forKey:@"btkDeviceID"];
    [hideSpecifier setProperty:@YES forKey:@"btkHideWiFi"];
    [updated addObject:hideSpecifier];
    PSSpecifier *hotspotSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Hide BT CarPlay Hotspot Indicator (Global)"
                                                                         target:self
                                                                            set:@selector(btkSetValue:specifier:)
                                                                            get:@selector(btkReadValue:)
                                                                         detail:Nil
                                                                           cell:PSSwitchCell
                                                                           edit:Nil];
    [hotspotSpecifier setProperty:deviceID forKey:@"btkDeviceID"];
    [hotspotSpecifier setProperty:@YES forKey:@"btkHotspotHide"];
    [updated addObject:hotspotSpecifier];
    PSSpecifier *respringSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Respring to Apply CarPlay Visual Changes"
                                                                      target:self
                                                                         set:nil
                                                                         get:nil
                                                                      detail:Nil
                                                                        cell:PSButtonCell
                                                                        edit:Nil];
    [updated addObject:respringSpecifier];
    if ([respringSpecifier respondsToSelector:@selector(setButtonAction:)]) {
        ((void (*)(id, SEL, SEL))objc_msgSend)(respringSpecifier, @selector(setButtonAction:), @selector(btkRespringAction));
    }
    CSLogImpl("btcarplay", "added CarPlay keepalive setting for %s", deviceID.UTF8String);
    if (!editsStoredList && [self respondsToSelector:@selector(setSpecifiers:)]) {
        [(PSListController *)self setSpecifiers:updated];
    }
    return updated;
}

static id BTKDynamicDeviceSpecifiers(id self, SEL selector) {
    IMP originalIMP = (IMP)gOriginalDynamicDeviceSpecifiers;
    if (!originalIMP) return nil;
    NSArray *original = nil;
    @try {
        original = ((id (*)(id, SEL))originalIMP)(self, selector);
    } @catch (NSException *exception) {
        // Some iOS 18 Bluetooth controllers index their native list before it
        // has been populated. Never let that private exception terminate Settings;
        // the keepalive controls can still be presented on a minimal list.
        CSLogImpl("btcarplay", "native Bluetooth specifiers failed: %s",
                  exception.reason.UTF8String ?: "unknown exception");
        original = @[];
    }
    return BTKAppendSettingToDeviceSpecifiers(self, original);
}

static BOOL BTKInstallPreferencesHooks(void) {
    static Class installedController;
    Class controller = objc_getClass("BTSDeviceConfigController");
    if (!controller) return NO;
    @synchronized (BTKPreferencesLock()) {
        if (installedController == controller) return YES;
        class_addMethod(controller, @selector(btkReadValue:), (IMP)BTKReadValue, "@@:@");
        class_addMethod(controller, @selector(btkSetValue:specifier:), (IMP)BTKSetValue, "v@:@@");
        class_addMethod(controller, @selector(btkRespringAction), (IMP)BTKRespringAction, "v@:");
        if (!BTKSwizzleInstanceMethod(controller, @selector(specifiers),
                                      (IMP)BTKDynamicDeviceSpecifiers,
                                      (IMP *)&gOriginalDynamicDeviceSpecifiers)) {
            return NO;
        }
        installedController = controller;
    }
    CSLogImpl("btcarplay", "Preferences hook installed for BTSDeviceConfigController");
    return YES;
}

#pragma mark - CarPlay activity and interface-bound heartbeat

static BOOL BTKCarPlaySceneActive(void) {
    static int presenceToken = 0;
    static dispatch_once_t presenceOnce;
    dispatch_once(&presenceOnce, ^{
        notify_register_check(kBTKCarPlayPresenceNotification.UTF8String, &presenceToken);
    });
    uint64_t presenceState = 0;
    notify_get_state(presenceToken, &presenceState);
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // CarPlay hosts publish a short lease instead of a permanent boolean. A
    // host crash therefore expires naturally even if it misses teardown.
    if (presenceState > 0 && now >= (NSTimeInterval)presenceState &&
        now - (NSTimeInterval)presenceState <= 15.0) return YES;

    UIApplication *application = UIApplication.sharedApplication;
    if (!application) return NO;

    for (UIScene *scene in application.connectedScenes) {
        NSString *role = scene.session.role;
        if (![role isKindOfClass:NSString.class] ||
            [role rangeOfString:@"CarPlay" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            continue;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) {
            return YES;
        }
    }
    return NO;
}

static BOOL BTKInterfaceIsCandidate(const char *name) {
    // iOS uses en0 for Wi-Fi on the audited device. Bluetooth PAN and USB/Ethernet
    // tethering surfaces are other en* interfaces, so bind explicitly to each
    // active non-Wi-Fi Ethernet-like interface rather than allowing a default
    // route through cellular or Wi-Fi.
    return name && strncmp(name, "en", 2) == 0 && strcmp(name, "en0") != 0;
}

static NSUInteger BTKSendHeartbeatOnActiveInterfaces(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || !interfaces) return 0;

    NSUInteger sent = 0;
    const uint8_t payload[] = { 'B', 'T', 'K', 0x01 };
    for (struct ifaddrs *cursor = interfaces; cursor; cursor = cursor->ifa_next) {
        if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET ||
            !(cursor->ifa_flags & IFF_UP) || !(cursor->ifa_flags & IFF_RUNNING) ||
            !BTKInterfaceIsCandidate(cursor->ifa_name)) continue;

        struct sockaddr_in *address = (struct sockaddr_in *)cursor->ifa_addr;
        struct sockaddr_in *netmask = (struct sockaddr_in *)cursor->ifa_netmask;
        if (!address || !netmask || netmask->sin_family != AF_INET) continue;

        int socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socketFD < 0) continue;

        int broadcast = 1;
        if (setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast)) != 0) {
            close(socketFD);
            continue;
        }
        unsigned int interfaceIndex = if_nametoindex(cursor->ifa_name);
        if (interfaceIndex == 0 || setsockopt(socketFD, IPPROTO_IP, IP_BOUND_IF,
                                              &interfaceIndex, sizeof(interfaceIndex)) != 0) {
            close(socketFD);
            continue;
        }

        struct sockaddr_in destination = {0};
        destination.sin_len = sizeof(destination);
        destination.sin_family = AF_INET;
        destination.sin_port = htons(9); // discard service; no application payload is required
        destination.sin_addr.s_addr = address->sin_addr.s_addr | ~netmask->sin_addr.s_addr;

        ssize_t result = sendto(socketFD, payload, sizeof(payload), 0,
                                (struct sockaddr *)&destination, sizeof(destination));
        if (result == (ssize_t)sizeof(payload)) {
            sent++;
        } else {
            static NSTimeInterval lastFailureLog = 0;
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            if ((now - lastFailureLog) >= 30.0) {
                lastFailureLog = now;
                CSLogImpl("btcarplay", "keepalive send failed on %s: %s",
                          cursor->ifa_name, strerror(errno));
            }
        }
        close(socketFD);
    }
    freeifaddrs(interfaces);
    return sent;
}

static void BTKPublishActivityState(BOOL active);
static _Atomic uint64_t gBTKKeepAliveGeneration = 0;

static dispatch_queue_t BTKKeepAliveQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.pavunato.btcarplaykeepalive.heartbeat",
                                      DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void BTKKeepAliveTick(void) {
    // Read live state every time; a queued timer must never replay a stale
    // snapshot of CarPlay or Bluetooth configuration.
    static NSTimeInterval lastDiagnostic = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL carPlayActive = BTKCarPlaySceneActive();
    if ((now - lastDiagnostic) >= 10.0) {
        lastDiagnostic = now;
        CSLogImpl("btcarplay", "keepalive tick carPlayActive=%d", carPlayActive);
    }
    if (!carPlayActive) {
        atomic_fetch_add_explicit(&gBTKKeepAliveGeneration, 1, memory_order_relaxed);
        BTKPublishActivityState(NO);
        return;
    }

    id manager = BTKBluetoothManager();
    NSArray *connected = BTKCallObject(manager, @selector(connectedDevices));
    if (![connected isKindOfClass:NSArray.class]) {
        CSLogImpl("btcarplay", "keepalive BluetoothManager returned no connected-device array");
        atomic_fetch_add_explicit(&gBTKKeepAliveGeneration, 1, memory_order_relaxed);
        BTKPublishActivityState(NO);
        return;
    }

    if ((now - lastDiagnostic) < 0.1) {
        CSLogImpl("btcarplay", "keepalive connected-device count=%lu", (unsigned long)connected.count);
    }
    BOOL configuredDeviceConnected = NO;
    for (id device in connected) {
        NSString *deviceID = BTKDeviceID(device);
        BOOL enabled = BTKDeviceObjectEnabled(device);
        if ((now - lastDiagnostic) < 0.1) {
            CSLogImpl("btcarplay", "keepalive connected device=%s id=%s enabled=%d",
                      object_getClassName(device), deviceID.UTF8String ?: "<none>", enabled);
        }
        if (enabled) {
            configuredDeviceConnected = YES;
            break;
        }
    }
    if (!configuredDeviceConnected) {
        atomic_fetch_add_explicit(&gBTKKeepAliveGeneration, 1, memory_order_relaxed);
        BTKPublishActivityState(NO);
        return;
    }

    uint64_t generation = atomic_fetch_add_explicit(&gBTKKeepAliveGeneration, 1,
                                                     memory_order_relaxed) + 1;
    BOOL shouldTrace = (now - lastDiagnostic) < 0.1;
    dispatch_async(BTKKeepAliveQueue(), ^{
        NSUInteger sent = BTKSendHeartbeatOnActiveInterfaces();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load_explicit(&gBTKKeepAliveGeneration, memory_order_relaxed) != generation) return;
            if (shouldTrace) {
                CSLogImpl("btcarplay", "keepalive interface send count=%lu", (unsigned long)sent);
            }
            BTKPublishActivityState(sent > 0);
            static NSTimeInterval lastLog = 0;
            if (sent > 0 && (now - lastLog) >= 30.0) {
                lastLog = now;
                CSLogImpl("btcarplay", "CarPlay active; sent %lu Bluetooth/PAN keepalive packet(s)",
                          (unsigned long)sent);
            }
        });
    });
}

static void BTKPublishActivityState(BOOL active) {
    static int token = 0;
    static dispatch_once_t once;
    static BOOL lastState = NO;
    static BOOL hasPublished = NO;
    dispatch_once(&once, ^{
        notify_register_check(kBTKActivityNotification.UTF8String, &token);
    });
    if (hasPublished && lastState == active) return;
    hasPublished = YES;
    lastState = active;
    notify_set_state(token, active ? 1 : 0);
    notify_post(kBTKActivityNotification.UTF8String);
    CSLogImpl("btcarplay", "keepalive activity state=%d", active);
}

static NSHashTable<UIView *> *gBTKNetworkViews;
static NSHashTable<UIView *> *gBTKStatusBars;
static NSHashTable<UIView *> *gBTKHiddenCarPlayStatusViews;
static Class gBTKSecondaryNetworkClass;
static IMP gBTKOriginalNetworkUpdate;
static IMP gBTKOriginalSecondaryUpdate;
static IMP gBTKOriginalStatusBarLayout;
static int gBTKActivityToken = 0;
static const void *kBTKNetworkReplacementKey = &kBTKNetworkReplacementKey;
static const void *kBTKStatusBarFallbackKey = &kBTKStatusBarFallbackKey;

static BOOL BTKKeepAliveActivityState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kBTKActivityNotification.UTF8String, &gBTKActivityToken);
    });
    uint64_t state = 0;
    notify_get_state(gBTKActivityToken, &state);
    return state == 1;
}

static void BTKRefreshNetworkItemView(UIView *networkView) {
    if (!networkView) return;
    UIView *replacement = objc_getAssociatedObject(networkView, kBTKNetworkReplacementKey);
    BOOL active = BTKKeepAliveActivityState();
    // Replace the native network item in the CarPlay process only. Keep the
    // indicator visible: red means inactive, green means keepalive is sending.
    networkView.hidden = YES;
    if (replacement) {
        replacement.frame = networkView.frame;
        replacement.backgroundColor = active
            ? [UIColor colorWithRed:0.12 green:0.72 blue:0.24 alpha:0.98]
            : [UIColor colorWithRed:0.82 green:0.12 blue:0.10 alpha:0.98];
        replacement.hidden = NO;
    }
}

static void BTKDecorateNetworkItemView(UIView *networkView);

static void BTKDecorateNetworkDescendants(UIView *view) {
    if (!view) return;
    NSString *className = NSStringFromClass(object_getClass(view));
    if ([className isEqualToString:@"UIStatusBarDataNetworkItemView"] ||
        [className isEqualToString:@"UIStatusBarSecondaryDataNetworkItemView"]) {
        BTKDecorateNetworkItemView(view);
        return;
    }
    for (UIView *child in view.subviews) BTKDecorateNetworkDescendants(child);
}

static void BTKDecorateStatusBarFallback(UIView *statusBar) {
    if (!statusBar) return;
    UIView *dot = objc_getAssociatedObject(statusBar, kBTKStatusBarFallbackKey);
    if (!dot) {
        dot = [[UIView alloc] initWithFrame:CGRectZero];
        dot.layer.cornerRadius = 7.0;
        dot.layer.masksToBounds = YES;
        dot.userInteractionEnabled = NO;
        objc_setAssociatedObject(statusBar, kBTKStatusBarFallbackKey, dot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [statusBar addSubview:dot];
        if (!gBTKStatusBars) gBTKStatusBars = [NSHashTable weakObjectsHashTable];
        [gBTKStatusBars addObject:statusBar];
        CSLogImpl("btcarplay", "created persistent CarPlay status-bar fallback dot");
    } else {
        if (!gBTKStatusBars) gBTKStatusBars = [NSHashTable weakObjectsHashTable];
        [gBTKStatusBars addObject:statusBar];
    }
    BOOL active = BTKKeepAliveActivityState();
    dot.backgroundColor = active
        ? [UIColor colorWithRed:0.12 green:0.72 blue:0.24 alpha:0.98]
        : [UIColor colorWithRed:0.82 green:0.12 blue:0.10 alpha:0.98];
    CGFloat width = CGRectGetWidth(statusBar.bounds);
    CGFloat x = MIN(MAX(116.0, 0.0), MAX(0.0, width - 14.0));
    dot.frame = CGRectMake(x, 18.0, 14.0, 14.0);
    dot.hidden = NO;
    static NSTimeInterval lastFallbackLog = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if ((now - lastFallbackLog) >= 10.0) {
        lastFallbackLog = now;
        CSLogImpl("btcarplay", "persistent CarPlay fallback dot frame=%s active=%d host=%s",
                  NSStringFromCGRect(dot.frame).UTF8String ?: "", active,
                  object_getClassName(statusBar));
    }
}

static void BTKDecorateNetworkItemView(UIView *networkView) {
    if (!networkView || !networkView.superview) return;
    if (!gBTKNetworkViews) gBTKNetworkViews = [NSHashTable weakObjectsHashTable];
    [gBTKNetworkViews addObject:networkView];
    UIView *replacement = objc_getAssociatedObject(networkView, kBTKNetworkReplacementKey);
    if (!replacement) {
        replacement = [[UIView alloc] initWithFrame:networkView.frame];
        replacement.backgroundColor = [UIColor colorWithRed:0.12 green:0.55 blue:0.20 alpha:0.94];
        replacement.layer.cornerRadius = 6.0;
        replacement.layer.masksToBounds = YES;
        UILabel *dot = [[UILabel alloc] initWithFrame:replacement.bounds];
        dot.text = @"●";
        dot.textColor = UIColor.whiteColor;
        dot.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
        dot.textAlignment = NSTextAlignmentCenter;
        dot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [replacement addSubview:dot];
        objc_setAssociatedObject(networkView, kBTKNetworkReplacementKey, replacement,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [networkView.superview insertSubview:replacement aboveSubview:networkView];
        CSLogImpl("btcarplay", "created CarPlay-only network replacement frame=%s",
                  NSStringFromCGRect(networkView.frame).UTF8String ?: "");
    }
    BTKRefreshNetworkItemView(networkView);
}

typedef void (*BTKStatusBarLayoutIMP)(id, SEL);
static void BTKStatusBarLayoutHook(id self, SEL selector) {
    if (gBTKOriginalStatusBarLayout) {
        ((BTKStatusBarLayoutIMP)gBTKOriginalStatusBarLayout)(self, selector);
    }
    UIView *statusBar = (UIView *)self;
    BTKDecorateNetworkDescendants(statusBar);
    // The status-data object may exist without materializing a network view.
    // Keep a visible CarPlay-only fallback dot until that view appears.
    BTKDecorateStatusBarFallback(statusBar);
}

typedef BOOL (*BTKNetworkUpdateIMP)(id, SEL, id, id);
static BOOL BTKNetworkUpdateHook(id self, SEL selector, id data, id actions) {
    BOOL result = YES;
    if (gBTKSecondaryNetworkClass && [self isKindOfClass:gBTKSecondaryNetworkClass] && gBTKOriginalSecondaryUpdate) {
        result = ((BTKNetworkUpdateIMP)gBTKOriginalSecondaryUpdate)(self, selector, data, actions);
    } else if (gBTKOriginalNetworkUpdate) {
        result = ((BTKNetworkUpdateIMP)gBTKOriginalNetworkUpdate)(self, selector, data, actions);
    }
    BTKDecorateNetworkItemView((UIView *)self);
    return result;
}

__attribute__((unused)) static void BTKInstallCarPlayNetworkReplacement(void) {
    Class networkClass = NSClassFromString(@"UIStatusBarDataNetworkItemView");
    gBTKSecondaryNetworkClass = NSClassFromString(@"UIStatusBarSecondaryDataNetworkItemView");
    if (!networkClass) {
        CSLogImpl("btcarplay", "CarPlay network-item class unavailable");
        return;
    }
    Class statusBarClass = NSClassFromString(@"UIStatusBar");
    Method statusBarLayout = statusBarClass ? class_getInstanceMethod(statusBarClass, @selector(layoutSubviews)) : NULL;
    if (statusBarLayout && method_getImplementation(statusBarLayout) != (IMP)BTKStatusBarLayoutHook) {
        gBTKOriginalStatusBarLayout = method_setImplementation(statusBarLayout, (IMP)BTKStatusBarLayoutHook);
        CSLogImpl("btcarplay", "installed CarPlay UIStatusBar layout hook");
    }
    Method networkMethod = class_getInstanceMethod(networkClass, @selector(updateForNewData:actions:));
    if (networkMethod && method_getImplementation(networkMethod) != (IMP)BTKNetworkUpdateHook) {
        gBTKOriginalNetworkUpdate = method_setImplementation(networkMethod, (IMP)BTKNetworkUpdateHook);
    }
    if (gBTKSecondaryNetworkClass) {
        Method secondaryMethod = class_getInstanceMethod(gBTKSecondaryNetworkClass, @selector(updateForNewData:actions:));
        if (secondaryMethod && method_getImplementation(secondaryMethod) != (IMP)BTKNetworkUpdateHook) {
            gBTKOriginalSecondaryUpdate = method_setImplementation(secondaryMethod, (IMP)BTKNetworkUpdateHook);
        }
    }
    if (!gBTKNetworkViews) gBTKNetworkViews = [NSHashTable weakObjectsHashTable];
    static int notifyToken = 0;
    notify_register_dispatch(kBTKActivityNotification.UTF8String, &notifyToken,
                             dispatch_get_main_queue(), ^(__unused int token) {
        for (UIView *view in gBTKNetworkViews.allObjects) BTKRefreshNetworkItemView(view);
        BOOL active = BTKKeepAliveActivityState();
        for (UIView *statusBar in gBTKStatusBars.allObjects) {
            UIView *dot = objc_getAssociatedObject(statusBar, kBTKStatusBarFallbackKey);
            if (dot) {
                dot.backgroundColor = active
                    ? [UIColor colorWithRed:0.12 green:0.72 blue:0.24 alpha:0.98]
                    : [UIColor colorWithRed:0.82 green:0.12 blue:0.10 alpha:0.98];
                dot.hidden = NO;
            }
        }
    });
    CSLogImpl("btcarplay", "installed CarPlay-only network replacement hook");
}

@interface BTKCarPlayIndicatorController : NSObject
@property (nonatomic, strong) UIView *pill;
@property (nonatomic, strong) UIImageView *signalView;
@property (nonatomic, strong) UIView *statusBarHost;
@property (nonatomic, strong) NSTimer *attachTimer;
@property (nonatomic, strong) NSTimer *presenceTimer;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) int notifyToken;
@property (nonatomic, assign) NSUInteger attachmentAttempts;
- (void)start;
@end

@implementation BTKCarPlayIndicatorController

static UIImageView *BTKNewCarPlayNetworkGlyph(void) {
    // Match the iOS Personal Hotspot status glyph rather than the Wi‑Fi glyph.
    UIImage *image = [UIImage systemImageNamed:@"personalhotspot"];
    if (!image) image = [UIImage systemImageNamed:@"personalhotspot.circle.fill"];
    if (!image) image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
    UIImageView *view = [[UIImageView alloc] initWithImage:image];
    view.tintColor = [UIColor colorWithWhite:0.94 alpha:1.0];
    view.contentMode = UIViewContentModeScaleAspectFit;
    view.clipsToBounds = YES;
    view.userInteractionEnabled = NO;
    return view;
}

static void BTKStyleCarPlayNetworkCapsule(UIView *capsule, BOOL active) {
    // Urban Jungle active moss/olive green; inactive remains neutral steel-gray.
    capsule.backgroundColor = active
        ? [UIColor colorWithRed:0.45 green:0.56 blue:0.34 alpha:0.96]
        : [UIColor colorWithRed:0.48 green:0.49 blue:0.54 alpha:0.96];
    capsule.layer.cornerRadius = 5.0;
    capsule.layer.masksToBounds = YES;
}

static void BTKPublishCarPlayPresence(BOOL present) {
    static int token = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kBTKCarPlayPresenceNotification.UTF8String, &token);
    });
    uint64_t lease = present ? (uint64_t)NSDate.date.timeIntervalSince1970 : 0;
    notify_set_state(token, lease);
    notify_post(kBTKCarPlayPresenceNotification.UTF8String);
    CSLogImpl("btcarplay", "CarPlay presence state=%d", present);
}

- (void)start {
    __weak typeof(self) weakSelf = self;
    self.notifyToken = 0;
    notify_register_dispatch(kBTKActivityNotification.UTF8String, &_notifyToken,
                             dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setActive:(state == 1)];
        });
    });

    uint64_t initialState = 0;
    notify_get_state(self.notifyToken, &initialState);
    [self setActive:(initialState == 1)];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneChanged:)
                                                 name:UISceneWillConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneChanged:)
                                                 name:UISceneDidActivateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneChanged:)
                                                 name:UISceneWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneChanged:)
                                                 name:UISceneDidDisconnectNotification
                                               object:nil];
    BTKPublishCarPlayPresence(YES);
    __weak typeof(self) presenceWeakSelf = self;
    self.presenceTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES
                                                             block:^(__unused NSTimer *timer) {
        BTKPublishCarPlayPresence(presenceWeakSelf != nil);
    }];
    [self sceneChanged:nil];
}

- (void)scheduleAttachmentRetries {
    if (self.statusBarHost || self.attachTimer) return;
    self.attachmentAttempts = 0;
    __weak typeof(self) weakSelf = self;
    self.attachTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES
                                                           block:^(NSTimer *timer) {
        BTKCarPlayIndicatorController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.statusBarHost || ++strongSelf.attachmentAttempts >= 20) {
            [timer invalidate];
            strongSelf.attachTimer = nil;
            return;
        }
        [strongSelf attachToStatusBarWindow];
    }];
}

- (void)stopAttachmentRetries {
    [self.attachTimer invalidate];
    self.attachTimer = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopAttachmentRetries];
    [self.presenceTimer invalidate];
    if (self.notifyToken > 0) notify_cancel(self.notifyToken);
    BTKPublishCarPlayPresence(NO);
}

- (UIWindow *)statusBarWindow {
    NSMutableArray<UIWindow *> *candidates = [NSMutableArray new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene respondsToSelector:@selector(windows)]) {
            [candidates addObjectsFromArray:[(UIWindowScene *)scene windows] ?: @[]];
        }
    }
    UIWindow *carPlaySurface = nil;
    CGFloat largestArea = 0.0;
    for (UIWindow *candidate in candidates) {
        NSString *name = NSStringFromClass(object_getClass(candidate));
        if ([name isEqualToString:@"DashBoard.DBDockWindow"] && !candidate.hidden) {
            CGFloat area = CGRectGetWidth(candidate.bounds) * CGRectGetHeight(candidate.bounds);
            if (area > largestArea) {
                largestArea = area;
                carPlaySurface = candidate;
            }
        }
    }
    if (carPlaySurface) {
        return carPlaySurface;
    }
    return nil;
}

static BOOL BTKIsNativeCarPlayStatusView(UIView *view) {
    if (!view) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name isEqualToString:@"STUIStatusBarWiFiSignalView"] ||
           [name isEqualToString:@"STUIStatusBarCellularSignalView"];
}

__attribute__((unused)) static NSUInteger BTKHideNativeCarPlayStatusViews(UIView *root) {
    if (!root) return 0;
    if (!gBTKHiddenCarPlayStatusViews) {
        gBTKHiddenCarPlayStatusViews = [NSHashTable weakObjectsHashTable];
    }
    NSUInteger hiddenCount = 0;
    if (BTKIsNativeCarPlayStatusView(root)) {
        if (!root.hidden) {
            root.hidden = YES;
            hiddenCount++;
            [gBTKHiddenCarPlayStatusViews addObject:root];
        }
        return hiddenCount;
    }
    for (UIView *child in root.subviews) {
        hiddenCount += BTKHideNativeCarPlayStatusViews(child);
    }
    return hiddenCount;
}

static void BTKRestoreNativeCarPlayStatusViews(void) {
    for (UIView *view in gBTKHiddenCarPlayStatusViews) view.hidden = NO;
    [gBTKHiddenCarPlayStatusViews removeAllObjects];
}
- (void)createPillIfNeeded {
    if (self.pill) return;
    self.pill = [[UIView alloc] initWithFrame:CGRectZero];
    BTKStyleCarPlayNetworkCapsule(self.pill, self.active);
    self.signalView = BTKNewCarPlayNetworkGlyph();
    [self.pill addSubview:self.signalView];
}

- (void)attachToStatusBarWindow {
    UIWindow *statusWindow = [self statusBarWindow];
    if (!statusWindow) return;
    // Keep the native CarPlay Wi‑Fi icon visible. The Personal Hotspot glyph
    // remains an additional, inset activity indicator in the same sidebar.
    NSUInteger hiddenWiFi = 0;
    (void)hiddenWiFi;
    [self createPillIfNeeded];
    if (self.statusBarHost != statusWindow) {
        [self.pill removeFromSuperview];
        self.statusBarHost = statusWindow;
        [statusWindow addSubview:self.pill];
        self.pill.layer.zPosition = 10000.0;
        [self stopAttachmentRetries];
    }
    if (BTKHideWiFiEnabled()) {
        NSUInteger hiddenCount = BTKHideNativeCarPlayStatusViews(statusWindow);
        if (hiddenCount > 0) CSLogImpl("btcarplay", "hide toggle hid %lu native CarPlay Wi-Fi/cellular view(s)", (unsigned long)hiddenCount);
    } else {
        BTKRestoreNativeCarPlayStatusViews();
    }
    // The audited CarPlay surface uses a two-line left status area: time on
    // the first line and cellular/Wi-Fi indicators on the second. With both
    // native glyphs hidden, use the cleared network slot for a rounded marker.
    CGFloat width = 25.0;
    CGFloat height = 14.0;
    CGFloat leftStatusX = 10.0;
    CGFloat secondLineY = 23.0;
    self.pill.frame = CGRectMake(leftStatusX, secondLineY, width, height);
    self.signalView.frame = CGRectInset(self.pill.bounds, 3.0, 3.0);
    BTKStyleCarPlayNetworkCapsule(self.pill, self.active);
    self.pill.layer.zPosition = 10000.0;
    self.pill.hidden = BTKHotspotHidden();
    self.pill.alpha = 1.0;
}

- (void)sceneChanged:(NSNotification *)notification {
    if ([notification.name isEqualToString:UISceneDidDisconnectNotification]) {
        BTKPublishCarPlayPresence(NO);
        [self stopAttachmentRetries];
        [self.presenceTimer invalidate];
        self.presenceTimer = nil;
        [self.pill removeFromSuperview];
        self.statusBarHost = nil;
        return;
    }
    BTKPublishCarPlayPresence(YES);
    [self attachToStatusBarWindow];
    if (self.statusBarHost) {
        self.pill.hidden = BTKHotspotHidden();
        return;
    }
    [self scheduleAttachmentRetries];
}

- (void)setActive:(BOOL)active {
    _active = active;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachToStatusBarWindow];
        if (self.statusBarHost) {
            self.pill.hidden = BTKHotspotHidden();
            BTKStyleCarPlayNetworkCapsule(self.pill, active);
        } else [self scheduleAttachmentRetries];
    });
}

@end

static void BTKStartCarPlayIndicator(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIApplication *application = UIApplication.sharedApplication;
        if (!application) {
            CSLogImpl("btcarplay", "CarPlay indicator unavailable: UIApplication is absent");
            return;
        }
        BTKCarPlayIndicatorController *controller = [BTKCarPlayIndicatorController new];
        [controller start];
        objc_setAssociatedObject(application, @selector(BTKStartCarPlayIndicator),
                                 controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CSLogImpl("btcarplay", "CarPlay keepalive status indicator started");
    });
}

static void BTKStartKeepAlive(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CSLogImpl("btcarplay", "SpringBoard keepalive monitor started");
        BTKPublishActivityState(NO);
        static int presenceToken;
        notify_register_dispatch(kBTKCarPlayPresenceNotification.UTF8String, &presenceToken,
                                 dispatch_get_main_queue(), ^(__unused int token) {
            BTKKeepAliveTick();
        });
        [NSTimer scheduledTimerWithTimeInterval:5.0
                                          repeats:YES
                                            block:^(__unused NSTimer *timer) {
            BTKKeepAliveTick();
        }];
    });
}

#pragma mark - Process bootstrap

static void BTKImageLoaded(const struct mach_header *header) {
    static BOOL installed = NO;
    if (installed || ![NSProcessInfo.processInfo.processName isEqualToString:@"Preferences"]) return;
    if (BTKInstallPreferencesHooks()) installed = YES;
}

__attribute__((constructor))
static void BTKInit(void) {
    @autoreleasepool {
        NSString *process = NSProcessInfo.processInfo.processName;
        if ([process isEqualToString:@"Preferences"]) {
            if (!BTKInstallPreferencesHooks()) objc_addLoadImageFunc(BTKImageLoaded);
        } else if ([process isEqualToString:@"SpringBoard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{ BTKStartKeepAlive(); });
        } else if ([process isEqualToString:@"CarPlayTemplateUIHost"]) {
            dispatch_async(dispatch_get_main_queue(), ^{ BTKStartCarPlayIndicator(); });
        }
        CSLogImpl("btcarplay", "loaded into %s", process.UTF8String ?: "?");
    }
}
