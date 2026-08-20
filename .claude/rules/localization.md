---
paths:
  - "Resources/**"
---

# String tables

Keys are the English text itself. A string that was never translated therefore shows
up in English rather than as an identifier — that is the whole reason for the scheme,
so do not switch to symbolic keys.

Every `localized("…")` call in `Sources` must have an entry in **both**
`Resources/en.lproj/Localizable.strings` and `Resources/ru.lproj/Localizable.strings`.
`Scripts/check-localization.py` extracts the calls and diffs them against each table;
a missing key fails the build. Run it locally with `python3 Scripts/check-localization.py`.

It also requires the tables to carry the **same** set of keys. A key present in one
language and absent in the other used to pass whenever it had also fallen out of the
code, which is how a reworded string leaves one translation behind.

## Keys that are not literals

A key does not have to be written at the call site: `AppFeature` stores `titleKey` and
`detailKey` and resolves them later. A literal-only scan cannot see those, and in 1.4.11
two reworded catalogue keys shipped with no table entry at all — Russian users read them
in English while CI stayed green.

So the checker refuses to guess. A `localized(...)` whose argument is not a literal must
be covered by an entry in `DECLARED_EXTRACTORS`, naming the file and the pattern that
produces its keys; otherwise the build fails and says which file to declare. Prefer
passing a literal. If indirection is genuinely right, declare it in the same change —
do not widen an existing extractor to cover an unrelated file.

## Adding a string

1. Call `localized("Plain English text")` in the code.
2. Add the same text as a key to both tables. In `en.lproj` the value repeats the key.
3. Group it under the existing comment headers (`/* Вкладки */`, `/* Impuls Actions */`
   and so on) rather than appending to the end.

## Format specifiers

Order and count must match across languages: `"in %d h %d min"` needs both numbers in
both tables. The Russian values use deliberate abbreviations — `через %d мин` fits the
panel header, and an abbreviation avoids the declension a full word would require.

Countdown phrases are stored lower-case; the capital comes from the call site through
`sentenceCased`, so the same phrase can later sit mid-sentence.

## Date formats as keys

`"yyyy-MM-dd 'at' HH.mm.ss"` is itself a key, which lets a language reorder the parts.
Keep it a valid `DateFormatter` pattern after translating.

## Entitlements

`Resources/Impuls.entitlements` and `Resources/Impuls.AdHoc.entitlements` must both
keep `com.apple.security.personal-information.calendars` and
`com.apple.security.automation.apple-events`. CI greps for them, and the built app is
verified against the signed entitlements.
