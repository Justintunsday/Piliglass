# Current iOS settings

The settings screen exposes the SwiftUI/UIKit client's capabilities. It no
longer launches Flutter's old settings categories or shows placeholder WebDAV
and privacy forms. Old shared Hive values are retained for compatibility;
removing a control does not erase unrelated user data.

## Storage and effective readers

| Setting | Storage / reader |
| --- | --- |
| Autoplay, default rate | `pili.native.player.*` in UserDefaults; `openVideo` and `loadNativePlayback` |
| Double-tap pause, hold 2× | Native preferences; actual UIKit gesture handlers |
| Lock button, system status, control timeout | Native preferences; player controller observes UserDefaults changes |
| Related videos, expanded description | Native preferences; `PiliNativeVideoDetailView` via AppStorage |
| Simple/full danmaku | Existing `NativeDanmakuSettings` profile stores and account-scoped rules |
| Default resolution | Existing Hive key; native playback request |
| CDN, live CDN, audio CDN | Existing Hive keys and VideoUtils resolver; existing latency service |
| Guest 1080P | Existing `p1080` key; native playback `tryLook` request |
| App recommendation source / personalization / retained recommendations | Existing keys; RcmdController |
| Dynamic unread check | Existing key; MainController |

The legacy bridge list was reduced from 49 toggles to 5 verified shared-service
toggles. Native player/detail settings use their own keys, so stale Flutter
preferences cannot silently disable current player features. Hardware decode,
old seek gestures, seek previews, high-energy charts, obsolete screenshots,
unused subtitle controls, Flutter-only appearance switches and fake sync
controls are not exposed.

Danmaku editors use independent sessions with no media loaded and do not toggle
the active player's fullscreen state. Successful edits refresh the active
session after persistence. Screen-local saves are flushed when leaving.

## Verification

- `check_native_settings.py`: real bridge allowlist and setter with fake Hive;
  verifies persistence, invalid/obsolete-key rejection and controller updates.
- `check_native_danmaku.py`: profile/account isolation and persisted rule CRUD.
- `preview_ios_navigation.py`: production settings navigation, gesture preference
  persistence and both danmaku entry points (service fixtures).
- `check_ios_player_controls.py`: production UIKit controls and speed methods
  with offline media fixtures.
- `ios.yml`: full Flutter + Swift/Aether build, including actual settings editors.
