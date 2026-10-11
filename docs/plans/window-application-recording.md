# Plan — Window and application recording

| Field | Value |
| --- | --- |
| Date | 2026-10-11 |
| Source | Conversation and [owner decision record](window-application-recording-grill.md) |
| Flags | none |
| Gates | Grilled and approved by owner; executing coding waves with execute-plan |
| Branch | implement/window-application-recording |
| Base SHA | 3c0b9c67c76ca54622885ac7216f8eea14f1f91a |

## 1. Objective & success criteria

Add two recording modes to ZoomIt for Mac: a single window and a single application on one display. Use Apple's content-sharing picker, menu actions, and derived global shortcuts. Preserve existing screen/region recording, settings, and the editor/save workflow.

The owner explicitly requires zoom/drawing and optional webcam to render onto the isolated target, continuous blank video until manual stop after target disappearance, fixed output dimensions, window movement across monitors, application capture on one selected display, selected-app audio with optional microphone, and XCTest UI automation.

Success means:

1. Record Window… and Record Application… open the real system picker. Defaults are Control+Option+5 and Control+Option+Shift+5. Control+5 and Control+Shift+5 still record screen/region.
2. A window recording excludes other windows, including other windows of the same app. Application mode includes windows and dialogs owned by the selected app on the picker-selected display, including newly opened ones; other apps, desktop, and dock are excluded.
3. Static zoom, live zoom, drawing, text, highlights, undo/erase, and enabled webcam appear in isolated recordings without importing pixels from a display capture. Webcam remains fixed in the video canvas as source content zooms.
4. Moving/resizing a window, including moving to another monitor, preserves fixed MP4 dimensions and aspect ratio with black padding. Application recording remains bound to its selected display.
5. Hidden/minimized/closed/quit/unavailable targets produce black target content on an advancing timeline until Stop Recording or a recording shortcut is used. Hidden content can resume through the same authorization; new windows/processes do not replace a closed target automatically.
6. System audio is limited to the selected app. A single-window video's audio can include other windows of that app, consistent with ScreenCaptureKit; the UI explains this. Optional microphone and webcam keep running while the target is absent.
7. Cancellation, failed startup, rapid repeated actions, system stop, unavailable source, and finalization leave a recoverable UI. Stop opens the existing editor and save panel once; cancel cleans resources and temporary files.
8. Self-tests and native UI tests pass, and exported video/audio checks establish actual content isolation, duration, overlays, and output dimensions. Both distribution compiler variants build and pass their tests.

## 2. Context & constraints

### Repository evidence

| Surface | Evidence | Implication |
| --- | --- | --- |
| Command contract | `Sources/ZoomItMacCore/Core/AppCommand.swift:20` | Replace the recording Boolean with a four-case scope and update all callers together. |
| Hotkeys | `Sources/ZoomItMacCore/Hotkeys/HotkeyService.swift:131`, `:233`, `:370` | Add two registrations, dispatch IDs, teardown, and modifier/conflict handling. |
| Settings | `Sources/ZoomItMacCore/Settings/SettingsWindowController.swift:780`, `:944`, `:1423`; `SettingsStore.swift:147` | Update shortcut validation and recording guidance without resetting user preferences. |
| Menu | `Sources/ZoomItMacCore/App/AppDelegate.swift:168`; `AppController.swift:51` | Add target-picker actions and an explicit stop action with useful state. |
| Recording startup | `Sources/ZoomItMacCore/Capture/RecordingController.swift:744`, `:759`, `:860` | Existing capture is display-dependent; target acquisition and configuration must become mode-specific. |
| Frame delivery | `RecordingController.swift:527`, `:549`, `:915` | Current output ignores non-complete frames, conditionally substitutes screen overlays, and lacks a stream delegate. |
| Writer | `RecordingController.swift:48`, `:87`, `:184` | Reuse H.264/MP4 and audio writing, with fixed dimensions, one timebase, and serialized appends. |
| Final frame | `RecordingController.swift:1027`, `:1051` | Current full-display fallback cannot be used for isolated modes. |
| Overlay entry points | `Sources/ZoomItMacCore/Core/ModeCoordinator.swift:188`, `:235`, `:305`, `:403`, `:463` | Static/live/draw activation must select an isolated source while these recording modes are active. |
| Overlay geometry | `Sources/ZoomItMacCore/Overlay/OverlayWindowController.swift:27`, `:151`; `ZoomCanvasView.swift:135`, `:836`; `ZoomViewportController.swift:70` | Canvas dimensions and cursor mapping currently assume a display screenshot. Separate source geometry from host display geometry. |
| Annotation rendering | `Sources/ZoomItMacCore/Annotations/AnnotationController.swift:21`, `:188` | Reuse annotation snapshots and rendering semantics, including in-progress strokes and highlight layering. |
| Webcam | `Sources/ZoomItMacCore/Capture/WebcamOverlayController.swift:5`; `RecordingController.swift:937` | Webcam composition exists, but coordinate mapping must work with a target canvas and fixed output. |
| Sibling feature | `Sources/ZoomItMacCore/Capture/DemoMirrorController.swift:335`, `:474` | Independent-window filters are already used. Its on-screen-only polling conflates hidden and closed targets and must not be copied unchanged. |
| Permissions | `Sources/ZoomItMacCore/Permissions/PermissionService.swift:100` | Existing screen capture preflight does not establish whether an OS-picked filter can capture with its own authorization. |
| Tests/build | `Package.swift:6`; `SelfTest/SelfTestRunner.swift:30`, `:646`; `Scripts/build-app.sh:47` | Minimum macOS 14, SwiftPM, no XCTest UI project, separate contributor bundle identity, two distribution variants. |

