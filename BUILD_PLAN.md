# Clickr — Build Plan

A native macOS menu bar app that controls an Apple TV over the local network, like the Remote in Control Center on iPhone.

**App name:** Clickr. Tagline: "A menu bar remote for Apple TV." Bundle ID: `com.ziggy46.clickr`.

---

## 0. Ground rules for Claude Code

- **Swift only.** Use SwiftUI, Network.framework, CryptoKit and Security.framework. **Don't add third-party Swift packages.** Write the protocol stack (OPACK, TLV8, BigInt, SRP, pairing, framing) in this repo.
- **Reference material is allowed.** The pyatv project (Python) documents and implements the Companion protocol. Read its protocol docs and source to learn message layouts, field names and key-derivation strings, but don't translate it line by line.
- **pyatv is also the test oracle.** Install it in a Python venv (dev only, never shipped). Use it to:
  - generate test vectors (SRP values, OPACK bytes, encrypted frames) for unit tests;
  - check a real Apple TV's behavior with `atvremote` / `atvscript` before debugging our own code.
- **Every protocol value in this plan marked ⚠︎ came from memory and must be checked against pyatv before use.** That covers frame type numbers, HID codes, HKDF salt/info strings and nonce layout. If pyatv disagrees with this plan, pyatv wins. Note the correction in this file.
- **Build in milestone order.** Don't start UI polish before Milestone 6 (first button press works).
- **Each milestone ends with its acceptance checks passing.** Commit after each one.
- **Keep the design exact.** All UI numbers are in Section 5. Don't restyle, don't add features, don't swap icons.

---

## 1. Targets and platform

| Item | Value |
|---|---|
| Minimum macOS | **14.0** (needed for `onKeyPress`; `MenuBarExtra` itself is 13+) |
| Liquid Glass | **macOS 26+**, gated with `if #available(macOS 26, *)` |
| Older macOS | Material fallback design (Section 5.3) |
| Architectures | Apple Silicon + Intel (universal) |
| App type | Menu bar only: `LSUIElement = YES`, no Dock icon, no main window |
| Distribution | Direct download, Developer ID signed and notarized. **Not the Mac App Store.** |
| Sandbox | On, with the `com.apple.security.network.client` entitlement |

**Info.plist keys**

- `NSLocalNetworkUsageDescription`: "Clickr finds and controls Apple TVs on your network."
- `NSBonjourServices`: `["_companion-link._tcp"]`
- `LSUIElement`: `YES`

---

## 2. Project layout

```
Clickr/
├─ Clickr.xcodeproj
├─ App/                          (app target: UI only)
│  ├─ ClickrApp.swift          MenuBarExtra entry point
│  ├─ RemoteViewModel.swift      @Observable; owns the session; maps UI → commands
│  ├─ Views/
│  │  ├─ RemotePopover.swift     chooses Glass vs Fallback
│  │  ├─ GlassRemoteView.swift   macOS 26 design (5.2)
│  │  ├─ FallbackRemoteView.swift  macOS 14–15 design (5.3)
│  │  ├─ PairingView.swift       (5.4)
│  │  ├─ Clickpad.swift
│  │  ├─ DeviceHeader.swift
│  │  ├─ NowPlayingCard.swift
│  │  └─ MenuBarIcon.swift       (5.1)
│  ├─ KeyboardShortcuts.swift
│  └─ Assets.xcassets            RemoteIcon (template PDF/SVG)
└─ Packages/CompanionKit/        (local Swift package: no UI, fully unit-tested)
   ├─ Sources/
   │  ├─ OPACK/                  encoder/decoder
   │  ├─ TLV8/                   encoder/decoder
   │  ├─ BigInt/                 arbitrary-precision unsigned ints + modPow
   │  ├─ SRP/                    SRP-6a client, 3072-bit group, SHA-512
   │  ├─ Pairing/                pair-setup, pair-verify, credentials
   │  ├─ Transport/              NWConnection + NWProtocolFramer + frame cipher
   │  ├─ Discovery/              NWBrowser wrapper
   │  ├─ Session/                message layer, HID commands, app launch
   │  └─ Store/                  Keychain persistence
   └─ Tests/                     one test target per module
```

