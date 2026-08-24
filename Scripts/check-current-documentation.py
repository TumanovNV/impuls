#!/usr/bin/env python3
"""Validate high-value current-state and agent documentation against the repository.

The normal knowledge-base checker validates Markdown structure and baseline
frontmatter. Documentation Guardian/freshness protect curated implementation
contracts. This focused guard covers the remaining cold-start risk: public and
agent entrypoints that can be syntactically valid yet quietly describe an old
release, locale set or route.

Historical release/audit documents are intentionally outside this checker.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION_RE = re.compile(r"(?m)^VERSION=(\d+\.\d+\.\d+)\s*$")
APP_LANGUAGE_RE = re.compile(r'^\s*case\s+\w+\s*=\s*"([^"]+)"\s*$', re.M)
VERSION_LITERAL_RE = re.compile(r"\b\d+\.\d+\.\d+\b")


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def current_version() -> str:
    match = VERSION_RE.search(read("Scripts/version"))
    if not match:
        raise ValueError("Scripts/version does not contain VERSION=x.y.z")
    return match.group(1)


def resource_locales() -> set[str]:
    return {path.name.removesuffix(".lproj") for path in (ROOT / "Resources").glob("*.lproj") if path.is_dir()}


def app_language_locales() -> set[str]:
    values = set(APP_LANGUAGE_RE.findall(read("Sources/Impuls/Services/AppLanguageService.swift")))
    return {value for value in values if value != "system"}


def bundle_locales() -> set[str]:
    text = read("Scripts/bundle.sh")
    match = re.search(r"<key>CFBundleLocalizations</key>\s*<array>(.*?)</array>", text, re.S)
    if not match:
        return set()
    return set(re.findall(r"<string>([^<]+)</string>", match.group(1)))


def locale_registry() -> dict:
    return json.loads(read("Scripts/site-locales/registry.json"))


def registry_locales() -> set[str]:
    return {entry["code"] for entry in locale_registry().get("locales", [])}


def privacy_locales() -> set[str]:
    return {
        path.stem
        for path in (ROOT / "Scripts/site-privacy-locales").glob("*.json")
        if path.name != "metadata.json"
    }


def validate_locale_contracts(errors: list[str]) -> None:
    sources = {
        "Resources/*.lproj": resource_locales(),
        "AppLanguageService": app_language_locales(),
        "CFBundleLocalizations": bundle_locales(),
        "website registry": registry_locales(),
        "privacy locale configs": privacy_locales(),
    }
    baseline = sources["Resources/*.lproj"]
    if not baseline:
        errors.append("no application localizations found under Resources/*.lproj")
        return
    for label, actual in sources.items():
        if actual != baseline:
            errors.append(
                f"locale set drift: {label}={sorted(actual)}; Resources={sorted(baseline)}"
            )

    registry = locale_registry()
    entries = registry.get("locales", [])
    codes = [entry.get("code") for entry in entries]
    if len(codes) != len(set(codes)):
        errors.append("website locale registry contains duplicate codes")
    for entry in entries:
        code = entry.get("code")
        path = entry.get("path")
        privacy_path = entry.get("privacy_path")
        if not isinstance(code, str) or not code:
            errors.append("website locale registry contains an invalid code")
            continue
        if not isinstance(path, str) or not isinstance(privacy_path, str):
            errors.append(f"registry locale {code} must define path and privacy_path")
        if code != registry.get("default_locale") and not (ROOT / "Scripts/site-locales" / f"{code}.json").is_file():
            errors.append(f"website locale {code} has no Scripts/site-locales/{code}.json config")

    count = len(baseline)
    localization_doc = read("knowledge-base/04-development/localization.md")
    expected_phrase = f"same {count} languages" if count != 7 else "same seven languages"
    if expected_phrase not in localization_doc:
        errors.append(
            "Localization canonical doc does not describe the current shared locale count; "
            "review all three localization contracts"
        )


def validate_agent_routes(errors: list[str]) -> None:
    agents = read("AGENTS.md")
    claude = read("CLAUDE.md")
    ai_index = read("knowledge-base/10-ai/AI-INDEX.md")
    manifest = json.loads(read("PROJECT-MANIFEST.json"))

    if re.search(r"baseline in `main` is Impuls \d+\.\d+\.\d+", agents):
        errors.append("AGENTS.md hardcodes a current main baseline; route exact version through Scripts/version")
    for required in (
        "PROJECT-MANIFEST.json",
        "knowledge-base/10-ai/AI-INDEX.md",
        "knowledge-base/00-project/project-status.md",
        "knowledge-base/04-development/localization.md",
        "Scripts/check-current-documentation.py",
    ):
        if required not in agents:
            errors.append(f"AGENTS.md is missing current agent route/check: {required}")

    for required in ("legal-privacy.md", "knowledge-base/04-development/localization.md"):
        if required not in claude:
            errors.append(f"CLAUDE.md is missing scoped localization/legal route: {required}")

    for required in ("[Localization]", "[Website Legal and Privacy Localization]"):
        if required not in ai_index:
            errors.append(f"AI-INDEX.md is missing current routing entry: {required}")

    product = manifest.get("product", {})
    web = manifest.get("web_and_collector", {})
    expected_manifest = {
        "product.localization_doc": product.get("localization_doc"),
        "web_and_collector.website_legal_doc": web.get("website_legal_doc"),
        "web_and_collector.website_locale_registry": web.get("website_locale_registry"),
    }
    required_paths = {
        "product.localization_doc": "knowledge-base/04-development/localization.md",
        "web_and_collector.website_legal_doc": "knowledge-base/07-web/legal-privacy.md",
        "web_and_collector.website_locale_registry": "Scripts/site-locales/registry.json",
    }
    for label, expected in required_paths.items():
        if expected_manifest[label] != expected:
            errors.append(f"PROJECT-MANIFEST route {label} must be {expected!r}")


def validate_current_entrypoints(errors: list[str]) -> None:
    version = current_version()
    kb_readme = read("knowledge-base/README.md")
    overview = read("knowledge-base/00-project/project-overview.md")
    module_catalog = read("knowledge-base/02-modules/README.md")
    invariants = read("knowledge-base/10-ai/invariants.md")
    impact = read("knowledge-base/10-ai/change-impact-matrix.md")
    release_pipeline = read("knowledge-base/05-release/release-pipeline.md")
    privacy = read("PRIVACY.md")
    security = read("SECURITY.md")

    if re.search(r"product baseline \*\*\d+\.\d+\.\d+\*\*", kb_readme):
        errors.append("knowledge-base/README.md hardcodes a product baseline instead of routing to Scripts/version")
    if re.search(r"публичная версия\s*[—-]\s*\d+\.\d+\.\d+", overview, re.I):
        errors.append("project-overview.md hardcodes an old/current public version; route current release through Project Status")
    if re.search(r"ИМПУЛЬС\s+\d+\.\d+\.\d+\s+содержит", module_catalog, re.I):
        errors.append("module catalog version-anchors the current shipped module set")
    if re.search(r"На baseline \d+\.\d+\.\d+ их три", invariants):
        errors.append("invariants.md version-anchors the current three-network-owner invariant")
    if re.search(r"На \d+\.\d+\.\d+ таблиц", invariants):
        errors.append("invariants.md version-anchors the current localization-table invariant")
    if "settings, RU/EN, tests" in impact:
        errors.append("change-impact-matrix.md still routes module strings through obsolete RU/EN parity")
    if "knowledge-base/13-qa/release-evidence/<version>.md" not in release_pipeline:
        errors.append("release-pipeline.md omits mandatory version-specific Release QA Evidence")

    canonical_policy = "https://tumanovnv.github.io/impuls/privacy/"
    if canonical_policy not in privacy:
        errors.append("PRIVACY.md does not link the canonical /privacy/ policy")
    if "https://tumanovnv.github.io/impuls/site-privacy.html" in privacy:
        errors.append("PRIVACY.md still presents legacy site-privacy.html as the operator policy URL")
    if "project-support" not in privacy.lower() and "project support" not in privacy.lower():
        errors.append("PRIVACY.md does not document the local-first project-support state introduced in 1.4.15")

    stale_security = re.findall(r"current (\d+\.\d+\.\d+) code", security)
    for candidate in stale_security:
        if candidate != version:
            errors.append(f"SECURITY.md calls {candidate} current while Scripts/version is {version}")


def validate_data() -> list[str]:
    errors: list[str] = []
    try:
        validate_locale_contracts(errors)
        validate_agent_routes(errors)
        validate_current_entrypoints(errors)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        errors.append(f"current-documentation validation error: {error}")
    return errors


def main() -> int:
    errors = validate_data()
    if errors:
        print("Current documentation validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        "Current documentation OK: version routing, app/website/legal locale sets, "
        "agent entrypoints and public privacy route are consistent."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
