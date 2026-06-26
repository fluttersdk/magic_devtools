import 'package:flutter/foundation.dart';
import 'package:magic/magic.dart';

import 'magic_preview.dart';

/// Compile-time switch for the preview catalog.
///
/// Defaults to [kDebugMode]: ON in debug builds, OFF in profile and release
/// (`kDebugMode` is false in both). A profile build can opt in with
/// `--dart-define=PREVIEW_ENABLED=true`; a debug build can force it off with
/// `--dart-define=PREVIEW_ENABLED=false`. Release is always blocked by the
/// `kReleaseMode` guard in [MagicPreview.registerRoutes] regardless. Because
/// this is a `const`, the release-mode optimizer can fold the guarded branch in
/// [MagicPreview.registerRoutes] dead and tree-shake the entire catalog,
/// every [PreviewEntry], and every builder it transitively references.
/// release-mode optimizer can fold the guarded branch in
/// [MagicPreview.registerRoutes] dead and tree-shake the entire catalog,
/// every [PreviewEntry], and every builder it transitively references.
const bool kPreviewEnabled = bool.fromEnvironment(
  'PREVIEW_ENABLED',
  defaultValue: kDebugMode,
);

/// **The dev-only preview registration entrypoint.**
///
/// The generated `_previews.g.dart` (Step 18) returns a `List<PreviewEntry>`
/// from a FUNCTION and feeds it here:
///
/// ```dart
/// // lib/_previews.g.dart (generated)
/// List<PreviewEntry> previewEntries() => <PreviewEntry>[ ... ];
///
/// // RouteServiceProvider.boot()
/// MagicPreview.register(previewEntries());
/// MagicPreview.registerRoutes();
/// ```
///
/// Entries are held in a function-scoped static list (never a top-level const
/// holding widget refs — the dart-lang/sdk#33920 foot-gun), assigned only from
/// [register], so the release-mode tree-shaker can prove them unreachable once
/// [registerRoutes] folds dead behind [kReleaseMode] + [kPreviewEnabled].
final class MagicPreview {
  MagicPreview._();

  /// The registered previews. Populated by [register]; empty until then.
  static List<PreviewEntry> _entries = const <PreviewEntry>[];

  /// The currently registered previews (read-only view).
  static List<PreviewEntry> get entries => List.unmodifiable(_entries);

  /// Register the catalog [entries].
  ///
  /// Call this BEFORE [registerRoutes], typically from the consumer's
  /// `RouteServiceProvider.boot()`. In release builds the guard in
  /// [registerRoutes] short-circuits, so even if entries are registered they
  /// are never wired into a route and stay tree-shakeable.
  static void register(List<PreviewEntry> entries) {
    // Defensively snapshot into an unmodifiable list so later mutation of the
    // caller's list cannot change the registered catalog after the fact.
    _entries = List.unmodifiable(entries);
  }

  /// Register the `/preview` catalog page and its `/preview/:component` deep
  /// link.
  ///
  /// ## Router-lock timing (load-bearing)
  ///
  /// [MagicRouter] locks its route table the first time `routerConfig` is
  /// accessed (`MagicRouter.routerConfig` builds the GoRouter and sets
  /// `_isBuilt`, after which `addRoute` throws `StateError`). The consumer MUST
  /// therefore call [registerRoutes] inside a provider `boot()` — which runs
  /// during the Magic bootstrap lifecycle, BEFORE `MaterialApp` reads
  /// `MagicRouter.instance.routerConfig` — otherwise the routes register too
  /// late and `/preview` silently never appears.
  ///
  /// ## Release boundary
  ///
  /// The body is gated by `kReleaseMode` (early return) and [kPreviewEnabled]
  /// (a `const bool.fromEnvironment`). Both fold to a dead branch in release,
  /// so the route, the [MagicPreviewCatalog], and every registered
  /// [PreviewEntry] are proven unreachable and tree-shaken from the bundle.
  static void registerRoutes() {
    // 1. Hard release boundary: nothing below this line survives a release
    //    build (const-folded dead by the optimizer).
    if (kReleaseMode) return;
    if (!kPreviewEnabled) return;

    // 2. Snapshot the entries inside this function body (never a top-level
    //    const list — sdk#33920) so the catalog widget receives them by value.
    final List<PreviewEntry> entries = _entries;

    // 3. Two plain pages render the catalog DIRECTLY (no persistent shell): the
    //    index shows the first entry; `/preview/:component` selects an entry by
    //    its slug. The `:component` builder RECEIVES the slug and rebuilds on
    //    every navigation, so deep-linking (`/preview/<slug>`) and sidebar
    //    selection both resolve the right entry. A persistent ShellRoute would
    //    NOT rebuild when only the child route swapped, leaving the catalog
    //    stuck on the first entry.
    MagicRoute.page(
      '/preview',
      () => MagicPreviewCatalog(
        entries: entries,
        onSelect: (entry) => MagicRoute.to('/preview/${entry.slug}'),
      ),
    ).name('magic-preview.index');

    MagicRoute.page(
      '/preview/:component',
      (String component) => MagicPreviewCatalog(
        entries: entries,
        activeSlug: component,
        onSelect: (entry) => MagicRoute.to('/preview/${entry.slug}'),
      ),
    ).name('magic-preview.component');
  }

  /// Test-only reset of the registered entries.
  @visibleForTesting
  static void resetForTesting() {
    _entries = const <PreviewEntry>[];
  }
}
