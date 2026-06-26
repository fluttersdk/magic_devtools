import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fluttersdk_wind/fluttersdk_wind.dart';

/// A single entry in the [MagicPreviewCatalog].
///
/// Each entry pairs a human [label] and a URL-safe [slug] with a [builder]
/// that renders the component (or component matrix) in isolation. The
/// generated `_previews.g.dart` (auto-discovered from `*.preview.dart` files)
/// returns a `List<PreviewEntry>` from a FUNCTION and feeds it to
/// [MagicPreview.register]; nothing here is ever a top-level const list, so the
/// release-mode tree-shaker can prove the whole catalog unreachable when the
/// dev-only boundary in [MagicPreview.registerRoutes] folds dead.
@immutable
final class PreviewEntry {
  /// Creates a preview entry.
  const PreviewEntry({
    required this.label,
    required this.slug,
    required this.builder,
  });

  /// The display name shown in the catalog sidebar (e.g. `Button`).
  final String label;

  /// The URL-safe identifier used as the `:component` route segment
  /// (e.g. `button`). Must be unique across the registered set; the
  /// `previews:refresh` codegen (Step 18) collision-checks slugs at build time.
  final String slug;

  /// Builds the preview body for this entry.
  final WidgetBuilder builder;
}

/// **The dev-only component preview catalog.**
///
/// Modeled on the `idea-design` reference catalog: a single, vertically
/// scrolling page that stacks EVERY registered [PreviewEntry] as its own
/// labeled section (heading + bordered card), with a left sidebar that acts as
/// jump-to-section navigation rather than a one-at-a-time selector. Tapping a
/// sidebar item scrolls its section into view; deep-linking `/preview/<slug>`
/// scrolls to that section on mount. The header carries a "Toggle theme" button
/// so the consumer flips light/dark for the whole catalog from one place.
///
/// ### Release boundary
///
/// This widget is only ever instantiated from within
/// [MagicPreview.registerRoutes], which is guarded by `kReleaseMode` +
/// `bool.fromEnvironment('PREVIEW_ENABLED')`. It must never be referenced from
/// a top-level const/final collection (the dart-lang/sdk#33920 foot-gun that
/// retains widget refs in release); keep every reference inside a function
/// body.
class MagicPreviewCatalog extends StatefulWidget {
  /// Creates the catalog over [entries].
  ///
  /// [activeSlug] selects which section to scroll to on mount; when null (or
  /// unmatched) the page opens at the top.
  const MagicPreviewCatalog({
    super.key,
    required this.entries,
    this.activeSlug,
    this.onSelect,
  });

  /// The previews to host. Passed in (never read from a top-level const) so the
  /// release boundary can stay airtight.
  final List<PreviewEntry> entries;

  /// The slug of the section to scroll into view on mount; null opens at the
  /// top.
  final String? activeSlug;

  /// Invoked when a sidebar item is tapped. The `/preview` route wires this to
  /// navigation (deep-link sync); the section is also scrolled into view
  /// locally regardless.
  final ValueChanged<PreviewEntry>? onSelect;

  @override
  State<MagicPreviewCatalog> createState() => _MagicPreviewCatalogState();
}

class _MagicPreviewCatalogState extends State<MagicPreviewCatalog> {
  final ScrollController _scrollController = ScrollController();

  /// One key per entry slug, attached to that section so a sidebar tap (or a
  /// deep-link on mount) can scroll the section into view via
  /// [Scrollable.ensureVisible].
  late Map<String, GlobalKey> _sectionKeys;

  /// The slug highlighted in the sidebar (the last selected / deep-linked one).
  String? _activeSlug;

  /// Pending retry of the scroll-into-view (see [_scrollToSlug]); cancelled on
  /// dispose so no timer outlives the widget (flutter_test flags stragglers).
  Timer? _scrollRetryTimer;

  @override
  void initState() {
    super.initState();
    _rebuildKeys();
    _activeSlug = widget.activeSlug;
    _scheduleScrollTo(widget.activeSlug);
  }

