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
/// Renders a scrollable sidebar of [PreviewEntry] labels next to a SINGLE
/// active preview pane: tapping a sidebar item (or deep-linking
/// `/preview/<slug>`) swaps the pane to that entry. Only the selected preview
/// is built, so a large catalog (including heavy controller-backed screen
/// previews) stays responsive instead of mounting every section at once. The
/// header shows the active entry's label plus a "Toggle theme" button bound to
/// wind's [WindThemeController] for a global light/dark flip.
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
  /// [activeSlug] selects which entry is shown; when null (or unmatched) the
  /// first entry is shown.
  const MagicPreviewCatalog({
    super.key,
    required this.entries,
    this.activeSlug,
    this.onSelect,
  });

  /// The previews to host. Passed in (never read from a top-level const) so the
  /// release boundary can stay airtight.
  final List<PreviewEntry> entries;

  /// The slug of the entry to display; null shows the first entry.
  final String? activeSlug;

  /// Invoked when a sidebar item is tapped. The `/preview` route wires this to
  /// navigation; when null, selection updates local state only.
  final ValueChanged<PreviewEntry>? onSelect;

  @override
  State<MagicPreviewCatalog> createState() => _MagicPreviewCatalogState();
}

class _MagicPreviewCatalogState extends State<MagicPreviewCatalog> {
  late String _selectedSlug;

  @override
  void initState() {
    super.initState();
    _selectedSlug = _resolveInitialSlug();
  }

  @override
  void didUpdateWidget(MagicPreviewCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeSlug != oldWidget.activeSlug ||
        widget.entries != oldWidget.entries) {
      _selectedSlug = _resolveInitialSlug();
    }
  }

  /// Pick the active slug: the requested one when it matches an entry,
  /// otherwise the first entry's slug, otherwise the empty string.
  String _resolveInitialSlug() {
    if (widget.entries.isEmpty) return '';
    final String? requested = widget.activeSlug;
    if (requested != null && widget.entries.any((e) => e.slug == requested)) {
      return requested;
    }
    return widget.entries.first.slug;
  }

  PreviewEntry? get _active {
    for (final PreviewEntry entry in widget.entries) {
      if (entry.slug == _selectedSlug) return entry;
    }
    return widget.entries.isEmpty ? null : widget.entries.first;
  }

  void _select(PreviewEntry entry) {
    setState(() => _selectedSlug = entry.slug);
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
            // Only the active preview is mounted; it scrolls vertically so a
            // tall matrix or screen does not overflow the viewport.
            Expanded(
              child: SingleChildScrollView(
                child: WDiv(className: 'p-6', child: _buildActivePane()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// The left navigation rail. The list scrolls independently (it can hold many
  /// more entries than fit the viewport height) under a fixed header.
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
                      className: entry.slug == _selectedSlug
                          ? 'px-3 py-2 rounded-md bg-primary-container'
                          : 'px-3 py-2 rounded-md hover:bg-surface-container-high',
                      child: WText(
                        entry.label,
                        className: entry.slug == _selectedSlug
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

  /// The toolbar with the active entry's title and the wind theme toggle.
  Widget _buildHeader(BuildContext context) {
    final PreviewEntry? active = _active;
    return WDiv(
      className:
          'flex flex-row items-center justify-between '
          'px-6 py-4 border-b border-color-border bg-surface',
      children: [
        WText(
          active?.label ?? 'No previews',
          className: 'text-fg text-lg font-semibold',
        ),
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

  /// Render the active preview in a bordered card under the ambient wind theme.
  Widget _buildActivePane() {
    final PreviewEntry? active = _active;
    if (active == null) {
      return const WText(
        'Register a preview to see it here.',
        className: 'text-fg-muted text-sm',
      );
    }
    return WDiv(
      className: 'p-6 rounded-lg border border-color-border bg-surface',
      child: Builder(builder: (paneContext) => active.builder(paneContext)),
    );
  }
}
