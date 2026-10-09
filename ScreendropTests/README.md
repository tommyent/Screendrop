# Logic tests

Run the shared `Screendrop` or `Screendrop Dev` scheme's Test action. On this fork's build Mac:

```sh
xcodebuild test -project Screendrop.xcodeproj -scheme "Screendrop Dev" \
  -configuration "Debug Dev" -destination "platform=macOS" \
  -derivedDataPath /private/tmp/screendrop-dd/wt-fork-logic-tests \
  DEVELOPMENT_TEAM=NMM3956F6W -allowProvisioningUpdates
```

`ScreendropTests` uses Swift Testing with **no app host**. It compiles the actual production files listed under “Tested logic” in the project. There are no copied implementations, generated source adapters, test dependencies or network calls. Tests do not open windows, register shortcuts, capture screens, access cameras or change preferences. AppKit types are used for model geometry and in-memory bitmaps only.

The regular Build action builds the app; the Test action builds the app and runs this suite. Nothing is installed or launched as an app. New test files in `ScreendropTests` are picked up by Xcode's synchronized group. Add production-file memberships to the test target when a new helper is needed.

Fixtures should be generated in memory. Keep any required recorded regression fixture small, anonymized and local to the test bundle; never depend on an agent's temporary folder or a network URL. Use `#expect`/`#require`, which remain active in optimized builds, instead of `assert` or trapping `precondition`.

The editor tests port `scripts/check-editor-{snapping,fill,interaction,snapping-interaction,viewport,resources}.swift` and the export-only part of `check-editor-snapping-render.swift`. Geometry, pointer state transitions, undo/redo, presets, viewport transforms, caches and export bitmaps run without a view or window. The old windowless canvas-drawing checks and Vision/movie cancellation integration script stay separate: they aren't pure model tests.
