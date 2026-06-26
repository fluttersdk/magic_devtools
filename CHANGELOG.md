# Changelog

All notable changes to this package are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `MagicPreview` framework: a dev-only component preview catalog hosted via two
  plain pages (`/preview` and `/preview/:component`). New
  `package:magic_devtools/preview.dart` barrel exports
  the `PreviewEntry` contract (`label`, `slug`, `builder`), the
  `MagicPreviewCatalog` widget (a scrollable sidebar next to a SINGLE active
  preview pane — tapping a sidebar item, or deep-linking `/preview/<slug>`,
  swaps the pane to that entry; only the selected preview is mounted, so a
  large screen-heavy catalog stays responsive — plus a global light/dark toggle
  bound to wind's `WindTheme.of(context).toggleTheme()`),
  and the `MagicPreview` registration entrypoint (`register` plus `registerRoutes`).
  The route, catalog, and every registered `PreviewEntry` are reachable only
  through `MagicPreview.registerRoutes`, which is guarded by `kReleaseMode` plus
  `const bool.fromEnvironment('PREVIEW_ENABLED', defaultValue: kDebugMode)`, so
  the whole surface const-folds dead and tree-shakes out of release builds.
  Entries are held in a function-scoped list (never a top-level const, the
  dart-lang/sdk#33920 foot-gun). The generated `_previews.g.dart` (Step 18) feeds
  a `List<PreviewEntry>` into `MagicPreview.register`. Consumers must call
  `MagicPreview.registerRoutes()` from a provider `boot()` BEFORE the router locks
  on first `routerConfig` access, else `/preview` silently never registers.
- `fluttersdk_wind` is now a direct dependency (the catalog renders on
  `WDiv`/`WText`/`WAnchor` and binds the theme toggle to `WindThemeController`).
- `MagicDuskIntegration.install()` now registers a navigate adapter via
  `DuskPlugin.registerNavigateAdapter` so `ext.dusk.navigate --route <path>`
  drives GoRouter through `MagicRouter.instance.to(path)` instead of falling
  back to the `SystemNavigator` platform broadcast. Returns `true` on success
  and `false` when the router is not yet initialised (catches `StateError`).
  `resetForTesting()` clears the adapter with `DuskPlugin.registerNavigateAdapter(null)`.

### Fixed

- **`/preview/<slug>` deep links now select the right entry**: the catalog moved off a persistent ShellRoute (which did not rebuild when only the child route swapped, leaving every deep link stuck on the first entry) to two plain pages; the `/preview/:component` builder receives the slug and rebuilds on navigation. Known dev-only limitation: feature-SCREEN previews (full controller-backed `MagicStatefulView`s) emit a couple of non-fatal `setState() during build` warnings because the catalog mounts the same screen in both the light and dark panes sharing a singleton controller; the screens render correctly and the real app routes are clean (the catalog is stripped from release).
- **`/preview` route no longer crashes the app**: the catalog group's index child path was `/` which composed to `/preview/`, tripping go_router's `route path may not end with '/'` assertion and blanking the entire app on every route. Changed the index child path to `''` so the composed path is exactly `/preview`.
- **Catalog previews now inherit the host theme**: each light/dark pane copied a bare `WindThemeData` that carried no aliases, so component semantic tokens (`text-fg`, `bg-surface`, ...) resolved to no-ops and every preview rendered Flutter's red unstyled-text fallback. Panes now `copyWith(brightness:)` the ambient app theme, preserving aliases and brand colors.
- **Catalog overflow**: the preview surface now scrolls vertically and each pane scrolls horizontally, so wide variant matrices no longer trigger RenderFlex overflows in the side-by-side light/dark layout.

## [0.0.1] - 2026-06-17

### Added

- Initial release, extracted from the `magic` package. `MagicDuskIntegration`
  (14 enrichers for `fluttersdk_dusk` snapshots) and `MagicTelescopeIntegration`
  (5 watchers plus `MagicHttpFacadeAdapter` for `fluttersdk_telescope`) now live
  here as a dedicated, debug-only dev-tooling adapter rather than as sub-barrels
  of `magic`.
- Two import barrels: `package:magic_devtools/dusk.dart` and
  `package:magic_devtools/telescope.dart`.
- The relocated enricher and watcher test suites moved over unchanged.

### Note

- Local development resolves the `magic`, `fluttersdk_dusk`, and
  `fluttersdk_telescope` siblings through `dependency_overrides` path entries.
  Those overrides are dev-only; version pins replace them at publish (the
  publish-time pubspec is user-owned).
