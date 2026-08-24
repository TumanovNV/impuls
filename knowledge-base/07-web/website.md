---
title: Website Architecture
type: web
status: active
documentation_version: 1.6
app_version: 1.4.15
last_reviewed: 2026-08-24
tags: [impuls, website, github-pages, seo, design-system, localization]
---

# Website Architecture

## Hosting boundary

`docs/` обслуживается GitHub Pages. Engineering knowledge base находится отдельно в `knowledge-base/`.

Маркетинговый сайт, privacy/legal pages и локализации приложения — три разные поверхности. На текущем baseline их locale sets совпадают: RU, EN, DE, FR, ES, JA и Simplified Chinese. Это совпадение не превращает их в один контракт; canonical cross-surface route — [Localization](../04-development/localization.md), а юридическая генерация отдельно принадлежит [Website Legal and Privacy Localization](legal-privacy.md).

Текущие marketing routes:

```text
ru       /
en       /en/
de       /de/
fr       /fr/
es       /es/
ja       /ja/
zh-Hans  /zh-hans/
```

Текущие privacy routes принадлежат тому же registry, но отдельному legal contract: `/privacy/`, `/en/privacy/`, `/de/privacy/`, `/fr/privacy/`, `/es/privacy/`, `/ja/privacy/`, `/zh-hans/privacy/`.

## Canonical marketing source and generated pages

`docs/index.html` — canonical RU marketing content/layout source и self-contained production page: no external CSS/JS/fonts и no runtime localization dependency. Значения design system остаются в CSS этой страницы; intent описан в [Website Design System](design-system.md).

Публичный набор website locales хранится в `Scripts/site-locales/registry.json`. Один `Scripts/build-site-locale.py` генерирует все non-default marketing pages:

```text
Scripts/site-locales/registry.json
              │
docs/index.html (RU source)
        │
        ├── en.json      ──> docs/en/index.html
        ├── de.json      ──> docs/de/index.html
        ├── fr.json      ──> docs/fr/index.html
        ├── es.json      ──> docs/es/index.html
        ├── ja.json      ──> docs/ja/index.html
        └── zh-Hans.json ──> docs/zh-hans/index.html
```

Все marketing pages кроме RU root **generated и не редактируются вручную**. Любой layout/content contract сначала меняется в canonical RU source или соответствующем locale config, затем pages регенерируются.

Privacy/legal HTML также generated, но **не из `docs/index.html`**. Его sources — `Scripts/site-privacy-template.html`, `Scripts/site-privacy-locales/<locale>.json`, `Scripts/site-privacy-locales/metadata.json` и registry `privacy_path`. Не смешивать два generator contracts и не редактировать `docs/**/privacy/index.html` напрямую.

### Marketing translation storage

DE, FR, ES, JA и zh-Hans — fully external marketing locales: user-facing strings, screenshot alt text, localized head metadata и localized JSON-LD copy живут в `Scripts/site-locales/<locale>.json`.

English проходит через тот же generic builder и хранит head/JSON-LD metadata в `Scripts/site-locales/en.json`. На текущем migration baseline его body/alt dictionary всё ещё читается из существующих `EN`/`ALT` объектов canonical RU page через `source_dictionary` / `source_alt_dictionary`. Это transitional compatibility, а не разрешение снова создавать language-specific generators.

DE/FR/ES/JA/zh-Hans marketing translations подготовлены AI-assisted и прошли structural/technical review; native-speaker linguistic review пока не записан как выполненный. Legal translation status имеет отдельный disclosure в [legal-privacy.md](legal-privacy.md).

## Locale registry and routing owners

`Scripts/site-locales/registry.json` — canonical routing owner публичного locale cluster. Для каждой локали он задаёт:

- BCP-47 locale code;
- короткий label marketing selector;
- marketing URL `path`;
- legal URL `privacy_path`;
- OpenGraph locale.

**Locale code, marketing path и privacy path не обязаны совпадать текстуально.** Текущий важный пример: BCP-47 code `zh-Hans` публикуется по `/zh-hans/`, а policy — по `/zh-hans/privacy/`. Generators, legacy routing, workflows, sitemap и tests обязаны читать paths из registry, а не строить `docs/<code>/` самостоятельно.

