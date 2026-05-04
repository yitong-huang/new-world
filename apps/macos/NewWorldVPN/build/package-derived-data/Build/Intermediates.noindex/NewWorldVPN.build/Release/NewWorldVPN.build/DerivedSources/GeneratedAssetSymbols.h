#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "MenuBarBrickConnected" asset catalog image resource.
static NSString * const ACImageNameMenuBarBrickConnected AC_SWIFT_PRIVATE = @"MenuBarBrickConnected";

/// The "MenuBarBrickDisconnected" asset catalog image resource.
static NSString * const ACImageNameMenuBarBrickDisconnected AC_SWIFT_PRIVATE = @"MenuBarBrickDisconnected";

#undef AC_SWIFT_PRIVATE
