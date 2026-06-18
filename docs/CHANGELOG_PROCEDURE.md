# Changelog procedure

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com) + Julia
release-note style. Apply this on every release.

## Style rules

- Sections, in this order, omit empty ones: **Added, Changed, Deprecated, Removed, Fixed, Security**.
- Dated header: `## [X.Y.Z] - YYYY-MM-DD` (ISO 8601). Latest first.
- One line per entry, terse, present tense, impersonal. No marketing words ("powerful", "seamless").
- Reference issues/PRs as `[#N]`, with link definitions at file end.
- No intro paragraph, no recap, no "summary sandwich". Entries only.

## Per release

1. Decide version. Julia 0.x: minor bump = breaking slot; patch = non-breaking.
2. Move accumulated changes into a new dated `## [X.Y.Z]` section. Get the date from the release day, not the commit log.
3. Set `version` in `Project.toml` to match.
4. ceresis note: a changelog **fails** `ceresis check` on structure (headers + bullets) and length — that is inherent to the format, not slop. Only fix genuine vocab/voice tells it flags ("no longer", "in order to", etc.); ignore the structure violations.
5. Release notes for the registry comment are a separate artifact — see the General-registry lesson in workspace memory (must contain the keyword "breaking" or "changelog" for a minor bump or AutoMerge bounces).
