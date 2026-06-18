# Changelog

Notable changes per release. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow Julia 0.x semver (a minor bump is the breaking slot).

## [0.3.0] - 2026-06-18

### Added
- `OP_UNION_DROP` and `OP_WHERE_RELAX` dispatch operators, gated by a whole-project method map.
- `--blame` maps surviving mutants to the test units that cover but do not kill them; detects `ReTestItems`/`TestItemRunner` units [#5].
- `--parallel` runs mutants across worker processes [#7].
- `--in-diff <ref>` scopes a run to lines changed against a git ref.
- `OP_COMPARISON_CHAIN`, `OP_TERNARY_SWAP`, `OP_BROADCAST_DROP` operators.
- Unified diff per surviving mutant in the report [#4].
- Custom-operator authoring guide [#6].

### Fixed
- Test-only deps in `test/Project.toml` are honoured during instrumentation [#2], [#3].
- Source-collocated test items resolve via the package source directory [#5].
- The parallel path preserves each mutant's `error_msg` [#7].

### Changed
- Internal cleanup and a warm/schema module split; no behaviour change.

## [0.2.0] - 2026-06-16

### Added
- Git-diff run scope, idiom operators, and compile-once mutant schemata.

## [0.1.1] - 2026-06-08

### Fixed
- Crash-safe shadow-copy execution; dogfood hardening.

## [0.1.0] - 2026-06-05

### Added
- AST mutation operators, site discovery, byte-splice patcher, warm-worker pool, fallback taxonomy.

[#2]: https://github.com/SuperSeriousLab/Gremlins.jl/issues/2
[#3]: https://github.com/SuperSeriousLab/Gremlins.jl/issues/3
[#4]: https://github.com/SuperSeriousLab/Gremlins.jl/issues/4
[#5]: https://github.com/SuperSeriousLab/Gremlins.jl/issues/5
[#6]: https://github.com/SuperSeriousLab/Gremlins.jl/issues/6
[#7]: https://github.com/SuperSeriousLab/Gremlins.jl/issues/7
