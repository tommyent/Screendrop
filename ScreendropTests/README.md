# Logic tests

Scrolling Capture frame dumps are opt-in (`ScrollingCaptureTrace` in the app's defaults) and local only: each capture writes its selection crops as PNGs plus `frames.jsonl` and `page.json` under the app's Caches folder in `Screendrop/ScrollingCaptureFrames`, laid out as a corpus page for `scripts/scroll-corpus-run.swift`. They contain screen content.

Scrolling Capture is tested by its corpus run (`scripts/scroll-corpus-run.swift`, outside the test target) plus three tests on the pure functions in `ScrollingOffsetTests`, which use three 600x400 PNG crops of Wikipedia's "Scroll" article (CC BY-SA 4.0) from the scrolling corpus, in `Fixtures/wikipedia-scroll-*.png`. Never commit frames of private captures.

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

`RecordingAgentPromptTests` compiles the production input/transcript schemas, clip timeline, prompt planner and folder writer. It checks cuts and speed, corrected versus recognizer text, cue-only and silent recordings, action grouping, Markdown escaping and legacy decoding. Its disposable red/blue movie checks JPEG pixels, relative links, collision handling, mismatched duration and cancellation cleanup. It does not run speech recognition, the full Studio renderer, Finder or clipboard actions.

The editor tests port `scripts/check-editor-{snapping,fill,interaction,snapping-interaction,viewport,resources}.swift` and the export-only part of `check-editor-snapping-render.swift`. Geometry, pointer state transitions, undo/redo, presets, viewport transforms, caches and export bitmaps run without a view or window. The old windowless canvas-drawing checks and Vision/movie cancellation integration script stay separate: they aren't pure model tests.

Idle saving also has a standalone race harness against the actual app sources, including `AnnotationEditorModel`, the renderer, file transaction and close guard. After a Dev build, pass its DerivedData folder:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  python3 scripts/check-editor-idle-save.py /path/to/DevDerivedData
```

It excludes only `AppEntry.swift`, uses the existing built DockProgress dependency, and verifies Foundation's storage resolves inside a temporary home before creating synthetic captures. It covers crop/undo, image deletion, text/composition and drag gates, coalescing, transaction failure, and close/quit during a delayed render. One AppKit window exercises the close delegate but is never shown or focused. Three 5K background/blur commits provide timings. The runner holds the shared benchmark lock only while executing the checks.

Session snapshot checks cover unedited opens, five-session retention, deduplication, cropped pixels and pasted pictures after restore, Undo/Redo and auto-save in both editors, and Studio soundtrack retention and write failures. Recovery cases include unreadable metadata, failed pruning, error suppression and both saved-open and crash-draft-open sessions during storage failures. Library Trash uses a disposable destination to check that the snapshot folder moves with its capture; no files go to the user's Trash.

