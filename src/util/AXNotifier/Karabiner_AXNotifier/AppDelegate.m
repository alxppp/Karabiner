#import "AXApplicationObserverManager.h"
#import "AppDelegate.h"
#import "MigrationUtilities.h"
#import "NotificationKeys.h"
#import "PreferencesKeys.h"
#import "Relauncher.h"
#import "ServerClient.h"
#import "SharedKeys.h"
#import "WindowObserver.h"

// ==================================================
@interface AppDelegate ()

@property(assign) IBOutlet NSWindow* window;
@property(assign) IBOutlet ServerClient* client;
@property BOOL axEnabled;
@property(copy) NSDictionary* focusedUIElementInformation;
@property(copy) NSDictionary* overlaidWindowElementInformation;
@property(copy) NSDictionary* previousSentInformation;
@property AXApplicationObserverManager* axApplicationObserverManager;
@property WindowObserver* windowObserver;

@end

@implementation AppDelegate

- (void)tellToServer {
  NSMutableDictionary* target = nil;
  if (self.overlaidWindowElementInformation) {
    target = [NSMutableDictionary dictionaryWithDictionary:self.overlaidWindowElementInformation];
  } else {
    target = [NSMutableDictionary dictionaryWithDictionary:self.focusedUIElementInformation];
  }

  // Send if the current information and the previous information are different.
  for (NSString* key in target) {
    if (![target[key] isEqual:self.previousSentInformation[key]]) {
      goto send;
    }
  }
#if 0
  NSLog(@"tellToServer skip");
#endif
  return;

send:
  target[@"mtime"] = @((NSUInteger)([[NSDate date] timeIntervalSince1970] * 1000));
#if 0
  NSLog(@"%@", target);
#endif
  @try {
    [[self.client proxy] updateFocusedUIElementInformation:target];
    self.previousSentInformation = target;
  }
  @catch (NSException* exception) {
    NSLog(@"%@", exception);
    self.previousSentInformation = nil;
  }
}

- (void)distributedObserver_kKarabinerServerDidLaunchNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
      [NSTask launchedTaskWithLaunchPath:[[NSBundle mainBundle] executablePath] arguments:@[]];
      [NSApp terminate:self];
    }
  });
}

- (void)observer_kFocusedUIElementChanged:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
      NSDictionary* d = [notification userInfo];
      // systemuiserver is handled by WindowObserver. (== observer_kWindowVisibilityChanged)
      if ([d[@"bundleIdentifier"] isEqualToString:@"com.apple.systemuiserver"]) {
        return;
      }

      self.focusedUIElementInformation = @{
        @"BundleIdentifier" : d[@"bundleIdentifier"],
        @"WindowName" : d[@"title"],
        @"UIElementRole" : d[@"role"],
      };
      [self tellToServer];
    }
  });
}

- (void)observer_kWindowVisibilityChanged:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
      NSDictionary* d = [notification userInfo];
      if ([d[@"visibility"] isEqualToNumber:@YES]) {
        self.overlaidWindowElementInformation = @{
          @"BundleIdentifier" : d[@"bundleIdentifier"],
          @"WindowName" : d[@"windowName"],
          @"UIElementRole" : d[@"role"],
        };
      } else {
        self.overlaidWindowElementInformation = nil;
      }
      [self tellToServer];
    }
  });
}

- (void)timerFireMethod:(NSTimer*)timer {
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
      if (AXIsProcessTrusted()) {
        if (![[NSApplication sharedApplication] isHidden]) {
          [[NSApplication sharedApplication] hide:self];
        }

        if (!self.axEnabled) {
          self.axEnabled = YES;

          // Renew AXApplicationObserverManager
          [self setupAXApplicationObserverManager];
        }

      } else {
        self.axEnabled = NO;
      }
    }
  });
}

#define kDescendantProcess @"org_pqrs_Karabiner_AXNotifier_DescendantProcess"

- (void)applicationDidFinishLaunching:(NSNotification*)aNotification {
  NSInteger isDescendantProcess = [[[NSProcessInfo processInfo] environment][kDescendantProcess] integerValue];
  setenv([kDescendantProcess UTF8String], "1", 1);

  // ------------------------------------------------------------
  if ([MigrationUtilities migrate:@[ @"org.pqrs.KeyRemap4MacBook.AXNotifier" ]
           oldApplicationSupports:@[]
                         oldPaths:@[ @"/Applications/KeyRemap4MacBook.app/Contents/Applications/KeyRemap4MacBook_AXNotifier.app" ]]) {
    [Relauncher relaunch];
  }

  // ------------------------------------------------------------
  [_window setLevel:NSFloatingWindowLevel];

  if (![[NSUserDefaults standardUserDefaults] boolForKey:kDoNotShowAXWarningMessage]) {
    if (!AXIsProcessTrusted()) {
      [_window orderFront:self];

      if (!isDescendantProcess) {
        NSDictionary* options = @{(__bridge NSString*)(kAXTrustedCheckOptionPrompt) : @YES };
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
      }
    }
  }

  // ----------------------------------------
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(distributedObserver_kKarabinerServerDidLaunchNotification:)
                                                          name:kKarabinerServerDidLaunchNotification
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(observer_kFocusedUIElementChanged:)
                                               name:kFocusedUIElementChanged
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(observer_kWindowVisibilityChanged:)
                                               name:kWindowVisibilityChanged
                                             object:nil];

  // ----------------------------------------
  if (AXIsProcessTrusted()) {
    self.axEnabled = YES;
  }
  [self setupAXApplicationObserverManager];
  self.windowObserver = [WindowObserver new];

  [NSTimer scheduledTimerWithTimeInterval:0.5
                                   target:self
                                 selector:@selector(timerFireMethod:)
                                 userInfo:nil
                                  repeats:YES];

  // ----------------------------------------
  [Relauncher resetRelaunchedCount];
}

- (void)dealloc {
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupAXApplicationObserverManager {
  self.axApplicationObserverManager = [[AXApplicationObserverManager alloc] initWithPreferences:[[self.client proxy] preferencesForAXNotifier]];
}

@end
