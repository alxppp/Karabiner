@import Carbon;
#import "AXNotifierManager.h"
#import "AppDelegate.h"
#import "AppLauncher.h"
#import "ClientForKernelspace.h"
#import "InputSource.h"
#import "MigrationUtilities.h"
#import "NotificationKeys.h"
#import "PreferencesKeys.h"
#import "PreferencesManager.h"
#import "PreferencesWindowController.h"
#import "Relauncher.h"
#import "ServerController.h"
#import "ServerForUserspace.h"
#import "ServerObjects.h"
#import "SessionObserver.h"
#import "SharedKeys.h"
#import "StartAtLoginUtilities.h"
#import "StatusBar.h"
#import "StatusMessageManager.h"
#import "Updater.h"
#import "WorkSpaceData.h"
#import "XMLCompiler.h"

#include <stdlib.h>

@interface AppDelegate ()

@property(weak) IBOutlet ClientForKernelspace* clientForKernelspace;
@property(weak) IBOutlet PreferencesManager* preferencesManager;
@property(weak) IBOutlet ServerForUserspace* serverForUserspace;
@property(weak) IBOutlet ServerObjects* serverObjects;
@property(weak) IBOutlet StatusBar* statusbar;
@property(weak) IBOutlet StatusMessageManager* statusMessageManager;
@property(weak) IBOutlet Updater* updater;
@property(weak) IBOutlet WorkSpaceData* workSpaceData;
@property(weak) IBOutlet XMLCompiler* xmlCompiler;

// for IONotification
@property IONotificationPortRef notifyport;
@property CFRunLoopSourceRef loopsource;

@property NSMutableDictionary* mutableFocusedUIElementInformation;
@property(copy, readwrite) NSDictionary* inputSourceInformation;
@property(copy, readwrite) NSArray* workspaceAppIds;
@property(copy, readwrite) NSArray* workspaceWindowNameIds;
@property(copy, readwrite) NSArray* workspaceInputSourceIds;
@property(readwrite) NSNumber* workspaceUIElementRoleId;

@property SessionObserver* sessionObserver;
@property PreferencesWindowController* preferencesWindowController;

@end

@implementation AppDelegate

// ----------------------------------------
- (void)send_workspacedata_to_kext {
  NSMutableArray* workspaceIds = [NSMutableArray new];
  // Add dummy item to ensure send data.
  [workspaceIds addObject:@(BRIDGE_WORKSPACETYPE_NONE)];
  [workspaceIds addObject:@0];

  for (NSNumber* n in self.workspaceAppIds) {
    [workspaceIds addObject:@(BRIDGE_WORKSPACETYPE_APP_ID)];
    [workspaceIds addObject:n];
  }

  for (NSNumber* n in self.workspaceInputSourceIds) {
    [workspaceIds addObject:@(BRIDGE_WORKSPACETYPE_INPUT_SOURCE_ID)];
    [workspaceIds addObject:n];
  }

  if (self.workspaceUIElementRoleId) {
    [workspaceIds addObject:@(BRIDGE_WORKSPACETYPE_UI_ELEMENT_ROLE_ID)];
    [workspaceIds addObject:self.workspaceUIElementRoleId];
  }

  for (NSNumber* n in self.workspaceWindowNameIds) {
    [workspaceIds addObject:@(BRIDGE_WORKSPACETYPE_WINDOW_NAME_ID)];
    [workspaceIds addObject:n];
  }

  [self.clientForKernelspace send_workspacedata_to_kext:workspaceIds];
}

// ------------------------------------------------------------
- (void)distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [WorkSpaceData refreshEnabledInputSources];
  });
}

