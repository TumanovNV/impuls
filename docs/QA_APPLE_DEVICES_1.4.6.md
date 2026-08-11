# Hardware QA — Impuls 1.4.6 Apple Device Battery Center

Manual test matrix for the multi-device Battery Center. Created in phase 01,
before any 1.4.6 code exists.

CI can build the code and run the fixtures; it cannot connect an iPhone or put
AirPods in a case. A box is ticked only by someone who saw the result on the
device named in the row, and the date and macOS version go in the notes column.

**Status: eleven rows verified on 11 August 2026.** The AirPods registry
question came back negative and the `system_profiler` fallback that replaced it
came back positive; the iPhone USB path was refused without a session and then
worked through one. Everything else is still untested.

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
| 3.11 | Accessory battery updates within a minute while the panel is open | `[ ]` | polled at 60 s |

## 4. AirPods

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 4.1 | AirPods connected: what the system actually publishes — overall only, or left/right/case | `[x]` | 11 Aug 2026, AirPods Pro connected: the IORegistry publishes **nothing** — no overall value, no components. macOS shows the level from `bluetoothd` |
| 4.2 | AirPods Pro connected: same question | `[ ]` | |
| 4.3 | AirPods Max connected: single battery presented as a single battery | `[ ]` | |
| 4.4 | One bud in the case: the missing bud is absent, not 0% | `[ ]` | |
| 4.5 | Case closed and away: last case value is shown with its age, or not at all | `[ ]` | |
| 4.6 | AirPods disconnected: no stale value presented as realtime | `[ ]` | |
| 4.7 | AirPods switched to an iPhone mid-session: card leaves cleanly | `[ ]` | |
| 4.8 | Values match the system Bluetooth menu | `[ ]` | |
| 4.9 | Whether `BatteryPercentLeft` / `Right` / `Case` exist at all on current macOS | `[x]` | 11 Aug 2026: they do not. `ioreg -r -k BatteryPercent -l` returned no nodes with AirPods Pro connected; "AirPods" appears nowhere in the registry; the historical `DeviceCache` in `com.apple.Bluetooth.plist` is gone |
| 4.10 | `system_profiler` fallback: AirPods appear with a battery | `[x]` | 11 Aug 2026, AirPods Pro: `airPodsPro` "AirPods Pro (…)", model `Headphones`, right bud 87 % |
| 4.11 | The value matches what macOS reports at the same moment | `[x]` | 11 Aug 2026: macOS `Right Battery Level: 87 %`, Impuls `right=87`. Watched across three runs as it fell 89 → 88 → 87, matching each time |
| 4.12 | Only the components the system actually publishes are shown | `[x]` | 11 Aug 2026: one bud was in the case; only the other bud's value existed and only it was shown. No invented left or case value |
| 4.13 | `system_profiler` cost is acceptable | `[x]` | 11 Aug 2026: 0.08–0.12 s wall clock, ~2 KB JSON. Run at most once per 30 s, and on panel open |
| 4.14 | Disconnected accessories are not listed with a stale charge | `[x]` | 11 Aug 2026: four paired but disconnected devices in the same output were correctly absent |

## 5. iPhone and iPad over USB — Beta

Blocks enabling the provider. If these fail, the provider does not ship enabled,
and `APPLE_DEVICE_BATTERY_SUPPORT.md` records why.

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 5.1 | Trusted iPhone connected by cable: discovered | `[x]` | 11 Aug 2026, iOS 26.5.2: `ListDevices` returned 1 USB device, `ReadPairRecord` found the pairing, lockdownd answered `QueryType` |
| 5.2 | Battery percentage read and matching the iPhone's own display | `[ ]` | the value **is** read — 65 %, then 69 % while charging, over five consecutive reads. Comparing it against what the phone's own screen shows still needs a person holding the phone |
| 5.3 | Charging state correct while charging and while not | `[ ]` | charging = true and externalConnected = true were read while the phone was on the cable; the discharging case is untested |
| 5.4 | User-visible device name shown, no identifier anywhere in the UI | `[ ]` | |
| 5.5 | Untrusted iPhone: the "unlock and trust this computer" explanation, not an error code | `[ ]` | |
| 5.6 | Locked iPhone: a clear state, no hang, no repeated retries | `[ ]` | |
| 5.7 | Trust denied by the user: understandable state, no loop | `[ ]` | |
| 5.8 | Cable pulled mid-read: no hang, no crash, card becomes disconnected | `[ ]` | |
| 5.9 | iPad over USB: same rows as 5.1–5.3 | `[ ]` | |
| 5.10 | iPhone and iPad connected simultaneously: two cards, correct values | `[ ]` | |
| 5.11 | Nothing is written to the device: no pairing record, no profile, no setting, no file | `[ ]` | |
| 5.12 | Provider disabled: no socket, no connection attempt at all | `[ ]` | |
| 5.13 | Current iOS version noted for each device tested | `[x]` | iOS 26.5.2, `iPhone17,2`, 11 Aug 2026 |
| 5.16 | TLS session: in-memory identity, handshake, peer validation, battery | `[x]` | 11 Aug 2026: PKCS#8 unwrapped, `SecIdentityCreate` succeeded with no keychain, handshake completed, peer validated against the pair record, battery returned |
| 5.17 | Repeated reads are stable and leak nothing | `[x]` | 11 Aug 2026: five consecutive reads all returned 65 %, 0.02 s each; open file descriptors 3 before and 3 after |
| 5.18 | Locked iPhone, cable pulled mid-read, reconnect | `[ ]` | needs a person at the device |
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
| 9.5 | Manual refresh works and is not the only way to get data | `[ ]` | |
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

## 12. Performance

| # | Case | Result | Notes |
| --- | --- | --- | --- |
| 12.1 | Idle CPU with the panel closed, comparable to 1.4.5 | `[ ]` | |
| 12.2 | Idle CPU with several external devices present | `[ ]` | |
| 12.3 | Wakeups and timers do not grow with the number of devices | `[ ]` | |
| 12.4 | Memory stable over a long session | `[ ]` | |
