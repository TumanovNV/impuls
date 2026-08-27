---
title: Power and Battery Module
type: module
status: production
documentation_version: 1.8
app_version: 1.4.16
last_reviewed: 2026-08-27
tags: [impuls, module, battery, devices, iokit]
---

# Power / Battery

## Назначение

На portable Mac пользователь видит Battery; на desktop Mac — Power. Local Mac data дополняется opt-in Apple device center.

## Architecture

```mermaid
flowchart TD
    PM[PowerMonitor] --> LOCAL[LocalMacDeviceProvider]
    LOCAL --> DPC[DevicePowerCenter]
    EXT{Show Connected Apple Devices?} -->|yes| ACC[AppleAccessoryBatteryProvider]
    EXT -->|yes| MOB[MobileDeviceBatteryProvider]
    ACC --> DPC
    MOB --> DPC
    DPC --> MERGE[DeviceSnapshotMerger]
    MERGE --> UI[PowerPane / Settings / Menu Bar]
    MERGE --> ALERT[LowBatteryAlertService]
    UI --> SAW[StayAwakeService]
    SAW --> LEASE[WakeLeaseRegistry]
    LEASE --> DRV[IOKitPowerAssertionDriver]
```

## Power Center presentation (1.4.14)

`PowerPane` — master-detail Device Navigator: вертикальный список устройств слева, detail card справа, вместо прежнего горизонтального переключателя-и-карточки. Desktop-ветка никогда не выдумывает процент: у Mac mini в навигаторе и в detail card нет battery percentage, только AC source/adapter. Severity coloring (`warning <= 20%`, `critical <= 10%`) зеркалит `LowBatteryAlertEngine.Policy`, так что устройство, готовое дать alert, уже так выглядит в списке. Merge/refresh/provider contracts ниже не изменились.

## Local Mac

`PowerMonitor` остаётся отдельным established path. `LocalMacDeviceProvider` адаптирует его в unified device model. Не переписывать local power path ради external devices.

### Adapter Current (IMP-22)

Optional `Adapter Current` — это только положительное целое значение mA из публичного `IOPSCopyExternalPowerAdapterDetails()` / `kIOPSPowerAdapterCurrentKey`. Оно читается из уже полученного adapter-details dictionary в существующем snapshot path: нет второго IOKit read, нового provider, timer, polling, observer, subprocess или retry. Отсутствующий dictionary/key, zero, negative, wrong type или failed conversion остаются `nil`; desktop/no-battery path также не показывает метрику.

Это **adapter current reported by macOS**, не charging current, battery charging current, live charging power, wall draw, adapter output power или available adapter capacity. Source-of-truth остаётся integer mA; UI показывает `<1000` как integer mA, `>=1000` как locale-aware A максимум с одним decimal. Никакой wattage из него не вычисляется. Rated adapter watts (`kIOPSPowerAdapterWattsKey`) и existing battery-side derived W остаются отдельными, неизменными метриками. `kIOPSPowerAdapterSourceKey` не используется: public contract не задаёт mapping к MagSafe/USB-C. Adapter serial/ID/family/revision не читаются, не хранятся и не логируются; новая метрика local-only, без persistence, telemetry или network.

## Stay Awake (1.4.16, IMP-40)

**Что это.** Явный пользовательский режим в Power Center: пока он включён, Mac не уходит в user-idle system sleep. Отдельная explicit опция «Не выключать экран» добавляет к тому же lease требование по дисплею. Она **выключена при каждом включении режима** и недоступна, пока режим выключен: состояния «экран удерживается, а Stay Awake выключен» не существует.

**Как реализовано.** Только публичные IOKit power-management assertions:

| Требование | Assertion type | Что даёт |
| --- | --- | --- |
| `WakeRequirement.systemIdleSleep` | `kIOPMAssertPreventUserIdleSystemSleep` (`"PreventUserIdleSystemSleep"`) | нет idle system sleep; экран при этом может гаснуть |
| `WakeRequirement.displayIdleSleep` | `kIOPMAssertPreventUserIdleDisplaySleep` (`"PreventUserIdleDisplaySleep"`) | экран не гаснет по бездействию |

