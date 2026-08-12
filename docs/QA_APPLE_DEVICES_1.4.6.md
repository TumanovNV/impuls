# Hardware QA — Impuls 1.4.6 Apple Device Battery Center

Manual test matrix for the multi-device Battery Center. Created in phase 01,
before any 1.4.6 code exists.

CI can build the code and run the fixtures; it cannot connect an iPhone or put
AirPods in a case. A box is ticked only by someone who saw the result on the
device named in the row, and the date and macOS version go in the notes column.

**Status: twenty-four rows verified and two limitations or UI issues reproduced on
11–12 August 2026.** The AirPods registry question came back negative and the
`system_profiler` fallback that replaced it came back positive, but the public
macOS report can retain a bud that is already back in its case; the iPhone USB
path was refused without a session and then worked through one. Everything else
is still untested.

Legend: `[ ]` not tested · `[x]` verified on hardware · `[—]` not applicable to
this configuration · `[!]` tested and failed, see notes.

## 1. Mac itself — regression against 1.4.5

The existing module must not get worse. These are the rows that block a release.

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 1.1 | MacBook, Apple Silicon: percentage, state, time estimate as in 1.4.5 | `[ ]` | |
| 1.2 | MacBook: charging, discharging, charged, finishing charge | `[ ]` | |
| 1.3 | MacBook: cycle count, maximum capacity, temperature, condition still shown when available | `[ ]` | |
| 1.4 | Desktop Mac (mini / Studio / iMac): the Power layout, not an empty battery card | `[ ]` | |
| 1.5 | Module disabled in Settings: no monitoring, no timer, no external discovery | `[ ]` | |
| 1.6 | Panel open: fast local refresh; panel closed: no fast timer | `[ ]` | |
| 1.7 | Existing settings from 1.4.5 load unchanged | `[ ]` | |
| 1.8 | Backup exported by 1.4.5 imports into 1.4.6 | `[ ]` | |
| 1.9 | Backup exported by 1.4.6 imports into 1.4.5 without crashing | `[ ]` | |
| 1.10 | Backup moved between a MacBook and a desktop Mac | `[ ]` | |

## 2. Update experience

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 2.1 | Update 1.4.5 → 1.4.6: no new permission prompt appears on its own | `[ ]` | |
| 2.2 | Update 1.4.5 → 1.4.6: no new network connection at launch | `[ ]` | |
| 2.3 | Apple devices stay off until the user turns them on | `[ ]` | |
| 2.4 | Sparkle update from 1.4.5 installs and relaunches normally | `[ ]` | |

## 3. Magic accessories

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 3.1 | Magic Mouse connected: appears with a percentage | `[ ]` | |
| 3.2 | Magic Keyboard connected: appears with a percentage | `[ ]` | |
| 3.3 | Magic Trackpad connected: appears with a percentage | `[ ]` | |
| 3.4 | Value matches the system Bluetooth menu | `[ ]` | |
| 3.5 | Accessory switched off: card leaves or is marked disconnected, never shows 0% | `[ ]` | |
| 3.6 | Accessory connected by cable: no invented charging state | `[ ]` | |
| 3.7 | Built-in keyboard and trackpad of a MacBook are not listed as accessories | `[ ]` | |
| 3.8 | Two accessories of the same model connected at once: two distinct cards | `[ ]` | |
| 3.9 | A non-Apple Bluetooth mouse or keyboard is not listed | `[ ]` | vendor identifier, not the product name |
| 3.10 | Accessory reconnects after being switched off: same card, not a second one | `[ ]` | |
| 3.11 | Accessory battery updates within a minute while the panel is open | `[ ]` | provider polls at 10 s while the panel is active; hardware behaviour still unverified |