`Scripts/sync-site-locales.py` читает registry и синхронизирует canonical RU marketing source:

- полный marketing `hreflang` cluster (`ru`, `en`, `de`, `fr`, `es`, `ja`, `zh-Hans`, `x-default`);
- `og:locale` / `og:locale:alternate` cluster;
- `WebSite.inLanguage` для реально существующих public marketing pages;
- видимый seven-locale selector;
- runtime labels для release metadata на generated pages;
- legacy `?lang=` navigation через registry path;
- responsive behavior language selector.

`Scripts/sync-site-privacy-links.py` владеет privacy CTA в marketing source. Link остаётся относительным `privacy/`, поэтому generated marketing page автоматически ведёт к собственному localized child policy route.

`Scripts/sync-site-sitemap.py` читает тот же registry и `Scripts/site-privacy-locales/metadata.json`. Он владеет **обоими** индексируемыми кластерами в `docs/sitemap.xml`: marketing routes и privacy routes. Legal `lastmod` происходит из policy `effective_date`, а не из wall clock или старого sitemap.

Sync scripts deterministic и имеют `--check`. Generated page не должна сама решать, какие языки или legal routes существуют.

## Marketing SEO contract

Каждая marketing locale — самостоятельная индексируемая страница со своим:

- `<html lang>`;
- title и meta description;
- self canonical;
- OpenGraph locale/title/description;
- Twitter title/description;
- localized `SoftwareApplication` и `FAQPage` JSON-LD;
- полным reciprocal marketing `hreflang` cluster.

`x-default` marketing cluster остаётся RU root. Locale попадает в registry только вместе с реальным static URL, self-canonical, sitemap projection и reciprocal hreflang.

Privacy pages имеют собственные localized title/description, self-canonical и reciprocal **legal** hreflang cluster; их детальный структурный/правовой contract находится в [Website Legal and Privacy Localization](legal-privacy.md).

Текущий baseline:

```text
app locales:       ru, en, de, fr, es, ja, zh-Hans
marketing locales: ru, en, de, fr, es, ja, zh-Hans
privacy locales:   ru, en, de, fr, es, ja, zh-Hans
```

## Screenshots

RU marketing page использует RU product captures, EN — EN captures. External marketing locale configs `de.json`, `fr.json`, `es.json`, `ja.json` и `zh-Hans.json` сознательно задают `screenshot_locale: en`: body/head/alt локализованы, но продуктовые снимки остаются реальными английскими captures, пока отдельные наборы для этих языков не подготовлены. Нельзя рисовать fake localized UI вместо реального приложения.

Screenshot assets должны быть real product captures либо явно demo data. Нельзя публиковать личные данные, internal notes, реальные calendar events или identifiers.

## Release and generated-page data flow

```mermaid
flowchart LR
    REG[site-locales/registry.json] --> LOC[sync-site-locales.py]
    REG --> LINK[sync-site-privacy-links.py]
    REG --> MAP[sync-site-sitemap.py]
    REG --> LGEN[build-site-locale.py]
    REG --> PGEN[build-site-privacy-locale.py]

    GH[GitHub Releases latest] --> JS[Runtime Releases API fetch]
    GH --> REL[sync-site-release.py]
    REL --> RU[Canonical RU marketing fallback + JSON-LD]
    RU --> LOC
    RU --> LINK
    LOC --> LGEN

    PMETA[privacy metadata] --> MAP
    PCOPY[privacy locale JSON] --> PGEN
    PTPL[privacy template] --> PGEN

    LGEN --> LAND[7 marketing pages]
    PGEN --> PRIV[7 privacy pages]
    LEGACY[sync-site-privacy-legacy.py] --> OLD[/site-privacy.html noindex handoff]
    MAP --> SITEMAP[sitemap.xml]

    LAND --> PAGE[GitHub Pages]
    PRIV --> PAGE
    OLD --> PAGE
    SITEMAP --> PAGE
```

