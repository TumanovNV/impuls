---
title: Snippets Module
type: module
status: production
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
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

## Identity

Snippet ID compact/hash-based: label, либо text для unnamed item. Duplicate identity заменяется новой записью, что также даёт устойчивый SwiftUI list identity без hashing огромных strings при каждом diff.

## Permissions / network

Нет permission/network. Copy использует system pasteboard; именно это позволяет не требовать Accessibility permission для injection.

## Source map

- `SnippetStore.swift`
- `SnippetsPane.swift`
- `StorageEnvironment.swift`

## Инварианты

- user-editable file остаётся human-readable;
- reload before write;
- bounded file/search;
- no automatic feed from clipboard;
- no Accessibility injection.