Rule: `CompanionKit` never imports SwiftUI or AppKit. The app talks to it through one `AppleTVSession` actor plus the `DeviceBrowser`.

---

## 3. Protocol stack (CompanionKit)

### 3.1 Discovery

- Use `NWBrowser` for `_companion-link._tcp` in domain `local.`.
- Publish `[DiscoveredDevice]` with name, endpoint and TXT record. Parse the TXT keys for the model and the identifier; check pyatv for which keys are present.
  - *Verified against pyatv 0.18.0:* model is `rpMd` (e.g. `AppleTV11,1`), stable identifier is `rpMRtID` (tvOS 16+), pairing flags are `rpFl` (hex). Other keys seen: `rpBA`, `rpHI`, `rpHA`, `rpHN`, `rpAD`, `rpVr`, `rpMac`. TXT keys are case-insensitive; match them lowercased.
  - Model names: `AppleTV5,3` → "Apple TV HD"; `AppleTV6,2`, `AppleTV11,1`, `AppleTV14,1` → "Apple TV 4K"; any other `AppleTV*` → "Apple TV".
  - **Correction:** Macs, iPhones, iPads and HomePods also advertise `_companion-link._tcp`. Keep only results whose `rpMd` starts with `AppleTV`.
  - `NWBrowser` returns one result per interface (Wi-Fi + Ethernet); dedupe by service name.
- Re-browse on network change. Remove devices that disappear.

### 3.2 Framing

Each frame is:

```
[type: 1 byte][length: 3 bytes, big-endian][payload: length bytes]
```

- Implement this as an `NWProtocolFramer` so `NWConnection` delivers whole frames.
- Frame types ✓ (verified, pyatv 0.18.0): `PS_Start=3, PS_Next=4, PV_Start=5, PV_Next=6, U_OPACK=7, E_OPACK=8, P_OPACK=9, SessionStart req/rsp=16/17`. Also `NoOp=1, PA_Req=10, PA_Rsp=11, SessionData=18, FamilyIdentity req/rsp/update=32/33/34`.
- *From pyatv:* only the first frame of each auth phase uses `PS_Start`/`PV_Start`; every later frame in that phase, **including the device's responses**, uses `PS_Next`/`PV_Next`.
- *From pyatv:* once encrypted, the 3-byte length **includes the 16-byte Poly1305 tag**. Empty payloads are sent unencrypted (no tag).

### 3.3 OPACK

- A binary format for dict / array / string / data / int / float / bool / null / UUID, with back-references for repeated values.
- Model it as `enum OPACKValue` with `Codable`-free encode and decode functions.
- **Tests:** round-trip every type. Byte-exact match against OPACK produced by pyatv for at least 10 real messages, including nested dicts, large ints and back-references.

### 3.4 TLV8

- Type-length-value with 255-byte chunking, as in HomeKit.
- **Tests:** a value longer than 255 bytes splits and rejoins correctly.

### 3.5 BigInt and SRP

- **BigInt:** unsigned, `[UInt64]` limbs, little-endian limb order. Needs add, sub, mul, mod and `modPow` (Montgomery or sliding-window), plus big-endian byte import/export.
- **Performance target:** a 3072-bit `modPow` in **under 200 ms** in a release build on Apple Silicon.
- **SRP-6a:**
  - 3072-bit group from RFC 5054, `g = 5`, SHA-512.
  - Username `"Pair-Setup"` ✓ (verified); the password is the 4-digit PIN as a decimal string.
- **Tests:**
  - BigInt against Python's `int` for random values. Generate the vectors with a script and commit it.
  - SRP: feed fixed private values into both our client and pyatv/srptools, then assert that A, u, S, K and M1 match exactly.

### 3.6 Pairing

**Pair-setup (one time, PIN on the TV)**