Version/download/SHA at runtime читаются из GitHub Releases API. Static marketing markup уже содержит synchronized fallback для crawlers/no-JS и не является independent release source of truth.

`Scripts/sync-site-release.py` владеет `FALLBACK_RELEASE`, `[data-release]`, SHA-256, release fields JSON-LD и download links. Новый app release не требует ручного редактирования каждой marketing language page. Privacy policy revision/version не происходит из app release: legal policy metadata имеет собственного владельца.

## Durable product facts

Нерелизные marketing facts, которые должны переживать release sync, принадлежат `Scripts/sync-site-product-facts.py`.

Текущий localization product fact виден на каждой marketing locale:

- RU: `7 языков интерфейса`;
- EN: `7 interface languages`;
- DE: `7 Sprachen`;
- FR: `7 langues`;
- ES: `7 idiomas`;
- JA: `7 言語対応`;
- zh-Hans: `支持 7 种语言`;
- FAQ каждой страницы перечисляет все семь app-locales и System/manual language behavior.

RU/EN variants этого факта остаются в canonical RU source/embedded EN dictionary; остальные variants — в external marketing locale configs. Если набор shipped app localizations меняется, нельзя исправить только число в generated HTML: необходимо пройти все три контракта через [Localization](../04-development/localization.md), обновить intended marketing facts/config/assertions и заново построить страницы.

## Site synchronization workflow

`.github/workflows/site-release-sync.yml` поддерживает **landing locales, privacy/legal locales, sitemap и release metadata**. Он запускается после relevant generator/config changes, после release publication, после успешного `release` workflow и вручную.

Текущий порядок:

1. `Scripts/sync-site-release.py` — static release fallback / download / SHA;
2. `Scripts/sync-site-product-facts.py` — durable marketing facts;
3. `Scripts/sync-site-locales.py` — marketing locale routing/runtime cluster из registry;
4. `Scripts/sync-site-privacy-links.py` — localized child-policy CTA route в marketing source;
5. `Scripts/sync-site-sitemap.py` — marketing + privacy sitemap cluster из registry/policy metadata;
6. `Scripts/build-site-locale.py` — каждый non-default marketing locale из registry;
7. `Scripts/build-site-privacy-locale.py` — **все** privacy locales, включая default RU;
8. `Scripts/sync-site-privacy-legacy.py` — legacy `/site-privacy.html` → `noindex,follow` handoff на `/privacy/`;
9. все owners запускаются с `--check`; затем workflow проверяет release fallback/no-JS links, marketing/legal reciprocal hreflang, policy revision markers и legacy noindex;
10. bot коммитит только фактически изменившиеся `docs/index.html`, generated marketing/privacy pages, sitemap и legacy handoff.

Page paths для checks/commit всегда берутся из registry отдельно от locale code. Workflow не является app release path: не меняет `Scripts/version`, не подписывает, не тегирует приложение и не загружает app assets. Его bot commit затрагивает только `docs/`, а push-trigger смотрит на generator/config sources, поэтому bot-generated `docs/` commit не создаёт бесконечный loop.

Focused pre-merge gates остаются разделены:

- `.github/workflows/site-localization.yml` — marketing locale/generator/SEO contract;
- `.github/workflows/site-legal-localization.yml` — privacy/legal structure/routing/factual anchors;
- `knowledge-base` freshness/current-doc guards — documentation/ownership parity.

## Adding a future website locale

Новый язык не должен приводить к `build-<locale>-page.py`, копии HTML или ручной поддержке отдельной страницы.

Если расширяется marketing surface:

1. создать `Scripts/site-locales/<locale>.json` с полной key parity и localized head/schema;
2. добавить locale ровно один раз в `Scripts/site-locales/registry.json`, явно задав code и public `path`;
3. расширить language-specific assertions/tests для нового текста;
4. запустить registry-driven sync/generator checks;
5. после публикации проверить layout и естественность текста, не объявляя native review без фактической вычитки.

Если тот же язык должен иметь legal page, registry entry также получает `privacy_path`, а `Scripts/site-privacy-locales/<locale>.json` должен удовлетворять legal contract. Если marketing/legal rollout намеренно расходится с app locale set, это должно быть явно пересмотрено в [Localization](../04-development/localization.md), а не возникнуть случайно.

