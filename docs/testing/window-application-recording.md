# Window and application recording — verification

This feature adds native target selection, isolated zoom/drawing/webcam composition, selected-app audio, and a video timeline that continues after target loss. The approved behavior and scope are recorded in [the implementation plan](../plans/window-application-recording.md) and [the owner decisions](../plans/window-application-recording-grill.md).

## Verification status

The execute-plan run implements application code, deterministic self-tests, native XCTest UI tests, fixtures, and assertion helpers. Compile checks are separate from executing the tests. Standard and App Store app builds have passed; the final test-code compile result is recorded in the plan execution log.

**Runtime suites have not been executed by this coding run.** Native picker accessibility, picker-only authorization, source status delivery on macOS 14, two-display behavior, device permissions, and exported-video/audio assertions remain runtime acceptance gates. A compiled test is not evidence that its scenario passed.

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
- Avoid another app/session consuming the same global shortcuts. UI tests are serial and the wrapper holds a run lock. Remove a stale `.build/recording-ui/run.lock` only after confirming no test run is active.

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

Recording assertions read exported MP4s and check:

- First, middle, final, and lifecycle-transition frames, including the black tail after target loss.
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
| Cancel and retry | No writer/editor starts on cancellation; a later real selection succeeds | Native UI |
| Rapid repeated start | One picker/recording is created; starts during selection/finalization are rejected | Native UI + state integration tests |
| Existing screen overlay before selection | Old display pixels/annotations are discarded before target capture | Native UI + exported frames |
| Static zoom/draw | Frozen isolated target, correct transformed annotations; source loss overrides the freeze | Native UI + composition tests |
| Live zoom/typing | New target frames remain live under correct viewport and annotation transforms | Native UI + composition tests |
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
| Persisted/custom hotkeys | Existing actions retain precedence; conflicting new shortcut is explained and its menu works | Effective-binding tests + Settings UI |
| Screen/region regressions | Existing recording/overlay/editor flow still works | Existing self-tests + native regression tests |
| Five-minute 4K capture | No accumulating pending-frame backlog or unbounded memory growth; audio/video timeline remains continuous | Manual performance check with Instruments/Activity Monitor |

For the hardware matrix, also check negative display origins, mixed Retina/non-Retina scaling, display disconnection, camera denial/unavailable camera, microphone denial, webcam presets/shapes and drag repositioning. Record unavailable hardware/OS environments as pending. Do not report the release accepted until the required native gates have evidence.

## Behavior details for QA

Blank target content is black; enabled webcam and optional microphone can continue over it. Old target images, frozen static images, strokes and sketch-pad fill must not survive unavailability. An idle stationary source remains available and must not turn black because it has not changed.

The final frame comes from isolated composition or black in window/application modes. Trigger source loss immediately before Stop and examine the clip's final frames. No first/last/error-frame path may substitute a display screenshot.

Source closure does not stop the video writer. Actual writer/encoding failure is an error, and must not be disguised as a successfully saved black fallback movie. Save errors should allow choosing another location or explicitly discarding the recording.

Window and application recording use the same configured Record Toggle base. Shift/Option variants are toggled relative to that base; Settings lists the actual shortcuts. Test both default and customized bases that already contain Shift and/or Option, including collisions with another feature's derived variant.