## 4. AirPods

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 4.1 | AirPods connected: what the system actually publishes — overall only, or left/right/case | `[x]` | 11 Aug 2026, AirPods Pro connected: the IORegistry publishes **nothing** — no overall value, no components. macOS shows the level from `bluetoothd` |
| 4.2 | AirPods Pro connected: same question | `[x]` | 12 Aug 2026: AirPods Pro were discovered by Impuls; Left, Right and Case appeared only when macOS published their corresponding `system_profiler` keys |
| 4.3 | AirPods Max connected: single battery presented as a single battery | `[ ]` | |
| 4.4 | One bud in the case: the missing bud is absent, not 0% | `[!]` | 12 Aug 2026: after the right bud was returned to its case, both `system_profiler` and macOS Bluetooth Settings retained left 100 %, right 100 %, case 28 % for the full 30 s sample. No public presence property exists, so Impuls cannot honestly remove the last-known right value until macOS removes the key |
| 4.5 | Case closed and away: last case value is shown with its age, or not at all | `[ ]` | |
| 4.6 | AirPods disconnected: no stale value presented as realtime | `[ ]` | |
| 4.7 | AirPods switched to an iPhone mid-session: card leaves cleanly | `[ ]` | |
| 4.8 | Values match the system Bluetooth menu | `[x]` | 12 Aug 2026: `system_profiler` and macOS Bluetooth Settings both showed left 100 %, right 100 %, case 28 %. They matched each other, including the last-known right value after it was put in the case |
| 4.9 | Whether `BatteryPercentLeft` / `Right` / `Case` exist at all on current macOS | `[x]` | 11 Aug 2026: they do not. `ioreg -r -k BatteryPercent -l` returned no nodes with AirPods Pro connected; "AirPods" appears nowhere in the registry; the historical `DeviceCache` in `com.apple.Bluetooth.plist` is gone |
| 4.10 | `system_profiler` fallback: AirPods appear with a battery | `[x]` | 11 Aug 2026, AirPods Pro: `airPodsPro` "AirPods Pro (…)", model `Headphones`, right bud 87 % |
| 4.11 | The value matches what macOS reports at the same moment | `[x]` | 11 Aug 2026: macOS `Right Battery Level: 87 %`, Impuls `right=87`. Watched across three runs as it fell 89 → 88 → 87, matching each time |
| 4.12 | Only the components the system actually publishes are shown | `[x]` | 11 Aug: only one published bud existed and only it was shown. 12 Aug: macOS retained both component keys for more than 30 s after Right returned to the case; Bluetooth Settings showed the same stale state. Impuls mirrored the report and did not guess physical presence |
| 4.13 | `system_profiler` cost is acceptable | `[x]` | 11 Aug 2026: 0.08–0.12 s wall clock, ~2 KB JSON. 12 Aug QA: manual refresh performed a fresh read and active polling ran at 10 s; source-report time was presented as «Получено от macOS» |
| 4.14 | Disconnected accessories are not listed with a stale charge | `[x]` | 11 Aug 2026: four paired but disconnected devices in the same output were correctly absent |

## 5. iPhone and iPad over USB — Beta

