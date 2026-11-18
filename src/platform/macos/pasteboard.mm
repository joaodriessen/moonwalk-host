/**
 * @file src/platform/macos/pasteboard.mm
 * @brief Definitions for macOS system clipboard (pasteboard) access.
 * @details Backs the native in-stream clipboard feature: text-only (UTF-8) for v1.
 *          The host is passive storage — it never polls or initiates sync, it only
 *          serves reads/writes on demand from `nvhttp`'s `/actions/clipboard` route.
 *          Never log clipboard content; byte counts only.
 */

// platform includes
#import <AppKit/AppKit.h>

// local includes
#include "src/logging.h"
#include "src/platform/common.h"

using namespace std::literals;

namespace platf {

  // Transport-layer size cap for clipboard text, matching nvhttp's
  // max_request_streambuf_size (~1 MiB). Enforced again here on read so an
  // oversized pasteboard value is never emitted piecemeal.
  static constexpr size_t kClipboardMaxBytes = 1024 * 1024;

  std::string get_clipboard() {
    @autoreleasepool {
      NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
      NSString *contents = [pasteboard stringForType:NSPasteboardTypeString];
      if (!contents) {
        return {};
      }

      const char *utf8 = contents.UTF8String;
      if (!utf8) {
        return {};
      }

      size_t len = strlen(utf8);
      if (len > kClipboardMaxBytes) {
        // Never truncate a secret — refuse to return a partial value.
        BOOST_LOG(warning) << "Clipboard read exceeds size cap ("sv << len << " bytes); returning empty"sv;
        return {};
      }

      return std::string(utf8, len);
    }
  }

  bool set_clipboard(const std::string &content) {
    @autoreleasepool {
      NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
      [pasteboard clearContents];

      NSString *string = [[NSString alloc] initWithBytes:content.data()
                                                  length:content.size()
                                                encoding:NSUTF8StringEncoding];
      if (!string) {
        BOOST_LOG(warning) << "Clipboard write failed: content is not valid UTF-8"sv;
        return false;
      }

      return [pasteboard setString:string forType:NSPasteboardTypeString] == YES;
    }
  }

  std::int64_t clipboard_change_count() {
    @autoreleasepool {
      // NSInteger is 64-bit on all supported (modern) macOS architectures. This is the
      // native monotonic "did the pasteboard change" primitive -- it increments on every
      // write to the pasteboard, by any app, including our own set_clipboard() above.
      // Cheap property read; no content is touched or logged.
      return (std::int64_t) [NSPasteboard generalPasteboard].changeCount;
    }
  }

}  // namespace platf

// Bounded image extension. Decode/validation happens before replacing any data;
// a failed write restores materialized original items instead of clearing them.
#include "src/png_clipboard.h"

#import <ImageIO/ImageIO.h>

namespace platf {
  namespace {
    bool replace_clipboard_items(NSPasteboard *pasteboard, NSArray<NSPasteboardItem *> *replacement) {
      NSMutableArray<NSPasteboardItem *> *saved = [NSMutableArray array];
      NSUInteger total = 0;
      for (NSPasteboardItem *old in pasteboard.pasteboardItems) {
        if (saved.count >= 64 || old.types.count > 32) {
          return false;
        }
        NSPasteboardItem *copy = [[NSPasteboardItem alloc] init];
        for (NSPasteboardType type in old.types) {
          NSData *data = [old dataForType:type];
          if (!data || data.length > 16 * 1024 * 1024 - total) {
            return false;
          }
          total += data.length;
          if (![copy setData:data forType:type]) {
            return false;
          }
        }
        [saved addObject:copy];
      }
      [pasteboard clearContents];
      if ([pasteboard writeObjects:replacement]) {
        return true;
      }
      [pasteboard clearContents];
      [pasteboard writeObjects:saved];
      return false;
    }

    bool write_png(NSPasteboard *pasteboard, const std::string &png) {
      if (!png_clipboard::valid_header(png)) {
        return false;
      }
      NSData *data = [NSData dataWithBytes:png.data() length:png.size()];
      NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:data];
      if (!image || image.pixelsWide <= 0 || image.pixelsHigh <= 0 || image.pixelsWide > 4096 || image.pixelsHigh > 4096) {
        return false;
      }
      NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
      if (![item setData:data forType:NSPasteboardTypePNG]) {
        return false;
      }
      return replace_clipboard_items(pasteboard, @[item]);
    }
  }  // namespace

  clipboard_image_t get_clipboard_png() {
    @autoreleasepool {
      NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
      NSData *data = [pasteboard dataForType:NSPasteboardTypePNG];
      bool nativePng = data != nil;
      if (!data) {
        data = [pasteboard dataForType:NSPasteboardTypeTIFF];
      }
      if (!data) {
        return {};
      }
      if (data.length > 32 * 1024 * 1024) {
        return {{}, true};
      }
      CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef) data, nullptr);
      if (!source) {
        return {};
      }
      CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
      CFRelease(source);
      if (!props) {
        return {};
      }
      int64_t width = 0, height = 0;
      CFNumberRef w = (CFNumberRef) CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
      CFNumberRef h = (CFNumberRef) CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
      if (w && CFGetTypeID(w) == CFNumberGetTypeID()) {
        CFNumberGetValue(w, kCFNumberSInt64Type, &width);
      }
      if (h && CFGetTypeID(h) == CFNumberGetTypeID()) {
        CFNumberGetValue(h, kCFNumberSInt64Type, &height);
      }
      CFRelease(props);
      if (width <= 0 || height <= 0 || width > 4096 || height > 4096 || width * height > 16 * 1024 * 1024) {
        return {{}, true};
      }
      if (!nativePng) {
        NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:data];
        if (!image) {
          return {};
        }
        data = [image representationUsingType:NSBitmapImageFileTypePNG properties:@ {}];
      }
      if (!data || data.length > png_clipboard::max_bytes) {
        return {{}, true};
      }
      std::string png((const char *) data.bytes, data.length);
      if (!png_clipboard::valid_header(png)) {
        return {};
      }
      return {std::move(png), false};
    }
  }

  bool set_clipboard_png(const std::string &png) {
    @autoreleasepool {
      return write_png([NSPasteboard generalPasteboard], png);
    }
  }
#ifdef SUNSHINE_TESTS
  bool test_set_clipboard_png(NSPasteboard *pasteboard, const std::string &png) {
    return write_png(pasteboard, png);
  }
#endif
}  // namespace platf