`sync-site-locales.py`, `sync-site-sitemap.py`, `site-release-sync.yml` и generic builders не должны получать hardcoded language-specific branch.

## No-JavaScript contract

Каждая static marketing locale обязана быть полноценной без JavaScript:

- реальный DMG link;
- версия, размер, filename и SHA-256 в markup;
- localized body/head/FAQ/product facts;
- все модули видны стопкой, пока JS не построил selector;
- ни один content block не зависит от opacity/IntersectionObserver, чтобы быть читаемым.

Runtime JavaScript может освежить release metadata и включить interaction, но не является переводчиком для external locales. Privacy pages также являются полноценными статическими документами и не зависят от runtime translation.

## Themes and responsive behavior

Website follows `prefers-color-scheme`; отдельного theme toggle нет. Dark/light обязаны проверяться обе.

Seven-locale selector остаётся обычной статической навигацией, не JavaScript menu. До 699 px wordmark text скрывается, locale strip получает собственный horizontal scroll без скролла всей страницы, а Download остаётся отдельной доступной кнопкой. До 359 px скрывается и brand icon, чтобы язык и Download не вытеснялись за viewport. Все семь links остаются в DOM и доступны клавиатуре/скринридеру.

## Invariants

1. `docs/index.html` — canonical RU marketing content/layout source.
2. `docs/en/`, `docs/de/`, `docs/fr/`, `docs/es/`, `docs/ja/`, `docs/zh-hans/` marketing pages generated и не редактируются вручную.
3. `docs/**/privacy/index.html` legal pages generated и не редактируются вручную; их source contract отдельный от marketing HTML.
4. App, marketing website и privacy/legal website — разные localization contracts, хотя текущий baseline содержит семь одинаковых BCP-47 codes.
5. `Scripts/site-locales/registry.json` — единственный canonical routing list public website locales и их marketing/privacy paths.
6. Один generic marketing builder и один generic privacy builder обслуживают все свои generated locales; language-specific generator запрещён.
7. `sync-site-locales.py` владеет marketing page locale cluster, `sync-site-sitemap.py` — marketing + legal sitemap projection; оба читают registry.
8. Нельзя строить filesystem/public path из locale code: использовать registry `path` / `privacy_path`.
9. Release metadata принадлежит `sync-site-release.py`; durable marketing facts — `sync-site-product-facts.py`; legal revision/effective date — privacy metadata owner.
10. Public marketing locale существует только если есть real static URL, self-canonical, sitemap entry и reciprocal marketing hreflang; legal page имеет отдельный reciprocal legal cluster.
11. Все static marketing/privacy pages полезны без JavaScript.
12. `site-release-sync.yml` публикует только website/legal markup и не становится вторым app release workflow.
13. `/site-privacy.html` — legacy noindex handoff, не canonical policy и не sitemap URL.

## Связано

- [Localization](../04-development/localization.md)
- [Website Legal and Privacy Localization](legal-privacy.md)
- [Website Design System](design-system.md)
- [Version Statistics Collector](version-statistics-collector.md)
- [Settings, Onboarding and Feedback](../01-architecture/settings-onboarding-feedback.md)
- [Release Pipeline](../05-release/release-pipeline.md)
- `.claude/rules/website.md`
- `.claude/rules/legal-privacy.md`
- `Scripts/sync-site-release.py`
- `Scripts/sync-site-product-facts.py`
- `Scripts/sync-site-locales.py`
- `Scripts/sync-site-privacy-links.py`
- `Scripts/sync-site-sitemap.py`
- `Scripts/sync-site-privacy-legacy.py`
- `Scripts/build-site-locale.py`
- `Scripts/build-site-privacy-locale.py`
- `Scripts/site-locales/registry.json`
- `Scripts/site-privacy-locales/metadata.json`
- `.github/workflows/site-localization.yml`
- `.github/workflows/site-legal-localization.yml`
- `.github/workflows/site-release-sync.yml`