Blocks enabling the provider. If these fail, the provider does not ship enabled,
and `APPLE_DEVICE_BATTERY_SUPPORT.md` records why.

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 5.1 | Trusted iPhone connected by cable: discovered | `[x]` | 11 Aug 2026, iOS 26.5.2: transport sequence succeeded. 12 Aug 2026, Beta QA build: one USB iPhone reached the provider and appeared in the live UI without restarting Impuls |
| 5.2 | Battery percentage read and matching the iPhone's own display | `[x]` | 12 Aug 2026: Impuls reported 100 % and the physical iPhone screen showed 100 % at the same moment |
| 5.3 | Charging state correct while charging and while not | `[x]` | 11 Aug: charging = true and externalConnected = true were read while charging. 12 Aug at 100 %: not charging with external power still connected was reported correctly |
| 5.4 | User-visible device name shown, no identifier anywhere in the UI | `[x]` | 12 Aug 2026: a display name, USB connection and Beta label appeared in the live UI; the observation and QA record contain no raw identifier |
| 5.5 | Untrusted iPhone: the "unlock and trust this computer" explanation, not an error code | `[ ]` | |
| 5.6 | Locked iPhone: a clear state, no hang, no repeated retries | `[x]` | 12 Aug 2026: with USB still connected, the locked iPhone remained visible and readable; provider reads kept returning one device, the process stayed stable and no usbmuxd connection remained open. No permission or transport error occurred, so the last-good failure path was not exercised |
| 5.7 | Trust denied by the user: understandable state, no loop | `[ ]` | |
| 5.8 | Cable pulled mid-read: no hang, no crash, card becomes disconnected | `[x]` | 12 Aug 2026: USB was pulled immediately after Refresh. Impuls and the UI stayed responsive; provider settled on a successful empty list and the iPhone stopped being current. FD returned 58 → 60 → 58, no usbmuxd connection remained, no duplicate or raw transport error appeared, and a 35 s stabilization window showed no retry loop |
| 5.9 | iPad over USB: same rows as 5.1–5.3 | `[ ]` | |
| 5.10 | iPhone and iPad connected simultaneously: two cards, correct values | `[ ]` | |
| 5.11 | Nothing is written to the device: no pairing record, no profile, no setting, no file | `[ ]` | |
| 5.12 | Provider disabled: no socket, no connection attempt at all | `[ ]` | |
| 5.13 | Current iOS version noted for each device tested | `[x]` | iOS 26.5.2, `iPhone17,2`, 11 Aug 2026 |
| 5.16 | TLS session: in-memory identity, handshake, peer validation, battery | `[x]` | 11 Aug 2026: PKCS#8 unwrapped, `SecIdentityCreate` succeeded with no keychain, handshake completed, peer validated against the pair record, battery returned |
| 5.17 | Repeated reads are stable and leak nothing | `[x]` | 11 Aug 2026: five consecutive transport reads all returned 65 %, 0.02 s each; open file descriptors 3 before and 3 after. 12 Aug, live UI: repeated Refresh Devices caused no hang, duplicate, unavailable flash or connection problem; the Impuls process remained healthy at its 58-FD baseline with no open usbmuxd connection |
| 5.18 | Locked iPhone, cable pulled mid-read, reconnect | `[x]` | 12 Aug 2026: after the Test 4 disconnect, the same locked iPhone reappeared automatically in about 1 s; unlocked reconnect also worked. No manual refresh or Impuls restart was required, the opaque identity set stayed unchanged, one device returned, FD settled at 58 and no usbmuxd connection remained open |
| 5.19 | Locked iPhone recovers after unlock without restarting Impuls | `[x]` | 12 Aug 2026: after unlocking the same USB-connected iPhone, one manual refresh returned one readable device at 100 % in the same Impuls process. The UI kept one card with no duplicate or transport error; visual continuity confirmed the same device identity |
| 5.14 | **The deciding measurement:** with a trusted iPhone connected, does `GetValue` in the battery domain return a value or an error? | `[x]` | 11 Aug 2026, iOS 26.5.2: **`Error = GetProhibited`**. `StartSession` then succeeded and returned `EnableSessionSSL = true`. `DeviceName` and `ProductType` are readable without a session; the battery domain is not |
| 5.15 | With the flag off (the shipping default), no socket is ever opened to `/var/run/usbmuxd` | `[x]` | 11 Aug 2026, macOS 15, ad-hoc release bundle: `lsof -U` showed no usbmuxd connection over a 10 s run. Verified without hardware because it is about what Impuls does *not* do |

## 6. Wi-Fi — future, not a 1.4.6 blocker

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 6.1 | iPhone reachable over Wi-Fi sync after USB pairing | `[ ]` | |
| 6.2 | Device disappears from Wi-Fi: last value marked with its age | `[ ]` | |
| 6.3 | Network changed or Wi-Fi off: no alert storm | `[ ]` | |

## 7. Devices with no Mac-side path