Создание — `IOPMAssertionCreateWithName`, освобождение — `IOPMAssertionRelease`, `IOReturn` проверяется в обе стороны. Deprecated спеллинги того же заголовка (`kIOPMAssertionTypeNoIdleSleep`, `kIOPMAssertionTypeNoDisplaySleep`, `kIOPMAssertionTypePreventSystemSleep`) не используются намеренно. Никаких private symbols, никакого entitlement и никакого permission prompt: `IOPMAssertionCreateWithName` их не требует, поэтому у фичи нет authorization path.

**Чего здесь нет.** Ни `/usr/bin/caffeinate` как дочернего процесса, ни `pmset` в production, ни `Process()`, ни shell. Assertion принадлежит процессу — это ровно то, что берёт сам `caffeinate`, — поэтому дочерним процессом управлять нечем. Системные настройки пользователя (Energy Saver / Battery / Display sleep) **не изменяются**: после release система возвращается к своим собственным настройкам. `pmset -g assertions` остаётся исключительно read-only инструментом ручного QA.

**Lease/token ownership.** `WakeLeaseRegistry` выдаёт `WakeLeaseToken` и владеет физическими assertions. Сколько бы lease ни просили `systemIdleSleep`, существует ровно **один** physical system assertion; то же независимо для display. `release(token)` действует только на свой token, поэтому один владелец не может отменить чужое требование, а release неизвестного или уже освобождённого token — no-op. Токен создаётся только реестром (`fileprivate init`), так что подделать его из другого файла нельзя.

В 1.4.16 владелец **ровно один** — ручной режим. Реестр всё равно реестр, а не флаг, потому что правило владения — сложная часть, и переписывать под него выросших вокруг флага вызывающих дороже. Никакого второго владельца, никакого background lease и никакого скрытого держателя не добавлено, и speculative AI-код сюда не заводится.

**Transactional reconciliation.** `reconcile` сначала создаёт всё недостающее и только потом освобождает лишнее и коммитит таблицу lease. Отсюда три свойства: неудачное создание нового требования не стоит уже работающего assertion; частичное создание откатывается до броска ошибки, поэтому orphan не остаётся; состояние сервиса и состояние системы не могут разойтись, потому что таблица пишется после «да» от системы. Неудачный release не фатален и не повторяется: handle в любом случае выбрасывается, иначе он был бы освобождён второй раз.

**Честное состояние при отказе.** Если assertion создать не удалось, `isActive` остаётся `false` — UI никогда не утверждает, что Mac удерживается, когда это не так. Сообщение bounded и локальное; `IOReturn` — диагностика для разработчика, а не текст для человека.

**Timed modes.** 30 минут / 1 час / 2 часа / до выключения. Дедлайн — монотонный `ContinuousClock`, чтобы ручной перевод системных часов не превращал 30 минут в 5 или в 4 часа. Repeating timer не нужен: assertion удерживает Mac сам. Существует максимум **один** отложенный one-shot; смена длительности, выключение и shutdown его отменяют, а generation-счётчик гасит уже поставленный в очередь callback, поэтому старый дедлайн не может выключить более новый режим. Часы, а не планировщик, решают, истёк ли срок: слишком раннее пробуждение перевзводит остаток вместо преждевременного выключения.

**Lifecycle.** Сервис живёт в `NotchViewModel` рядом с остальными общими сервисами, а не во view: свернувшаяся панель и закрытый Power Center режим не выключают. Выключают его четыре вещи — человек, выбранный дедлайн, отключение модуля Power (единственная поверхность управления исчезает, значит скрытого lease не остаётся) и `NotchViewModel.stop()` из `applicationWillTerminate`. Normal termination освобождает явно; abnormal process death (crash/kill) закрывает macOS, потому что assertion принадлежит процессу — это backstop, а не замена явной очистке. `shutdown()` идемпотентен.

