/// magic_devtools umbrella barrel.
///
/// Exposes [MagicDevtools], the one-call `installPre` / `installPost` wiring
/// for fluttersdk_dusk and fluttersdk_telescope plus their Magic
/// integrations, installed around [Magic.init] under `kDebugMode`.
///
/// See the finer-grained `dusk.dart`, `telescope.dart`, and `preview.dart`
/// barrels when you need direct access to a single integration, a
/// non-standard watcher set, or the preview catalog.
library;

export 'src/magic_devtools.dart';
