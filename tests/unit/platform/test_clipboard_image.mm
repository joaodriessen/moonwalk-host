#import <AppKit/AppKit.h>
#include <gtest/gtest.h>
#include <src/png_clipboard.h>
#include <string>

namespace platf {
  bool test_set_clipboard_png(NSPasteboard *, const std::string &);
}

@interface InertImagePasteboard: NSObject
@property (nonatomic, strong) NSArray<NSPasteboardItem *> *pasteboardItems;
@property (nonatomic) NSInteger clears;
@property (nonatomic) BOOL failNextWrite;
- (NSInteger)clearContents;
- (BOOL)writeObjects:(NSArray *)objects;
@end
@implementation InertImagePasteboard

- (NSInteger)clearContents {
  ++_clears;
  self.pasteboardItems = @[];
  return self.clears;
}

- (BOOL)writeObjects:(NSArray *)objects {
  if (self.failNextWrite) {
    self.failNextWrite = NO;
    return NO;
  }
  self.pasteboardItems = objects;
  return YES;
}

@end

TEST(NativeClipboardImage, ValidPngPublishesAndFailedWriteRestoresAllOriginalTypes) {
  @autoreleasepool {
    NSData *bytes = [[NSData alloc] initWithBase64EncodedString:@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==" options:0];
    std::string png((const char *) bytes.bytes, bytes.length);
    InertImagePasteboard *pasteboard = [[InertImagePasteboard alloc] init];
    NSPasteboardItem *original = [[NSPasteboardItem alloc] init];
    [original setString:@"keep me" forType:NSPasteboardTypeString];
    [original setData:[NSData dataWithBytes:"\0\xff" length:2] forType:@"private.binary"];
    pasteboard.pasteboardItems = @[original];
    EXPECT_FALSE(platf::test_set_clipboard_png((NSPasteboard *) pasteboard, "not PNG"));
    EXPECT_EQ(pasteboard.clears, 0);
    pasteboard.failNextWrite = YES;
    EXPECT_FALSE(platf::test_set_clipboard_png((NSPasteboard *) pasteboard, png));
    EXPECT_TRUE([[pasteboard.pasteboardItems.firstObject stringForType:NSPasteboardTypeString] isEqualToString:@"keep me"]);
    EXPECT_EQ([pasteboard.pasteboardItems.firstObject dataForType:@"private.binary"].length, 2);
    EXPECT_TRUE(platf::test_set_clipboard_png((NSPasteboard *) pasteboard, png));
    EXPECT_TRUE([[pasteboard.pasteboardItems.firstObject dataForType:NSPasteboardTypePNG] isEqualToData:bytes]);
  }
}

TEST(NativeClipboardImage, StrictContainerRejectsTruncationCrcCorruptionAndTrailingData) {
  @autoreleasepool {
    NSData *bytes = [[NSData alloc] initWithBase64EncodedString:@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==" options:0];
    std::string png((const char *) bytes.bytes, bytes.length);
    ASSERT_TRUE(png_clipboard::valid_header(png));
    EXPECT_FALSE(png_clipboard::valid_header(png.substr(0, png.size() - 12)));
    EXPECT_FALSE(png_clipboard::valid_header(png.substr(0, png.size() - 1)));
    EXPECT_FALSE(png_clipboard::valid_header(png + "trailing"));
    png[42] ^= 1;
    EXPECT_FALSE(png_clipboard::valid_header(png));
    InertImagePasteboard *pasteboard = [[InertImagePasteboard alloc] init];
    pasteboard.pasteboardItems = @[];
    EXPECT_FALSE(platf::test_set_clipboard_png((NSPasteboard *) pasteboard, png));
    EXPECT_EQ(pasteboard.clears, 0);
  }
}
