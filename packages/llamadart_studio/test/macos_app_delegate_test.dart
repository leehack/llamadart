@TestOn('vm && mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native delegate releases its activity once and forwards plugin events',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'studio_delegate_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final config = File('.dart_tool/package_config.json');
      final packages =
          (jsonDecode(await config.readAsString())
                  as Map<String, dynamic>)['packages']
              as List<dynamic>;
      final flutter = packages.cast<Map<String, dynamic>>().singleWhere(
        (package) => package['name'] == 'flutter',
      );
      final sdk = Directory.fromUri(
        config.absolute.uri.resolve(flutter['rootUri'] as String),
      ).parent.parent;
      final frameworks = '${sdk.path}/bin/cache/artifacts/engine/darwin-x64';
      final library = '${temporary.path}/AppDelegate.dylib';
      final harness = File('${temporary.path}/main.m');
      final executable = '${temporary.path}/delegate_test';
      await harness.writeAsString(_harness);

      Future<void> run(List<String> arguments) async {
        final result = await Process.run('xcrun', arguments);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }

      // Compile the production source unchanged, including its optional ObjC
      // delegate dispatch. Loading the dylib does not invoke NSApplicationMain.
      await run([
        'swiftc',
        '-emit-library',
        '-module-name',
        'StudioAppDelegateRegression',
        '-F',
        frameworks,
        '-framework',
        'FlutterMacOS',
        '-Xlinker',
        '-rpath',
        '-Xlinker',
        frameworks,
        'macos/Runner/AppDelegate.swift',
        '-o',
        library,
      ]);
      await run([
        'clang',
        '-fobjc-arc',
        '-F',
        frameworks,
        '-framework',
        'Cocoa',
        '-framework',
        'FlutterMacOS',
        '-Wl,-rpath,$frameworks',
        harness.path,
        '-o',
        executable,
      ]);
      final failures = <String>[];
      for (final scenario in ['launch', 'terminate', 'lifecycle']) {
        final result = await Process.run(executable, [library, scenario]);
        if (result.exitCode != 0) {
          failures.add('$scenario: ${result.stdout}\n${result.stderr}');
        }
      }
      expect(failures, isEmpty);
    },
  );
}

const _harness = r'''
#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSUInteger begins = 0;
static NSUInteger ends = 0;
static id activity;

static id beginActivity(id self, SEL selector, NSActivityOptions options,
                        NSString *reason) {
  begins++;
  activity = [NSObject new];
  return activity;
}

static void endActivity(id self, SEL selector, id token) {
  NSCAssert(token == activity, @"Must end the activity that was begun");
  ends++;
}

@interface PluginLifecycleProbe : NSObject <FlutterAppLifecycleDelegate>
@property NSUInteger launches;
@property NSUInteger terminations;
@end

@implementation PluginLifecycleProbe
- (void)handleDidFinishLaunching:(NSNotification *)notification {
  self.launches++;
}
- (void)handleWillTerminate:(NSNotification *)notification {
  self.terminations++;
}
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    @try {
      NSCAssert(dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL), @"Load production delegate");
      Class delegateClass = NSClassFromString(@"StudioAppDelegateRegression.AppDelegate");
      NSCAssert(delegateClass, @"Find production delegate class");
      Class processClass = object_getClass(NSProcessInfo.processInfo);
      method_setImplementation(class_getInstanceMethod(processClass,
          @selector(beginActivityWithOptions:reason:)), (IMP)beginActivity);
      method_setImplementation(class_getInstanceMethod(processClass,
          @selector(endActivity:)), (IMP)endActivity);

      id<NSApplicationDelegate, FlutterAppLifecycleProvider> delegate =
          [[delegateClass alloc] init];
      NSNotification *launch = [NSNotification
          notificationWithName:NSApplicationDidFinishLaunchingNotification object:nil];
      NSNotification *termination = [NSNotification
          notificationWithName:NSApplicationWillTerminateNotification object:nil];
      NSString *scenario = @(argv[2]);
      if ([scenario isEqualToString:@"launch"]) {
        [delegate applicationDidFinishLaunching:launch];
        NSCAssert(begins == 1, @"Launch starts one activity");
      } else if ([scenario isEqualToString:@"terminate"]) {
        [delegate applicationWillTerminate:termination];
        NSCAssert(ends == 0, @"Termination without launch has no activity to end");
      } else {
        PluginLifecycleProbe *plugin = [PluginLifecycleProbe new];
        [delegate addApplicationLifecycleDelegate:plugin];
        [delegate applicationDidFinishLaunching:launch];
        [NSNotificationCenter.defaultCenter postNotification:launch];
        [delegate applicationWillTerminate:termination];
        [NSNotificationCenter.defaultCenter postNotification:termination];
        [delegate applicationWillTerminate:termination];
        NSCAssert(begins == 1 && ends == 1, @"Release exactly once, including repeat callback");
        NSCAssert(plugin.launches == 1 && plugin.terminations == 1,
                  @"Flutter forwards both notifications to registered plugins");
      }
    } @catch (NSException *exception) {
      NSLog(@"%@", exception);
      return 1;
    }
  }
  return 0;
}
''';
