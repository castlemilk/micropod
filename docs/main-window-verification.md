# Main window verification

Micropod owns one SwiftUI `Window` for the main UI. Menu bar shortcuts, the
application menu, and Dock reopening use `MainWindowPresenter` to reveal the
existing native window, restoring it when minimized. Closing the main window
keeps the menu bar app running; reopening uses the same unique scene. Settings
does not register as the main window.

The presenter tests cover routing, activation, minimized windows, close
notifications, unrelated window closure, and first launch:

```sh
swift test --jobs 2 --filter 'MainWindowPresenterTests|MainWindowVisibilityTests|MenuBarPanelSnapshotTests'
```

On a logged-in macOS GUI session, run the isolated native regression:

```sh
bash scripts/test_main_window.sh
```

An optional first argument selects the evidence directory. The script builds
the production scene and presenter with a small SwiftUI QA view. It checks
repeated native menu actions, actual minimization and restoration, the Dock
reopen handler with another visible window, closing and reopening, and Launch
Services opening an already-running app. It records window counts and process
IDs in `result.json`, plus native rendered content images before and after
restoration. It times out after 45 seconds and stops only its QA process.

This test does not launch the installed Micropod app, use its runtime or
helpers, access cache data, or interrupt jobs. It verifies native window
lifecycle behavior; installed-app acceptance is a separate release check.
The Dock handler is invoked directly; actual Dock event delivery and the
production tray panel's dismissal/focus sequence require installed-app checks.
