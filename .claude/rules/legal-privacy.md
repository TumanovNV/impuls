---
paths:
  - "Scripts/build-site-privacy-locale.py"
  - "Scripts/site-privacy-locales/**"
  - "Scripts/site-privacy-template.html"
  - "Scripts/sync-site-privacy-links.py"
  - "Scripts/sync-site-privacy-legacy.py"
  - "Scripts/site-locales/registry.json"
  - ".github/workflows/site-legal-localization.yml"
  - ".github/workflows/site-release-sync.yml"
  - "knowledge-base/07-web/legal-privacy.md"
  - "docs/**/privacy/**"
  - "docs/site-privacy.html"
---

# Impuls website legal / privacy localization

Read `knowledge-base/07-web/legal-privacy.md` before changing any file in this scope. `PRIVACY.md` is the technical source for application data flows. Do not make a legal page contradict the product privacy model.

## Routes and ownership

- `Scripts/site-locales/registry.json` owns both marketing `path` and legal `privacy_path`.
- `/privacy/` is the Russian source policy.
- `/en/privacy/`, `/de/privacy/`, `/fr/privacy/`, `/es/privacy/`, `/ja/privacy/`, `/zh-hans/privacy/` are generated translations/localized notices.
- `/site-privacy.html` is legacy only: `noindex,follow`, handoff to `/privacy/`.
- Never derive a filesystem/public route from locale code; `zh-Hans` maps to `/zh-hans/privacy/`.

## Generation

- `Scripts/build-site-privacy-locale.py` is the only legal-page generator.
- `Scripts/site-privacy-template.html` owns legal-page presentation.
- `Scripts/site-privacy-locales/<locale>.json` owns legal copy.
- Generated `docs/**/privacy/index.html` files are not edited manually.
- `Scripts/sync-site-privacy-links.py` owns the landing-page privacy CTA route.
- `Scripts/sync-site-sitemap.py` owns indexed landing + privacy routes.
- `.github/workflows/site-legal-localization.yml` is the focused PR gate.

## Truthfulness rules

- Never state that Impuls collects no personal data at all: GitHub Pages documents visitor IP logging for security.
- Optional version statistics are opt-in, pseudonymous, fixed-endpoint, at most once per hour, HMACed before product database storage, and retained for 365 days without heartbeat.
- Do not describe the installation pseudonym as anonymous.
- Do not claim native-speaker legal review for DE/FR/ES/JA/zh-Hans; these translations are AI-assisted + structurally/technically reviewed on the current baseline.
- Do not claim GDPR certification, universal compliance, a DPO, EU representative, or a dedicated private privacy mailbox unless that fact has actually been established.
- Known gap: there is no dedicated private Impuls privacy email currently published. The GitHub initial-contact route must warn that Issues are public and must not contain confidential data.
- Known gap requiring legal assessment: if GDPR Article 3(2) applies to Impuls, Article 27 generally requires an EU representative unless the narrow Article 27(2) exception applies. Do not assume the exception: EDPB guidance says processing is only “occasional” when it is not carried out regularly and is outside the controller's regular activity. The recurring opt-in version-statistics flow means an Article 27 assessment is still required before claiming complete GDPR compliance.

## International wording

The Russian policy is the source document. Translations are provided for understandable notice and must say that mandatory rights under applicable local law are not reduced by the translation.

The GDPR supplement is conditional: “where GDPR applies”. Optional version statistics use consent; voluntarily initiated support requests are described as processing to answer the request and for legitimate product-support/security interests, subject to applicable rights. Do not turn this into an unconditional claim that every GDPR obligation has been satisfied.

Article 13 requires controller contact details and, where applicable, representative contact details. Until a private privacy mailbox and any required EU representative actually exist, do not invent those details in public copy; keep the gap visible in engineering/legal review.

## Required checks

Before merge, require the legal-localization unit tests, generated-page idempotence, seven-way legal hreflang, privacy sitemap routes, legacy noindex handoff, knowledge-base gate and the full application build to be green.
