---
title: Release Process
type: release
status: active
documentation_version: 1.0
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, release, github-actions]
---

# Релизный процесс ИМПУЛЬС

## Source of truth версии

Версия задаётся в [`Scripts/version`](../../Scripts/version):

```text
VERSION=x.y.z
```

Для каждой версии должен существовать непустой файл:

```text
docs/releases/x.y.z.md
```

## Штатный flow

1. Подготовить код и тесты в рабочей ветке.
2. Изменить `Scripts/version`.
3. Создать `docs/releases/<version>.md`: сначала русский раздел, затем `---`, затем краткий английский раздел.
4. Обновить security audit, если изменение касается updates, networking, permissions или stored data.
5. Обновить релевантную knowledge base документацию.
6. Открыть Pull Request.
7. Дождаться успешного CI.
8. Слить PR в `main`.
9. Release workflow создаёт tag `v<version>`, собирает и проверяет артефакты, подписывает appcast и публикует GitHub Release.
10. Website sync обновляет статический fallback публичного сайта после релиза.

## Что не делать вручную

Не создавать release/tag вручную в обход workflow при штатном релизе. Не коммитить signing keys. Не менять release semantics как «маленькую правку» без отдельного review.

## Сборка локально

Основные команды проекта:

```bash
swift test -c release
./Scripts/bundle.sh release
./Scripts/dmg.sh
```

`bundle.sh` использует Developer ID Application, если соответствующая переменная окружения доступна; иначе предусмотрен ad-hoc fallback. Фактическое состояние подписи и notarization перед конкретным релизом проверяется по build/release workflow и артефакту, а не по старой документации.

## Release-sensitive файлы

Особое внимание требуется для:

- `.github/workflows/build.yml`;
- `.github/workflows/release.yml`;
- `Scripts/bundle.sh`;
- `Scripts/dmg.sh`;
- `Scripts/version`;
- `Package.swift` / `Package.resolved`;
- `Sources/Impuls/Services/UpdateService.swift`;
- release notes и appcast logic.

## Обновления

Встроенное обновление принадлежит `UpdateService.swift` и Sparkle. Автоматические проверки и автоматическая установка являются opt-in. System profiling должен оставаться отключённым. Signed feed и verify-before-extraction — обязательные security properties.

## Документация релиза

После изменения release flow обновить этот документ и при архитектурном изменении создать ADR. После каждого выпуска обновляется [Project Status](../00-project/project-status.md), если релиз меняет текущий baseline.
