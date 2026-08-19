---
title: ADR-005 Signed Update Trust Chain
type: decision
status: accepted
documentation_version: 1.1
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, adr, updates, sparkle, security]
---

# ADR-005 — Signed Update Trust Chain

## Status

Accepted.

## Context

Публичные builds могут временно быть ad-hoc signed, но встроенное обновление всё равно обязано аутентифицировать собственный release archive.

## Decision

Использовать pinned Sparkle 2.9.5, fixed GitHub appcast, signed feed, Ed25519 archive signature и verify-before-extraction. Release workflow хранит private key только в GitHub secret и сверяет derived public key с ключом приложения.

## Important distinction

Apple Developer ID/notarization и Sparkle update signature — разные trust layers. Нельзя отключать Sparkle verification из-за отсутствия Developer ID.

## Consequences

Dependency/update configuration changes являются security-sensitive и проходят CI/release gates.

## References

- [Update System](../05-release/update-system.md)
- [Release Pipeline](../05-release/release-pipeline.md)
