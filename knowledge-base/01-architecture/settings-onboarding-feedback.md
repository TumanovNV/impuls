---
title: Settings, Onboarding and Feedback
type: architecture
status: active
documentation_version: 1.3
app_version: 1.4.14
last_reviewed: 2026-08-21
tags: [impuls, settings, onboarding, feedback, project-support]
---

# Settings, Onboarding and Feedback

## Роль подсистем

Эти поверхности находятся вне notch panel, но используют тот же shared state и privacy contracts.

```mermaid
flowchart TD
    APP[AppDelegate] --> SET[SettingsStore]
    APP --> SW[SettingsWindowController]
    APP --> ON[OnboardingWindowController]
    APP --> FW[FeedbackWindowController]
    SET --> VM[NotchViewModel / services]
    ON --> SET
    ON --> VT[VersionTelemetryService consent]
    APP --> PSW[ProjectSupportPromptWindowController]
    FW --> FS[FeedbackService]
    FS --> PB[Copy report to pasteboard]
    FS --> GH[Open GitHub issue URL in browser]
    NC[NotchController] -->|deliberate use / returned to idle| APP
    APP --> PS[ProjectSupportPromptService]
    PS --> PSW
    PSW --> FW
    PSW --> PROJ[Open project URL in browser]
```

## SettingsStore

`SettingsStore` — process-level persisted configuration. Он хранит hotkey, activation mode/delay, panel size/display scope, module ordering/enabled state, clipboard policy, external-device opt-in, low-battery choices и Menu Bar configuration.

Portable `ImpulsSettingsSnapshot` сознательно уже полного local state: device ordering/hidden keys и selected physical-device key живут отдельно и не входят в backup.

## Onboarding

`OnboardingEligibility` чисто решает `full / whatsNew / none`:

- fresh install без settings/legacy completion → full tour;
- existing install с новой version → What's New;
- уже просмотренная current version → none.

Закрытие окна считается явным dismissal, чтобы tour не становился ловушкой на каждом launch.

Full flow: welcome → features → Menu Bar → quick actions → permissions → privacy → ready. Feature cards берутся из `AppFeatureCatalog`, то есть onboarding не должен рекламировать несуществующий module.

### What's New content

Заголовок и текст What's New берутся из `WhatsNewCatalog.content(forVersion:)`, вызываемого с реальным `Bundle.main.shortVersion` — не из захардкоженной строки в `OnboardingFlow`. До 1.4.14 заголовок и описание были буквально вписаны в `OnboardingFlow.whatsNew`, поэтому апгрейд на 1.4.12/1.4.13 продолжал показывать заметки 1.4.11. Каталог хранит bullet-список изменений по каждой версии; версия без записи получает generic fallback с настоящим номером версии, а не текст соседней версии. Добавление new entry для будущего релиза — единственное, что должно понадобиться в `WhatsNewCatalog.swift`.

## Telemetry offer

Version-statistics offer встроен как отдельный choice. Unknown consent может быть предложен, allowed/denied не переопрашиваются бесконечно. `Not now` не превращается скрыто в allow.

## Feedback

`FeedbackService` не является network owner. Он:

1. нормализует bounded summary/details (120 / 4000 chars);
2. опционально добавляет только app version, macOS version и CPU architecture;
3. формирует Markdown report;
4. кладёт report в pasteboard с internal marker;
5. открывает строго `https://github.com/TumanovNV/impuls/issues/new` в default browser.

Clipboard contents, notes, filenames/paths, calendar, device identifiers и logs автоматически не добавляются. Если prefilled URL превысил 7000 chars, report остаётся скопированным, а URL открывается без body.

## Project support prompt

Единственное, что Impuls когда-либо предлагает по собственной инициативе: один раз попросить звезду на GitHub или обратную связь. Формулировка сознательно не «оцените нас на 5 звёзд» — звезда на GitHub не пятизвёздочный рейтинг, и в тексте нет ни guilt language, ни countdown, ни искусственной срочности.

Ответственности разделены на три части, и ни одна не может принять решение в одиночку.

### Eligibility — `ProjectSupportPromptService`

