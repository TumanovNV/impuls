---
title: Power and Battery Module
type: module
status: production
documentation_version: 1.2
app_version: 1.4.16
last_reviewed: 2026-08-24
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
```

## Power Center presentation (1.4.14)

`PowerPane` — master-detail Device Navigator: вертикальный список устройств слева, detail card справа, вместо прежнего горизонтального переключателя-и-карточки. Desktop-ветка никогда не выдумывает процент: у Mac mini в навигаторе и в detail card нет battery percentage, только AC source/adapter. Severity coloring (`warning <= 20%`, `critical <= 10%`) зеркалит `LowBatteryAlertEngine.Policy`, так что устройство, готовое дать alert, уже так выглядит в списке. Merge/refresh/provider contracts ниже не изменились.

## Local Mac

`PowerMonitor` остаётся отдельным established path. `LocalMacDeviceProvider` адаптирует его в unified device model. Не переписывать local power path ради external devices.

## External device privacy boundary

Module switch и external-device switch различны. External providers стартуют только когда Power module enabled **и** пользователь включил `Show Connected Apple Devices`. Production `MobileDeviceBatteryProvider.featureEnabled` default = true; hidden product gate отсутствует. iPhone/iPad support остаётся Beta/undocumented-protocol risk.

## Providers

- local Mac: public IOPowerSources + bounded IORegistry supplement для доступных значений;
- accessories: IORegistry + best-effort fixed-argument `system_profiler` source;
- iPhone/iPad: local usbmuxd/lockdown transport over USB or Wi-Fi sync, existing trust required.

`IORegistryAccessoryMapper` (1.4.14) распознаёт Bluetooth Magic Keyboard/Magic Mouse/Magic Trackpad и по USB-IF vendor ID `0x05AC`, и по Bluetooth SIG Apple vendor ID `0x004C` — `AppleDeviceManagementHIDEventService` репортит эти аксессуары под `0x004C`, что раньше приводило к тихой потере записи на реальном Mac mini, хотя Control Center видел заряд корректно. Пустой `Product` string на этих устройствах закрывается небольшой hardware-confirmed таблицей Bluetooth ProductID, а registry-флаг `Built-In` теперь приоритетнее эвристики по transport string, когда он присутствует.

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
- `PowerPane.swift`

## Инварианты

- `.power` internal module ID не менять;
- no private Apple frameworks;
- external discovery explicit opt-in;
- raw identifiers never UI/log/feedback/backup;
- I/O off main actor;
- missing stays missing;
- mobile provider failure не ломает local/accessory providers;
- failed Notification Center delivery never becomes persisted fired-state;
- retry uses the existing provider lifecycle rather than a new background loop.

## Связано

- [ADR-004](../08-decisions/ADR-004-local-only-device-identity.md)
- `docs/APPLE_DEVICE_BATTERY_SUPPORT.md`
- `docs/QA_APPLE_DEVICES_1.4.6.md`
