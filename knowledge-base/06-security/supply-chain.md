---
title: Dependency and Supply-Chain Policy
type: security-reference
status: active
documentation_version: 1.3
app_version: 1.4.11
last_reviewed: 2026-08-19
tags: [impuls, security, dependencies, supply-chain, swiftpm]
---

# Dependency and Supply-Chain Policy

Impuls deliberately keeps its third-party dependency surface small. A package dependency is executable code inside the application trust boundary, so adding or changing one is an architecture/security decision rather than ordinary implementation housekeeping.

## Current Swift package inventory

The authoritative machine allowlist is [`Scripts/dependency-policy.json`](../../Scripts/dependency-policy.json). At the current baseline it contains one approved remote Swift package: **Sparkle 2.9.5**, used for the signed application update path.

The policy pins four independent facts:

- package identity;
- repository location;
- exact semantic version;
- exact resolved 40-character Git revision.

`Package.swift` must declare every direct package with `exact:`. `Package.resolved` must contain exactly the approved pin set. The policy also requires future transitive pins to be explicitly listed rather than silently accepted.

## Why version + revision

An exact version requirement protects against normal semver drift. The lockfile revision gives a second check that the dependency resolved to the reviewed Git object. CI compares both against the explicit policy so a package bump, a new transitive package or an unexpected resolved revision is visible immediately.

This does not replace upstream signature/repository security or a review of the package's own code/release. It makes repository-level dependency drift machine-detectable.

## Update protocol

Before adding or updating a dependency:

1. establish why existing Apple frameworks/project code are insufficient;
2. review the new package's purpose, maintenance/security implications and required privileges/network behavior;
3. update `Package.swift` using an exact version for a direct dependency;
4. resolve and review `Package.resolved`;
5. update `Scripts/dependency-policy.json` with the exact version/revision and canonical owning doc;
6. update this document and any architecture/security/network/update documents affected by the package;
7. run dependency policy tests plus the normal Swift/security/build CI;
8. create an ADR when the dependency introduces a long-lived architecture boundary.

A dependency must not be added solely to avoid implementing a small bounded helper that can safely remain in the standard library/Foundation/AppKit stack.

## Update-system special case

Sparkle is not merely a UI library: it participates in the software update trust chain. Its version/policy therefore also belongs to [Update System](../05-release/update-system.md), [Release Pipeline](../05-release/release-pipeline.md), [Security Model](security-model.md) and ADR-005.

Changing Sparkle requires verifying that signed appcast and verify-before-extraction guarantees remain intact. The dependency policy does not weaken those product-level update checks.

## Automation

Run:

```bash
python3 Scripts/check-dependency-policy.py
python3 -m unittest discover -s Tests/PythonTests -p 'test_dependency_policy.py'
```

The `knowledge-base` workflow runs these checks whenever `Package.swift`, `Package.resolved`, the allowlist/checker/tests, or knowledge-base automation changes.

Documentation Guardian also treats dependency requirement/version changes as a contract-sensitive diff that requires review of this security document. The freshness checker maps this document to `Package.swift`, `Package.resolved` and the dependency policy so older dependency drift cannot remain hidden.

## Boundaries

The policy contains only public dependency metadata. Never place package registry credentials, GitHub tokens, signing keys, Sparkle private signing material or other secrets in this file or its machine allowlist.