Три порога **одновременно**: 30 календарных дней с первого meaningful use, 10 разных active days и 20 meaningful uses. Любой из них по отдельности описывает установку, о которой забыли.

Отсчёт начинается с первого засчитанного использования, а не с даты установки. Дату установки не реконструируют по filesystem metadata: у существующих пользователей записи просто нет, и первое использование после обновления становится днём ноль. Иначе апдейт показал бы окно всем сразу.

Счётчики только растут. Часы, переведённые назад, не уменьшают их и не дают eligibility: `firstMeaningfulUseAt` не сдвигается, более ранний календарный день не считается новым active day, а разница в днях уходит в минус.

Использования ближе 60 s друг к другу — один эпизод. Иначе «20 uses» означало бы 20 кликов, которые набираются за один занятый день.

### Meaningful use — `NotchController`

Один funnel, `noteDeliberateUse`, ровно из шести мест того же файла: глобальный хоткей, клик по свёрнутой вкладке, две команды Menu Bar workspace, открытие Power по клику в уведомлении и клик по телу панели.

Hover сознательно **не** считается: sampler открывает панель по близости указателя, а близость — не намерение. Клик внутри панели — то, что не даёт «hover-пользователю» остаться невидимым для механизма, потому что клик и есть выражение намерения. Ни фоновая работа, ни таймеры, ни проверки обновлений, ни перерисовка Menu Bar, ни запуск приложения использованием не являются.

### Момент — `AppDelegate`

`onReturnedToIdle` приходит из одного места: завершения визуального сворачивания, после того как hit region вернулся к якорю, и только для сессии, в которой было явное действие. Дальше `AppDelegate` ставит **одну** отменяемую `DispatchWorkItem` на `+8 s`; eligibility проверяется до постановки, поэтому у обычного пользователя работа не создаётся вовсе. Возобновление работы отменяет отложенный показ, `applicationWillTerminate` — тоже.

Все условия перечитываются в момент срабатывания, а не захватываются при постановке. Поэтому окно не может появиться на запуске (минимум 120 s uptime), поверх открытой панели, поверх onboarding, What's New, Settings, Feedback или диалога Sparkle (блокирует любое видимое titled-окно; панели и status item borderless), во время ожидающего перезапуска для смены языка и дважды за сессию. Update-consent alert выполняется модально и сам по себе блокирует main queue.

**Границу этой проверки нужно называть точно.** `NSApp.windows` содержит только окна самого Impuls. Системный TCC-диалог принадлежит системному процессу и в этот список не попадает, поэтому `showsTitledWindow` сам по себе **не** доказывает, что prompt не появится рядом с ним. На практике риск закрывает происхождение TCC-запросов: Impuls вызывает их только по явному действию пользователя, а такие действия происходят либо в Settings, либо в открытой панели — и то и другое уже блокирует показ. Остаётся узкий случай: системный диалог, переживший поверхность, которая его вызвала. Это проверяется вручную в `SUP-01`, а не объявляется доказанным из кода.

Подробности cadence — в [Background Work & Concurrency Registry](../12-reference/background-concurrency-registry.md), пороги — в [Resource Budget Registry](../12-reference/resource-budget-registry.md).

### State machine

```mermaid
stateDiagram-v2
    [*] --> neverShown
    neverShown --> snoozedOnce: Not now / закрыл окно
    neverShown --> openedGitHub: Support on GitHub принят браузером
    neverShown --> openedFeedback: Share Feedback
    snoozedOnce --> dismissedForever: второй отказ
    snoozedOnce --> openedGitHub: Support on GitHub
    snoozedOnce --> openedFeedback: Share Feedback
    openedGitHub --> [*]
    openedFeedback --> [*]
    dismissedForever --> [*]
```

Максимум **два** автоматических показа за всё время локального состояния. Второй показ возможен не раньше чем через 60 дней после первого **и** только если после него была реальная активность: время, прошедшее над неиспользуемым приложением, второго вопроса не оправдывает.

Закрытие окна — отказ, а не отложенное решение: оставить вопрос нерешённым значило бы спросить снова при первой возможности.