- (void)distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    InputSource* inputSource = [WorkSpaceData getCurrentInputSource];
    if (!inputSource) {
      self.workspaceInputSourceIds = nil;
    } else {
      self.workspaceInputSourceIds = [self.xmlCompiler inputsourceids:inputSource.languagecode
                                                        inputSourceID:inputSource.inputSourceID
                                                          inputModeID:inputSource.inputModeID];
    }
    [self send_workspacedata_to_kext];

    // ----------------------------------------
    NSMutableDictionary* inputSourceInformation = [NSMutableDictionary new];
    inputSourceInformation[@"mtime"] = @((NSUInteger)([[NSDate date] timeIntervalSince1970] * 1000));

    if ([inputSource languagecode]) {
      inputSourceInformation[@"languageCode"] = [inputSource languagecode];
    }
    if ([inputSource inputSourceID]) {
      inputSourceInformation[@"inputSourceID"] = [inputSource inputSourceID];
    }
    if ([inputSource inputModeID]) {
      inputSourceInformation[@"inputModeID"] = [inputSource inputModeID];
    }

    self.inputSourceInformation = inputSourceInformation;
  });
}

- (void)observer_ConfigXMLReloaded:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    // If <appdef> or <inputsourcedef> is updated,
    // the following values might be changed.
    // Therefore, we need to resend values to kext.
    //
    // - workspaceAppIds
    // - workspaceWindowNameIds
    // - workspaceUIElementRoleId
    // - workspaceInputSourceIds

    [self updateFocusedUIElementInformation:nil];
    [self distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:nil];
    [self distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:nil];
  });
}

// ------------------------------------------------------------
- (void)callClearNotSave {
  if (![self.preferencesManager value:@"general.keep_notsave_at_wake"]) {
    // disable notsave.* in order to disable "Browsing Mode" and
    // other modes which overwrite some keys
    // because these modes annoy password input.
    [self.preferencesManager clearNotSave];
  }
}

- (void)observer_NSWorkspaceDidWakeNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_NSWorkspaceDidWakeNotification");
    [self callClearNotSave];
  });
}

- (void)observer_NSWorkspaceScreensDidWakeNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_NSWorkspaceScreensDidWakeNotification");
    [self callClearNotSave];
  });
}

- (void)registerWakeNotification {
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceDidWakeNotification:)
                                                             name:NSWorkspaceDidWakeNotification
                                                           object:nil];
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceScreensDidWakeNotification:)
                                                             name:NSWorkspaceScreensDidWakeNotification
                                                           object:nil];
}

- (void)unregisterWakeNotification {
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                name:NSWorkspaceDidWakeNotification
                                                              object:nil];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                name:NSWorkspaceScreensDidWakeNotification
                                                              object:nil];
}

// ------------------------------------------------------------
static void observer_IONotification(void* refcon, io_iterator_t iterator) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_IONotification");

    AppDelegate* self = (__bridge AppDelegate*)(refcon);
    if (!self) {
      NSLog(@"[ERROR] observer_IONotification refcon == nil\n");
      return;
    }

    for (;;) {
      io_object_t obj = IOIteratorNext(iterator);
      if (!obj) break;

      IOObjectRelease(obj);
    }
    // Do not release iterator.

    // = Documentation of IOKit =
    // - Introduction to Accessing Hardware From Applications
    //   - Finding and Accessing Devices
    //
    // In the case of IOServiceAddMatchingNotification, make sure you release the iterator only if you’re also ready to stop receiving notifications:
    // When you release the iterator you receive from IOServiceAddMatchingNotification, you also disable the notification.

    // ------------------------------------------------------------
    [self.clientForKernelspace refresh_connection_with_retry];
    [self send_workspacedata_to_kext];
  });
}

- (void)unregisterIONotification {
  if (self.notifyport) {
    if (self.loopsource) {
      CFRunLoopSourceInvalidate(self.loopsource);
      self.loopsource = nil;
    }
    IONotificationPortDestroy(self.notifyport);
    self.notifyport = nil;
  }
}

