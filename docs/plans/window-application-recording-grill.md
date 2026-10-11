# Grill — Window and application recording

| Field | Value |
| --- | --- |
| Date | 2026-10-11 |
| Source | Conversation: investigate existing window/application recording, then plan implementation and grill owner |
| Mode | Interactive; answered by owner in conversation |
| Flags | none |
| Status | Product decisions settled; implementation plan prepared for review |

## Grounded findings

- Current command has only a region Boolean: `Sources/ZoomItMacCore/Core/AppCommand.swift:20`. Calls propagate through `Hotkeys/HotkeyService.swift:131`, `App/AppController.swift:51`, and `Core/ModeCoordinator.swift:463`.
- Recording chooses the active display under the cursor and optionally a dragged rectangle: `Capture/RecordingController.swift:759`. It uses a display filter and `sourceRect`, not an isolated target: `Capture/RecordingController.swift:860`.
- Recorder's overlay callback can replace captured frames with a screen overlay image: `Capture/RecordingController.swift:527`, `Core/ModeCoordinator.swift:466`. Isolated recordings cannot reuse this blindly.
- Stop appends a display screenshot: `Capture/RecordingController.swift:1027`, `Capture/RecordingController.swift:1051`. Isolated targets need a final-frame policy that cannot widen capture.
- Stream currently has no delegate: `Capture/RecordingController.swift:915`. Target loss, system stop, and stream errors must finalize once and preserve captured material.
- MP4 writer fixes dimensions at initialization: `Capture/RecordingController.swift:48`. Window resizing requires scaling/padding or a different export architecture.
- Webcam snapshots expose image, screen frame, and corner radius: `Capture/WebcamOverlayController.swift:5`. Current compositing maps screen coordinates through display/region geometry: `Capture/RecordingController.swift:937`; isolated content requires its own output-coordinate mapping.
- DemoMirror already uses isolated window capture: `Capture/DemoMirrorController.swift:335`. Its cursor selection and on-screen polling are examples, not recording-ready lifecycle logic; polling must not mistake minimization for closure (`Capture/DemoMirrorController.swift:474`).
- Recording shortcuts derive from one persisted shortcut; Shift is toggled for region: `Hotkeys/HotkeyService.swift:233`. More modifier variants require checking conflicts in both directions, including existing customized shortcuts: `Settings/SettingsWindowController.swift:780`, `Settings/SettingsWindowController.swift:944`.
- Menu currently exposes only Record Screen: `App/AppDelegate.swift:168`. Recording settings explain only screen/region: `Settings/SettingsWindowController.swift:1423`.
- The package supports macOS 14 and newer, standard and `ZOOMIT_APP_STORE` builds. Tests live in the core self-test runner rather than XCTest: `Package.swift:6`, `SelfTest/SelfTestRunner.swift:30`. The status-menu test is at `SelfTest/SelfTestRunner.swift:646`.
- Local Xcode SDK headers confirm the system picker, singleWindow/singleApplication modes, exclusions, observer callbacks, contentRect/pointPixelScale, and aspect preservation exist on macOS 14. Newer APIs (such as includedApplications/includedDisplays/includedWindows metadata) must be availability checked before use; do not silently raise the deployment target.

### Primary API references

