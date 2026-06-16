# magic_devtools

The Magic adapter layer for [`fluttersdk_dusk`](https://pub.dev/packages/fluttersdk_dusk)
and [`fluttersdk_telescope`](https://pub.dev/packages/fluttersdk_telescope).

`magic_devtools` is debug-only dev tooling. It wires Magic's runtime
primitives (forms, navigation, controllers, gates, auth, broadcasting, HTTP)
into the two fluttersdk inspection tools so that dusk snapshots and telescope
records are enriched with Magic-aware context. It carries no runtime cost in
release builds because you only install and wire it under `kDebugMode`.

It exposes two import barrels:

- `package:magic_devtools/dusk.dart` exposes `MagicDuskIntegration`, which
  registers 14 Magic-aware enrichers into `fluttersdk_dusk`'s snapshot
  pipeline.
- `package:magic_devtools/telescope.dart` exposes
  `MagicTelescopeIntegration`, which registers 5 Magic watchers and the
  `MagicHttpFacadeAdapter` into `fluttersdk_telescope`.

## Install

Add `magic_devtools` as a `dev_dependency` in an app built on `magic` that
also uses `fluttersdk_dusk` and/or `fluttersdk_telescope`. It is a dev tool,
not a runtime dependency, so it belongs under `dev_dependencies`:

```yaml
dev_dependencies:
  magic_devtools: ^0.0.1
```

`magic_devtools` depends on `magic`, `fluttersdk_dusk`, and
`fluttersdk_telescope` directly, so transitive resolution does not happen
through `magic` itself.

## Wiring

Both integrations are debug-only and run in `lib/main.dart`. The ordering is
load-bearing: the dusk/telescope plugin installs **before** `Magic.init()`
(so the snapshot pipeline is live during Magic boot and the exception watcher
catches boot errors), and the Magic integration installs **after**
`Magic.init()` (because its enrichers and adapter resolve Magic primitives
through the IoC container).

### Dusk

`MagicDuskIntegration` MUST run after `Magic.init()` because its enrichers
query `Magic.find<X>()` for form, navigation, and controller state.
`DuskPlugin` itself installs before `Magic.init()` so the snapshot pipeline is
live during Magic boot:

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

`MagicTelescopeIntegration` MUST run after `Magic.init()` because
`MagicHttpFacadeAdapter` resolves the `NetworkDriver` via the IoC container.
`TelescopePlugin` itself installs before `Magic.init()` so the exception
watcher catches Magic boot errors:

```dart
if (kDebugMode) {
  TelescopePlugin.install();
}
await Magic.init(configFactories: [...]);
if (kDebugMode) {
  MagicTelescopeIntegration.install();
}
```

You can wire either integration on its own, or both together: install each
plugin before `Magic.init()` and each Magic integration after it.

## Development

This repository resolves its `magic`, `fluttersdk_dusk`, and
`fluttersdk_telescope` siblings through `dependency_overrides` path entries
(`../magic`, `../dusk`, `../telescope`) for local multi-repo development.
Those overrides are dev-only: version pins replace them at publish (the
publish-time pubspec is user-owned).