- (void)registerIONotification {
  [self unregisterIONotification];

  self.notifyport = IONotificationPortCreate(kIOMasterPortDefault);
  if (!self.notifyport) {
    NSLog(@"[ERROR] IONotificationPortCreate failed\n");
    return;
  }

  // ----------------------------------------------------------------------
  io_iterator_t it;
  kern_return_t kernResult;

  kernResult = IOServiceAddMatchingNotification(self.notifyport,
                                                kIOMatchedNotification,
                                                IOServiceNameMatching("org_pqrs_driver_Karabiner"),
                                                &observer_IONotification,
                                                (__bridge void*)(self),
                                                &it);
  if (kernResult != kIOReturnSuccess) {
    NSLog(@"[ERROR] IOServiceAddMatchingNotification failed");
    return;
  }
  observer_IONotification((__bridge void*)(self), it);

  // ----------------------------------------------------------------------
  self.loopsource = IONotificationPortGetRunLoopSource(self.notifyport);
  if (!self.loopsource) {
    NSLog(@"[ERROR] IONotificationPortGetRunLoopSource failed");
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), self.loopsource, kCFRunLoopDefaultMode);
}

// ------------------------------------------------------------
- (void)observer_NSWindowWillCloseNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSWindow* window = [notification object];
    if (self.preferencesWindowController &&
        self.preferencesWindowController.window == window) {
      self.preferencesWindowController = nil;
    }
  });
}

// ------------------------------------------------------------
#define kDescendantProcess @"org_pqrs_Karabiner_DescendantProcess"

- (void)applicationDidFinishLaunching:(NSNotification*)aNotification {
  NSInteger isDescendantProcess = [[[NSProcessInfo processInfo] environment][kDescendantProcess] integerValue];
  setenv([kDescendantProcess UTF8String], "1", 1);

  // ------------------------------------------------------------
  if ([MigrationUtilities migrate:@[ @"org.pqrs.KeyRemap4MacBook" ]
           oldApplicationSupports:@[ @"KeyRemap4MacBook" ]
                         oldPaths:@[ @"/Applications/KeyRemap4MacBook.app" ]]) {
    [Relauncher relaunch];
  }

  // ------------------------------------------------------------
  if (![self.serverForUserspace register]) {
    // Relaunch when register is failed.
    NSLog(@"[ServerForUserspace register] is failed. Restarting process.");
    [NSThread sleepForTimeInterval:2];
    [Relauncher relaunch];
  }
  [Relauncher resetRelaunchedCount];

  // Wait until other apps connect to me.
  [NSThread sleepForTimeInterval:1];

  [[NSApplication sharedApplication] disableRelaunchOnLogin];

  [self.preferencesManager load];

  [self.statusMessageManager setupStatusMessageManager];
  [self.statusbar refresh];
  [self.xmlCompiler reload];

  self.sessionObserver = [[SessionObserver alloc] init:1
      active:^{
        [self.statusMessageManager resetStatusMessage];
        [self registerIONotification];
        [self registerWakeNotification];
      }
      inactive:^{
        [self.statusMessageManager resetStatusMessage];
        [self unregisterIONotification];
        [self unregisterWakeNotification];
        [self.clientForKernelspace disconnect_from_kext];
      }];

  // ------------------------------------------------------------
  // We need to speficy NSNotificationSuspensionBehaviorDeliverImmediately for NSDistributedNotificationCenter
  // because kTISNotify* will be dropped sometimes without this.
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:)
                                                          name:(NSString*)(kTISNotifyEnabledKeyboardInputSourcesChanged)
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:)
                                                          name:(NSString*)(kTISNotifySelectedKeyboardInputSourceChanged)
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(observer_ConfigXMLReloaded:)
                                               name:kConfigXMLReloadedNotification
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(observer_NSWindowWillCloseNotification:)
                                               name:NSWindowWillCloseNotification
                                             object:nil];

  // ------------------------------------------------------------
  [self distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:nil];
  [self distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:nil];

  [self.updater checkForUpdatesInBackground];

  // ------------------------------------------------------------
  [AXNotifierManager restartAXNotifier];

  // ------------------------------------------------------------
  // Send kKarabinerServerDidLaunchNotification after launching AXNotifier.
  //
  // AXNotifier will be relaunched by kKarabinerServerDidLaunchNotification.
  // If we send the notification before launching AXNotifier,
  // two AXNotifier processes will be launched when AXNotifier is already running.
  //
  // * relaunched AXNotifier.
  // * AXNotifier launched by manageAXNotifier.

  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kKarabinerServerDidLaunchNotification
                                                                 object:nil];

  // ------------------------------------------------------------
  // Open Preferences if Karabiner was launched by hand.
  // ------------------------------------------------------------
  {
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath isEqualToString:@"/Applications/Karabiner.app"]) {
      NSLog(@"Skip setStartAtLogin for %@", bundlePath);

      dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [NSAlert new];
        [alert setMessageText:@"Karabiner Alert"];
        [alert addButtonWithTitle:@"Close"];
        [alert setInformativeText:@"Karabiner.app should be located in /Applications/Karabiner.app.\nDo not move Karabiner.app into other folders."];
        [alert runModal];
      });

    } else {
      if (![StartAtLoginUtilities isStartAtLogin] &&
          [[NSUserDefaults standardUserDefaults] boolForKey:kResumeAtLogin]) {
        if (!isDescendantProcess) {
          [self openPreferences:self];
        }
      }
      [ServerController updateStartAtLogin:YES];
    }
  }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)theApplication hasVisibleWindows:(BOOL)flag {
  [self openPreferences:self];
  return YES;
}

