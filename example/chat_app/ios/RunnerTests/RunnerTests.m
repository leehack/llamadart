@import XCTest;
@import integration_test;

INTEGRATION_TEST_IOS_RUNNER(RunnerTests)

// Flutter executes the Dart suite before materializing its XCTest results.
// Keep the latest run's bounded evidence even when its assertions fail.
@implementation RunnerTests (ValidationAttachments)
- (void)tearDown {
  NSFileManager *files = NSFileManager.defaultManager;
  NSURL *documents = [files URLsForDirectory:NSDocumentDirectory
                                 inDomains:NSUserDomainMask].firstObject;
  NSURL *runs = [documents URLByAppendingPathComponent:@"validation/runs" isDirectory:YES];
  NSArray<NSURL *> *directories = [files contentsOfDirectoryAtURL:runs
      includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
  NSURL *latest = [[directories sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
    return [a.lastPathComponent compare:b.lastPathComponent];
  }] lastObject];
  if (latest != nil) {
    for (NSURL *url in [files contentsOfDirectoryAtURL:latest
        includingPropertiesForKeys:@[NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
      NSNumber *size = nil;
      [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
      if (size != nil && size.unsignedLongLongValue <= 2 * 1024 * 1024 &&
          [@[@"json", @"jsonl", @"csv", @"xml", @"html"] containsObject:url.pathExtension]) {
        XCTAttachment *attachment = [XCTAttachment attachmentWithContentsOfFileAtURL:url];
        attachment.name = url.lastPathComponent;
        attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
      }
    }
  }
  [super tearDown];
}
@end