  @override
  void didUpdateWidget(MagicPreviewCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entries != oldWidget.entries) {
      _rebuildKeys();
    }
    if (widget.activeSlug != oldWidget.activeSlug) {
      _activeSlug = widget.activeSlug;
      _scheduleScrollTo(widget.activeSlug);
    }
  }

  @override
  void dispose() {
    _scrollRetryTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _rebuildKeys() {
    _sectionKeys = {
      for (final PreviewEntry entry in widget.entries)
        entry.slug: GlobalKey(
          debugLabel: 'magic-preview-section-${entry.slug}',
        ),
    };
  }

  /// Scroll the [slug] section into view after the next frame (so the section's
  /// key has a mounted context to resolve against).
  void _scheduleScrollTo(String? slug) {
    if (slug == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSlug(slug));
  }

  void _scrollToSlug(String slug) {
    _ensureVisible(slug);
    // Controller-backed screen sections defer-mount and settle their heights
    // over a few frames, which can leave the first scroll short. Re-run once
    // the layout has settled so the section lands at the top precisely.
    _scrollRetryTimer?.cancel();
    _scrollRetryTimer = Timer(
      const Duration(milliseconds: 450),
      () => _ensureVisible(slug),
    );
  }

  void _ensureVisible(String slug) {
    if (!mounted) return;
    final BuildContext? sectionContext = _sectionKeys[slug]?.currentContext;
    if (sectionContext == null) return;
    Scrollable.ensureVisible(
      sectionContext,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.0,
    );
  }

  void _select(PreviewEntry entry) {
    setState(() => _activeSlug = entry.slug);
    _scrollToSlug(entry.slug);
    widget.onSelect?.call(entry);
  }

  @override
  Widget build(BuildContext context) {
    return WDiv(
      className: 'flex flex-row w-full h-full bg-surface',
      children: [
        _buildSidebar(),
        WDiv(
          className: 'flex flex-col flex-1 h-full',
          children: [
            _buildHeader(context),
            // The whole catalog scrolls vertically; every section is stacked
            // here and reachable via the sidebar jump links.
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                child: WDiv(
                  className: 'flex flex-col gap-12 p-6',
                  children: [
                    if (widget.entries.isEmpty)
                      const WText(
                        'Register a preview to see it here.',
                        className: 'text-fg-muted text-sm',
                      )
                    else
                      for (final PreviewEntry entry in widget.entries)
                        _buildSection(entry),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// The left navigation rail: a jump link per registered preview. The list
  /// scrolls independently (it can hold many more entries than fit the
  /// viewport height) under a fixed header.
  Widget _buildSidebar() {
    return WDiv(
      className:
          'flex flex-col w-56 h-full '
          'bg-surface-container border-r border-color-border',
      children: [
        const WText(
          'Previews',
          className: 'text-fg-muted text-xs font-semibold uppercase px-6 py-4',
        ),
        Expanded(
          child: SingleChildScrollView(
            child: WDiv(
              className: 'flex flex-col px-3 pb-3 gap-1',
              children: [
                for (final PreviewEntry entry in widget.entries)
                  WAnchor(
                    key: ValueKey('magic-preview-nav-${entry.slug}'),
                    onTap: () => _select(entry),
                    child: WDiv(
                      className: entry.slug == _activeSlug
                          ? 'px-3 py-2 rounded-md bg-primary-container'
                          : 'px-3 py-2 rounded-md hover:bg-surface-container-high',
                      child: WText(
                        entry.label,
                        className: entry.slug == _activeSlug
                            ? 'text-sm text-fg'
                            : 'text-sm text-fg-muted',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The toolbar with the title and the wind theme toggle.
  Widget _buildHeader(BuildContext context) {
    return WDiv(
      className:
          'flex flex-row items-center justify-between '
          'px-6 py-4 border-b border-color-border bg-surface',
      children: [
        const WText('Components', className: 'text-fg text-lg font-semibold'),
        WAnchor(
          key: const ValueKey('magic-preview-theme-toggle'),
          // Flip dark/light for the whole catalog via wind's theme controller.
          onTap: () => WindTheme.of(context).toggleTheme(),
          child: WDiv(
            className:
                'px-3 py-2 rounded-md bg-surface-container '
                'border border-color-border',
            child: const WText(
              'Toggle theme',
              className: 'text-sm text-fg-muted',
            ),
          ),
        ),
      ],
    );
  }

  /// A single labeled section: heading + underline + a bordered card hosting
  /// the entry's preview body. Keyed so the sidebar can scroll to it.
  Widget _buildSection(PreviewEntry entry) {
    return WDiv(
      key: _sectionKeys[entry.slug],
      className: 'flex flex-col gap-4',
      children: [
        WText(
          entry.label,
          className:
              'text-fg text-lg font-semibold border-b border-color-border pb-2',
        ),
        WDiv(
          className: 'p-6 rounded-lg border border-color-border bg-surface',
          child: Builder(builder: (paneContext) => entry.builder(paneContext)),
        ),
      ],
    );
  }
}
