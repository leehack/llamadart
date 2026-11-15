#import <Cocoa/Cocoa.h>
#import <FlutterMacOS/FlutterMacOS.h>
#define FlutterEngine EmbedderFlutterEngine
#include "embedder.h"
#undef FlutterEngine

@interface FlutterEngine (SemanticsTest)
@property BOOL semanticsEnabled;
@end
@interface FlutterViewController (SemanticsTest)
- (void)notifySemanticsEnabledChanged;
- (void)updateSemantics:(const FlutterSemanticsUpdate2 *)update;
@end

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    FlutterViewController *controller = [[FlutterViewController alloc] initWithProject:nil];
    [controller loadView];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 800, 600)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.contentView = controller.view;
    // A Dart isolate is unnecessary: exercise the real native accessibility
    // bridge directly, including VALUE_CHANGED dispatch to the hosted view.
    controller.engine.semanticsEnabled = YES;
    [controller notifySemanticsEnabledChanged];

    FlutterSemanticsFlags flags = {};
    flags.struct_size = sizeof(flags);
    FlutterSemanticsNode2 root = {};
    root.struct_size = sizeof(root);
    root.id = 0;
    root.flags2 = &flags;
    root.label = "root";
    root.hint = root.value = root.increased_value = root.decreased_value = "";
    root.tooltip = root.identifier = "";
    root.text_selection_base = root.text_selection_extent = -1;
    root.rect = {0, 0, 800, 600};
    root.transform = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    int32_t childId = 1;
    root.child_count = 1;
    root.children_in_traversal_order = root.children_in_hit_test_order = &childId;
    FlutterSemanticsNode2 child = root;
    child.id = 1;
    child.child_count = 0;
    child.children_in_traversal_order = child.children_in_hit_test_order = nullptr;
    child.label = "";
    child.value = "before";
    child.rect = {0, 0, 300, 100};
    FlutterSemanticsNode2 *nodes[] = {&root, &child};
    FlutterSemanticsUpdate2 update = {};
    update.struct_size = sizeof(update);
    update.node_count = 2;
    update.nodes = nodes;
    [controller updateSemantics:&update];

    id flutterView = controller.view.accessibilityChildren.firstObject;
    id nativeRoot = [flutterView accessibilityChildren].firstObject;
    id nativeText = [nativeRoot accessibilityChildren].firstObject;
    NSCAssert([[nativeText accessibilityRole] isEqual:NSAccessibilityStaticTextRole],
              @"Output must remain readable static text");
    NSCAssert([[nativeText accessibilityValue] isEqual:@"before"], @"Initial output is readable");

    child.value = "after";
    update.node_count = 1;
    update.nodes = &nodes[1];
    [controller updateSemantics:&update];
    NSCAssert([[nativeText accessibilityValue] isEqual:@"after"], @"Updated output is readable");
    NSLog(@"STATIC_SEMANTICS_UPDATE_OK");
    [controller.engine shutDownEngine];
  }
  return 0;
}