### Platform evidence and compatibility

The installed Xcode SDK declares picker modes, picker observers, filter style/contentRect/pointPixelScale, aspect preservation, and relevant stream status APIs on macOS 14. Filter `includedWindows`, `includedApplications`, and `includedDisplays` are only available from macOS 15.2. Do not make those properties mandatory or raise the deployment target.

Use the actual authorized filter supplied by the [system picker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker). Its window/application modes and exclusions are configured per request. [Apple's filter documentation](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) distinguishes independent-window capture from display-bound app filtering. [Apple's capture walkthrough](https://developer.apple.com/videos/play/wwdc2022/10155/) describes app-wide audio, newly created app windows, and fixed output scaling.

XCTest supports launching an installed macOS app by [bundle identifier](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/init%28bundleidentifier%3A%29) or URL. That establishes a testing route, but does not prove the system picker's accessibility tree on every supported OS.

No runtime capture or UI-automation spike has been executed for this plan. The local toolchain reports Swift 6.4 / arm64 macOS. Runtime compatibility and permission checks are explicit implementation gates below. No source files have been changed.

## 3. Approach & key decisions

### A. Mode and target contracts

Add `RecordingScope: Equatable` with `.screen`, `.region`, `.window`, `.application`. Migrate `AppCommand.toggleRecording(region:)` to `toggleRecording(scope:)` in the same integration wave as its callers. `RecordingController.toggle(scope:onStateChange:)` remains the single recording start/stop entry point; any recording shortcut stops an active recording. Menu Stop Recording never initiates selection.

Introduce these internal contracts in the foundation wave:

- `RecordingCanvasGeometry`: fixed output pixel size, logical source canvas, aspect-fit rectangle, host-display placement, and invertible content/view/global coordinate transforms. Output dimensions are positive even integers; filter geometry and scale are validated before writer creation.
- `RecordingSourceFrame`: immutable isolated image and frame metadata, host-clock presentation time, source availability, and a session generation. Never contains a display screenshot for isolated scopes.
- `RecordingOverlaySnapshot`: source-relative viewport, frozen target image when static/draw requires it, annotation snapshots including in-progress work, typing/cursor state, optional sketch-pad fill, and a session generation.
- `RecordingSessionState`: idle → selecting → starting → recording (available or unavailable) → stopping → editing/saving → idle. Failure before recording returns to idle; writer failure during recording enters finalization/error. Selection cancellation is not a recording or an editor launch.
- `RecordingFrameRenderer`: renders an authorized target image or black base, then viewport transformation and annotations, then optional webcam in output coordinates. It never calls screen capture.

Keep framework filter references on the capture side rather than embedding them in pure geometry/annotation values. Use explicit actor/queue ownership and audited immutable image wrappers; do not pass mutable AppKit views into capture callbacks.

### B. Native picker and authorization

Create `RecordingPickerController`, an NSObject observer wrapper for the shared picker. Restrict allowedPickerModes to singleWindow or singleApplication, exclude ZoomIt's bundle/windows, and set allowsChangingSelectedContent=false for the recording session. Multiple windows/apps are not selectable. Verify the returned style matches the requested scope.

Own observer registration, picker configuration, session generation, and cleanup for the full recording session. Forward callbacks to the main actor; reject duplicate/stale results and results associated with another stream. Cancel closes selection cleanly; a second start request while selecting cannot create a second writer. Do not globally disable the shared picker while another component owns it.

For these modes, attempt OS picker authorization rather than requiring full-display preflight before presenting it. Screen/region retain their current gate. Required startup compatibility checks cover selection, authorized stream creation, optional filtered screenshots if used, and cancellation with Screen Recording permission granted and absent. Never fall back to full-display capture on an authorization failure.

Treat the picker filter as authoritative on macOS 14. Use its geometry, shareable-content information, and frame metadata without guessing a target from matching rectangles. Use newer target identity metadata only behind availability checks. Application capture must remain bound to the display selected by the picker; on newer systems validate a single included display. On macOS 14 verify the picker/stream behavior with fixture apps on two displays before accepting the implementation. If it cannot express the required policy, stop at that compatibility gate and report the concrete limitation; silently widening capture or changing minimum OS is not allowed.

### C. Fixed video canvas and independent timeline

Choose output dimensions once from the selected filter's logical content size and pixel scale. Window capture uses an independent-window filter so movement across displays does not change target identity. Aspect-fit each subsequent source frame into that fixed canvas, with black padding; application mode uses the full selected display's filtered composition, not a union crop that jumps as windows open.

Use one monotonic host-clock timeline for screen frames, repeated idle frames, black frames, rendered overlays, webcam, and optional microphone. Target cadence is 30 fps, matching the existing recording configuration when overlays are enabled. Retain only the latest source frame and one pending composition; keep writer/capture queues bounded (existing queueDepth=5). Drop obsolete source updates under load rather than queueing full-resolution images without a limit.

A scheduled isolated-mode frame pump is independent of SCStream callbacks. Complete frames update the source; idle status means unchanged content and keeps the current isolated frame. Blank/suspended/stopped statuses and terminal source errors invalidate it and schedule black target frames. An idle stream alone must not be treated as disappearance: a stationary window can remain idle indefinitely. Record stream availability changes on supported newer OS versions, and validate macOS 14 status/error delivery in the compatibility checks.

When the authorized source returns from hiding/minimization, use complete frames from that same stream/filter. After closure/quit, remain black until manual stop; do not retarget by title, bundle ID, or a recycled window ID. If the stream terminates, release that source stream but retain the frame pump, writer, selected microphone, webcam, and explicit recording status. A genuine writer error cannot be masked by endlessly writing black frames.

Source disappearance clears frozen source imagery and suppresses old annotations in the output. Black content is padded/composited with enabled webcam, and optional microphone continues. This resolves the intersection of the owner's continued-blank-recording and webcam decisions; it is a reversible implementation default.

### D. Zoom, drawing, typing and webcam on isolated content

Extract common canvas rendering from the current display-based view into `ZoomCanvasRenderer` and share existing annotation drawing code through `AnnotationRenderer`. Keep highlight layering, shapes, text/font choices, cursor/caret rendering, and sketch-pad behavior consistent; avoid a second divergent annotation renderer.

Separate the image's logical canvas and scale from the display that hosts the interactive overlay. Extend viewport/view/controller APIs additively for explicit content geometry; existing screen/region callers retain their defaults. Cursor conversion and pan bounds use this geometry instead of assuming image coordinates equal display coordinates.

While an isolated recording is active, existing static/live zoom and draw commands show the isolated canvas fitted to the interactive display. Static zoom/draw freeze only the current isolated frame while the source remains available; live zoom consumes the newest isolated frame. Pointer input maps into the fixed logical source canvas. Annotations remain in those canvas coordinates when the source resizes or moves. Padding and outside-target gestures are clipped; no neighboring screen content is sampled.

The recorder consumes a render-state snapshot, not a screenshot of the host overlay or full desktop. Full-screen interactive presentation may show a larger fitted target; the exported video uses its fixed canvas and the same viewport/annotation transforms. Captured source pixels never contain ZoomIt's presentation overlay, avoiding feedback regardless of sharingType behavior.

Before showing a target picker, dismiss any existing screen overlay and reset its annotations. During isolated recording, source activation, static snapshots, live updates, viewport snips/copy/save, and final-frame generation route to isolated content; none calls `captureDisplayForOverlay` or the screen LiveCaptureSession. Escape dismisses zoom/draw presentation and retains recording, matching the app's separate recording lifecycle.

Map webcam placement to normalized output coordinates after all source zoom/annotation transforms. Its on-screen draggable view maps through the presentation geometry, remains fixed in output size/position, and stays composited even when there is no zoom overlay or the source is blank. Preserve current screen/region webcam behavior. Optional camera denial produces a visible mode-appropriate explanation and a recording without webcam, following existing optional-device policy.

### E. Audio, stop and cleanup

Enable ScreenCaptureKit audio on the same selected-target filter. Do not create an unfiltered audio stream. Single-window audio is selected-app audio, not guaranteed window-specific audio. Reuse the existing optional microphone selection/noise settings and explain the scope in recording Settings/README.

For isolated modes, replace the stop-time display screenshot with the last correctly composed isolated frame or black frame at the session's final timestamp. Finalization must not resurrect a hidden/closed target image. Ensure the fallback movie writer also uses only isolated frames or black; test both no-first-frame and writer-failure paths. Screen/region retain their established final-frame behavior.

Manual stop atomically stops the frame pump, prevents new appends, drains pending work, stops native streams/devices, finalizes the writer once, and launches the editor once. Stream source errors do not invoke this manual-stop path automatically. Handle system withdrawal of sharing as source unavailability with an explicit status label and usable Stop Recording.

Session generations prevent pending picker results, scheduled renders, and completion callbacks from leaking into the next recording. Every cancellation/error/stop path removes observers, pending work, selectors, borders, webcam, timers and temporary resources it owns. Editor/save cancellation preserves current cleanup behavior; save errors stay visible.

### F. Entry points, shortcuts and persisted settings

Add menu actions for Record Region…, Record Window…, Record Application…, and Stop Recording alongside Record Screen. Show recording/selection/finalization state and disable competing starts while selection/start/finalization is in progress. Keep Stop Recording usable while the source is unavailable. Add accessibility identifiers to the new actions, recording indicator/status, overlay, and relevant editor controls.

Derive all four recording shortcuts from the stored recording key/modifiers using XOR for Shift/Option, consistent with the existing Shift variant: base=screen, Shift=region, Option=window, Shift+Option=application. This produces the requested default shortcuts and four distinct combinations even for customized bases.

Introduce a shared binding map so registration and Settings collision checks see effective bindings, including other features' modifier variants. On edit, reject an assignment that collides with an existing feature and show the exact conflicting action. On loading existing preferences, preserve existing registered actions and skip conflicting newly introduced variants with an actionable Settings message; menu actions remain usable. Check registration errors instead of implying a global shortcut was registered successfully.

Do not add persisted target IDs or automatically record the last app/window. No settings schema migration is required; comments/help and derived shortcut descriptions change, while user values and defaults remain intact.

### Alternatives rejected

- Cropping a display to a window: exposes overlapping content, fails cross-monitor following, and violates target isolation.
- Including ZoomIt's overlay windows in an app filter: imports presentation pixels and risks feedback; the owner requested direct isolated rendering.
- Reusing a screen-overlay snapshot or display screenshot as fallback: can expose unrelated content on stop or target loss.
- Automatically stopping on window close: contradicts the owner's explicit blank-until-stop decision.
- Replacing the target after close/quit: changes authorization and target identity without a new selection.
- Changing writer dimensions on resize: conflicts with a fixed MP4 video track.
- Mock-only picker tests/manual-only e2e: does not satisfy the owner's XCTest UI choice.
- Multi-display application composition, multiple apps/windows, and broad editor/DemoMirror refactors: separate features.

## 4. Work breakdown — implementation tasks

Each path in a row is owned only by that task within its wave. Directory prefixes below are exact path prefixes, not permission to edit arbitrary sibling files. Test IDs in section 5 are validation responsibilities of these tasks, not additional competing writers.

| ID | Goal | Owned files | Depends on | Acceptance |
| --- | --- | --- | --- | --- |
| I1 | Add scope, geometry, session/timeline contracts and shared rendering primitives with deterministic self-tests | `Sources/ZoomItMacCore/Core/RecordingScope.swift`; `Sources/ZoomItMacCore/Capture/RecordingCanvasGeometry.swift`; `Sources/ZoomItMacCore/Capture/RecordingSessionState.swift`; `Sources/ZoomItMacCore/Capture/RecordingFrameRenderer.swift`; `Sources/ZoomItMacCore/Overlay/ZoomCanvasRenderer.swift`; `Sources/ZoomItMacCore/Annotations/AnnotationRenderer.swift`; `Sources/ZoomItMacCore/Annotations/AnnotationController.swift`; `Sources/ZoomItMacCore/SelfTest/RecordingSelfTests.swift`; `Sources/ZoomItMacCore/SelfTest/SelfTestRunner.swift` | None | Additive contracts compile; existing annotation behavior passes; pure geometry, renderer, state transitions and monotonic timeline tests run without permissions. |
| I2 | Introduce a native XCTest project, fixture apps and OS compatibility probe | `Tests/RecordingUI/RecordingUI.xcodeproj/project.pbxproj`; `Tests/RecordingUI/RecordingUI.xcodeproj/xcshareddata/xcschemes/RecordingUI.xcscheme`; `Tests/RecordingUI/RecordingUI.xcodeproj/xcshareddata/xcschemes/RecordingUIAppStore.xcscheme`; `Tests/RecordingUI/HostInfo.plist`; `Tests/RecordingUI/FixtureInfo.plist`; `Tests/RecordingUI/PickerProbeApp.swift`; `Tests/RecordingUI/FixtureApp.swift`; `Tests/RecordingUI/HarnessSmokeTests.swift`; `Tests/RecordingUI/PickerCompatibilityTests.swift`; `Tests/RecordingUI/Support/NativePickerDriver.swift`; `Tests/RecordingUI/Support/TestEnvironment.swift`; `Scripts/test-recording-ui.sh` | None | Shared schemes run; fixture apps have distinct IDs and predictable windows/audio; real picker selection/cancel, filter isolation, fixed-display app capture, idle/hidden/closed status delivery and authorization are measured. XCTest interacts with the system picker instead of bypassing it. |
| I3 | Integrate authorized target capture, paced composition, absent-source recording and safe finalization | `Sources/ZoomItMacCore/Capture/RecordingController.swift`; `Sources/ZoomItMacCore/Capture/RecordingPickerController.swift`; `Sources/ZoomItMacCore/Capture/RecordingSourceSession.swift`; `Sources/ZoomItMacCore/Capture/WebcamOverlayController.swift` | Wave 1 | Four scopes work through one lifecycle; isolated modes never capture a display fallback; app audio remains filtered; generation guards, blank frames, webcam and microphone continue correctly; editor/save finalization is exactly once. |
| I4 | Route overlay controls and view geometry to the selected isolated source | `Sources/ZoomItMacCore/Core/AppCommand.swift`; `Sources/ZoomItMacCore/Core/ModeCoordinator.swift`; `Sources/ZoomItMacCore/App/AppController.swift`; `Sources/ZoomItMacCore/Overlay/OverlayWindowController.swift`; `Sources/ZoomItMacCore/Overlay/ZoomCanvasView.swift`; `Sources/ZoomItMacCore/Overlay/ZoomViewportController.swift` | Wave 1 | All commands use RecordingScope; static/live/draw/typing use isolated source and shared renderer; cursor, padding, annotations and webcam align; screen/region/normal overlay behavior passes existing tests. |
| I5 | Wire menus, recording status, configurable shortcut variants and collision handling | `Sources/ZoomItMacCore/App/AppDelegate.swift`; `Sources/ZoomItMacCore/Hotkeys/HotkeyService.swift`; `Sources/ZoomItMacCore/Hotkeys/HotkeyBindings.swift`; `Sources/ZoomItMacCore/Settings/SettingsWindowController.swift`; `Sources/ZoomItMacCore/Settings/SettingsStore.swift` | Wave 1 | Menus/shortcuts reach every scope; unavailable recordings expose Stop; selectors match I4's pinned contract; old preferences remain intact and new shortcut conflicts are explicit. |
| I6 | Complete integration/self-tests and native recording UI/output coverage | `Sources/ZoomItMacCore/SelfTest/SelfTestRunner.swift`; `Sources/ZoomItMacCore/SelfTest/RecordingSelfTests.swift`; `Sources/ZoomItMacCore/SelfTest/RecordingIntegrationSelfTests.swift`; `Sources/ZoomItMacCore/SelfTest/RecordingOverlaySelfTests.swift`; `Sources/ZoomItMacCore/SelfTest/RecordingHotkeySelfTests.swift`; `Tests/RecordingUI/RecordingUITests.swift`; `Tests/RecordingUI/Support/VideoAssertions.swift`; `Tests/RecordingUI/Support/AudioAssertions.swift`; `Tests/RecordingUI/Support/NativePickerDriver.swift`; `Tests/RecordingUI/Support/TestEnvironment.swift`; `Tests/RecordingUI/RecordingUI.xcodeproj/project.pbxproj`; `Sources/ZoomItMacCore/Capture/VideoClipEditorController.swift` | Wave 2 | Required cases in section 5 pass and fail for deliberately broken behavior; only accessibility identifiers/labels are added to editor controls; no weakening/skipping of required flows. |
| I7 | Document behavior, permissions, automation setup and acceptance matrix | `README.md`; `docs/testing/window-application-recording.md` | Wave 2 | Docs describe actual modes, shortcuts, isolated overlays, app-wide audio, blank behavior, fixed dimensions, test commands and prerequisites. |

### Pinned Wave 2 integration interfaces

I3 provides `toggle(scope:onStateChange:)`, `stopIfRecording()`, an isolated-source snapshot accessor, and main-actor callbacks for source availability, capture geometry, latest isolated frames and recording state. I4 owns mode-specific render-state snapshots and supplies them to I3's compositor. I3 never reaches into AppKit canvas views.

I4 adds `AppController` selectors `toggleRecording`, `toggleRecordingRegion`, `toggleRecordingWindow`, `toggleRecordingApplication`, and `stopRecording`; these dispatch only to ModeCoordinator. I5 references exactly these selectors and four RecordingScope cases. I3 exposes read-only state sufficient for selecting/starting/recording/unavailable/finalizing status through callbacks; I5 does not depend on private booleans.

Agree concrete parameter structs from I1's contracts at the Wave 1 barrier before parallel work begins. Do not invent different APIs in each task or commit a half-migrated command enum. Implementation/tests that need to alter a file owned by a sibling must route the change to that owner or a later serialized fix task.

## 5. Work breakdown — test tasks

| ID | Layer | Covers | Owned test files / implementation owner | Acceptance |
| --- | --- | --- | --- | --- |
| U1 | Unit/self-test | I1 | `RecordingSelfTests.swift`, runner registration; I1 | Valid/invalid geometry, even dimensions, aspect-fit padding, coordinate round-trips, frozen/live source policy, unavailable source overriding frozen images, blank/webcam layering, annotation/text/highlight equivalence, monotonic timestamps and session-generation rejection. |
| C1 | Native compatibility | I2 | `PickerCompatibilityTests.swift`, `HarnessSmokeTests.swift`, probe/fixture support; I2 | Native picker UI can be driven; window/app filters remain isolated; one-display application policy holds; cancellation/permission outcomes and native absent-target status behavior are recorded on supported OS versions. |
| U2 | Integration/self-test | I3–I5 | `RecordingIntegrationSelfTests.swift`, `RecordingOverlaySelfTests.swift`, `RecordingHotkeySelfTests.swift`, `RecordingSelfTests.swift`, runner registration; I6 | Fake source/writer/clock exercise complete-idle-hidden-close-error-stop transitions, no display fallback at any phase, no stale frames after unavailability, exactly-once finalization, annotations/webcam alignment, audio scope configuration, collision checks in both directions, old preferences and all dispatch routes. |
| E1 | Native XCTest UI/e2e | I3–I5 | `RecordingUITests.swift`, `NativePickerDriver.swift`, `TestEnvironment.swift`, `VideoAssertions.swift`, `AudioAssertions.swift`; I6 | Real picker → active recording → target changes → stop → editor → export/save/cancel produces files with the expected content and behavior. |

### Native project and fixture design

Add a small committed Xcode project solely for the XCTest UI runner, standalone picker probe and fixture apps. Launch the actual ZoomIt bundle by URL through XCUIApplication; build it with the existing `Scripts/build-app.sh` using a dedicated identity and app name. Keep production SwiftPM/build scripts intact. RecordingUIAppStore runs the same tests against a bundle built with `ZOOMIT_DISTRIBUTION=appstore`, so the existing build script applies `ZOOMIT_APP_STORE` to the complete package and uses the sandbox entitlements. Do not rely on an Xcode app-target compiler define propagating to a Swift package dependency. Use separate test identities such as `com.sysinternals.zoomitmac.recordingtests.homebrew` and `.appstore`, privacy usage descriptions and matching distribution entitlements. The preflight verifies it launches the requested test bundle and distribution rather than an installed official app.

Build two fixture app targets from FixtureApp.swift with distinct bundle IDs. Target app A provides identifiable colored/patterned windows, a child dialog, buttons to open/close/minimize/resize windows, and deterministic test tone playback. App B provides an overlapping forbidden-content marker and a different test tone. UI tests control the fixture apps through real accessibility elements. The native picker probe is a separate test app that uses real SCContentSharingPicker/SCStream APIs to settle compatibility before integration.

Use exported MP4 sampling via AVAssetReader/AVAssetImageGenerator. Check first/middle/last frames and segments around target disappearance, not merely file existence. Assert required marker regions with tolerant pixel thresholds after H.264 encoding; avoid screenshot-golden tests sensitive to theme/fonts. Assert output size and elapsed recorded duration including the blank tail. Audio assertions analyze fixture tone frequencies so app B's tone cannot leak into selected-app audio. Core composition tests inject a known webcam image without hardware; real camera/microphone scenarios require configured test devices and are identified in the manual matrix when hardware is absent.

### Required UI scenarios

- Window and application selection through the real picker, picker cancellation, retry after cancellation, and duplicate hotkey/start attempts while selecting/starting.
- Window mode excludes the target app's second window and app B's overlapping marker. App mode includes app A's second/new windows and child dialog on the selected display, while excluding app B.
- Static zoom, live zoom, draw-only, typing/highlights/undo/erase, and zoom transitions are visible in exported isolated video. Begin selection with an existing screen overlay and verify its pixels/annotations are absent.
- Resize and move the target while recording. Check aspect preservation and fixed dimensions, including negative-origin/mixed-scale displays where available. Two-display fixture tests prove window following and app capture staying on its original display.
- Minimize/hide, restore, close target window, and quit target app. The app remains recording and the saved clip includes a timed black target segment until explicit stop; no previous frozen content survives unavailability. Reopening the app/window does not silently change the selected target.
- Selected-app audio contains only app A's test tones. Window mode documents/accepts app A's other-window audio. Optional microphone and webcam composition stay aligned with the fixed canvas and blank tail.
- Stop via base recording hotkey, each derived mode hotkey, menu Stop Recording, and OS withdrawal of source sharing followed by manual Stop. Only one editor/save flow opens.
- Trim/export/save, editor cancel, save-panel cancel, zero-source-frame clip, repeat recordings, and regular screen/region regression flows. Expected permission denial must be visible and leave a usable app.

E2e applies because this is a user-facing OS capture, device/audio, encoding and filesystem flow. It is required by the owner's explicit testing choice; no no-e2e flag is active.

### Run recipe

Existing noninteractive checks at each implementation barrier:

```sh
swift build
swift run ZoomItMacSelfTest
swift build -Xswiftc -DZOOMIT_APP_STORE
swift run -Xswiftc -DZOOMIT_APP_STORE ZoomItMacSelfTest
```

New planned commands, implemented by I2:

```sh
zsh Scripts/test-recording-ui.sh --preflight
zsh Scripts/test-recording-ui.sh --compatibility
zsh Scripts/test-recording-ui.sh --distribution homebrew
zsh Scripts/test-recording-ui.sh --distribution appstore
```

The wrapper builds only dedicated test apps/fixtures. For the real recorder it invokes `Scripts/build-app.sh` with explicit `ZOOMIT_DISTRIBUTION`, `ZOOMIT_BUNDLE_ID`, `ZOOMIT_DISPLAY_NAME` and `ZOOMIT_APP_NAME` values for that variant, without changing those variables globally. It registers the resulting bundle and passes its absolute URL to the UI tests. It runs `xcodebuild test -project Tests/RecordingUI/RecordingUI.xcodeproj -scheme RecordingUI -destination 'platform=macOS' -parallel-testing-enabled NO -resultBundlePath <unique-run-path>`, selecting RecordingUIAppStore for the sandbox variant. It uses a unique artifact directory under `.build/recording-ui/`, waits for fixture readiness, and tears down test-owned processes. It never terminates an installed official ZoomIt or resets its TCC records.

Prerequisites: full Xcode with UI testing tools; an unlocked logged-in macOS desktop; permission for the dedicated recorder/test runner to capture and automate the UI; a deterministic test language for system picker labels; no competing session using global test hotkeys. Native UI tests run serially. First setup may require granting OS privacy/automation permission through system UI; tests cannot silently grant TCC or modify its database. A missing permission is a failed preflight with exact remediation, not a passed or skipped required test.

Run core required flows on macOS 14 and the current supported macOS. Two-display cases require a real or supported virtual second display and must be recorded as pending if unavailable, not reported passed. No user accounts, external services, network credentials or production data are needed. Camera/microphone device checks are supplementary to deterministic compositing/audio tests and have explicit hardware prerequisites.

Native picker accessibility is a Wave 1 gate. If the system picker cannot be automated with public XCTest/accessibility APIs on an OS in the matrix, capture the UI tree/failure evidence and revise that test driver within I2. A mocked picker or a silent substitution of manual tests does not satisfy the plan.

## 6. Execution waves

| Wave | Tasks | Barrier |
| --- | --- | --- |
| 1 — contracts and feasibility | I1 and I2 may work independently in parallel | Both compiler variants build; existing and new foundation self-tests pass; XCTest fixture/host smoke and native compatibility checks pass on the available desktop. Record remaining OS/display environments honestly. Resolve any incompatible core API/picker assumptions before full integration. |
| 2 — complete feature integration | I3, I4 and I5 may work in parallel against the pinned interfaces | Whole command/caller migration lands together, all builds/self-tests remain green, native picker can record through editor/save, and target isolation/blank tail are checked. No task commits a broken intermediate command contract. |
| 3 — full verification and docs | I6 and I7 may work in parallel | Full self-tests and both native UI schemes pass; exported content/audio assertions pass; manual hardware/display matrix is recorded; docs match final behavior. Review must-fixes receive a serialized follow-on fix wave and appropriate reruns. |

Checkpoint each completed green wave. Never advance past a failing compatibility gate by deleting assertions or dropping requested behavior. Source integration in Wave 2 is one combined barrier; individual in-progress branches need not independently compile against partially landed APIs. No knowingly red checkpoint is planned.

Owned paths are disjoint within every wave. Paths repeated across waves (self-test runner, foundation tests, picker driver/test environment, test project) are intentionally sequential. No simultaneous task owns a package manifest, common project file or shared registry. I2 adds only existing smoke/probe files to the project in Wave 1; I6 adds the full recording tests in Wave 3. Do not create missing-file build references or placeholder test implementations at the first barrier.

## 7. Blast radius & risks

- **Overlay geometry is the largest source risk.** Current cursor anchoring, image scaling and annotations assume a whole display. Add explicit geometry with existing defaults and cover target canvases and legacy display canvases before wiring activation.
- **Privacy includes first/last/error frames.** It is insufficient to filter only the normal stream. All screen-based snapshots, cached overlay substitutions, static freezes, webcam mapping and writer fallbacks must be examined by tests.
- **Blank recording is a timeline change.** Current callbacks deliver only complete frames. The new pump must own duration during prolonged inactivity/closure, keep microphone synchronized, and stop once. A source becoming unavailable must not be confused with a writer failure.
- **Native picker opaque metadata on macOS 14.** Preserve the authorized filter; do not infer identity from window position. Native status delivery, app display binding and restoration behavior need the compatibility probe and oldest-supported-OS acceptance.
- **UI automation is OS-sensitive.** Its first implementation wave owns the native probe and driver. Preflight, public accessibility inspection, bounded waits, result bundles and stable fixture markers make failures diagnosable. Proving current-OS automation is not proof of macOS 14 automation.
- **Existing customized hotkeys may collide.** Registration/Settings must share the same binding model, preserve existing actions, and provide menu access if a new variant cannot register.
- **Performance and memory.** Full-size source plus overlay/webcam composition is more expensive than forwarding buffers. Use 30-fps pacing, cached render resources and bounded pending work; inspect five-minute 4K recording for growth, timestamp discontinuity and accumulating frame backlog. Do not claim a CPU guarantee before measurement.
- **Sandbox variant.** Test filtered capture, camera/mic options, the editor and user-selected export paths in the real sandbox scheme. Do not solve this feature by adding unrelated entitlements or permission bypasses.

No database, network API, external data migration, dependency upgrade or remembered-target migration is needed. Additive source/geometry primitives retain legacy behavior. No feature flag is needed for this local additive feature; rollback removes the new modes, target pump/render path and test harness changes while preserving existing user preference values and MP4s. No deployment, publishing or merge is part of this planning request.

## 8. Open questions / assumptions

No product question from the grill remains unanswered. The owner approved this plan and invoked execute-plan. This run writes the implementation and test code, with compile sanity checks; runtime verification and review remain separate phases of that skill.

Reversible defaults for review:

- The interactive isolated overlay displays the selected source canvas on the current presentation display, while the video follows the selected window independently across monitors. Application output remains on the picker-selected display.
- Static zoom/draw freeze the isolated target like the existing app, while live zoom updates. Source loss overrides frozen imagery and visible target annotations.
- Blank target frames may contain the enabled webcam; optional microphone continues. No stale annotations/frozen target image appear on the black base.
- Existing annotations are cleared before target selection; annotations created during recording are anchored in fixed logical canvas coordinates through resizing.
- New derived shortcuts toggle Shift/Option and retain existing-custom-binding precedence on upgrade. Their actual combinations are shown in Settings.
- One active recording/picker selection at a time. Changing recording target requires stopping and choosing again.
- Native compatibility checks are required on macOS 14 and current macOS, with second-display/hardware cases identified as pending until their environments are available.

Runtime unknowns are technical verification work assigned to I2/I3/I6, not owner-deferred scope: system picker automation/accessibility, picker-only authorization, unavailable-source status delivery, and app capture's single-display binding on macOS 14. If a constraint prevents the chosen behavior, present the exact evidence and the concrete alternative for owner review; never silently change the agreed behavior.

## 9. Completeness ledger

| Item | Disposition | Task ID / reason |
| --- | --- | --- |
| Scope enum and every command/caller | In this run | I1, I3, I4, I5 |
| Native window/app picker and ZoomIt exclusions | In this run | I2, I3 |
| macOS 14 availability, opaque filters, authorization and status delivery | In this run | I2, I3, I6 |
| Menu actions, explicit stop/status and keyboard dispatch | In this run | I4, I5 |
| Derived hotkeys, registration failures, bidirectional conflict checks and persisted users | In this run | I5, I6 |
| Fixed geometry, padding, cursor transforms and cross-monitor window movement | In this run | I1, I3, I4, I6 |
| Application windows/dialogs/new windows on one selected display | In this run | I2, I3, I6 |
| Static/live/draw/typing, highlights, undo/erase and sketch pads | In this run | I1, I4, I6 |
| Overlay activation before/after recording, screenshots/snips while isolated, and feedback prevention | In this run | I3, I4, I6 |
| Frozen-frame invalidation and source generation guards | In this run | I1, I3, I4, I6 |
| Blank-frame timeline during hidden/closed/quit/system source stop | In this run | I1, I3, I6 |
| Selected-app audio and optional microphone/noise settings | In this run | I3, I5, I6 |
| Fixed webcam composition and drag mapping, including blank source | In this run | I1, I3, I4, I6 |
| Safe final frame and all writer fallback paths | In this run | I3, I6 |
| Cancellation, duplicate selection/start, error handling and resource cleanup | In this run | I1, I3, I5, I6 |
| Existing editor, export/save/cancel and repeat recording | In this run | I3, I6 |
| Legacy screen/region and normal overlay regression checks | In this run | I1, I3, I4, I5, I6 |
| XCTest project, real picker driver, fixture apps, capture/video/audio assertions and test runner | In this run | I2, I6 |
| Both compiler/distribution variants and oldest/current OS matrix | In this run | I2, I6, I7 |
| README and permission/test/acceptance documentation | In this run | I7 |
| Multiple selected apps or arbitrary multiple windows | Out of scope | Different capture-selection features; owner selected one window/app per recording. |
| Combining application windows across monitors | Out of scope | Owner selected one-display application mode. |
| Remembering targets or switching targets mid-recording | Out of scope | Separate selection/persistence behavior; fresh explicit selection is required. |
| DemoMirror behavior changes and general editor refactoring | Out of scope | Sibling features; only necessary editor accessibility identifiers are included. |
| CI provider setup, publishing, deployment and merging | Out of scope | Separate delivery actions; local runnable XCTest commands are included. |

There is no owner-deferred remainder.

## Execution log

- Baseline: only the two planning documents were untracked; no pre-existing source changes.
- Owner invoked execute-plan on the approved plan. Coding and test-harness implementation are included; full test execution/review are separate, as required by that explicitly invoked skill. Runtime gates are recorded as unverified rather than silently claimed green.

### Wave 2 concrete interfaces

- `RecordingController.sessionState: RecordingSessionState` (read-only), `isolatedGeometry: RecordingCanvasGeometry?`, `isolatedSourceFrame: RecordingSourceFrame?`, `isolatedGeneration: UInt64`, `isIsolatedRecording: Bool`.
- `RecordingController.toggle(scope:onStateChange:)`, `stopIfRecording()`. Retain the existing Boolean toggle only as a temporary compatibility wrapper until command migration lands.
- `RecordingController.isolatedOverlaySnapshotProvider: (@MainActor @Sendable () -> RecordingOverlaySnapshot?)?`.
- `RecordingController.onIsolatedSourceChanged: (@MainActor (RecordingSourceFrame?, RecordingCanvasGeometry?, UInt64) -> Void)?`; `onSessionStateChanged: (@MainActor (RecordingSessionState) -> Void)?`.
- `ModeCoordinator.recordingSessionState: RecordingSessionState` and `onRecordingSessionStateChanged: ((RecordingSessionState) -> Void)?` forward recording state. `AppController.recordingSessionState` forwards the same query for menu validation.
- AppController selector names: `toggleRecording`, `toggleRecordingRegion`, `toggleRecordingWindow`, `toggleRecordingApplication`, `stopRecording`.
- I4 owns geometry-aware overlay/view/viewport APIs and the snapshot provider. I3 owns isolated source delivery and output timing. I5 observes/query state through ModeCoordinator/AppController and owns menu/hotkey dispatch.

- Wave 1 completed: I1 (foundation agent) and I2 (ui_harness agent); standard and App Store `swift build` passed; XCTest `build-for-testing` passed; script/plist/project syntax checked. No runtime suites executed.
