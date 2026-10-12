# Window and application recording — verification

This feature adds native target selection, isolated zoom/drawing/webcam composition, selected-app audio, and a video timeline that continues after target loss. The approved behavior and scope are recorded in [the implementation plan](../plans/window-application-recording.md) and [the owner decisions](../plans/window-application-recording-grill.md).

## Verification status

The execute-plan run implements application code, deterministic self-tests, native XCTest UI tests, fixtures, and assertion helpers. Compile checks are separate from executing the tests. Standard and App Store app builds and both XCTest schemes’ build-for-testing checks passed. The development app bundle was built and its signature verified. Checkpoint details are recorded in the plan execution log.

The original execute-plan coding run did not execute runtime suites. During the subsequent review-fix run on 2026-10-12, both standard and App Store self-test suites passed, and both independent `VideoAssertionsTests` passed against real MP4s. Those two tests also failed against the old frame-sampling implementation, proving the regression checks detect single-frame leaks and blank-tail interruptions.

Both native schemes passed build-for-testing. Native preflight launched the dedicated recorder and fixtures and passed `HarnessSmokeTests.testPreflight`. The picker cancellation/retry test obtained an authorized window filter and received source frames, but failed its required primary-color marker assertion. Full native recording acceptance remains pending; no assertion was relaxed. The retained failing run is `.build/recording-ui/run-20261012-021202-OvEQHO/RecordingUI.xcresult`, with `probe-evidence.json` beside it. Reproduce with `zsh Scripts/test-recording-ui.sh --preflight`, inspect the captured source and probe color measurement, then rerun the full distribution commands below. macOS 14, two-display behavior, device permissions, and complete recording/export flows still require passing evidence.

### Picker runtime follow-up — 2026-10-12

The reported missing picker and disappearing Wi-Fi/menu items coincided with a Control Center crash. Closed or unrealized AppKit windows can report `windowNumber == -1`; exclusions now retain only valid CGWindowIDs. Presentation is deferred until menu tracking unwinds, and Control Center was relaunched after the earlier crash to restore the system picker service.

Dev and dedicated test executables previously embedded the official bundle identity while their signed app bundles used different identities. The build now embeds the same generated Info.plist that it packages. Native service logs confirm the dedicated recorder's correct identity, and extracted executable metadata matches bundle metadata for the dev and both test distributions.

Picker-only capture also failed after selection because stream-specific configuration changed the issued filter's metadata before capture, producing `matchesPickedContent=0` and error `-3801`. The recorder now keeps the native default configuration stable through the recording and retains the stream without adding configuration overrides. Application selection on this OS returns display style (`2`), one application, and one display; validation accepts this restricted filter and rejects invalid target counts. Self-tests cover these cases and a real unrealized NSWindow's invalid ID.

On macOS 26.6.2, `RecordingUITests.testSystemPickerFromRecordingShortcutsAndCancelEditor` passed for both window and application scopes: global start shortcut → real native selection → available capture → explicit Stop Recording menu → exactly one editor → cancel → ready for another recording. The driver uses the actual native Share button's window-center position on macOS 26, whose picker controls are absent from the accessibility tree, and requires the recorder to accept the OS-issued selection. It never constructs a replacement filter. Standard and App Store self-tests passed, both app variants built, and the dev bundle's signature verified.

The passing native result is `.build/recording-ui/picker-menu-live/PickerFlow.xcresult`. Full recording/export/privacy and hardware acceptance remains pending. A separate Control+5 stop attempt failed on this desktop: enabled macOS symbolic shortcuts `122` and `132` consume Control+5 and Control+Shift+5. Use the Stop Recording menu here, or choose an available shortcut through Settings; the required stop-shortcut test remains intact and needs an environment without those system conflicts.

## Test layers

| Layer | What it checks | Requires capture permission? |
| --- | --- | --- |
| Existing and recording self-tests | Geometry, annotation rendering, fixed composition, source state/generation guards, timeline, writer integration, and effective shortcut conflicts | No OS capture permission; writer tests create temporary local MP4s |
| Picker compatibility tests | Real native picker selection/cancellation, authorized source isolation, idle/hidden/closed statuses, restoration, and display binding | OS picker authorization and UI automation access |
| Recording UI tests | Real ZoomIt menu/hotkey → native picker → recording → editor/export/save/cancel, with video/audio checks | Dedicated recorder's capture authorization, UI automation, and an interactive desktop |
| Manual device/display matrix | Real camera/microphone and mixed-scale/multiple-display cases unavailable to a deterministic fixture | Relevant optional-device permissions and configured hardware |

## Local commands

Run the existing executable test runner for both product surfaces:

