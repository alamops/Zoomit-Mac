# Window and application recording — verification

This feature adds native target selection, isolated zoom/drawing/webcam composition, selected-app audio, and a video timeline that continues after target loss. The approved behavior and scope are recorded in [the implementation plan](../plans/window-application-recording.md) and [the owner decisions](../plans/window-application-recording-grill.md).

## Verification status

The execute-plan run implements application code, deterministic self-tests, native XCTest UI tests, fixtures, and assertion helpers. Compile checks are separate from executing the tests. Standard and App Store app builds and both XCTest schemes’ build-for-testing checks passed. The development app bundle was built and its signature verified. Checkpoint details are recorded in the plan execution log.

The original execute-plan coding run did not execute runtime suites. During the subsequent review-fix run on 2026-10-12, both standard and App Store self-test suites passed, and both independent `VideoAssertionsTests` passed against real MP4s. Those two tests also failed against the old frame-sampling implementation, proving the regression checks detect single-frame leaks and blank-tail interruptions.

The previously failing picker fixture-color assertion is fixed. Native capture inherited the display's wide-gamut color profile while recording composition expected sRGB. Isolated recording and the source probe now explicitly request sRGB; the OS-issued filter is retained. On macOS 26.6.2, all six picker compatibility tests passed in the full standard run, and the native trim/export/Save-cancel test passed with the original color thresholds. Both distribution self-test suites pass, including new color-rendering and real writer/trim regressions.

Full native acceptance remains pending. The latest completed standard run on 2026-10-13 executed all 29 tests: 26 passed, 3 failed, none skipped. All six picker compatibility tests passed, including the fixture-color assertion, as did all four video-assertion regressions. All recording shortcuts, real native Stop Sharing, screen/region recording, app audio, window ordering, target-loss black tails, and completed Save/export flows passed. Result: `.build/recording-ui/run-20261013-161800-vfWVAR/RecordingUI.xcresult`.

The three failures exposed one production privacy defect and two test defects. The resize export genuinely included an attached orange dialog because native capture includes child windows by default. The stream configuration now explicitly excludes children in window mode and includes them in application mode, with regression checks for both scopes. The real OS-issued filter and the attached-dialog fixture remain intact. Window mode fails safely on macOS 14.0–14.1, which lack the child-exclusion API; it requires macOS 14.2 or later. Application mode retains its macOS 14 minimum.

The other failures were the desktop-overlay query missing a visible unnamed borderless window and a typing assertion sampling before the actual text interval. The test now enumerates the full overlay window snapshot and aligns its unchanged typing interval to the final encoded Stop frame and actual HID Stop request. Offline decoding confirmed the existing exported text reaches a white fraction of 0.01258, above the unchanged baseline-plus-0.0005 threshold. These fixes have passed both distribution self-test suites and both native scheme compile checks; their full native reruns await refreshing Accessibility authorization for the changed signed runner. No required marker, privacy, or lifecycle assertion was weakened.

Earlier full results are retained: `.build/recording-ui/run-20261013-154428-pr2xf0/RecordingUI.xcresult` (20 passed, 9 failed) and `.build/recording-ui/run-20261013-110031-7gBbhp/RecordingUI.xcresult` (21 passed, 8 failed). Their keyboard authorization, region-query, sharing-control, and menu-coordinate failures were repaired and verified by the latest run.

Two earlier attempts stopped before any test case executed while awaiting separate Touch ID/password authentication to **Enable UI Automation**; that authentication subsequently succeeded. Retained startup failures: `.build/recording-ui/run-20261013-134054-LAcMLg/RecordingUI.xcresult` and `.build/recording-ui/run-20261013-134343-6ZSklj/RecordingUI.xcresult`. Both distribution self-tests passed again after the harness repairs, and both XCTest schemes compile. The wrapper now shares a stable DerivedData directory across serial schemes: previously each unique build path changed the ad-hoc runner identity and invalidated Accessibility authorization. The unchanged runner's signing requirement was verified identical after preparing both schemes. Complete native reruns await the real macOS Accessibility grant for this prepared runner. macOS 14 and optional-device/performance checks also remain unverified. Earlier dated failing results below are retained historical evidence.

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

On a desktop where macOS reserves the default Control+number shortcuts, run both full suites serially with `--available-shortcuts`. This configures Control+Command bases through the dedicated recorder's actual Settings UI and checks the persisted button titles. It preserves all tests, exercises real global shortcut handlers, and leaves macOS shortcuts unchanged:

```sh
zsh Scripts/test-recording-ui.sh --distribution homebrew --available-shortcuts
zsh Scripts/test-recording-ui.sh --distribution appstore --available-shortcuts
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

- Use full Xcode with a macOS 14.2+ SDK and an unlocked, logged-in desktop running macOS 14.2 or later for the complete window/application suite. Run as the console user. SSH/headless/root sessions do not provide the required interactive environment.
- Use an English test login for the system picker labels. The driver retains accessibility trees and screenshots if native controls cannot be found.
- Allow the dedicated test apps and Xcode test runner to capture/automate the UI when macOS requests it. Grant permissions through System Settings/system UI. No harness edits the TCC database or silently grants permission.
- XCTest can separately request Touch ID/password authentication to **Enable UI Automation**. Check every display for that dialog and approve it before the runner's startup timeout. A Screen Recording grant does not satisfy this separate system requirement.
- Real HID shortcut events additionally require Accessibility permission for `.build/recording-ui/DerivedData/Build/Products/Debug/RecordingUITests-Runner.app`. Add that exact prepared bundle through System Settings. Both schemes share its stable build path; per-run results remain separate. Source or Xcode changes can still require a renewed grant for a changed signed runner.
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

Run required flows on both macOS 14.2 and the current supported macOS, and for both distribution variants. On macOS 14.0–14.1 verify application recording and the explicit unsupported-window error without starting a window stream. Record OS/Xcode versions, display arrangements/scales, bundle identity, permissions, fixture evidence, output file, and pass/fail/pending for each run.

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

## Stop-frame and delayed-overlay review fixes (2026-10-12)

The writer now retains the required Stop image until the video input accepts it. Finish closes the audio inputs, prevents further realtime appends, and retries video readiness on the writer queue without blocking cancellation. Readiness has a five-second deadline. A missing image, append failure, or readiness timeout reports an error and removes the partial movie rather than exporting old content or substituting a fallback movie.

Static zoom, live zoom, and drawing now check the bound recording scope after their desktop-capture await. Window/application sessions reject those delayed results throughout selection, startup, recording, Stop, editing, and Save, including startup before `isRecording` becomes true. Screen and region recordings retain desktop overlay support.

Standard and App Store self-tests pass with four new real-writer cases: delayed readiness with both audio inputs enabled and a decoded black final frame; bounded readiness failure even when fallback is otherwise enabled; a missing final image; and cancellation during the wait. The scope-state regression covers both isolated scopes through every bound phase and ordinary screen/region support. Both distribution app bundles and the dev bundle were rebuilt.

The first unfiltered native run executed 29 tests: 6 passed and 23 failed. Besides the existing six standalone picker-probe timeouts, all 17 recording tests stopped in setup because the status menu and main menu both contain a Settings item. The status-menu item now has the unique accessibility identifier `settings.open`, and the harness uses it. This resolves the ambiguous selector without changing or weakening recording assertions. First-run evidence: `/tmp/zoomit-final-frame-full-native.xcresult` and `/tmp/zoomit-final-frame-full-native.log`.

The second run was interrupted after 12 completed tests (3 passed, 9 failed); `/tmp/zoomit-final-frame-full-native-retry.log` retains those results, and its result bundle is incomplete. Its application hide/restore/quit/relaunch test reached recording, Stop, editor, and Save. The filename again lost lowercase `c` characters, so the UI test failed its requested-destination check. Independently decoding the actual file, `.build/qa-focus/appliation-quit-blak-tail-CAE4EB3F-765A-44FA-A957-317E1984F4CA.mp4`, with the unchanged `RecordedVideo` assertions passed all 764 frames: selected-app marker, 1.5-second blank tail through the final Stop frame, and forbidden-app exclusion. This verifies the recording artifact, not the failing Save-input flow. Decode evidence: `/tmp/zoomit-final-frame-native-tail.log`.

After cleaning up only the interrupted run's dedicated recorder and fixture executables, both self-test variants passed again on the final source tree. Logs: `/tmp/zoomit-final-frame-standard-final-selftests.log` and `/tmp/zoomit-final-frame-appstore-final-selftests.log`. Dev and sandboxed test bundles passed `codesign --verify --deep --strict`.

The final unfiltered standard native run completed all 29 tests: 8 passed, 21 failed, 0 skipped. Fixture/preflight tests passed 2/2, recorder UI tests passed 2/17, and independent video-assertion tests passed 4/4. The passing recorder cases were application window ordering through exported MP4 assertions and preview mute/unmute accessibility. The six picker-probe tests again timed out accepting native selection. Evidence: `/tmp/zoomit-final-frame-full-native-final.xcresult`, `/tmp/zoomit-final-frame-full-native-final.log`, and `/tmp/zoomit-final-frame-full-native-final-summary.json`.

The other 15 recorder failures were:

| Failure | Cases | First assertion / location |
| --- | --- | --- |
| Application still unavailable after reactivation | 1 | `RecordingUITests.swift:250`; before Stop |
| Save changed requested filename | 2 | `RecordingUITests.swift:123`; app dialogs and selected-display exports |
| Trimmed export lacks primary-color marker | 1 | `Support/VideoAssertions.swift:83`; same color-shift failure as the earlier editor run |
| Stop shortcut did not open editor | 1 | `RecordingUITests.swift:71`; desktop has known Control+5 conflicts |
| Desktop drawing overlay did not appear | 1 | `RecordingUITests.swift:383` |
| First isolated zoom overlay did not open | 1 | `RecordingUITests.swift:303`; before Stop |
| Picker cancellation/retry event synthesis timed out | 1 | `RecordingUITests.swift:131` |
| Settings menu-opening notification timed out | 7 | `Support/TestEnvironment.swift:89`; screen/region, audio, picker shortcuts, sharing withdrawal, and three window cases |

These results do not establish complete native acceptance. Reproduce on an unlocked, quiet test desktop: quit other ZoomIt instances; allow the dedicated recorder/probe and Xcode runner through macOS's permission UI; ensure no stale picker is open; and resolve shortcut conflicts through the test environment or app Settings. Run `zsh Scripts/test-recording-ui.sh --distribution homebrew`, then the corresponding `--distribution appstore` command serially. Check the actual Save filename against the requested name, app restoration before Stop, overlays, and the decoded trim colors; retain failing artifacts instead of relaxing assertions. App Store native runtime, macOS 14, and the device/performance matrix remain pending.

## Picker color investigation and native retest (2026-10-13)

The original authorized probe received 255 window frames but its required primary marker peaked at 0.038452, below the unchanged 0.2 threshold. The display uses Display P3: the fixture's sRGB green `(13, 217, 26)` has roughly `(100, 214, 69)` coordinates in P3. Misinterpreting those coordinates as sRGB explained both the probe failure and the yellow-green trimmed export. Requesting sRGB at the native capture boundary fixes the source rather than changing the assertion.

New self-tests verify the capture configuration, render the fixture green from both tagged sRGB and P3 images, and encode/decode and trim a real MP4 against the intended RGB values. A scratch experiment deliberately mislabeling P3 pixels reproduced the regression and failed the color check. Both standard and App Store self-tests pass. Both dedicated recorder variants and the development bundle were rebuilt.

Picker automation also canceled its own chooser: XCTest treated a pointer coordinate rooted in the fixture as a UI interruption and pressed the system Cancel button. The driver now anchors the same absolute hover/click in the already-present Control Center picker dialog. It still requires Apple's actual selection callback and never reconstructs an authorization filter.

Retained standard full run: `/tmp/zoomit-picker-color-native-round2.xcresult` and `/tmp/zoomit-picker-color-native-round2.log`. All six compatibility cases passed, including cancellation/retry, window target loss/restoration, application windows/dialogs, application stacking order, and cross-display binding. The recovered window primary marker was 0.866394; forbidden-app markers remained excluded. The native trim/export/Save-panel cancellation recovery case passed, with exported primary marker 0.81952. The independently decoded application-quit recording passed its selected-app marker, forbidden-app exclusion, and required 1.5-second black tail across all 614 frames, although native Save typed the wrong filename and the complete case therefore failed.

The bounded follow-up run used an experimental Control+Command shortcut profile because this desktop reserves the default Control+1/2/4/5 and derived system chords. It persisted the shortcut correctly but failed its XCTest label synchronization during setup; this unvalidated profile and an unproven character-typing workaround are not shipped. The follow-up completed all 29 cases: 9 passed, 20 failed, none skipped in the finalized result. All 17 recording cases failed during shortcut-label setup; the fixture dialog lookup, application selection, and application hidden-source signal also failed. The four other compatibility cases and four video-assertion tests passed. No fixture-color assertion failed. The dedicated recorder's experimental shortcut was restored after its process exited; user app preferences and macOS shortcuts were untouched. This run does not establish recording acceptance. Its retained evidence is `/tmp/zoomit-picker-color-native-available.xcresult` and the matching `.log`. The first attempted driver repair waited for a highlight before issuing the hover that creates it; that interrupted run is retained as `/tmp/zoomit-picker-color-native-round1.xcresult`.

For the remaining acceptance, use the full distribution commands above on an unlocked test login whose system shortcuts do not consume ZoomIt's configured defaults, grant the dedicated bundles' requested capture/automation permissions through the system UI, and keep the shared desktop idle during native Save. Required results remain real picker selection, all exported-frame privacy checks, target-loss blank tails, Stop shortcuts, editor/save/cancel, audio, and overlay flows. Run both distribution variants and record their complete counts; then complete macOS 14 and the optional microphone/camera matrix. These are pending gates, not passing skips.

Final source checks: standard and App Store self-tests passed (`/tmp/zoomit-picker-color-standard-selftests.log` and `/tmp/zoomit-picker-color-appstore-selftests.log`); both final native schemes passed build-for-testing (`/tmp/zoomit-picker-color-final-ui-compile.log` and `/tmp/zoomit-picker-color-final-appstore-ui-compile.log`). The final dev bundle is `.build/ZoomIt (Dev).app`, rebuilt and verified with `codesign --verify --deep --strict`.