1. M1–M2: SRP start, then receive the salt and B.
2. M3–M4: send A and M1 proof, then verify M2.
3. M5–M6: exchange long-term Ed25519 keys. Use `Curve25519.Signing`, with ChaCha20-Poly1305 encrypting the sub-TLV. Take the key from HKDF-SHA512 over the SRP session key; get the salt/info strings from pyatv ✓ (below).
   - *Verified (pyatv 0.18.0):* encryption key = HKDF-SHA512(K, salt `"Pair-Setup-Encrypt-Salt"`, info `"Pair-Setup-Encrypt-Info"`); controller signing material = HKDF-SHA512(K, salt `"Pair-Setup-Controller-Sign-Salt"`, info `"Pair-Setup-Controller-Sign-Info"`), signed as `deviceX ‖ pairingID ‖ LTPK`.
   - M1 TLV is `{Method: 0x00, SeqNo: 0x01}`; M3 `{SeqNo: 3, PublicKey: A, Proof: M1}`; M5 `{SeqNo: 5, EncryptedData}`.
   - ChaCha20-Poly1305 nonces during pairing are fixed ASCII strings, left-padded with 4 zero bytes to 12 bytes: `"PS-Msg05"`, `"PS-Msg06"`, `"PV-Msg02"`, `"PV-Msg03"`.

Pairing data travels as TLV8 inside OPACK, e.g. `{"_pd": <tlv>, "_pwTy": 1}` ✓ (verified; every pair-setup message carries `_pwTy: 1`). A reply TLV containing the Error tag (`0x07`) is a failure.

**Pair-verify (every connect)**

- X25519 ephemeral exchange, plus Ed25519 signatures of both sides' keys.
- Derive session keys with HKDF-SHA512.
- *Verified (pyatv 0.18.0):* PV_Start sends `{"_pd": TLV{SeqNo: 1, PublicKey: X25519 pub}, "_auTy": 4}`. The M2 sub-TLV is decrypted with key HKDF-SHA512(shared, salt `"Pair-Verify-Encrypt-Salt"`, info `"Pair-Verify-Encrypt-Info"`). The device signs `theirX25519 ‖ theirID ‖ ourX25519`; we sign `ourX25519 ‖ ourID ‖ theirX25519`. M3 is `{SeqNo: 3, EncryptedData}` on PV_Next.
- Client/server encrypt keys come from info strings `"ClientEncrypt-main"` (our output) / `"ServerEncrypt-main"` (our input) ✓ (verified). **Addition:** the HKDF salt is the **empty string**, and the input keying material is the pair-verify X25519 shared secret.

**Credentials**

- `PairingCredentials { deviceID, ourLTSK, ourLTPK, theirLTPK, theirID }`, stored in the Keychain per Apple TV identifier.
- **Tests:** pair-verify message construction checked against pyatv vectors. A full pairing run against a real Apple TV is a manual check (Milestone 5).

### 3.7 Encrypted transport

- After pair-verify, encrypt every frame payload with ChaCha20-Poly1305.
- **Nonce:** a per-direction counter. **Corrected (pyatv 0.18.0):** the nonce is the counter encoded as a **12-byte little-endian integer**, i.e. 8 counter bytes little-endian followed by 4 zero bytes (padding at the end).
- **AAD:** the 4-byte frame header ✓ (verified), with the length already including the 16-byte tag.
- Counters start at 0 and increment per frame, separately for each direction.
- A decrypt failure tears down the connection and reconnects through pair-verify.

### 3.8 Session and commands

- **Message envelope:** `_i` (identifier), `_t` (1 = event, 2 = request, 3 = response), `_c` (content), `_x` (transaction ID) ✓ (verified). Requests and events go in `E_OPACK` frames. A response containing `_em` is an error.
- **Session start:** `_sessionStart` with a random `_sid` and `_srvT: "com.apple.tvremoteservices"` ✓ (verified). **Clarification:** it's an ordinary `E_OPACK` request, not a frame of type 16/17. `_sid` is a random UInt32; the session ID is `(remote _sid << 32) | local _sid`. pyatv sends `_systemInfo` before `_sessionStart` and `TVRCSessionStart` (`{"ProtocolVersionKey": "1.2"}`) after; check whether tvOS needs them when implementing M6.
- **HID buttons:** `_hidC` with `_hBtS` (1 = down, 2 = up) and `_hidC` code. A press sends down then up about 20 ms apart. A long press (Home, Select) holds down for 1 s.