Любое решение — показ, отказ, открытие GitHub, открытие feedback — сбрасывается на диск сразу. Ручной прогон `SUP-01` показал, почему: при обычном `UserDefaults.set` запись остаётся в кеше процесса, и снятие приложения без штатного завершения возвращало состояние «вопрос ещё не задавали». Ограничение в два показа существует ровно настолько, насколько решение переживает процесс.

### GitHub

Impuls только передаёт один точный allowlisted HTTPS URL браузеру по явному клику. Ни GitHub API, ни OAuth, ни token, ни проверки аккаунта, ни HTTP-запроса из приложения. Поэтому это **не** четвёртый network owner: запрос делает браузер, ровно как для ссылки, набранной руками.

Проверка URL fail-closed по образцу `FeedbackService.isAllowedIssueURL` — схема, host, точный path, отсутствие query, credentials, порта и fragment.

Impuls не знает и не утверждает, что звезда поставлена. Максимум, что записывается, — `openedGitHub`, и только после того, как `NSWorkspace` принял URL; флага `starred` не существует. Неудачное открытие ничего не решает и не расходует оставшуюся возможность спросить.

`Share Feedback` открывает существующее окно обратной связи. Второй feedback-реализации нет.

### Privacy

Eligibility считается полностью локально. Ни дата первого использования, ни счётчики, ни `shownCount`, ни состояние наружу не отправляются. Это не telemetry: событий `prompt shown` / `star clicked` не существует, и добавлять их нельзя — это была бы отдельная задача про consent. Хранимые данные — счётчики, а не история: ни модулей, ни запросов, ни содержимого. Состояние машинно-локально и не входит в portable backup; см. [Storage and Persistence](storage-persistence.md).

### Постоянный путь

Settings → Feedback содержит постоянный блок «Support the Project» с кнопкой «Support Impuls on GitHub» рядом с «Send Feedback…». Он stateless: открывает тот же URL, не трогая состояние prompt, поэтому продолжает работать после `dismissedForever`, а выбор в Settings не считается ответом на вопрос, которого Impuls не задавал.

Ручной сценарий записан как `SUP-01` в [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md).

## Source map

- `Sources/Impuls/Settings/SettingsStore.swift`
- `Sources/Impuls/Settings/SettingsWindow.swift`
- `Sources/Impuls/UI/OnboardingFlow.swift`
- `Sources/Impuls/Services/WhatsNewCatalog.swift`
- `Sources/Impuls/Services/AppFeatureCatalog.swift`
- `Sources/Impuls/Services/FeedbackService.swift`
- `Sources/Impuls/Settings/FeedbackWindow.swift`
- `Sources/Impuls/Services/ProjectSupportPromptService.swift`
- `Sources/Impuls/Settings/ProjectSupportPromptWindow.swift`
- `Sources/Impuls/App/AppDelegate.swift`
- `Sources/Impuls/Notch/NotchController.swift`

## Verification references

- [`ProjectSupportPromptServiceTests.swift`](../../Tests/ImpulsTests/ProjectSupportPromptServiceTests.swift)
- [`ProjectSupportPromptLifecycleTests.swift`](../../Tests/ImpulsTests/ProjectSupportPromptLifecycleTests.swift)
- [`FeedbackServiceTests.swift`](../../Tests/ImpulsTests/FeedbackServiceTests.swift)
- [`OnboardingFlowTests.swift`](../../Tests/ImpulsTests/OnboardingFlowTests.swift)

## Инварианты

- onboarding never invents product features;
- What's New content always matches the running `Bundle.main.shortVersion`; a version with no curated entry gets a generic version-accurate fallback, never a previous version's copy;
- update install must not replay full first-run tour;
- portable settings exclude local physical-device identity;
- feedback does not perform HTTP request itself;
- diagnostics remain minimal and optional;
- the support prompt is capped at two automatic appearances for the lifetime of the local state, and every terminal state is terminal;
- eligibility is computed locally and never transmitted; it must not grow a telemetry event;
- Impuls never checks, claims or stores whether a GitHub star was given;
- neither the prompt nor Settings performs an HTTP request; both only hand one exact allow-listed URL to the browser after a click;
- the prompt appears only from an idle transition after real use, never at launch and never over another Impuls window.
