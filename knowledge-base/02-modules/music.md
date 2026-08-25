---
title: Music Module
type: module
status: production
documentation_version: 1.4
app_version: 1.4.16
last_reviewed: 2026-08-25
tags: [impuls, module, music, webkit, automation]
---

# Music

## Web content process termination (1.4.16, IMP-12 / #112)

WebKit's content process может умереть — краш или system reclaim под memory pressure, что для тяжёлого SPA обычное дело. Раньше это никем не обрабатывалось: view становился пустым, а последний adopted track оставался на экране вместе с transport-кнопками, которые молча ничего не делали. JS-pump умирал вместе с процессом, поэтому ничего само не исправлялось — помогал только явный reload.

`WebMusicPlayer.webViewWebContentProcessDidTerminate(_:)` теперь очищает состояние и сообщает об отказе:

- guard по **идентичности** web view (`current === webView`) плюс `isPopup` — поздний callback от view, которым player уже не владеет (после `teardown()`), или от popup, не может очистить живое состояние;
- `onState(source, nil)` — capabilities сбрасываются через тот же state pipeline, а не вторым независимым путём, который мог бы с ним разойтись;
- `onFailure(source, …)` — фиксированное локализованное сообщение, ничего со страницы;
- `playbackIntent += 1` — press, который был в полёте, принадлежал странице, которой больше нет.

**Automatic reload намеренно отсутствует.** Страница, упавшая один раз, склонна упасть снова, и перезагрузка из того же callback'а, который сообщает о падении, — это и есть retry storm. Восстановление идёт обычным путём: следующий явный Open/Reload пользователя, `show(source:)` находит пригодный web view, WebKit поднимает новый процесс. Никаких новых таймеров, задач или сетевых путей.

Источник в отчёте передаётся как обычно, поэтому существующий guard `selectedSource == source` в `MediaController` решает, вправе ли уже переключённый сервис что-то менять. Обе половины защищают пользователя только вместе, и обе покрыты тестами.

**Recovery.** Отказ от automatic reload имеет смысл только если следующий явный Open/Retry действительно восстанавливает плеер. После termination web view сохраняет прежний provider URL, поэтому обычная логика `show(source:)` увидела бы «тот же source, URL всё ещё allowlisted» и запросила бы snapshot у страницы, которой больше нет — пользователь остался бы в failed state даже после Retry.

Поэтому termination поднимает `needsRecoveryLoad`, а `show(source:)` принимает решение через `WebMusicPlayer.showAction(...)`:

| Ситуация | Действие |
| --- | --- |
| source изменился | `load` (recovery-флаг к новому сервису не относится) |
| recovery нужен, текущий URL — provider | `recoveryReload` — ровно одна явная навигация |
| recovery нужен, URL не provider (например локальная страница ошибки) | `load` домашней страницы |
| обычный случай, страница жива | `snapshot` |

Флаг снимается **до** навигации, поэтому recovery происходит один раз; повторный краш поднимает его снова и снова даёт пользователю Retry — это цикл ровно настолько, насколько его выбирает пользователь. Сбрасывается также при teardown и при создании нового web view. Ни таймера, ни отложенной перезагрузки, ни фоновой сетевой активности не добавлено: навигация выполняется только внутри явного пользовательского `show(source:)`.


## Назначение

Управление **явно выбранным** источником музыки без угадывания «какой из запущенных плееров главный», с честным Now Playing state — источник не выдаёт непроверенную возможность за доступную.

Поддерживаются Apple Music, Яндекс Музыка, VK Музыка и YouTube Music. Каталог источников в 1.4.16 не расширился: см. «Provider compatibility audit (1.4.16)» ниже — расширение возможно только для источника, реально прошедшего весь gate из этого раздела, а не просто присутствующего в market-share таблице.

## Architecture

```mermaid
flowchart TD
    UI[MediaPane] --> MC[MediaController]
    MC -->|Apple Music| NB["NativeMusicBridging (LivePlayerBridge)"]
    NB --> PB[PlayerBridge]
    PB --> AE[Apple Events / Music app]
    MC -->|Explicit Open Web Player| WMP["WebMusicPlaying (WebMusicPlayer)"]
    WMP --> MS[Selected provider site]
    WMP --> BR[Bounded Media Session bridge]
    MC --> STATE[Track / artwork / position / playback state / capabilities]
    CAT[MusicProviderCatalog] -.region-relevant subset.-> UI
```

