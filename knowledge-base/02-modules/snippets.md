---
title: Snippets Module
type: module
status: production
documentation_version: 1.2
app_version: 1.4.16
last_reviewed: 2026-08-20
tags: [impuls, module, snippets]
---

# Snippets

## Назначение

Ручной список часто используемого текста. Это не автоматическая clipboard history: попадание в Snippets всегда intentional.

## Flow

```mermaid
flowchart LR
    FILE[snippets.json] --> ST[SnippetStore]
    EDIT[User add/remove] --> ST
    EXT[External editor] --> FILE
    ST --> UI[SnippetsPane]
    ST --> ACT[Actions search]
    ST --> COPY[System Pasteboard]
    ST --> FILE
```

## Persistence

`~/Library/Application Support/Impuls/snippets.json`, pretty-printed user-editable JSON. Label optional. Перед записью store reload'ит file, чтобы не затереть external edits. File signature включает size/modification/resource identity.

Limits: 10 MiB, 5 000 items, query 256 chars, searchable value bounded 16 KiB.

Запись идёт через serial utility queue `io.tumanov.impuls.snippets.writer`, как у `NoteStore`. Debounce нет намеренно: snippet меняется по осознанному действию, а не на каждое нажатие клавиши. `NotchViewModel.stop()` вызывает `flushSynchronously()` — durability на выходе приравнена к notes.

Пока запись в полёте, `reload()` не читает file: копия в памяти новее диска, и чтение отменило бы изменение, которое ещё летит. Retry в `reload()` действительно повторяет попытку — подмена файла редактором во время bounded read проявляется как read/decode failure, и прежний `catch` возвращался на первой же итерации, из-за чего единственный сценарий, ради которого цикл был написан, не срабатывал.

## File pins (1.4.16, IMP-39)

Помимо текста, элементом может быть **локальный файл**. Это по-прежнему ручной список: файл попадает сюда только явным действием — кнопкой рядом с `+` или drag-and-drop в панель.

**Взаимодействие.** Одиночный клик кладёт файл в системный pasteboard как файловый объект (`writeObjects([url as NSURL])`), то есть ⌘V в Finder вставляет сам файл, а не текст пути. Двойной клик открывает файл в приложении по умолчанию через `NSWorkspace`. Различение одиночного и двойного клика делает `ClickArbiter`: одиночное действие откладывается на `NSEvent.doubleClickInterval` — системный интервал, а не константа — и отменяется, если пришёл второй клик. Поэтому двойной клик никогда не даёт copy+open и не открывает файл дважды; третий и последующие клики игнорируются. Для клавиатуры и VoiceOver те же действия есть в контекстном меню и в accessibility actions: Copy, Open, Show in Finder, Choose File Again, Delete.

**Что хранится.** Содержимое файла не читается и не сохраняется никогда. Bookmark (~1.1 KiB, ~1.5 KiB в base64) содержит имя тома, UUID тома и inode — больше, чем путь, — поэтому он не уезжает в portable backup: `ImpulsBackupDocument` вырезает его на экспорте, оставляя читаемый путь. Это же означает, что file pin стоит примерно в двадцать раз дороже текстового элемента и что строка pin'а в `snippets.json` содержит одну длинную base64-строку: файл остаётся валидным и правится руками, но именно эта строка руками не читается. В `snippets.json` у file pin читаемый путь лежит в `text`, а необязательный `file.bookmark` — единственное, что позволяет пережить переименование и перемещение. Файл остаётся hand-editable: запись вида `{"text": "/Users/me/report.pdf", "file": {}}` валидна и резолвится по пути. Bookmark создаётся без security scope — приложение не sandboxed, и scoped bookmark обещал бы containment, которого нет.

**Разрешение ссылки.** `SnippetFileResolver` пробует bookmark, затем путь. Опции резолва — `[.withoutUI, .withoutMounting]`; `withoutMounting` здесь несущая: без неё bookmark на отключённый том пытался бы его смонтировать и мог заблокировать вызывающий поток. Если bookmark оказался stale, но разрешился, он переписывается на месте — без дубликата и без изменения порядка.

**Чего resolver не делает.** Не ищет файл. Нет recursive scan, Spotlight, поиска по имени и угадывания по inode: неразрешимая ссылка — это честное `File Unavailable`, а не догадка. У недоступного pin остаются только Choose File Again и Delete; Copy/Open/Reveal fail closed и не делают ничего. Re-select заменяет ссылку у той же строки, сохраняя её позицию; Cancel не меняет ничего.

**Границы.** Один pin — один обычный файл. Каталог, file package (`.app`, `.rtfd`, документы Pages), dead symlink, сокет и устройство отклоняются до создания записи. **Живой** symlink принимается: `isRegularFileKey` отвечает про сам линк, поэтому проверка идёт по разрешённой цели — иначе рабочий symlink на нормальный файл получал бы отказ. Picker выставляет `treatsFilePackagesAsDirectories`, чтобы в package нельзя было «провалиться» выбором и получить молчаливый отказ.

Availability проверяется лениво — при появлении строки и по действию пользователя; ни таймера, ни поллинга, ни watcher'а модуль не добавляет. Автоматическая проверка выполняется **вне main actor**: `withoutMounting` ограничивает только bookmark-ветку, а fallback по пути заканчивается `fileExists`/`resourceValues`, и они блокируются на timeout примонтированной, но не отвечающей сетевой шары. Это та же причина, по которой `ShelfStore` увёл свой existence sweep с main actor.

Клик по file pin считается только в области содержимого строки: горизонтальный padding у file pin намеренно не реагирует, потому что клик там обошёл бы arbiter и скопировал файл сразу. У текстового элемента tap по-прежнему на всей строке.

Drop локального файла на панель «Заготовки» создаёт pin. Это перекрывает window-level drop, который иначе отправил бы файл на Полку, — сознательно: drop именно в этот таб означает «закрепи», а не «положи на полку». Остальные табы работают как раньше.

File pin не попадает в Actions search. Не потому, что Actions не умеет файл — `ImpulsActionValue.file` существует и используется clipboard-элементами, — а потому, что pin это ещё Open, Reveal, re-select и unavailable state, которых строка Actions не выражает. Показать половину поведения под тем же именем хуже, чем оставить pin там, где оно есть целиком.

**Удаление.** Remove убирает только запись. На этом пути нет `FileManager.removeItem`, trash и перемещения — пользовательский файл остаётся на диске, и это закреплено регрессионным тестом.

## Identity

Snippet ID compact/hash-based: label, либо text для unnamed item. Duplicate identity заменяется новой записью, что также даёт устойчивый SwiftUI list identity без hashing огромных strings при каждом diff.

## Permissions / network

Нет permission/network. Copy использует system pasteboard; именно это позволяет не требовать Accessibility permission для injection.

## Source map

- `SnippetStore.swift`
- `SnippetFilePin.swift`
- `SnippetFileActions.swift`
- `SnippetsPane.swift`
- `StorageEnvironment.swift`

## Инварианты

- user-editable file остаётся human-readable;
- reload before write;
- bounded file/search;
- no automatic feed from clipboard;
- no Accessibility injection;
- содержимое закреплённого файла не читается и не сохраняется;
- ссылка на файл не восстанавливается поиском;
- удаление pin не трогает файл на диске.