- (void)dealloc {
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ------------------------------------------------------------
- (void)updateFocusedUIElementInformation:(NSDictionary*)information;
{
  if (information) {
    // We ignore our investigation application.
    if ([information[@"BundleIdentifier"] isEqualToString:@"org.pqrs.Karabiner.EventViewer"]) return;

    NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:information];
    dict[@"OriginalBundleIdentifier"] = dict[@"BundleIdentifier"];

    self.mutableFocusedUIElementInformation = dict;
  }

  if (self.mutableFocusedUIElementInformation) {
    // override BundleIdentifier
    NSString* overrideBundleIdentifier = [self.xmlCompiler overrideBundleIdentifier:self.mutableFocusedUIElementInformation[@"OriginalBundleIdentifier"]
                                                                         windowName:self.mutableFocusedUIElementInformation[@"WindowName"]
                                                                      uiElementRole:self.mutableFocusedUIElementInformation[@"UIElementRole"]];
    if (overrideBundleIdentifier) {
      self.mutableFocusedUIElementInformation[@"BundleIdentifier"] = overrideBundleIdentifier;
    } else {
      self.mutableFocusedUIElementInformation[@"BundleIdentifier"] = self.mutableFocusedUIElementInformation[@"OriginalBundleIdentifier"];
    }

    // ----------------------------------------
    self.workspaceAppIds = [self.xmlCompiler appids:self.mutableFocusedUIElementInformation[@"BundleIdentifier"]];
    self.workspaceWindowNameIds = [self.xmlCompiler windownameids:self.mutableFocusedUIElementInformation[@"WindowName"]];
    self.workspaceUIElementRoleId = @([self.workSpaceData getUIElementRole:self.mutableFocusedUIElementInformation[@"UIElementRole"]]);
  }

  [self send_workspacedata_to_kext];
}

- (NSDictionary*)focusedUIElementInformation {
  return self.mutableFocusedUIElementInformation;
}

// ------------------------------------------------------------
- (IBAction)launchEventViewer:(id)sender {
  [AppLauncher openEventViewer];
}

- (IBAction)openPreferences:(id)sender {
  if (self.preferencesWindowController == nil) {
    self.preferencesWindowController = [[PreferencesWindowController alloc] initWithServerObjects:@"PreferencesWindow" serverObjects:self.serverObjects];
  }
  [self.preferencesWindowController show];
}

- (IBAction)checkForUpdatesStableOnly:(id)sender {
  [self.updater checkForUpdatesStableOnly];
}

- (IBAction)quit:(id)sender {
  [ServerController quitWithConfirmation];
}

@end
