# CLAUDE.md

Guidance for Claude Code working inside the `magic_devtools` repo. This file is the root spec; the
package is small enough that it has no path-scoped rules under `.claude/rules/` yet.

## What this package is for, and why it is a package at all

`magic_devtools` is the seam between `magic` and the dev tooling. It holds the adapters that wire
`fluttersdk_dusk` and `fluttersdk_telescope` into a running Magic app, plus a dev-only component
preview catalog.

It exists so that `magic` core can keep ZERO dependency on dusk and telescope. Those adapters used to
live in magic; moving them out is what lets a production app depend on magic without dragging an E2E
driver and a runtime inspector into its resolution graph. Every consumer adds this package as a
**dev_dependency**, never a dependency.

That is also why every install call is guarded by `kDebugMode` AT THE CALL SITE, in the consumer's
`main.dart`, and never inside a method here. Moving the guard inward defeats the release tree-shake and
pulls both tools into the production bundle, which is the one failure this package's whole shape is
arranged to prevent.

## Stack

Flutter package. Dart >=3.11.0, Flutter >=3.41.0. Runtime deps: `magic`, `fluttersdk_dusk`,
`fluttersdk_telescope`, `fluttersdk_wind`. No code generation.

It is the only package in the ecosystem that sees magic, dusk, telescope and wind at once. That is a
capability, not an accident: dusk's frozen dependency contract forbids it from importing any of the
packages whose data it reports, so anything that has to join the four can only be assembled here.

`fluttersdk_wind` is reached through magic's barrel, which re-exports it wholesale. Importing it
directly is flagged as an unnecessary import.

## Commands

| Command | When |
|---|---|
| `flutter test --coverage` | Default runner, and the CI gate. |
| `flutter analyze --no-fatal-infos` | CI gate. |
| `dart format --set-exit-if-changed .` | CI gate. Run it before pushing; a branch that never ran the formatter fails here and nowhere earlier. |
| `flutter pub get` | Resolve deps. |
| `dart pub publish --dry-run` | Pre-publish validation. |

Local sibling development goes through the gitignored `pubspec_overrides.yaml`. The committed
`pubspec.yaml` stays on hosted caret constraints so a fork outside this workspace resolves on its own.

## Barrels

Four, and the split is the API:

| Barrel | For |
|---|---|
| `lib/magic_devtools.dart` | `MagicDevtools`, the umbrella `installPre` / `installPost` pair. What a consumer imports unless it needs something narrower. |
| `lib/dusk.dart` | `MagicDuskIntegration` alone: 14 snapshot enrichers plus the `MagicRouter` navigate adapter. |
| `lib/telescope.dart` | `MagicTelescopeIntegration` alone: 5 Magic watchers plus `MagicHttpFacadeAdapter`. |
| `lib/preview.dart` | The dev-only component preview catalog. |

Reach for a narrow barrel only when wiring one tool without the other, or when a host wants a
non-standard watcher set.

## The two-phase install is a contract, not a convenience

`installPre` runs BEFORE `Magic.init()`; `installPost` runs after. Neither half can move.

- **Pre** boots `DuskPlugin` and `TelescopePlugin` and registers telescope's opt-in `ExceptionWatcher`
  and `DumpWatcher`. It has to be early so the snapshot pipeline and the exception watcher are already
  live while Magic boots: they capture boot-time errors and the first route resolve, which is exactly
  the window a later install misses.
- **Post** wires Magic's runtime in. Its watchers, HTTP adapter and enrichers resolve dependencies
  through the IoC container (`Magic.find` / `Magic.bound`), so `Magic.init()` must have completed.

When adding wiring, decide which half it belongs to by asking what it resolves, not by which reads
tidier. Anything that touches the container is post. Anything that has to observe Magic booting, or
that registers with a subsystem which locks its table on first read (the router does), is pre.

Every install here is idempotent, so a second call in the same isolate is safe. Keep it that way: a
consumer with a lazy debug toggle will call twice.

## Enrichers and watchers

An enricher is `String? Function(Element, RefRegistry)`, dusk's frozen typedef. It is synchronous and
stateless, and it must NEVER retain the `Element` across calls. `MagicDuskIntegration.uninstall()`
removes each enricher it added, one by one, so an enricher added to the install list without a matching
removal leaks into the next test.

A watcher implements telescope's `TelescopeWatcher` contract (`name`, `install()`, `uninstall()`).
Dependency direction is one way and stays one way: `magic_devtools` depends on the telescope and dusk
contracts, and neither of those ever depends on magic.

## Preview catalog

`lib/preview.dart` hosts auto-discovered component previews behind `/preview` and `/preview/:component`.
It is reachable only through `MagicPreview.registerRoutes()`, which is guarded by `kReleaseMode` plus
`bool.fromEnvironment('PREVIEW_ENABLED')`, so it is tree-shaken from release builds.

Registration happens in the consumer's `RouteServiceProvider.boot()`, and it has to: `MagicRouter`
locks its route table the first time `routerConfig` is read, and a registration after that point
throws.

## Golden rules

1. `flutter analyze` clean, `dart format` zero diff, `flutter test` green. All three are CI jobs, so
   all three pass locally first.
2. TDD, red then green. A behaviour change gets a failing test that fails for the right reason before
   the implementation.
3. `CHANGELOG.md` gets a bullet under `## [Unreleased]` for every behavioural or interface change.
4. Never add a dependency that would let magic core reach dusk or telescope. The direction is
   `magic_devtools` to the tools, never the reverse.
5. Never move a `kDebugMode` guard inside this package.

## Branching

One long-lived `master`. Task branches (`feat/*`, `fix/*`, `docs/*`, `chore/*`) cut from master, PR
back into master. Release bumps `pubspec.yaml` and promotes `## [Unreleased]`, then a tag triggers
`publish.yml`.

## Style

- English only, in identifiers, comments, docblocks and commits.
- Types everywhere. Docblocks on every public class and contract, saying WHY rather than restating the
  signature.
- Multi-line collections with trailing commas. 120-character lines.
- No em-dash or en-dash anywhere, including commits and PR bodies. Comma, colon, semicolon, period or
  parentheses instead.
- No linter suppressions.
