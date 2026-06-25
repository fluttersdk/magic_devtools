import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:magic/magic.dart';

import 'magic_preview.dart';

/// Compile-time switch for the preview catalog.
///
/// Defaults to [kDebugMode]: the catalog is reachable in debug and profile
/// builds, never in release. A host can force it off in any mode with
/// `--dart-define=PREVIEW_ENABLED=false`. Because this is a `const`, the
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
    _entries = entries;
  }

  /// Register the `/preview` ShellRoute and its `:component` children.
  ///
  /// ## Router-lock timing (load-bearing)
  ///
  /// [MagicRouter] locks its route table the first time `routerConfig` is
  /// accessed (`MagicRouter.routerConfig` builds the GoRouter and sets
  /// `_isBuilt`, after which `addRoute`/`addLayout` throw `StateError`). The
  /// consumer MUST therefore call [registerRoutes] inside a provider `boot()`
  /// — which runs during the Magic bootstrap lifecycle, BEFORE `MaterialApp`
  /// reads `MagicRouter.instance.routerConfig` — otherwise the preview shell is
  /// registered too late and `/preview` silently never appears.
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

    // 3. The /preview ShellRoute: one persistent catalog shell wrapping an
    //    index page and one `:component` child page per entry. The shell is the
    //    catalog itself; child routes drive which entry is active via the
    //    `component` path parameter.
    MagicRoute.group(
      prefix: '/preview',
      layoutId: 'magic-preview',
      layout: (child) => _PreviewShell(entries: entries, child: child),
      routes: () {
        // Index: /preview shows the first entry. The child path is EMPTY (not
        // '/') so the composed full path is exactly '/preview'; go_router
        // asserts a route path may not end with '/' (except the root), so a '/'
        // child here ('/preview/') crashes router configuration at boot.
        MagicRoute.page(
          '',
          () => const SizedBox.shrink(),
        ).name('magic-preview.index');

        // /preview/:component shows the matching entry; the shell reads the
        // `component` path parameter to select it.
        MagicRoute.page('/:component', (String component) {
          return const SizedBox.shrink();
        }).name('magic-preview.component');
      },
    );
  }

  /// Test-only reset of the registered entries.
  @visibleForTesting
  static void resetForTesting() {
    _entries = const <PreviewEntry>[];
  }
}

/// The persistent shell for the `/preview` route group.
///
/// The shell IS the catalog: it reads the active `component` path parameter
/// from the router and renders [MagicPreviewCatalog] over the full entry set.
/// The nested child page is intentionally empty — the catalog owns the visual
/// surface; the child only carries the path parameter that selects the entry.
class _PreviewShell extends StatelessWidget {
  const _PreviewShell({required this.entries, required this.child});

  final List<PreviewEntry> entries;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Read the active `:component` slug from the router and let the catalog
    // navigate between entries by pushing `/preview/<slug>`.
    final String? slug = MagicRouter.instance.pathParameters['component'];
    return MagicPreviewCatalog(
      entries: entries,
      activeSlug: slug,
      onSelect: (entry) => MagicRoute.to('/preview/${entry.slug}'),
    );
  }
}
