/**
 * @file src/tray.h
 * @brief Definition of the tray API.
 */
#ifndef TRAY_H
#define TRAY_H

#ifdef __cplusplus
extern "C" {
#endif

  /**
   * @brief Tray menu item.
   */
  struct tray_menu;

  /**
   * @brief Tray icon.
   */
  struct tray {
    const char *icon;  ///< Icon to display.
    const char *tooltip;  ///< Tooltip to display.
    const char *notification_icon;  ///< Icon to display in the notification.
    const char *notification_text;  ///< Text to display in the notification.
    const char *notification_title;  ///< Title to display in the notification.
    void (*notification_cb)();  ///< Callback to invoke when the notification is clicked.
    struct tray_menu *menu;  ///< Menu items.
    const int iconPathCount;  ///< Number of icon paths.
    const char *allIconPaths[];  ///< Array of icon paths.
  };

  /**
   * @brief Tray menu item.
   */
  struct tray_menu {
    const char *text;  ///< Text to display.
    int disabled;  ///< Whether the item is disabled.
    int checked;  ///< Whether the item is checked.
    int checkbox;  ///< Whether the item is a checkbox.

    void (*cb)(struct tray_menu *);  ///< Callback to invoke when the item is clicked.
    void *context;  ///< Context to pass to the callback.

    struct tray_menu *submenu;  ///< Submenu items.
  };

  /**
   * @brief Create tray icon.
   * @param tray The tray to initialize.
   * @return 0 on success, -1 on error.
   */
  int tray_init(struct tray *tray);

  /**
   * @brief Run one iteration of the UI loop.
   * @param blocking Whether to block the call or not.
   * @return 0 on success, -1 if tray_exit() was called.
   */
  int tray_loop(int blocking);

  /**
   * @brief Update the tray icon and menu.
   * @param tray The tray to update.
   */
  void tray_update(struct tray *tray);

  /**
   * @brief Terminate UI loop.
   */
  void tray_exit(void);

  /**
   * @brief Select whether tray_init() creates a visible status item ("headless" mode).
   *
   * Skylight-local addition (not upstream dmikushin/tray or LizardByte/tray). Only macOS
   * (src/tray_darwin.m) currently implements this; other platforms don't define the symbol, so
   * callers must only invoke it from platform-guarded code. Must be called before tray_init()
   * to take effect -- it has no effect on an already-initialized tray. See
   * src/tray_darwin.m's tray_init() for what "headless" skips.
   * @param headless Non-zero to suppress the status item; zero for the default visible tray.
   */
  void tray_set_headless(int headless);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif /* TRAY_H */
