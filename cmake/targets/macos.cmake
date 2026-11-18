# macos specific target definitions
target_link_options(sunshine PRIVATE LINKER:-sectcreate,__TEXT,__info_plist,${APPLE_PLIST_FILE})
# The embedded plist is a LINK input, not a compile input — without this, editing it silently
# leaves an already-built binary carrying the old identity (bitten 2026-08-14: a rebuilt daemon
# still embedded the upstream CFBundleIdentifier because nothing relinked).
set_target_properties(sunshine PROPERTIES LINK_DEPENDS ${APPLE_PLIST_FILE})
# Tell linker to dynamically load these symbols at runtime, in case they're unavailable:
target_link_options(sunshine PRIVATE -Wl,-U,_CGPreflightScreenCaptureAccess -Wl,-U,_CGRequestScreenCaptureAccess)
