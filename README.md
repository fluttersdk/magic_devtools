<h1 align="center">magic_devtools</h1>

<p align="center">
  <strong>Magic adapters for the FlutterSDK dev-tooling ecosystem.</strong><br/>
  Wire Magic's runtime into <a href="https://pub.dev/packages/fluttersdk_dusk">fluttersdk_dusk</a> (E2E driver) and <a href="https://pub.dev/packages/fluttersdk_telescope">fluttersdk_telescope</a> (runtime inspector) — debug-only, zero release cost.
</p>

<p align="center">
  <a href="https://pub.dev/packages/magic_devtools"><img src="https://img.shields.io/pub/v/magic_devtools.svg" alt="pub package"></a>
  <a href="https://github.com/fluttersdk/magic_devtools/actions"><img src="https://img.shields.io/github/actions/workflow/status/fluttersdk/magic_devtools/ci.yml?branch=master&label=CI" alt="CI"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://pub.dev/packages/magic_devtools/score"><img src="https://img.shields.io/pub/points/magic_devtools" alt="pub points"></a>
  <a href="https://github.com/fluttersdk/magic_devtools/stargazers"><img src="https://img.shields.io/github/stars/fluttersdk/magic_devtools?style=flat" alt="GitHub stars"></a>
</p>

<p align="center">
  <a href="https://magic.fluttersdk.com">Documentation</a> ·
  <a href="https://pub.dev/packages/magic_devtools">pub.dev</a> ·
  <a href="https://github.com/fluttersdk/magic_devtools/issues">Issues</a>
</p>

---

> **Alpha Release** — part of the Magic ecosystem, under active development. APIs may change before stable. [Star the repo](https://github.com/fluttersdk/magic_devtools) to follow progress.

## What is magic_devtools?

`magic_devtools` is the Magic adapter layer for [`fluttersdk_dusk`](https://pub.dev/packages/fluttersdk_dusk) and [`fluttersdk_telescope`](https://pub.dev/packages/fluttersdk_telescope). It enriches dusk snapshots and telescope records with Magic-aware context (forms, navigation, controllers, gates, auth, broadcasting, HTTP) so an LLM agent or CI driver sees your app the way Magic sees it.

It is **debug-only**: you install and wire it under `kDebugMode`, so release builds tree-shake it entirely and it carries no runtime cost in production. This is exactly why it lives outside `magic` core — the framework keeps no dev-tooling production dependencies.

Three import barrels:

- `package:magic_devtools/dusk.dart` — `MagicDuskIntegration` registers 14 Magic-aware enrichers into fluttersdk_dusk's snapshot pipeline.
- `package:magic_devtools/telescope.dart` — `MagicTelescopeIntegration` registers 5 Magic watchers and `MagicHttpFacadeAdapter` into fluttersdk_telescope.
- `package:magic_devtools/preview.dart` — `MagicPreview` hosts a dev-only component preview catalog behind a `/preview` ShellRoute, tree-shaken from release builds.

## Install

`magic_devtools` and the tooling packages are imported in `lib/main.dart` (under `kDebugMode`), so they are regular `dependencies`, not `dev_dependencies` — `kDebugMode` tree-shakes them out of release builds, and because `lib/` imports them a `dev_dependencies` entry would trip the `depend_on_referenced_packages` lint. This matches how `fluttersdk_dusk` and `fluttersdk_telescope` are installed on their own.

```yaml
dependencies:
  magic_devtools: ^0.0.1
  fluttersdk_dusk: ^0.0.8        # add if you use dusk
  fluttersdk_telescope: ^0.0.4   # add if you use telescope
```

`magic_devtools` depends on `magic`, `fluttersdk_dusk`, and `fluttersdk_telescope` directly, so transitive resolution does not happen through `magic` itself.

## Wiring

Both integrations are debug-only and run in `lib/main.dart`. The ordering is load-bearing: the dusk/telescope plugin installs **before** `Magic.init()` (so the snapshot pipeline is live during Magic boot and the exception watcher catches boot errors), and the Magic integration installs **after** `Magic.init()` (its enrichers and adapter resolve Magic primitives through the IoC container).

### Dusk

```dart
if (kDebugMode) {
  DuskPlugin.install();
}
await Magic.init(configFactories: [...]);
if (kDebugMode) {
  MagicDuskIntegration.install();
}
```

### Telescope

```dart
if (kDebugMode) {
  TelescopePlugin.install();
}
await Magic.init(configFactories: [...]);
if (kDebugMode) {
  MagicTelescopeIntegration.install();
}
```

You can wire either integration on its own, or both together: install each plugin before `Magic.init()` and each Magic integration after it. The `dusk:install` and `telescope:install` Artisan commands wire these blocks into `lib/main.dart` automatically when `magic_devtools` is a dependency.

### Preview catalog

`MagicPreview` hosts a dev-only component preview catalog: a sidebar of registered components next to each preview rendered in BOTH light and dark, with a global theme toggle bound to wind's `WindThemeController`. It is reachable only through `MagicPreview.registerRoutes()`, guarded by `kReleaseMode` plus `const bool.fromEnvironment('PREVIEW_ENABLED', defaultValue: kDebugMode)`, so the route, the catalog, and every registered `PreviewEntry` const-fold dead and tree-shake out of release builds.

The router-lock timing is load-bearing: `MagicRouter` locks its route table on the first `routerConfig` access, so registration MUST happen in a provider `boot()` (which runs during the Magic bootstrap lifecycle, before `MaterialApp` reads `routerConfig`). Register too late and `/preview` silently never appears.

```dart
class RouteServiceProvider extends ServiceProvider {
  RouteServiceProvider(super.app);

  @override
  Future<void> boot() async {
    registerAppRoutes();
    if (kDebugMode) {
      MagicPreview.register(previewEntries()); // from the generated _previews.g.dart
      MagicPreview.registerRoutes();
    }
  }
}
```

The `previews:refresh` Artisan command scans `*.preview.dart` files and regenerates `previewEntries()` returning a `List<PreviewEntry>` from a function (never a top-level const, the dart-lang/sdk#33920 retention foot-gun).

## Ecosystem

| Package | |
|---------|--|
| [magic](https://pub.dev/packages/magic) | The Laravel experience for Flutter |
| [fluttersdk_dusk](https://pub.dev/packages/fluttersdk_dusk) | E2E driver for LLM agents and CI |
| [fluttersdk_telescope](https://pub.dev/packages/fluttersdk_telescope) | Passive runtime inspector |

## Contributing

```bash
git clone https://github.com/fluttersdk/magic_devtools.git
cd magic_devtools && flutter pub get
flutter test && dart analyze
```

Local development resolves the `magic`, `fluttersdk_dusk`, and `fluttersdk_telescope` siblings through a gitignored `pubspec_overrides.yaml` (path entries to the sibling clones). Create one alongside `pubspec.yaml`:

```yaml
# pubspec_overrides.yaml (gitignored; local path wiring only)
dependency_overrides:
  magic:
    path: ../magic
  fluttersdk_dusk:
    path: ../dusk
  fluttersdk_telescope:
    path: ../telescope
```

[Report a bug](https://github.com/fluttersdk/magic_devtools/issues/new)

## License

MIT — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Built with care by <a href="https://github.com/fluttersdk">FlutterSDK</a></sub><br/>
  <sub>If magic_devtools helps you, <a href="https://github.com/fluttersdk/magic_devtools">give it a star</a> — it helps others discover it.</sub>
</p>