HID codes ✓ (verified, pyatv 0.18.0 `HidCommand`):

| Button | Code |
|---|---|
| Up / Down / Left / Right | 1 / 2 / 3 / 4 |
| Menu (Back) | 5 |
| Select | 6 |
| Home | 7 |
| Volume + / − | 8 / 9 |
| Play/Pause | 14 |

pyatv's long-press Select holds down for 1 s, matching the plan.

- **Keep-alive** and reconnect: back off at 1 s, 2 s, 5 s, then 10 s max.
- **Text input** (`_tiStart` and RTI payloads) is **Milestone 9, stretch.** Its payload uses NSKeyedArchiver; study pyatv before starting.
- **Now playing:** Companion alone probably doesn't carry full metadata (pyatv gets it from MRP over AirPlay). **Milestone 10, stretch.** Until then the Now Playing card is **hidden**, not shown with placeholder text.

### 3.9 Public API used by the app

```swift
actor DeviceBrowser { var devices: AsyncStream<[DiscoveredDevice]> }
actor AppleTVSession {
  init(device: DiscoveredDevice, store: CredentialStore)
  var state: AsyncStream<ConnectionState>   // .disconnected, .connecting, .needsPairing, .connected
  func beginPairing() async throws          // TV shows PIN
  func finishPairing(pin: String) async throws
  func press(_ button: RemoteButton, hold: Bool = false) async throws
  func launchApp(bundleID: String) async throws
  func sendText(_ text: String) async throws // M9
}
```

---

## 4. Milestones

| # | Milestone | Acceptance checks |
|---|---|---|
| 0 | Project scaffold | Builds; menu bar icon appears; no Dock icon; Info.plist keys present; CompanionKit package with empty test targets runs |
| 1 | Discovery | The popover lists the real Apple TV by name within 3 s; it disappears when the TV is unplugged |
| 2 | Framing + plaintext connect | TCP connects; a hand-built `PS_Start` frame is sent and a response frame is parsed; framer unit tests pass |
| 3 | OPACK + TLV8 | All codec tests pass, including byte-exact pyatv vectors |
| 4 | BigInt + SRP | Vector tests pass; `modPow` meets the 200 ms target |
| 5 | Pair-setup + Keychain | PIN appears on the TV; entering it in the Pairing view succeeds; credentials survive an app relaunch |
| 6 | Pair-verify + encryption + first button | Relaunch, auto-connect without a PIN, press Select, and the TV reacts. **This is the core win.** |
| 7 | All buttons + keyboard shortcuts | Every control in Section 5 works; shortcuts in 5.6 work while the popover is focused |
| 8 | Full UI pass | Glass design on macOS 26 and fallback on 14/15 match Section 5 exactly; all icon states (5.1) wired to `ConnectionState`; multi-TV switcher works |
| 9 | Text input (stretch) | Typing in "Type on the TV" fills a tvOS search field |
| 10 | Now playing (stretch) | Card shows the real title, app and progress; hidden when nothing is playing |
| 11 | Ship | Developer ID signing, notarization, `.dmg`; first-run Local Network prompt appears and works |

---

## 5. Design spec (exact)

The source of truth is the design canvas (boards "macOS 26 · Liquid Glass", "First-time pairing", "macOS 15 and earlier · material fallback" and "Menu bar icon states"). The values below are transcribed from it.

- Units are points.
- "White N%" means `Color.white.opacity(N/100)`.
- Font is the system font (SF Pro).

### 5.1 Menu bar icon

