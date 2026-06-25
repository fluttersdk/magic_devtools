/// Magic dev-only component preview catalog barrel.
///
/// Import this file to host the auto-discovered component previews behind a
/// `/preview` ShellRoute. The whole surface is dev-only: it is reachable only
/// through [MagicPreview.registerRoutes], which is guarded by `kReleaseMode` +
/// `bool.fromEnvironment('PREVIEW_ENABLED')` and tree-shaken from release
/// builds.
///
/// Wiring (in the consumer's `RouteServiceProvider.boot()`, which runs BEFORE
/// `MagicRouter.instance.routerConfig` is first accessed — the router locks its
/// route table on that first access):
///
/// ```dart
/// @override
/// Future<void> boot() async {
///   registerAppRoutes();
///   if (kDebugMode) {
///     MagicPreview.register(previewEntries()); // from _previews.g.dart
///     MagicPreview.registerRoutes();
///   }
/// }
/// ```
///
/// See `src/preview/magic_preview.dart` for the [PreviewEntry] contract and the
/// [MagicPreviewCatalog] widget, and `src/preview/preview_routes.dart` for the
/// [MagicPreview] registration entrypoint and the release boundary.
library;

export 'src/preview/magic_preview.dart';
export 'src/preview/preview_routes.dart';
