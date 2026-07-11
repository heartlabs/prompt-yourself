# iOS App

## Adding new .swift files

New files must be registered in `HeartlabsEcho.xcodeproj/project.pbxproj`. Add:

1. `PBXFileReference` entry with a unique 8-char hex UUID
2. `PBXBuildFile` entry referencing that UUID
3. The UUID in the `HeartlabsEcho` `PBXGroup` children array
4. The UUID in the `PBXSourcesBuildPhase` files array

Search for any existing file's UUID in the `.pbxproj` to see the exact pattern, then add yours right after the last entry.

## Voice composer — invariants

The chat is voice-first: the only control is the companion orb
(`CompanionOrbView`), and recording + photo attachment happen exclusively
inside `ConversationModeView` (the full-screen composer). Each rule below
guards a real bug — do not relax them while editing nearby code:

1. **The composer owns the microphone.** Recording starts in the composer's
   `onAppear` and stops inside `finish(_:)` — the single funnel that every
   exit path goes through. Never start/stop the recognizer from other UI, and
   never dismiss the composer through any path that bypasses `finish(_:)`
   (that is how you get a hot mic after dismissal, or a double-send). To add
   an exit, add a case to `ExitReason` and handle it in the switch.
2. **`sendComposition` requires a finalized transcript.** Await
   `recognizer.stopTranscribingAsync()` first; a debug assertion fires if it
   is called while recording. Speech + photo go out as separate bubbles but
   exactly ONE `sendToLLM()` exchange — do not "fix" it into two sends.
3. **The mic must be OFF while the photo picker is open**
   (`openPhotoPicker` finalizes before presenting). The 300ms grace period in
   `handlePickerDismissed` is load-bearing: picker dismissal can land before
   the selection publishes, and removing the delay makes real picks register
   as cancels.
4. **All orb geometry lives in `Theme.Orb`** (diameters, band fraction, band
   fade, chip offset). The values are interdependent — the chip offset
   derives from the composer diameter, the band from the chat diameter.
   Change them there; never inline orb-related sizes at a call site.
5. **Layout contracts.** The chat's bottom band is a `safeAreaInset` on the
   transcript (not a VStack row) — scroll insets and the scroll-behind-orb
   fade depend on it. The composer's transcript `ScrollView` stays
   `scrollDisabled` — swipe-down-to-cancel owns vertical drags everywhere on
   that screen.
6. **The coach label retires itself.** `OrbCoachmark` counts only real
   compositions (via `sendComposition`'s return value). Don't count taps or
   cancelled attempts.