`NativeMusicBridging` and `WebMusicPlaying` are the two DI seams `MediaController` was given in 1.4.16 so its state machine — source switch, track switch, stale-result suppression, capability propagation, lifecycle — has deterministic unit coverage (`MediaControllerTests.swift`) instead of requiring a real Music app, Automation permission, or WebKit/network. Production always resolves to `LivePlayerBridge` and a real `WebMusicPlayer()`; nothing about the runtime behavior changed.

## Source selection

Source сохраняется в UserDefaults (`music.selectedSource.v1`). Выбор web source **не создаёт WebKit**. Только `openSelectedSource()` создаёт/показывает `WebMusicPlayer` и разрешает request.

### Regional recommendations (1.4.16)

`MusicProviderCatalog.allServices` — полный, неизменный каталог (`MusicSource.allCases`), который `MediaPane` показывает под «Все сервисы». `recommended(...)` — намеренно **не** переупорядоченный тот же список, а короткое **подмножество** конкретно под регион, иначе «Рекомендуемые» дублирует «Все сервисы» под другим заголовком (это было исправлено по review в PR #96). Единственный сигнал для выбора подмножества — `Locale.current.region` (локальный system region), без сети, без IP-geolocation, без backend-запроса. Приложенческий язык интерфейса (`appLanguage` из `Strings.swift`) используется **только** как вторичный детерминированный fallback, когда `Locale.current.region` не резолвится — никогда как замена региону и никогда как language==country допущение (см. `MusicProviderCatalogTests.swift`, включая проверку, что de/fr/es/ja/zh-Hans языки сами по себе не переключают подмножество).

Product-priority подмножества на 1.4.16 (все источники, которые не входят в подмножество, остаются доступны под «Все сервисы» — ничего не становится недостижимым, только не продвигается):

| Регион | `recommended(...)` |
| --- | --- |
| RU, BY, KZ, KG, AM, UZ, TJ | Yandex Music, VK Music, Apple Music (в этом порядке — Yandex и VK впереди, Apple Music сохранён, но не продвинут перед ними) |
| Материковый Китай (`CN` — не HK/MO/TW) | только Apple Music (YouTube Music там недоступен, поэтому не продвигается) |
| Всё остальное, включая неизвестный/неопознанный регион | Apple Music, YouTube Music |

## Apple Music

`PlayerBridge` получает state через scripting interface/public Automation path и distributed player notifications, за `NativeMusicBridging` (production: `LivePlayerBridge`). Active pane имеет bounded 1 s native refresh; duplicate refreshes coalesced.

Permission: Apple Events Automation. Status check не prompt'ит; пользователь сам инициирует request.

### Stale-refresh guard (1.4.16 fix)

До этого исправления возможна была гонка: scripting-refresh для трека A ещё in-flight, когда distributed notification для более нового трека B синхронно адаптируется через `adopt(_:)`; когда fetch трека A наконец возвращался, он безусловно перезаписывал уже актуальный трек B на короткое время, до следующего self-correcting refresh. `MediaController` теперь ведёт monotonic `stateGeneration`, инкрементируемый в каждом `adopt(...)`; `refreshFromAppleMusic()` захватывает generation перед запросом и отбрасывает завершение fetch, если generation успел сдвинуться. Тест: `MediaControllerTests.testLateAppleMusicFetchForAnOldTrackDoesNotOverwriteANewerAdoptedTrack`.

## Capabilities (1.4.16)

`MediaController.capabilities: MediaCapabilities` (`canPlayPause` / `canNext` / `canPrevious` / `canSeek`) заменяет прежнее допущение «у всех источников доступен весь transport». Apple Music отдаёт capability `true` безусловно, как только трек загружен — scripting-мост не даёт частичной granularity. Web-источник отдаёт ровно то, что нашёл его собственный transport-route lookup (тот же, которым пользуется `command(_:)`) — до этого изменения бридж уже вычислял этот сигнал (`handlers['nexttrack']` / Media Session action handlers / DOM-fallback через `clickKnown`), но никогда не передавал его в Swift. `MediaPane` теперь `.disabled()`-гейтит Previous/Play-Pause/Next по этим полям вместо того, чтобы всегда предлагать кнопку, которая может ничего не делать. `clear(reason:)` сбрасывает capabilities к all-false — недоказанная возможность не предлагается.

## Web players

Main-frame navigation ограничена provider allow-list; sign-in hosts включены явно. Subframes разрешают безопасные web schemes, но bridge inject'ится только main frame. Unrelated main-frame links не становятся частью Impuls browser boundary.

## Время жизни web-плеера

`MediaController.stop()` вызывает `WebMusicPlayer.teardown()`. До 1.4.12-hardening этого пути не существовало: `deactivate()` только убирал окно, и внедрённый мост продолжал раз в секунду отправлять состояние со свёрнутой панелью, переживая `NotchController.teardown()`. Это была единственная фоновая работа приложения без owner'а остановки.

`teardown()` идемпотентен, не создаёт `WKWebView` и не грузит URL, и оставляет объект пригодным к повторному открытию.

## Network


Это один из трёх разрешённых network owners: `WebMusicPlayer.swift`. Network возникает только после явного `Open Web Player`. 1.4.16 не меняет это в принципе: конструирование `MediaController`, выбор источника и чтение regional recommendations остаются полностью локальными (`MediaControllerTests.testConstructionAndSourceSelectionNeverBuildAWebPlayer`).

## State / persistence

Track/artwork/play state — runtime. Selected source — UserDefaults. Web session/cache управляются WebKit по своей конфигурации; module не превращает metadata в product telemetry. Capabilities и regional recommendation order — тоже чисто runtime/local, ничего нового не персистится и не логируется.

## Provider compatibility audit (1.4.16)

Issue #95 запросил desk-research аудит кандидатов, а не задачу «добавить максимум сервисов». Ни один кандидат не прошёл весь gate (реальный вход, реальное воспроизведение без неподдерживаемого DRM, метаданные через стабильный публичный surface / Media Session, а не через fragile DOM-scraping, контролы без хрупкого DOM-clicking, никакого архитектурного rewrite `WebMusicPlayer`) на уровне, достаточном для honest GREEN без учётной записи/региона/подписки, которых у аудита не было — поэтому 1.4.16 сознательно не добавляет новых источников:

- **Spotify** — remains unsupported. Technical reason unchanged and re-verified: Spotify Web Playback requires Widevine-decrypted audio, which WKWebView does not implement on macOS, so an embedded Spotify tab can authenticate but not produce sound. This is a limitation of the current WebKit-based web-player architecture, not a permanent claim about Spotify — no private framework, injection, Accessibility-scraping, or Widevine-redistribution workaround was considered acceptable, so none was attempted.
- **Zvuk, Amazon Music, Deezer** — YELLOW/UNKNOWN: plausible web-player candidates in principle, but without a live account/subscription in-session they could not be proven to clear the full gate (real sign-in, real audio, non-fragile metadata). Deferred rather than shipped on a guess.
- **LINE MUSIC, QQ Music, NetEase Cloud Music, KuGou Music, Kuwo Music** — UNKNOWN: region/account-gated services the audit had no way to verify live; deferred rather than silently promoted to GREEN.

None of these were ruled RED on principle — they are candidates for a future, properly account-verified pass (1.4.17+), not permanently rejected.

## Source map

- `MediaController.swift`
- `MusicSource.swift`
- `MusicProviderCatalog.swift`
- `PlayerBridge.swift` (includes `NativeMusicBridging` / `LivePlayerBridge`)
- `WebMusicPlayer.swift` (includes `WebMusicPlaying`)
- `MediaPane.swift`

## Инварианты

- no private `MediaRemote`;
- no process injection;
- source selection itself is offline;
- WebKit only explicit user action;
- provider navigation boundary stays allow-listed;
- artwork/data reads remain bounded;
- regional recommendation subset uses only local system region (+ deterministic app-language fallback), never IP/network/telemetry; every source it omits stays reachable under All Services;
- capabilities are reported honestly per source, never assumed uniform across providers.

## Связано

- [Networking](../01-architecture/networking.md)
- [Permissions](../01-architecture/permissions.md)
- `docs/audits/1.3.0-web-music-security.md`