A custom template image of a Siri Remote, shipped as a vector asset (PDF or SVG) with **Render As: Template Image**, so macOS tints it for light and dark menu bars. Rendered **11 × 19 pt** in the menu bar. The viewBox is `0 0 14 24`, with stroke `currentColor`, width 1.4, round caps and joins:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 14 24" fill="none" stroke="#000" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
  <rect x="2" y="1" width="9" height="22" rx="3.6"/>                 <!-- body -->
  <circle cx="6.5" cy="7.2" r="2.8"/>                                <!-- clickpad ring -->
  <circle cx="6.5" cy="7.2" r="0.7" fill="#000" stroke="none"/>      <!-- clickpad center -->
  <circle cx="4.9" cy="13.2" r="0.95" fill="#000" stroke="none"/>    <!-- Back -->
  <circle cx="8.1" cy="13.2" r="0.95" fill="#000" stroke="none"/>    <!-- TV -->
  <circle cx="4.9" cy="16.8" r="0.95" fill="#000" stroke="none"/>    <!-- Play -->
  <circle cx="8.1" cy="16.8" r="0.95" fill="#000" stroke="none"/>    <!-- Mute -->
  <path d="M12.8 9.5v3.6"/>                                          <!-- side volume rocker -->
</svg>
```

Don't substitute the SF Symbol `appletvremote.gen4`. Use the custom icon above.

**States**, driven by `ConnectionState`:

| State | Appearance |
|---|---|
| Disconnected | Icon at **40% opacity** |
| Connected | Icon at 100% |
| Open (popover showing) | Highlight drawn by the system. On macOS 26 it's the glass capsule; on older versions the standard menu bar highlight. Don't custom-draw it. |
| Needs pairing | Icon plus a **5 pt-radius dot**, top-right (offset ≈ x +8, y +5 on a 56 × 48 test tile; scale to the 11 × 19 icon so the dot touches the body's top-right corner). Design color is blue `#0A84FF` (dark) / `#0A6CFF` (light). |

**Known limitation:** a template image can't keep a colored dot. Try rendering the label as a composited non-template `NSImage` with the dot in system blue. If that tints badly in either menu bar appearance, fall back to a monochrome dot baked into a second template asset (`RemoteIconBadge`). Report which one shipped.

### 5.2 Popover — Liquid Glass (macOS 26+)

**Container**

- `MenuBarExtra(…).menuBarExtraStyle(.window)`. No arrow notch.
- Width **308**, padding **18**, corner radius **28**, vertical spacing **14**.
- Material: `.glassEffect(.regular.tint(Color(red: 20/255, green: 26/255, blue: 40/255).opacity(0.5)), in: .rect(cornerRadius: 28))`.
- Wrap all child glass shapes in one `GlassEffectContainer`.
- Design reference for the edge: 1 pt border at white 24% and a bright top highlight. Only add a manual stroke if the system glass doesn't already show an edge.
- Text color white. Secondary text white 78%.

**1. Device header**: an HStack with space-between.

- Left VStack, spacing 3:
  - Device name: **16 semibold**, e.g. "Living Room".
  - Status row, HStack spacing 6: a **7 pt** circle in `#30D158`, then "Connected · Apple TV 4K" at **12 regular**, white 78%. Show the model from TXT.
- Right: device switcher, a **36 × 36 circle**.
  - `.buttonStyle(.glass)`.
  - Icon: up/down chevrons (`chevron.up.chevron.down`) at 18 pt.
  - Opens a menu of discovered Apple TVs.
  - Hidden when only one TV is known.

**2. Now playing card** (Milestone 10; hidden until then)

- Padding **10**, radius **18**, glass at white 10% plus a 1 pt white 14% edge. VStack spacing 9.
- Row, HStack spacing 10:
  - Artwork **38 × 38**, radius **10**. Placeholder: white 20% fill with a 14 pt `play.fill`.
  - Title: **13 semibold**.
  - Subtitle: **12**, white 78%, in the form "Episode 3 · TV app".
- Progress bar: height **4**, radius 2. Track white 20%, fill solid white.

**3. Clickpad**, centered.

- Circle **224** diameter, glass at white 10%, 1 pt white 24% edge.
- Four direction buttons:
  - Hit area **46 × 46**, centered on each edge, **7** in from the ring.
  - Icon: chevrons at **22 pt**, stroke weight ≈ semibold. Use `chevron.up/down/left/right`.
  - No visible background.
