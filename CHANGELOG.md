# Changelog

All notable changes to this package are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
