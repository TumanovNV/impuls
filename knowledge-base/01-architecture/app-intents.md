# App Intents and system automation

Status: canonical architecture contract for IMP-53 / IMP-54.

## Scope

Impuls exposes a deliberately small system-automation surface. App Intents are adapters over existing product owners, not a second application runtime.

The stable catalog is:

| ID | Operation | Status |
| --- | --- | --- |
| `navigation.show` | Show Impuls | ship in IMP-54 |
| `navigation.openModule` | Open a selected Impuls module | ship in IMP-54 |
| `navigation.hide` | Hide Impuls | deferred |
| `navigation.toggle` | Toggle Impuls | rejected |
| `content.addSnippetText` | Add explicitly supplied text to Snippets | ship in IMP-54 |
| `content.addShelfFiles` | Add supplied files to Shelf | deferred |
| `content.addNoteText` | Add supplied text to Notes | deferred |
| `transform.translateText` | Translate supplied text | deferred |
| `query.safePowerState` | Return a redacted power/device state | deferred |
| `query.clipboardHistory` | Return clipboard history | rejected |
| `action.executeQuickAction` | Generic quick-action executor | rejected |

IMP-54 implements exactly three intent types: Show Impuls, one parameterized Open Module intent, and Add Text to Snippets. Power Center, Clipboard, Snippets and Shelf shortcuts are preconfigured instances of Open Module rather than duplicate intent types.

## Ownership boundary

- `NotchController` remains the only owner of panel/display routing.
- One shared `NotchViewModel` remains the only runtime service graph.
- `SnippetStore` remains the only Snippets persistence owner.
- App Intents never construct a `NotchController`, `NotchViewModel`, display state, `SnippetStore`, clipboard store, device provider or other product owner.
- `ImpulsAutomationRuntime` is a narrow bridge installed by `AppDelegate` after normal composition. It exposes only typed commands and stable errors to the executable App Intents target.

This keeps WidgetKit reusable later: a widget may reuse pure module/command/error types, but not panel UI, private clipboard data or device identities.

## Lifecycle contract

App Intents must behave consistently when Impuls is terminated, backgrounded or frontmost.

A system invocation may cold-launch the process before `AppDelegate` has installed the authoritative controller. That ordinary startup race is **not** `serviceUnavailable`. The automation runtime waits once for normal composition for a bounded five seconds, without polling. When `AppDelegate` installs the existing controller, pending invocations continue against it.

`serviceUnavailable` is reserved for a genuinely missing or torn-down runtime after bounded readiness. The readiness mechanism must never repair a race by constructing a second controller, model or store.

Navigation keeps display selection inside `NotchController`. App Intents do not choose monitors or create windows.

## Module availability

`navigation.openModule` accepts stable module identifiers. Before opening, the adapter verifies that the requested tab is in the current authoritative `visibleTabs` set. A disabled/unavailable module returns `moduleUnavailable`; it is not silently redirected to another module.

Power uses the existing `openPower()` path. Other modules use the existing `open(tab:)` path.

## Snippets mutation

`content.addSnippetText` accepts only text explicitly supplied to the Shortcut and an optional explicitly supplied label.

Before the persistence owner is called:

- text is trimmed and must be non-empty;
- text is limited to 64 KiB UTF-8 and 16,384 characters;
- label is trimmed and limited to 4 KiB UTF-8 and 160 characters;
- invalid input fails before any write;
- a successful invocation calls the shared `SnippetStore.add(label:text:)` path exactly once.

The intent does not read existing Snippets and does not return their contents.

## Privacy and discovery

Discovery metadata is static. It may contain intent titles, parameter descriptions, module names and predefined phrases only.

It must never contain stored clipboard contents, snippets, notes, calendar data, local file paths, device identifiers, logs or other user data. Discovery must not start providers, request TCC permissions, perform network access, install translation assets or query hardware.

Clipboard history is explicitly outside the App Intents read surface. A future power/device query requires a separate redaction, freshness and opt-in contract before implementation.

## Stable errors

The automation boundary exposes only:

- `moduleUnavailable`
- `invalidInput`
- `operationUnavailable`
- `permissionRequired`
- `serviceUnavailable`
- `unsupportedOperation`

The App Intents target maps these cases to localized human-readable errors. Raw system errors, internal paths, identifiers and provider diagnostics never cross the boundary.

## App Shortcuts

There is one `AppShortcutsProvider`. IMP-54 provides shortcuts for:

- Show Impuls;
- Open Power Center;
- Open Clipboard;
- Open Snippets;
- Open Shelf;
- Add Text to Snippets.

The user-facing metadata is localized for the same seven locales shipped by the app: English, Russian, German, French, Spanish, Simplified Chinese and Japanese.

The deployment target remains macOS 15. The first wave uses the macOS-15-compatible foreground/background execution contract; newer Siri/Spotlight schemas and execution modes are IMP-55 scope.

## Packaging

Impuls is a SwiftPM executable assembled into a `.app` by `Scripts/bundle.sh`, not an Xcode application target. Compiling App Intent Swift types is therefore insufficient: the bundle must also contain generated `Metadata.appintents` so Shortcuts/Spotlight can discover them.

`Scripts/bundle.sh` owns this extraction before signing. CI must fail if the packaged app does not contain non-empty App Intents metadata.

## Verification

Automated tests cover:

- bounded cold-launch readiness using the installed authoritative runtime;
- one requested module routed once;
- unavailable modules returning the stable error;
- Add Snippet trimming and exactly-once writing;
- empty/oversized input failing before a write;
- pending requests failing safely when the runtime tears down.

System smoke for IMP-54 covers the three intents with the app terminated, backgrounded and frontmost. Navigation must use the existing display owner and Add Snippet must produce one persisted item per invocation.

## Deferred macOS 27 work

IMP-55 owns Siri/Spotlight behavior specific to newer system releases, newer supported execution modes, schemas, rich snippets and related HIG decisions. None of those are required to ship the macOS 15 first wave.