**Никакого cross-launch restore.** Ничего не персистится: нет ключа в `UserDefaults`, из которого можно было бы восстановиться, поэтому запуск всегда даёт выключенный режим. Это energy/safety контракт, а не забытая фича.

**Battery caution.** Нейтральная строка при работе от батареи, без модалок и без блокировки. Показывается независимо от того, включён ли режим: одна и та же фраза отвечает и на «во что это обойдётся» до включения, и на «во что обходится» во время работы, а при выключенном режиме эта колонка всё равно пуста. Читает уже публикуемый `PowerMonitor.snapshot` — второго источника питания и нового polling нет. Desktop Mac её не показывает, потому что у него нет внутренней батареи.

**Telemetry.** Ничего не собирается: ни активации, ни длительности, ни timestamps, ни состояние батареи, ни display-preference. Фича local-only, нового network owner нет. Имя assertion (`Impuls: Stay Awake`) видно в `pmset -g assertions` и держится по тем же правилам, что и лог-строка: приложение и функция, без путей, идентификаторов и содержимого задачи. Не локализуется — иначе его нельзя было бы сопоставить в выводе инструмента, — и **только ASCII**: `pmset` печатает вывод в MacRoman, поэтому em dash доходит до UTF-8 терминала одиночным байтом `0xD1`, и скопированное из исходника имя перестаёт совпадать с тем, что человек видит на экране (проверено на живом assertion, macOS 26).

**Test seam.** `WakeLeaseRegistry` не имеет default driver — реальный `IOKitPowerAssertionDriver` называется ровно в одном месте приложения, в `NotchViewModel`. Тест, забывший передать fake, не компилируется; тест, который назвал бы реальный driver намеренно, падает на сканере в `StayAwakeServiceTests`. Конструирование самого driver'а инертно (assertion создаётся только при `acquire`), поэтому существующие тесты, строящие `NotchViewModel`, безопасны, а те, которым нужно включить режим, передают сервис на fake-бэкенде.

## External device privacy boundary

Module switch и external-device switch различны. External providers стартуют только когда Power module enabled **и** пользователь включил `Show Connected Apple Devices`. Production `MobileDeviceBatteryProvider.featureEnabled` default = true; hidden product gate отсутствует. iPhone/iPad support имеет статус Stable с 1.4.16 после повторного owner hardware QA. Сам transport по-прежнему использует undocumented Apple protocol и потому остаётся изолированным implementation boundary; Stable здесь означает подтверждённое пользовательское поведение, а не превращение протокола в public API.

## Providers

- local Mac: public IOPowerSources + bounded IORegistry supplement для доступных значений;
- accessories: IORegistry + best-effort fixed-argument `system_profiler` source;
- iPhone/iPad: local usbmuxd/lockdown transport over USB or Wi-Fi sync, existing trust required.

`IORegistryAccessoryMapper` (1.4.14) распознаёт Bluetooth Magic Keyboard/Magic Mouse/Magic Trackpad и по USB-IF vendor ID `0x05AC`, и по Bluetooth SIG Apple vendor ID `0x004C` — `AppleDeviceManagementHIDEventService` репортит эти аксессуары под `0x004C`, что раньше приводило к тихой потере записи на реальном Mac mini, хотя Control Center видел заряд корректно. Пустой `Product` string на этих устройствах закрывается небольшой hardware-confirmed таблицей Bluetooth ProductID, а registry-флаг `Built-In` теперь приоритетнее эвристики по transport string, когда он присутствует.

### Third-party Bluetooth accessories (1.4.16, #108)

Apple vendorship больше **не является условием показа**. Показывается то, для чего система сама отдаёт battery percentage.