```sh
swift run ZoomItMacSelfTest
swift run -Xswiftc -DZOOMIT_APP_STORE ZoomItMacSelfTest
```

Run native tests serially through the wrapper:

```sh
zsh Scripts/test-recording-ui.sh --preflight
zsh Scripts/test-recording-ui.sh --compatibility
zsh Scripts/test-recording-ui.sh --compatibility --picker-only
zsh Scripts/test-recording-ui.sh --distribution homebrew
zsh Scripts/test-recording-ui.sh --distribution appstore
```

`--preflight` checks the fixture/recorder environment and actual picker cancellation/retry. `--compatibility` selects the standalone picker probe tests and fixture checks. `--picker-only` requires that the dedicated probe has no blanket Screen Recording grant; selection must authorize the actual chosen content. The two distribution commands run all required native tests against the corresponding bundled recorder. App Store tests use the real sandbox build, not a compiler flag applied only to the UI runner.

To compile the harness without running interactive tests:

```sh
xcodebuild build-for-testing \
  -project Tests/RecordingUI/RecordingUI.xcodeproj \
  -scheme RecordingUI \
  -destination 'platform=macOS' \
  -derivedDataPath .build/recording-ui-compile \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

This compile-only command does not launch the picker or prove runtime permissions or capture behavior. The test wrapper builds/signs the appropriate dedicated recorder and fixtures for actual execution.

## Environment and permissions

- Use full Xcode with a macOS 14+ SDK and an unlocked, logged-in desktop. Run as the console user. SSH/headless/root sessions do not provide the required interactive environment.
- Use an English test login for the system picker labels. The driver retains accessibility trees and screenshots if native controls cannot be found.
- Allow the dedicated test apps and Xcode test runner to capture/automate the UI when macOS requests it. Grant permissions through System Settings/system UI. No harness edits the TCC database or silently grants permission.
- Normal capture tests and picker-only authorization tests have different permission prerequisites. Do not reset an installed official ZoomIt's grants to prepare a test.
- Two-display acceptance requires a second real or supported virtual display. The suite reports missing display prerequisites as failures with pending-environment evidence; it does not turn required cases into passing skips.
- Real microphone/webcam checks need configured devices. Deterministic composition tests can use known webcam pixels without a camera, and fixture audio does not need a microphone.
- Quit other ZoomIt/ZoomIt (Dev) instances before native tests. The existing single-instance lock or global shortcuts can block the dedicated recorder; preflight reports this instead of terminating your app. Avoid another app/session consuming the same shortcuts. UI tests are serial and the wrapper holds a run lock. Remove a stale `.build/recording-ui/run.lock` only after confirming no test run is active.

The wrapper builds the recorder through the existing app-build script using dedicated identities:

| App | Bundle identity |
| --- | --- |
| Standard test recorder | `com.sysinternals.zoomitmac.recordingtests.homebrew` |
| Sandboxed test recorder | `com.sysinternals.zoomitmac.recordingtests.appstore` |
| Picker probe | `com.sysinternals.zoomitmac.recordingtests.pickerprobe` |
| Fixture A | `com.sysinternals.zoomitmac.recordingtests.fixturea` |
| Fixture B | `com.sysinternals.zoomitmac.recordingtests.fixtureb` |

The recorder is launched by its validated absolute bundle URL. Fixture and probe apps are built by the committed XCTest project. Cleanup targets only explicitly built test executable paths. Official ZoomIt bundles, preferences, and processes remain outside the harness.

## Fixture and assertion design

Fixture A provides a green primary window, a cyan second window, an orange dialog, source animation, and a deterministic tone. Fixture B provides forbidden content and a different tone. Buttons expose lifecycle and geometry changes through public accessibility controls. These apps make same-app versus other-app capture differences observable.

The probe records native status/filter/pixel evidence to `probe-evidence.json` and snapshots to `probe-latest.png`. Newer filter identity metadata is inspected only behind its availability check. On macOS 14 the authorized filter remains opaque; the capture result and native status sequence must establish behavior without guessing an identity from a title or rectangle.

Each probe frame also retains native contentRect/contentScale/scaleFactor and buffer dimensions. The content rectangle already describes scaled surface points: multiply by scaleFactor to obtain pixels, without applying contentScale again. These values identify the changing target footprint inside a fixed-size surface, so input and annotations can exclude letterbox padding after resize. The conversion and clipping have deterministic regression coverage; their OS-specific alignment is also part of native resize acceptance. Apple's [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) describes obtaining this per-frame metadata.

Recording assertions read exported MP4s and check:

- Every decoded frame, including first/final frames and brief lifecycle transitions. Diagnostic attachments summarize at most 24 frames; privacy and lifecycle assertions use the full sequence.
- Required/forbidden fixture markers using tolerant color thresholds after H.264 compression.
- Constant video dimensions, correct aspect ratio/padding, and clip duration that includes unavailable-source time.
- Visible zoom, drawn annotations/typing/highlights, and fixed webcam placement through deterministic composition checks.
- Selected-app audio by detecting the expected fixture tone and excluding the other app's tone.

Every UI failure should retain its screenshots, native accessibility tree where relevant, `.xcresult`, exported artifacts where available, and probe evidence. The wrapper prints a unique artifact directory under `.build/recording-ui/` and retains build/test logs there. Do not diagnose a missing marker by relaxing its assertion before checking the captured file and selected mode.

## Acceptance matrix

Run required flows on both macOS 14 and the current supported macOS, and for both distribution variants. Record OS/Xcode versions, display arrangements/scales, bundle identity, permissions, fixture evidence, output file, and pass/fail/pending for each run.

| Scenario | Expected result | Verification |
| --- | --- | --- |
| Window picker | Only the selected window is recorded; fixture A's second window and fixture B are absent | Native UI + exported frames |
| Application picker | Fixture A's windows/new windows/dialogs on the selected display appear; fixture B/desktop/dock are absent | Native UI + exported frames |
| Application window ordering | Clicking alternating, overlapping windows of the selected app brings the clicked window forward in the native stream and exported video | `testApplicationWindowClicksChangeNativeFrameOrder` + `testApplicationWindowClicksChangeRecordedStackingOrder` |
| Cancel and retry | No writer/editor starts on cancellation; a later real selection succeeds | Native UI |
| Rapid repeated start | One picker/recording is created; starts during selection/finalization are rejected | Native UI + state integration tests |
| Existing screen overlay before selection | Old display pixels/annotations are discarded before target capture | Native UI + exported frames |
| Static zoom/draw | Frozen isolated target, correct transformed annotations; source loss overrides the freeze | Native UI + composition tests |
| Live zoom/typing | New target frames remain live under correct viewport and annotation transforms | Native UI + composition tests |
| Isolated live input | Fitted presentation captures clicks; keyboard zoom, panning, drawing and typing work; Escape returns interaction to the app while recording continues | Real-window self-tests + native UI |
| Pen/highlights/shapes/text/undo/erase | Recorded result matches target-local interaction, including in-progress work | Native UI + rendering tests |
| Resize window | Original MP4 dimensions remain constant; source fits with black padding | Native UI + geometry/video assertions |
| Move window across displays | Same selected window follows; output dimensions remain fixed | Two-display native test |
| App windows on another display | Recording remains bound to its selected display | Two-display native test |
| Minimize/hide and restore | Black target content while unavailable; newly authorized source content returns without stale annotations | Native UI + source integration tests |
| Close window/quit app | Timed black target frames continue until manual stop; reopening a new target does not retarget | Native UI + exported blank tail |
| OS stops sharing source | Recorder remains active with unavailable status until manual Stop | Native UI; retain OS status evidence |
| Stop with each shortcut/menu | Exactly one editor/save flow; source-unavailable sessions are stoppable | Native UI + lifecycle tests |
| App audio | Selected app tone present, fixture B tone absent; window audio is app-wide | Native UI + audio assertions |
| Webcam and microphone | Camera remains fixed after zoom/drag/host changes; microphone continues on black source | Deterministic composition + configured-device checks |
| Trim/export/save | Edited MP4 saved through actual editor/save UI; readable expected output | Native UI + output assertions |
| Editor/save cancellation | Resources/temp files cleaned; next recording remains usable | Native UI + lifecycle tests |
| No first source frame | Fixed-size black clip can finalize; no desktop fallback | Writer integration + native lifecycle checks |
| Writer failure with overlay visible | Overlay is dismissed before the error alert, partial output is removed, and the next recording is usable | Manual fault-injection acceptance |
| Persisted/custom hotkeys | Existing actions retain precedence; conflicting new shortcut is explained and its menu works | Effective-binding tests + Settings UI |
| Screen/region regressions | Existing recording/overlay/editor flow still works | Existing self-tests + native regression tests |
| Five-minute 4K capture | No accumulating pending-frame backlog or unbounded memory growth; audio/video timeline remains continuous | Manual performance check with Instruments/Activity Monitor |

For the hardware matrix, also check negative display origins, mixed Retina/non-Retina scaling, display disconnection, camera denial/unavailable camera, microphone denial, webcam presets/shapes and drag repositioning. Record unavailable hardware/OS environments as pending. Do not report the release accepted until the required native gates have evidence.

## Behavior details for QA

Blank target content is black; enabled webcam and optional microphone can continue over it. Old target images, frozen static images, strokes and sketch-pad fill must not survive unavailability. An idle stationary source remains available and must not turn black because it has not changed.

The final frame comes from isolated composition or black in window/application modes. Trigger source loss immediately before Stop and examine the clip's final frames. No first/last/error-frame path may substitute a display screenshot.

Source closure does not stop the video writer. Actual writer/encoding failure is an error, and must not be disguised as a successfully saved black fallback movie. Save errors should allow choosing another location or explicitly discarding the recording.

Window and application recording use the same configured Record Toggle base. Shift/Option variants are toggled relative to that base; Settings lists the actual shortcuts. Test both default and customized bases that already contain Shift and/or Option, including collisions with another feature's derived variant.

## Application window ordering investigation (2026-10-12)

The new focus fixtures use equally sized overlapping windows and alternate real pointer clicks between their exposed sides. The native source test checks newly captured color markers after each click; the exported-video test requires the corresponding stable window-order sequence and excludes fixture B throughout. A main-window label separately confirms that each click reached the intended app window.

On macOS 26.6.2, `testApplicationWindowClicksChangeRecordedStackingOrder` passed for the standard recorder: native app selection, primary/second/primary pointer clicks, Stop, editor, native Save, decoded MP4 ordering, and exclusion of fixture B in every decoded frame. Result: `/tmp/zoomit-focus-native-edit-menu.xcresult`; saved footage: `.build/qa-focus/app-window-order-9AFA62BB-853D-49ED-A00E-BBAD580247E4.mp4`. The Save destination was selected through `/tmp/zoomit-qa-order`, a symlink to the test-owned artifact directory, to avoid the earlier desktop path-entry interference. Standard and App Store self-tests passed. App Store native focus acceptance and macOS 14 remain pending.

The Save tests exposed two separate problems: the harness queried the wrong Go to Folder text field (corrected to `PathTextField`), and the app had no main Edit menu, so Command+A inserted the requested filename into the suggested filename rather than replacing it. Installing responder-chain Cut/Copy/Paste/Select All commands corrected filename entry and allowed the complete export test to pass. The independent source probe still cancels during native picker selection and captures no frames; its source-order test remains unverified. Retained failing probe result: `/tmp/zoomit-focus-native-active.xcresult`.

The owner initially reported the issue during ordinary application recording, then confirmed that recording was working and that the remaining concern was saving to the correct path. After the successful export test, the owner confirmed that everything was working and requested commit/push. The fixture recording follows window order without changing production capture code. Ordinary recording does not create a zoom overlay. During isolated Live Zoom, `ZoomCanvasView` deliberately captures mouse events because its fitted content coordinates differ from desktop coordinates; its non-drawing live-mode mouse handler consumes clicks. Escape dismisses that overlay while recording continues.

## Review-comment fixes (2026-10-12)

The preview mute button now updates its accessibility action on every volume synchronization. Recorder transitions block Break Timer, all DemoMirror scopes, and standard-build DemoType start/reset commands, while recording stop and exit handling remains reachable. Self-tests cover all five protected phases and normal idle/recording behavior in both product variants.

Blank-tail checks include the final encoded frame's duration and permit only one observed cadence interval plus a one-microsecond timestamp epsilon. Cadence uses the median positive presentation interval: a final Stop frame can arrive only 1/600 second after the previous frame without changing the video's normal 30 fps cadence. Four independent video-assertion tests pass, including short tails at 30/60 fps and this closely spaced final-frame case. The short-interval case first failed with the minimum-interval calculation, then passed with the median calculation. The native mute/unmute/mute accessibility test also passed. Combined result: `/tmp/zoomit-cr-final-regressions.xcresult`. Standard and App Store self-tests passed, and the dev bundle was rebuilt.

The broader editor test initially compared its trimmed export with an early wall-clock estimate that excluded picker/Stop latency. It now compares with the source duration exposed by the real editor. That duration check passes, but the exported clip fails its required primary-color marker check; no color assertion was weakened. Retained failing result: `/tmp/zoomit-cr-editor-flow-correct-duration.xcresult`.

The native application hide/restore/quit/relaunch test reached Save but failed its destination check because input dropped lowercase `c` characters in the requested filename. Result: `/tmp/zoomit-cr-native-black-tail.xcresult`. The actual file, `.build/qa-focus/appliation-quit-blak-tail-5002460A-DE60-48E8-8249-92609A88167C.mp4`, was independently decoded using the current `RecordedVideo` implementation: all 771 frames passed selected-app marker, 1.5-second blank-tail, and forbidden-app exclusion assertions. This verifies the stricter assertion against a real recording; the complete native Save-input flow remains failing.
