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
  [self llamadart_attachLatestRunIn:[documents URLByAppendingPathComponent:@"validation/runs" isDirectory:YES]
                         extensions:@[@"json", @"jsonl", @"csv", @"xml", @"html"]
                           maxBytes:2 * 1024 * 1024];
  // The image tests write their receipts and PNGs to the app cache
  // directory, which Test Lab does not collect on iOS.
  NSURL *caches = [files URLsForDirectory:NSCachesDirectory
                                inDomains:NSUserDomainMask].firstObject;
  [self llamadart_attachLatestRunIn:[caches URLByAppendingPathComponent:@"image_generation_e2e" isDirectory:YES]
                         extensions:@[@"json", @"png"]
                           maxBytes:16 * 1024 * 1024];
  [self llamadart_attachLatestRunIn:[caches URLByAppendingPathComponent:@"image_settings" isDirectory:YES]
                         extensions:@[@"json", @"jsonl", @"png"]
                           maxBytes:16 * 1024 * 1024];
  [super tearDown];
}

- (void)llamadart_attachLatestRunIn:(NSURL *)runs
                         extensions:(NSArray<NSString *> *)extensions
                           maxBytes:(unsigned long long)maxBytes {
  NSFileManager *files = NSFileManager.defaultManager;
  NSArray<NSURL *> *directories = [files contentsOfDirectoryAtURL:runs
      includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
  NSURL *latest = [[directories sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
    return [a.lastPathComponent compare:b.lastPathComponent];
  }] lastObject];
  if (latest == nil) return;
  for (NSURL *url in [files contentsOfDirectoryAtURL:latest
      includingPropertiesForKeys:@[NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size != nil && size.unsignedLongLongValue <= maxBytes &&
        [extensions containsObject:url.pathExtension]) {
      XCTAttachment *attachment = [XCTAttachment attachmentWithContentsOfFileAtURL:url];
      attachment.name = url.lastPathComponent;
      attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
      [self addAttachment:attachment];
    }
  }
}
@end
