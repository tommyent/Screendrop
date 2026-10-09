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

Fixtures should be generated in memory. Keep any required recorded regression fixture small and local to the test bundle; never depend on an agent's temporary folder or a network URL. Use `#expect`/`#require`, which remain active in optimized builds, instead of `assert` or trapping `precondition`.

The editor tests port `scripts/check-editor-{snapping,fill,interaction,snapping-interaction,viewport,resources}.swift` and the export-only part of `check-editor-snapping-render.swift`. Geometry, pointer state transitions, undo/redo, presets, viewport transforms, caches and export bitmaps run without a view or window. The old windowless canvas-drawing checks and Vision/movie cancellation integration script stay separate: they aren't pure model tests.

`StitcherTests` contains all 44 canonical R7 groups as individually discoverable tests. Case 13 retains the two approved Sublime source-code frames as losslessly compressed decoded BGRA pixels (166,296 bytes total; largest 84,844 bytes). Cases 15 and 24 now generate list rows/icon redraws and a playing-video/pinned-sidebar pair in `SyntheticFixtures.swift`; the faint-header edge test also generates flat surfaces in code. Their original expected offsets, refusal, dimensions and edge spans remain unchanged, but these cases no longer replay the exact private recorded screens. No Finder, website or Inbox pixels are bundled. Resources load from the test bundle without any team archive or absolute source paths. The original canonical suite's SHA-256 is `d53aa38c1a576270a557f4b7b8075debfb286ede8f86a32a4a55131fa0917698`.

Two original primary-matcher safety limits, previously printed without assertions, are now scoped `withKnownIssue` expectations in cases 19 and 23. Their expected failures are visible in Xcode, and an unexpected fix requires updating the marker. Changing-header coverage limits in case 44 remain diagnostic output; successful controls are asserted. A passing suite does not mean every animated/periodic scene is safe or supported.

The canonical inputs also run through `ScrollingCaptureEngine`, the production dispatcher, via a test-only observer. The original R7 expectations and known-issue markers remain active. Static and minor-redraw legacy appends compare both outputs byte for byte; the refusal controls additionally prohibit new appends from the dispatcher. The compatibility boundary permits at most two levels per channel in aligned overlap, only after R7 accepts a positive match; pale animation within that boundary retains R7's behavior. Owner pixels remain exact. `DISPATCH` log rows identify the engine, state and output height for every sample. The generated wider-region tests assert every static and video pixel, including one complete video moment, selected start/stop cropping, scrollbar masks, browser chrome, hover, backscroll and recovery. No capture service or panel runs in these tests.
