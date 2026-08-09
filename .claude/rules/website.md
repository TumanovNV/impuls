---
paths:
  - "docs/**"
---

# The Impuls website

`docs/index.html` is one self-contained file served by GitHub Pages. No build step,
no external stylesheet, no external script. Keep it that way: the page has to render
from a single request even when nothing else is reachable.

## Never hardcode a release

Version, DMG link and SHA-256 are read from the GitHub Releases API at runtime by the
code around `const RELEASE_API`. The version written in the markup is a fallback for
when the API is unreachable, not the source of truth. Cutting a new release therefore
requires **no** change to the site.

Three literal strings must survive every edit, because both workflows grep for them:

```
const RELEASE_API = 'https://api.github.com/repos/TumanovNV/impuls/releases/latest';
function releaseHash(asset,body)
data-conversion="feedback"
```

## The CSS pitfall that already cost a broken headline

The hero headline paints its gradient through the letters:

```css
h1 .grad{background:linear-gradient(…);-webkit-background-clip:text;background-clip:text;color:transparent}
```

Any later rule that overrides the fill with the **`background` shorthand** silently
resets `background-clip` to `border-box`. The gradient then fills the element's box,
the letters stay transparent, and the headline disappears behind a coloured
rectangle. That is exactly what happened in the light-mode block.

**In theme overrides, always use `background-image`**, never `background`:

```css
@media(prefers-color-scheme:light){
  h1 .grad{background-image:linear-gradient(…)}   /* correct */
}
```

The same trap applies to any future element that clips a background to text.

## Checking both appearances

The page has no theme switch — it follows `prefers-color-scheme`. To review light
mode without changing system settings, collect the rules from the light media query
and re-inject them unconditionally, then confirm
`getComputedStyle(el).webkitBackgroundClip` is still `text` on `h1 .grad`.

Check the dark and light rendering of anything you touch. The light block is a small
set of overrides at the end of the stylesheet, so a change to a base rule may leave
its light counterpart stale.

## Release notes and audits

- `docs/releases/<version>.md` — Russian section, a `---` separator, then a short
  English summary. CI refuses to release when the file for `Scripts/version` is missing.
- `docs/audits/` — security notes per version. Additive; do not rewrite past audits.
- `docs/site-privacy.html`, `robots.txt`, `sitemap.xml`, `manifest.webmanifest` —
  update the sitemap when a page is added.