Confirm the honest behaviour: they are absent, and nothing in the UI promises
them.

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 7.1 | Apple Watch paired to the user's iPhone: not listed, not promised | `[ ]` | |
| 7.2 | Apple Pencil paired to an iPad: not listed | `[ ]` | |
| 7.3 | AirTag nearby: not listed, and no invented percentage | `[ ]` | |
| 7.4 | Vision Pro: not listed | `[ ]` | |
| 7.5 | HomePod / Apple TV: not listed | `[ ]` | |

## 8. Robustness

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 8.1 | Zero external devices: a calm empty state, not an error | `[ ]` | |
| 8.2 | One device | `[ ]` | |
| 8.3 | Ten or more devices: list scrolls, panel geometry intact | `[ ]` | |
| 8.4 | Two devices with identical names: distinguishable, not merged | `[ ]` | |
| 8.5 | Same iPhone visible over two transports: one card, not two | `[ ]` | |
| 8.6 | Very long device name, Cyrillic name, emoji in name: no overflow | `[ ]` | |
| 8.7 | Mac sleep and wake: providers recover, no duplicated timers, no scan storm | `[ ]` | |
| 8.8 | Bluetooth off and on again | `[ ]` | |
| 8.9 | Module turned off and on again | `[ ]` | |
| 8.10 | Application restart: no orphaned tasks, no stale card presented as live | `[ ]` | |
| 8.11 | A failing provider does not affect the Mac battery or any other module | `[ ]` | |

## 9. Settings

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 9.1 | Apple devices can be turned off entirely; discovery then does nothing | `[ ]` | |
| 9.2 | Individual device can be hidden and shown again | `[ ]` | |
| 9.3 | Device order can be changed and survives a restart | `[ ]` | |
| 9.4 | A stale or hidden device can be forgotten | `[ ]` | |
| 9.5 | Manual refresh works and is not the only way to get data | `[x]` | 12 Aug 2026, AirPods Pro: manual refresh performed a fresh `system_profiler` read; with the panel active, the provider also polled at 10 s |
| 9.6 | Settings survive an application restart | `[ ]` | |

## 10. Privacy

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 10.1 | No identifier (UDID, serial, Bluetooth address) anywhere in the panel or Settings | `[ ]` | |
| 10.2 | No identifier in ordinary logs | `[ ]` | |
| 10.3 | Feedback report contains no device identifier and no device battery data | `[ ]` | |
| 10.4 | Exported backup contains no identifier, no last-seen time and no battery history | `[ ]` | |
| 10.5 | No network connection is created by any of this | `[ ]` | |

## 11. Interface and accessibility

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 11.1 | Compact, standard and large panel presets: nothing clipped | `[ ]` | |
| 11.2 | Mac with a notch and Mac without one | `[ ]` | |
| 11.3 | Light and dark system appearance | `[ ]` | |
| 11.4 | Increase Contrast, Reduce Transparency, Reduce Motion | `[ ]` | |
| 11.5 | VoiceOver reads a device card as name, charge and state — never an identifier | `[ ]` | |
| 11.6 | VoiceOver reads multi-component AirPods sensibly | `[ ]` | |
| 11.7 | Keyboard navigation between modules and within the list still works | `[ ]` | |
| 11.8 | Russian and English interface, both complete | `[ ]` | |
| 11.9 | Device age never renders as a negative duration | `[!]` | 12 Aug 2026, live iPhone Beta QA: the fresh device age rendered as `-3 с`. After hardware QA, abbreviated age was changed to a non-negative elapsed duration with future clock skew clamped to zero, and a regression test was added. The rebuilt UI still needs one manual confirmation |

## 12. Performance

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 12.1 | Idle CPU with the panel closed, comparable to 1.4.5 | `[ ]` | |
| 12.2 | Idle CPU with several external devices present | `[ ]` | |
| 12.3 | Wakeups and timers do not grow with the number of devices | `[ ]` | |
| 12.4 | Memory stable over a long session | `[ ]` | |