Раньше `SystemProfilerAccessoryParser.device(named:)` начинался с `guard isApple(properties)`, то есть стороннее устройство отбрасывалось **до** того, как вообще проверялось наличие батареи. Это и был дефект: наушники, у которых macOS читает заряд, не показывались из-за производителя.

Теперь порядок обратный: обязательны `device_address` (стабильная identity) и хотя бы один валидный `device_batteryLevel*`. Нет показания — нет карточки, независимо от вендора.

Vendor ID при этом сохраняет одну роль — он решает, **как устройство называется**:

- Apple vendor (`0x004C`) → прежняя классификация по product name; AirPods и Magic-аксессуары не затронуты, включая fallback `.unknown` = «Apple Device»;
- не-Apple → generic kind строго из `device_minorType` (`Headset`/`Headphones` → `.headphones`, `Keyboard`, `Mouse`, `Trackpad`, иначе `.accessory`). Product name **не** используется для классификации: сторонний девайс волен назвать себя «AirPods Pro Max Ultra», и это не доказательство бренда.

Generic kinds (`.headphones`, `.keyboard`, `.mouse`, `.trackpad`, `.accessory`) — vendor-neutral: реальное user-visible имя устройства плюс класс, который заявила сама система. Бренд/модель не угадываются.

`externalPower` остаётся `.unknown` для всех аксессуаров любого вендора: этот источник не сообщает charging state ни для кого. Новых источников, сканирования, сетевых запросов и изменения cadence нет — это тот же single `system_profiler` read.

**Что осталось недоступным.** Bluetooth-устройство, для которого `SPBluetoothDataType` не публикует battery field, показать нельзя. Единственное место в системе, где такое значение встречается, — anonymous accessory power source в `pmset -g accps`; он идёт через `IOPSCopyPowerSourcesByType`/`kIOPSAccessoryType`, которых нет в public SDK headers, и не содержит ни имени, ни стабильной identity. Привязать этот процент к конкретному Bluetooth-устройству без догадки невозможно, поэтому Impuls этого не делает. См. `13-qa/behavioral-qa-matrix.md` PWR-13.

### AppleDeviceKind: что реально может появиться (1.4.16, IMP-10 / Part D)

Enum — словарь модели, а не обещание покрытия. Ни один case не удалён; ниже честное состояние на 1.4.16.