- [System picker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker): shared picker and observer lifecycle.
- [Content filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter): isolated window and display-bound application filtering.
- [Apple capture walkthrough](https://developer.apple.com/videos/play/wwdc2022/10155/): application audio scope, dynamic app windows, and fixed output scaling.

No runtime capture spike or tests have been run for this planning request. Local Swift reports 6.4 with an arm64 macOS toolchain. API header availability is evidence of compatibility, not proof of runtime picker or capture behavior.

## Decisions

The seven decisions below reflect the owner's explicit answers, including three choices that differ from the initial recommendations.

| # | Topic | Question | Answer | Source |
| --- | --- | --- | --- | --- |
| 1 | Scope | Single window, application, or both? | Both; application includes its windows/dialogs on one selected display. | Owner: “Both” |
| 2 | Entry points | System picker or target under cursor; menu and/or shortcuts? | System picker, menu actions, Control+Option+5 window and Control+Option+Shift+5 app; retain screen/region. | Owner selected system picker with menus and shortcuts |
| 3 | Overlays | Include zoom/drawing and webcam? | Include zoom, drawing, and enabled webcam by rendering them onto isolated content. | Owner explicitly selected this option |
| 4 | Target lifecycle | Hidden/minimized versus closed/quit? | Keep recording blank frames until explicitly stopped, including after target closure/quit. | Owner explicitly selected this option |
| 5 | Geometry | Resize and multiple displays? | Fixed MP4 canvas; aspect-fit window with padding, follow window across displays; application remains on one selected display. | Owner explicitly selected this option |
| 6 | Audio | Selected application, all system audio, or mic only? | Selected app audio and optional microphone; single-window capture still includes app-wide audio. | Owner selected recommended audio policy |
| 7 | Verification | Self-tests and manual e2e, live capture fixtures, or native UI automation? | Introduce XCTest UI automation for picker, recording, and save flows, in addition to automated self-tests and capture-output checks. | Owner explicitly selected XCTest UI automation |

### Reversible implementation defaults

These defaults fill routine details without changing the owner's seven decisions. They are called out in the plan so review can override them.

- During isolated recording, existing static/live zoom and draw controls operate on a target-only canvas. The interactive full-screen overlay is a presentation of that canvas, not a display screenshot. Starting target selection dismisses any existing screen overlay and discards its annotations; it must not import a previous screen capture.
- Static zoom/draw preserve existing frozen-image behavior while the target is available; live zoom updates from isolated capture. Source unavailability overrides frozen images and clears visible target annotations so the recording's target area becomes black.
- “Blank” means a black target area. Enabled webcam and microphone continue while the target is unavailable; app audio stays restricted to the selected app. Recording indicator and explicit Stop Recording remain active.
- Reappearing hidden content resumes only through the same authorized filter. A closed window or terminated app is not automatically replaced by a new window or relaunched process.
- Annotations use a stable logical canvas, and webcam placement uses output coordinates. Resizing and monitor movement do not change MP4 dimensions or zoom the webcam.
- Derived shortcuts toggle Option and Shift relative to the configured recording shortcut, matching existing modifier-variant conventions. Customized conflicting shortcuts preserve existing actions; conflicting new variants remain accessible from menus and show the conflict in Settings.
- UI tests use a separate bundle identity, full Xcode, a logged-in desktop, and explicit OS permission setup. Native picker automation is required; a mocked picker or manual-only checklist does not satisfy the chosen test scope.

## Completeness dispositions

| Item | Disposition | Owner or reason |
| --- | --- | --- |
| All recording entry points, command propagation, selected modes | In this change | Owner selected both modes with menus and shortcuts. |
| Picker cancellation, failed startup, duplicate callbacks, system stop and stream error | In this change | Necessary lifecycle handling. |
| Target-specific stop/final-frame behavior and isolation while zoom/draw is active | In this change | Otherwise recordings can expose unrelated screen content. |
| Resizing, target movement, hiding/minimizing, closure/quit, display disconnection | In this change | Behavior must be explicit and tested for selected scope. |
| Enabled audio and webcam behavior | In this change | Existing options must behave consistently with chosen recording mode. |
| Menu, settings explanations, hotkey collision handling, default and existing settings | In this change | Every reachable entry point and persisted preference must remain usable. |
| Editor, save, cancel cleanup and repeat recording | In this change | Existing post-recording flow must work in new modes. |
| README, acceptance checks, standard and App Store compiler variants | In this change | Documentation and verification must describe shipped behavior. |
| Multiple apps in one recording, multiple independently selected windows | Out of scope | Distinct capture features; original request selects one window or application. |
| Combining application windows across displays | Out of scope | Owner selected application capture on one display; combining displays is a different composition feature. |
| Rendering ZoomIt zoom/drawing directly onto isolated content | In this change | Owner explicitly selected this behavior. |
| Producing timed blank frames after target disappearance | In this change | Owner explicitly selected continued recording until manual stop. |
| Native XCTest UI project, picker automation, fixture apps and exported-video checks | In this change | Owner explicitly selected XCTest UI automation. |
| Changing DemoMirror semantics or unrelated recording/editor repairs | Out of scope | Separate features/defects unless necessary to support these modes. |

## Assumptions still open

- No unanswered product questions remain. The reversible defaults above are subject to plan review; they are not represented as explicit owner answers.
- Runtime system-picker permission behavior, absent-target status delivery on macOS 14, and accessibility of the system picker need compatibility validation during execution. These are technical gates, not a basis to drop requested behavior or silently raise the minimum OS version.
- Selected-target isolation is required throughout first frame, normal frames, static/live zoom, webcam composition, hidden/error states, and finalization.