- Center **OK** button:
  - Circle **88** diameter, `.buttonStyle(.glassProminent)` tinted blue `rgba(10,110,255,0.62)`. Use `.tint(Color(red: 10/255, green: 110/255, blue: 1).opacity(0.62))`.
  - Label "OK" at **16 semibold**.
- **Gestures**: a click on an arrow presses that direction. Drag/swipe on the ring (≥ 30 pt travel) sends the matching direction, once per swipe.

**4. Button row**: a 3-column grid, spacing **10**.

- Each button: height **60**, radius **22**, `.buttonStyle(.glass)`, VStack spacing 5. Icon **20 pt**, label **11 regular** at white 86%.

| Button | Icon | Action |
|---|---|---|
| Back | `chevron.left` | Menu (5) |
| Home | `tv` | Home (7); long-press opens Control Center on TV |
| Play/Pause | `playpause.fill` | 14 |

**5. Volume pill**

- Height **48**, radius **24**, glass at white 12%, horizontal padding 4.
- Left: a **44 × 44** button with `minus` at 20 pt.
- Center: HStack spacing 8, with `speaker.wave.1` at 18 pt and "Volume" at **13**, white 88%.
- Right: a **44 × 44** button with `plus` at 20 pt.
- Press-and-hold repeats every 150 ms.

**6. Text field** (functional in Milestone 9; visible but disabled until then)

- VStack spacing 6.
- Label "Type on the TV" at **11**, white 78%.
- Field: height **38**, radius **19** (capsule), horizontal padding **16**, fill black 24%, 1 pt white 22% border, text **13**.

**7. Footer hint**

- **11 regular**, white 78%, centered, line spacing ≈ 1.45.
- Text: "Keyboard works too: arrow keys move, Return selects, Esc goes back, Space plays or pauses."

### 5.3 Popover — material fallback (macOS 14–15)

The same structure and order as 5.2, with these differences:

| Element | Fallback value |
|---|---|
| Container | Width **300**, padding **16**, radius **14**, spacing **14**, background `#2B2B30` (`.background(.regularMaterial)` with dark appearance is acceptable if it matches closely), 1 pt white 10% border |
| Arrow notch | Shown in the design, but **`MenuBarExtra` windows have no arrow**. Drop it; don't fake one. |
| Device name | 15 semibold |
| Secondary text | `#A1A1A6` |
| Switcher | 36 × 36, radius 9, transparent, icon `#A1A1A6` |
| Now playing card | Padding 10, radius 10, white 6% fill; artwork 36 × 36 radius 6 `#4A5A6A`; progress 3 pt, track white 16%, fill `#0A84FF` |
| Clickpad | 220 diameter, fill `#353539`, 1 pt white 8% border; arrows 44 × 44 inset 6; OK 84 diameter fill `#46464C`, 15 semibold |
| Button row | Height 58, radius 14, fill `#3A3A3F`, label color `#D1D1D6` |
| Volume pill | Height 44, radius 14, fill `#3A3A3F` |
| Text field | Height 36, radius 10, padding 12, fill `#1F1F23`, border white 14% |
| Primary text | `#F5F5F7` |

### 5.4 Pairing view

Shown in place of the remote when the state is `.needsPairing`, inside the same popover. On macOS 26 it uses the glass container from 5.2; on 14–15, the fallback container.

- Width **308**, padding **24**, VStack spacing **16**, centered text.
- **Icon badge**: a **56** circle in glass (white 14% plus white 24% edge) holding the remote icon from 5.1 at **17 × 29**.
- **Title**: "Pair with {device name}" at **17 semibold**.
- **Body**: "Enter the 4-digit code shown on your TV." at **13**, white 80%.
- **PIN boxes**: 4 boxes, HStack spacing **10**.
  - Each box **54 × 62**, radius **18**, fill black 26%, 1 pt white 26% border, digit at **28 semibold**, centered.
  - Focused box: **2 pt `#4DA3FF`** border plus a 3 pt outer ring at `#4DA3FF` 28%.
  - Typing advances focus; Delete goes back; paste of 4 digits fills all boxes.