| Kind | Производящий источник | Deterministic tests | Hardware evidence |
| --- | --- | --- | --- |
| `mac` | `LocalMacDeviceProvider` (public IOPowerSources) | да | PWR-01…04 (в 1.4.15 все `not-run`) |
| `iPhone`, `iPad` | `MobileDeviceBatteryProvider` (usbmux/lockdown) | да | да — повторный owner QA, Stable с #106 |
| `airPods`, `airPodsPro`, `airPodsMax` | `SystemProfilerAccessoryParser` (+ overlay) | да, включая captured-фикстуру реального вывода | частично: AirPods Pro наблюдались; component-topology (PWR-06) не проверялась |
| `magicMouse`, `magicKeyboard`, `magicTrackpad` | `IORegistryAccessoryMapper`, `SystemProfilerAccessoryParser` (+ overlay) | да, включая product-ID fallback | vendor/product ID подтверждены на Mac mini (2026-08) |
| `headphones`, `keyboard`, `mouse`, `trackpad`, `accessory` | `SystemProfilerAccessoryParser` (generic, из `device_minorType`) | да | `headphones` — да (#108/#110, сторонний headset, 80%); остальные generic — нет |
| `unknown` | fallback любого источника | да | n/a — это отсутствие классификации, а не устройство |
| `appleWatch`, `applePencil`, `visionPro`, `airTag`, `siriRemote` | **нет производящего источника** | нет | нет |

Последняя строка — зарезервированный словарь. Эти значения не может создать ни один сегодняшний provider: Apple Watch и Vision Pro не публикуют заряд ни в одном из разрешённых локальных источников, Apple Pencil и AirTag не являются Bluetooth-аксессуарами с battery-полем в `SPBluetoothDataType`, Siri Remote не наблюдался. Оставлены намеренно: удаление ничего не улучшит, а вернуть их придётся при первом же источнике.

### Классификация переименованных Apple-аксессуаров (1.4.16, IMP-10 / B1)

`SystemProfilerAccessoryParser` определял kind Apple-устройства **только** по product name, а имя здесь — это JSON-ключ, то есть user-visible Bluetooth-имя, которое пользователь волен изменить. Переименованные Magic Mouse/Keyboard/Trackpad становились `.unknown`, хотя `system_profiler` в той же записи уже публиковал `device_productID`, который `AppleAccessoryNaming` умеет распознавать. `IORegistryAccessoryMapper` этот fallback имел всегда — асимметрия и была дефектом.

Теперь порядок такой: имя первично; product ID используется **только** если имя ничего не дало. Fallback ограничен Apple Bluetooth vendor namespace (`0x004C`, что здесь и означает `isApple`), потому что тот же числовой ID в другом namespace значит другое — сторонний девайс до таблицы Apple не доходит никогда. Таблица не расширялась: те же три hardware-confirmed ID.

Классификация вынесена в один общий метод, используемый обоими входными точками (с батареей и без). Kind входит в `AppleDeviceIdentity`, поэтому устройство обязано классифицироваться одинаково независимо от наличия показания — иначе один физический аксессуар получил бы две identity.

Display name не меняется: пользовательское имя остаётся тем, что видит пользователь.

### Cross-source dedup (1.4.16, IMP-10 / B3)

`AccessoryCrossSourceDedupTests` проверяет **production** pipeline (`AppleAccessoryBatteryProvider` через `start(onUpdate:)`), а не отдельный dedup-хелпер: один физический Magic Mouse, видимый одновременно из IORegistry и `system_profiler`, даёт одну identity и одну карточку; registry имеет приоритет там, где уже дал battery; pmset overlay при этом не запускается вовсе. Отдельно зафиксировано, что переименование на стороне `system_profiler` не создаёт вторую карточку — это и есть причина, по которой B1 важен для dedup, а не только для иконки.

### pmset battery overlay для Bluetooth-аксессуаров (1.4.16, #108 follow-up)

**Что это.** Третий accessory-источник, строго overlay. `system_profiler` остаётся **единственным** источником identity подключённых Bluetooth-устройств; `pmset` поставляет только число.

**Почему.** Реальный сторонний headset, который macOS сама показывает как 80%, не публикует battery field в `SPBluetoothDataType`, не имеет battery property нигде в IORegistry и отсутствует в public `IOPSCopyPowerSourcesList`. Значение доходит до macOS через `IOPSCopyPowerSourcesByType`/`kIOPSAccessoryType`, которых нет ни в одном public SDK header — поэтому Impuls их **не вызывает**, а запускает shipped-бинарь, который это делает.

**Честный статус источника.** `/usr/bin/pmset` — публичный системный CLI по фиксированному пути, никаких private symbols Impuls не вызывает. Но `-g accps` и `-xml` не описаны в `man pmset`: это **undocumented compatibility surface**, и обращение с ним соответствующее — любой отказ (нет бинаря, non-zero exit, timeout, не-plist, изменившаяся схема) даёт **пустой overlay**, то есть теряется дополнительное значение батареи и ничего больше. Power продолжает работать, остальные источники не затронуты, выдуманных значений не появляется.

**Correlation rule — строго one-to-one, fail closed.** Два источника не имеют общего идентификатора: accessory UUID из `pmset` — не Bluetooth address и вообще не встречается в выводе `system_profiler` (проверено). Единственная связка — user-visible name, а имя доказательство слабое: пользователь его меняет и уникальность не гарантирована. Поэтому overlay применяется, только когда одновременно:

1. запись `pmset` — Bluetooth accessory (`Transport Type == Bluetooth`, `Type == Accessory Source`);
2. нормализованные имена совпадают (регистр и пробелы — шум, ничего больше);
3. классы совместимы по семейству (`Headset`/`Headphones` → headphones, и т.д.);
4. **ровно один** кандидат и **ровно одна** запись с этим именем.

Иначе overlay не применяется. Два устройства с одним именем дисквалифицируют **оба**: доказательств, какое из них чьё, нет, а выбрать одно — это догадка.

Никогда не используются для сопоставления: сам процент, порядок записей, время появления, «подключён только один аксессуар», похожесть имени, попытка связать accessory UUID с Bluetooth address.

**Identity.** После overlay сохраняется существующая address-derived `AppleDeviceIdentity` из `system_profiler`. Accessory UUID из `pmset` **не читается парсером вообще** — его нет в модели, поэтому он не может быть сохранён, залогирован или показан, а его стабильность при reconnect не является зависимостью. Миграция существующих device preferences не требуется.

**Charging.** Берётся из `Is Charging`, когда источник его сообщает. `Is Charged` не считается доказательством внешнего питания: полная батарея — не кабель. Отсутствующее или противоречивое → `unknown`. 100% по-прежнему не доказательство зарядки.

**Isolation.** Оба accessory-источника (`system_profiler` и `pmset`) выставляют `async` non-isolated методы и выполняют subprocess вместе с парсингом внутри `Task.detached(priority: .utility)`. Provider остаётся `@MainActor`, но тяжёлая часть на нём не выполняется: синхронный метод, вызванный из main-actor контекста, заморозил бы UI до ответа инструмента или до истечения deadline. Публикация результата и состояние provider'а по-прежнему на MainActor; существующая проверка `Task.isCancelled` перед `publish` продолжает отбрасывать устаревший результат.

**Cadence.** Не менялась. `pmset` запускается **только** когда после registry и `system_profiler` остались подключённые устройства без показания — если всё уже отвечено, процесс не порождается.

**Real hardware evidence (2026-08-25).** Владелец подтвердил скриншотом System Settings → Bluetooth: заряд стороннего headset = 80%. Живой прогон production-пути на том же Mac: `system_profiler` — 0 устройств с батареей, 1 подключённое без; `pmset` — 1 Bluetooth accessory reading, 80%, `Is Charging = 0`; overlay — 1 карточка, 80%, headphones, charging `disconnected`; всего accessory cards — 1, дубликата нет. См. `13-qa/behavioral-qa-matrix.md` PWR-14.

### iPhone/iPad reliability audit (1.4.16)

Аудит existing mobile provider для issue #93. Полная протокольная история — `docs/APPLE_DEVICE_BATTERY_SUPPORT.md`; здесь фиксируется только то, что реально изменилось в 1.4.16 и итоговое решение Beta/Stable.

Transport dedup/precedence (USB предпочтителен, Network — fallback, группировка по стабильному `rawIdentifier`, а не по transient numeric `DeviceID`) уже существовал и покрыт deterministic tests — не менялся.

Найдено и исправлено два реальных defect, оба доказаны по существующему коду/его собственным комментариям, а не предположены:

1. **Locked device терял last-known reading.** `MobileDeviceClient.error(for:)` уже различал `PasswordProtected` (`.deviceLocked`) от `InvalidHostID`/`UserDeniedPairing` (`.notTrusted`), но `MobileDeviceBatteryProvider.publish(failure:)` схлопывал оба в один `DeviceProviderStatus.permissionRequired`, а `DevicePowerCenter.apply()` для этого статуса очищал `lastGoodDevices` — прямое противоречие собственному комментарию `DevicePowerCenter`: "A transient failure must not blank the list." Добавлен отдельный `DeviceProviderStatus.deviceLocked`: карточка сохраняется как Last Known (та же ветка, что и `.temporarilyFailed`), UI показывает честное "device is locked" вместо общего "unlock and tap Trust", а не выдуманную точную причину — только там, где протокол её действительно различает.
2. **Disconnect-during-read race.** `refresh()` при уже идущем чтении просто ставил `refreshPending = true` и ждал завершения текущего чтения — топология могла измениться (устройство отключилось) **до** того, как in-flight read вернул результат, и тот успевал опубликоваться как `.ready` прежде, чем следующий refresh его поправит. Новый `refreshDiscardingInFlightRead()` (topology change и wake) отменяет readTask и запускает чтение заново, вместо того чтобы просто ставить его в очередь; обычный polling-tick `refresh()` по-прежнему только ставит follow-up в очередь, не отменяя ничего. Никакого нового timer/generation token — используется уже существующий `Task.cancel()` + `Task.isCancelled` guard в `refresh()`.

Cadence не менялся (60s active / 900s idle остаются). Никакого нового network/LAN discovery, private API или изменения privacy boundary.

**Beta → Stable: Stable approved.** После stabilization #93/#94 владелец продукта многократно проверил реальные iPhone и iPad в рабочих сценариях, включая USB и уже настроенный Finder Wi-Fi Sync. Устройства стабильно появляются, показывают фактическое состояние батареи и корректно возвращаются после reconnect; correctness gaps, требующие сохранять пользовательскую маркировку Beta, в этом цикле не подтверждены. В 1.4.16 продуктовая маркировка Beta снимается. Это presentation/status change: transport, cadence, privacy/network boundary, trust model и правило «missing stays missing» не меняются. Недокументированность usbmuxd/lockdown остаётся техническим риском и продолжает явно фиксироваться в архитектуре и research-документации.

## Числа из системных словарей

IOKit и usbmuxd отдают `CFNumber` той ширины, которую выбрал драйвер или устройство. Все читатели используют один `RegistryNumber`: отклонить не-`NSNumber`, отклонить `CFBoolean`, отклонить не-finite, округлить, преобразовать через failable инициализатор. Преобразование тотальное — `Int(someDouble)` вне диапазона `Int` это trap, а не переполнение.

Своего верхнего предела helper не несёт намеренно: что считать правдоподобным процентом или ёмкостью, решает домен (`AppleDeviceNormalizer` ограничивает процент диапазоном `0...100`, `PowerSnapshot` проверяет пару ёмкостей перед делением). Скрытый предел на этом уровне молча отбрасывал бы значения, которые владелец домена считает корректными.

## Honest missing data

Missing value остаётся missing: нет fabricated 0%, guessed charging state или guessed connector. Last-good external reading может временно оставаться с freshness timestamp после transient failure; alerts используют более строгий current-ready set.

## Refresh lifecycle

`DevicePowerCenter` координирует providers и `DeviceRefreshScheduler`. Opening panel даёт immediate foreground refresh внешним providers. Heavy device I/O не выполняется на main actor.

`AppleAccessoryBatteryProvider` регистрируется на IOKit-уведомления о появлении и исчезновении аксессуаров. Контекстом callback'а служит retained `AccessoryNotificationContext`, который держит provider **слабо**, а не сам provider: IOKit хранит указатель всё время жизни регистрации и не может узнать, что provider освобождён. Teardown сначала инвалидирует box — с этого момента уже поставленный в очередь callback читает `nil` и ничего не делает, — затем освобождает iterators и port, и лишь потом освобождает сам box на main-очереди, куда доставляются уведомления. Порядок здесь и есть гарантия; IOKit собственной не даёт.

## Low battery alerts

Opt-in. Persisted setting не prompt'ит notifications самостоятельно. Alerts оценивают только sufficiently fresh/current provider data.

### Delivery reliability contract (1.4.16)

`LowBatteryAlertEngine` различает **pending** и **confirmed** state:

- пересечение порога сначала создаёт process-local `deliveryID`; оно блокирует duplicate async sends, но не записывает `warningFired` / `criticalFired` на диск;
- `LowBatteryAlertService` пересекает единственную системную границу через `UNUserNotificationCenter.add`;
- только после того, как Notification Center принял request без ошибки, service вызывает `confirmDelivery`, и соответствующее fired-state становится durable;
- ошибка доставки вызывает `cancelDelivery`: тот же sufficiently fresh low reading может повториться на следующей **обычной** provider evaluation. Отдельного retry timer, tighter cadence или busy loop для этого нет;
- если компонент успел подняться выше re-arm threshold, pending token инвалидируется. Позднее завершение старой async delivery не должно закреплять уже завершившийся low-battery cycle;
- critical alert по-прежнему имеет приоритет над warning в одном цикле устройства. Успешный critical commit также закрывает lower-priority warning state, которое он заместил;
- pending state намеренно не переживает process death. Если процесс завершился до подтверждения системной доставки, безопасная ошибка — повторить предупреждение после следующего запуска, а не считать недоставленное уведомление показанным.

`UNUserNotificationCenter.add` подтверждает принятие request системой, но не доказывает, что пользователь физически увидел banner. Поэтому Behavioral QA отдельно проверяет реальный Notification Center/TCC path; unit tests владеют retry, dedup, persistence и precedence state machine.

Между тем моментом, когда `deliver()` бросает ошибку, и моментом, когда `LowBatteryAlertService` возвращается на `@MainActor`, чтобы вызвать `cancelDelivery`, есть реальный actor hop (`delivery` не MainActor-изолирован); `Task { @MainActor ... }` теперь явный, а не выведенный, потому что `Package.swift` собирает этот target в Swift 5 language mode, где implicit-isolation inheritance для unstructured `Task {}` не гарантирован. Deterministic tests не гадают число `Task.yield()`: `testDeliveryFailureRetriesAtSameReadingAndOnlySuccessPersists` повторно вызывает тот же production `evaluate()` в bounded poll до тех пор, пока retry не пройдёт, что и есть реальный retry-путь — следующая обычная provider evaluation, а не отдельный таймер.

## Identity

Raw UDID/serial/Bluetooth/pairing material не выходит в UI/logs/backup. `AppleDeviceIdentity` создаёт opaque local identity boundary.

## Source map

- `PowerMonitor.swift`, `PowerSnapshot.swift`
- `DevicePowerCenter.swift`, `DeviceBatteryProviding.swift`
- `LocalMacDeviceProvider.swift`
- `AppleAccessoryBatteryProvider.swift`
- `MobileDeviceBatteryProvider.swift`
- `AppleDeviceIdentity.swift`
- `DeviceSnapshotMerger.swift`, `DeviceRefreshScheduler.swift`
- `LowBatteryAlertEngine.swift`, `LowBatteryAlertService.swift`
- `PowerPane.swift`, `PowerStayAwakeBar.swift`
- `PowerAssertionDriver.swift`, `WakeLeaseRegistry.swift`, `StayAwakeService.swift`

## Инварианты

- `.power` internal module ID не менять;
- no private Apple frameworks;
- external discovery explicit opt-in;
- raw identifiers never UI/log/feedback/backup;
- I/O off main actor;
- missing stays missing;
- mobile provider failure не ломает local/accessory providers;
- failed Notification Center delivery never becomes persisted fired-state;
- retry uses the existing provider lifecycle rather than a new background loop;
- a locked-but-trusted device keeps its last-known reading rather than being dropped;
- a topology/wake refresh discards an in-flight read instead of letting it publish after the device set has changed;
- wake assertions are held per lease: one physical assertion per requirement, released only when its last lease goes, and never released on another owner's behalf;
- a power assertion is never claimed in the interface before the system granted it;
- Stay Awake is never restored across a launch, never persisted, and never held without a control that can end it.

## Связано

- [ADR-004](../08-decisions/ADR-004-local-only-device-identity.md)
- `docs/APPLE_DEVICE_BATTERY_SUPPORT.md`
- `docs/QA_APPLE_DEVICES_1.4.6.md`
