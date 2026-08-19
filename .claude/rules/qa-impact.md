---
paths:
  - "Sources/**"
  - "Tests/**"
  - "Resources/*.entitlements"
  - "Scripts/bundle.sh"
  - "Scripts/dmg.sh"
  - "Scripts/version"
  - ".github/workflows/release.yml"
---

# Behavioral QA impact traceability

Behavioral code and its verification route through the machine-readable QA impact map.

Before finishing a change in these paths:

1. read `knowledge-base/13-qa/change-impact-traceability.md`;
2. inspect `Scripts/qa-impact-rules.json` for the source/test owner you touched;
3. run `python3 Scripts/check-qa-impact.py --base <base-sha>` against the real PR base;
4. review every reported Behavioral QA ID rather than guessing the affected scenarios from memory.

If a changed tracked production file is reported as `unmapped behavioral source change`, do not add a broad exemption. Either map it to the correct existing QA IDs or add/update the Behavioral QA Matrix when the behavior is genuinely new. A narrow exemption is allowed only when another explicit verification contract owns the area and the reason is documented in `qa-impact-rules.json`.

When `Scripts/version` changes in the same diff, every impacted non-automated QA ID must already be classified in `knowledge-base/13-qa/release-evidence/<version>.md`. The impact checker establishes traceability only; `check-release-qa-evidence.py --release-gate` still owns the shipping decision.

Never turn a green unit test into a manual hardware/TCC `pass`. Tests and release evidence are different evidence classes.