- **Pair button**:
  - Full width, height **44**, capsule, `.buttonStyle(.glassProminent)` tinted `rgba(10,100,235,0.85)`, label **14 semibold**.
  - Disabled until 4 digits are entered.
  - Shows a spinner while verifying.
- **Cancel button**: full width, height **40**, plain, text `#A9D2FF` at **14**.
- **Footnote**: "You only do this once. The pairing key stays in your Mac's Keychain." at **11**, white 78%.
- **Wrong PIN**: shake the boxes, clear them, then show "That code didn't match. Try again." in the body line.

### 5.5 Other states

| State | Display |
|---|---|
| No Apple TV found | Header shows "No Apple TV found". Body: "Make sure your Mac and Apple TV are on the same network." Remote controls disabled at 40% opacity. |
| Connecting | Status dot is gray `#8E8E93`, with the text "Connecting…" |
| Disconnected | Status dot is `#FF453A`, with the text "Not connected · Retry"; Retry is a link-style button |

### 5.6 Keyboard shortcuts

These work while the popover has focus. Use `.onKeyPress`.

| Key | Action |
|---|---|
| ↑ ↓ ← → | Directions |
| Return | Select |
| Esc | Back (Menu). The popover must **not** close on Esc while the remote has focus. If `MenuBarExtra` closes it anyway, document that and use ⌫ instead. |
| Space | Play/Pause |
| ⌘↑ / ⌘↓ | Volume up / down |
| H | Home |

Key repeat on arrows sends repeated presses.

### 5.7 Accessibility

- Every icon-only button has an `accessibilityLabel` (Up, Down, Left, Right, Select, Back, Home, Play or pause, Volume up, Volume down, Switch Apple TV).
- Respect Reduce Transparency: on macOS 26 with it enabled, use the fallback colors from 5.3.
- Respect Increase Contrast: borders go to white 50%.

---

## 6. Liquid Glass implementation notes

```swift
@ViewBuilder func remoteBody() -> some View {
  if #available(macOS 26, *) {
    GlassEffectContainer(spacing: 14) { GlassRemoteView(model: model) }
  } else {
    FallbackRemoteView(model: model)
  }
}
```

- Use the system glass APIs (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)` / `.glassProminent`). Don't fake glass with blur plus gradients on macOS 26.
- These API names come from the macOS 26 SDK as of mid-2026. **Confirm them against the installed Xcode SDK** and adjust if they've changed.
- Keep both views reading from the same `RemoteViewModel`. No logic in views beyond layout.

---

## 7. Testing and verification

- **Unit tests** (Swift Testing) for OPACK, TLV8, BigInt, SRP, the frame cipher and the framer. Vectors come from `scripts/gen_vectors.py` (pyatv/srptools), committed with the generated JSON.
- **Integration test target** (skipped in CI) that needs a real Apple TV:
  1. discover;
  2. pair-verify with stored credentials;
  3. press Select;
  4. disconnect.
- **Manual checklist per release:**
  - fresh install → Local Network prompt;
  - pairing;
  - relaunch auto-connects;
  - every button;
  - every shortcut;
  - light and dark menu bars;
  - macOS 26 glass and macOS 14/15 fallback;
  - Wi-Fi drop and reconnect.
- **Design check:** screenshot both popovers and compare against the canvas boards before closing Milestone 8.

---

## 8. Out of scope for v1

- Siri / microphone
- AirPlay streaming
- Power on via Wake-on-LAN
- Multiple simultaneous TVs
- iOS or Windows ports
- Mac App Store build

---

## 9. Verification log

- **pyatv 0.18.0** (installed in `.venv`, dev only), checked at project start:
  - Matched the plan: frame types, HID codes, SRP username, `_pd`/`_pwTy`, envelope keys, `_sessionStart`/`_srvT`, `ClientEncrypt-main`/`ServerEncrypt-main`, AAD = frame header.
  - Corrected: transport nonce layout (12-byte little-endian counter, zero padding at the end).
  - Added: empty HKDF salt for session keys; pairing salt/info strings; fixed pairing nonces; tag counted in frame length; `_auTy: 4`; `_systemInfo` / `TVRCSessionStart`; Companion TXT keys and the Apple TV filter.
