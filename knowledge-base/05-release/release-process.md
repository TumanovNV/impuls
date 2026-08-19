---
title: Release Process
type: release
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, release, github-actions, qa]
---

# Релизный процесс ИМПУЛЬС

## Source of truth версии

Версия задаётся в [`Scripts/version`](../../Scripts/version):

```text
VERSION=x.y.z
```

Для каждой версии должны существовать:

```text
docs/releases/x.y.z.md
knowledge-base/13-qa/release-evidence/x.y.z.md
```

Первый файл — пользовательские release notes. Второй — проверяемый manual/hardware/TCC evidence record. Release notes не заменяют QA evidence, а QA evidence не заменяет automated CI.

## Штатный flow

1. Подготовить код и тесты в рабочей ветке.
2. Изменить `Scripts/version`.
3. Создать `docs/releases/<version>.md`: сначала русский раздел, затем `---`, затем краткий английский раздел.
4. Скопировать [`../13-qa/release-evidence/TEMPLATE.md`](../13-qa/release-evidence/TEMPLATE.md) в `knowledge-base/13-qa/release-evidence/<version>.md`.
5. Зафиксировать candidate/release commit и реальные test environments без serial/UDID/hostname/user content.
6. Для каждого `mixed`, `manual-macos`, `manual-hardware` и `manual-service` сценария из [Behavioral QA Matrix](../13-qa/behavioral-qa-matrix.md) записать честный результат.
7. Выбрать release decision: `certified`, `ship-with-known-gaps` или `blocked`.
8. Добавить/обновить security audit, если изменение касается updates, networking, permissions или stored data.
9. Обновить релевантную knowledge base документацию.
10. Выполнить normal checks, включая `python3 Scripts/check-release-qa-evidence.py --release-gate`.
11. Открыть Pull Request.
12. Дождаться успешного CI.
13. Слить PR в `main`.
14. Release workflow создаёт или обновляет tag/release `v<version>`, собирает и проверяет артефакты, подписывает appcast и публикует GitHub Release.
15. Website sync обновляет статический fallback публичного сайта после релиза.

## Release QA gate

Политика хранится в [`../../Scripts/release-qa-policy.json`](../../Scripts/release-qa-policy.json), проверка — в [`../../Scripts/check-release-qa-evidence.py`](../../Scripts/check-release-qa-evidence.py).

С версии **1.4.12**:

- evidence file для версии обязателен;
- `not-recorded` запрещён;
- каждый manual/mixed scenario обязан присутствовать ровно один раз;
- `pass`/`fail`/`blocked` для macOS/hardware сценария должен ссылаться на реальную Mac-среду;
- `manual-hardware` требует `real-mac-hardware` environment;
- `certified` разрешён только если все manual/mixed строки — `pass` или обоснованный `not-applicable`;
- `ship-with-known-gaps` обязан сохранять unresolved rows и непустой раздел `Known gaps`;
- `blocked` означает, что кандидат нельзя считать готовым к выпуску и `--release-gate` должен вернуть ошибку.

`1.4.11` остаётся честным retrospective baseline: до появления системы structured evidence repository не сохранял release-time hardware/TCC matrix, поэтому прошлые пробелы не подменяются фиктивными `pass`.

Для проверки только структуры/исторических записей без shipping-decision gate можно отдельно запускать:

```bash
python3 Scripts/check-release-qa-evidence.py --all
```

## Что не делать вручную

Не создавать release/tag вручную в обход workflow при штатном релизе. Не коммитить signing keys. Не менять release semantics как «маленькую правку» без отдельного review.

Не отмечать manual QA как `pass` только потому, что:

- unit/CI tests зелёные;
- есть старый скриншот похожего состояния;
- сценарий присутствует в Behavioral QA Matrix;
- похожая версия когда-то работала на другом Mac.

## Сборка локально

Основные команды проекта перед release candidate:

```bash
swift test -c release
./Scripts/bundle.sh release
./Scripts/dmg.sh
python3 Scripts/check-release-qa-evidence.py --release-gate
```

`bundle.sh` использует Developer ID Application, если соответствующая переменная окружения доступна; иначе предусмотрен ad-hoc fallback. Фактическое состояние подписи и notarization перед конкретным релизом проверяется по build/release workflow и артефакту, а не по старой документации.

## Release-sensitive файлы

Особое внимание требуется для:

- `.github/workflows/build.yml`;
- `.github/workflows/release.yml`;
- `.github/workflows/knowledge-base.yml`;
- `Scripts/bundle.sh`;
- `Scripts/dmg.sh`;
- `Scripts/version`;
- `Scripts/check-release-qa-evidence.py` / `Scripts/release-qa-policy.json`;
- `Package.swift` / `Package.resolved`;
- `Sources/Impuls/Services/UpdateService.swift`;
- `knowledge-base/13-qa/behavioral-qa-matrix.md`;
- `knowledge-base/13-qa/release-evidence/`;
- release notes и appcast logic.

## Обновления

Встроенное обновление принадлежит `UpdateService.swift` и Sparkle. Автоматические проверки и автоматическая установка являются opt-in. System profiling должен оставаться отключённым. Signed feed и verify-before-extraction — обязательные security properties.

## Документация релиза

После изменения release flow обновить этот документ и при архитектурном изменении создать ADR. После каждого выпуска обновляется [Project Status](../00-project/project-status.md), если релиз меняет текущий baseline.

Release-specific manual evidence хранится только в [Release QA Evidence](../13-qa/release-evidence/README.md). Matrix описывает contract inventory, release evidence — факт выполнения, CI/tests — deterministic proof.
