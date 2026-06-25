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
/// Renders a sidebar of [PreviewEntry] labels next to the active preview,
/// shown simultaneously in BOTH light and dark so dark/light parity (the
/// catalog's stated purpose) is verifiable at a glance. Each pane wraps the
/// entry's body in its own nested [WindTheme] with a fixed [Brightness], so
/// both brightnesses render no matter which way the global toggle points.
///
/// The header carries a theme toggle bound to wind's [WindThemeController] via
/// `WindTheme.of(context).toggleTheme()`; it flips the brightness of the host
/// app theme (and any descendant that reads the ambient [WindTheme]), which is
/// how a consumer eyeballs how the whole surface reacts to a global toggle.
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

  /// Invoked when a sidebar item is tapped. The `/preview` ShellRoute wires
  /// this to navigation; when null, selection updates local state only.
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
    // 1. Layout: a fixed sidebar next to a scrollable preview surface.
    return WDiv(
      className: 'flex flex-row w-full h-full bg-surface',
      children: [
        _buildSidebar(),
        WDiv(
          className: 'flex flex-col flex-1 h-full',
          children: [
            _buildHeader(context),
            WDiv(className: 'flex-1 p-6', child: _buildPreviewPanes()),
          ],
        ),
      ],
    );
  }

  /// The left navigation rail listing every registered preview.
  Widget _buildSidebar() {
    return WDiv(
      className:
          'flex flex-col w-56 h-full p-3 gap-1 '
          'bg-surface-container border-r border-color-border',
      children: [
        const WText(
          'Previews',
          className: 'text-fg-muted text-xs font-semibold uppercase px-3 py-2',
        ),
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
    );
  }

  /// The toolbar with the title and the wind theme toggle.
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
          // Bind dark/light to wind's theme controller. This flips the ambient
          // brightness for the host app theme; the per-pane previews below
          // pin their own brightness so both always render.
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

  /// Render the active preview twice: once forced light, once forced dark.
  Widget _buildPreviewPanes() {
    final PreviewEntry? active = _active;
    if (active == null) {
      return const WText(
        'Register a preview to see it here.',
        className: 'text-fg-muted text-sm',
      );
    }

    return WDiv(
      className: 'flex flex-row gap-6 items-start',
      children: [
        _buildPane(active, Brightness.light, 'Light'),
        _buildPane(active, Brightness.dark, 'Dark'),
      ],
    );
  }

  /// A single brightness-pinned pane wrapping [entry] in its own [WindTheme].
  Widget _buildPane(PreviewEntry entry, Brightness brightness, String label) {
    return WDiv(
      className: 'flex flex-col flex-1 gap-2',
      children: [
        WText(
          label,
          className: 'text-fg-muted text-xs font-semibold uppercase',
        ),
        WindTheme(
          // A fresh WindThemeData with a fixed brightness so this pane renders
          // in [brightness] regardless of the global toggle state.
          data: WindThemeData(brightness: brightness, syncWithSystem: false),
          child: Builder(
            builder: (paneContext) => WDiv(
              className: 'p-6 rounded-lg border border-color-border bg-surface',
              child: entry.builder(paneContext),
            ),
          ),
        ),
      ],
    );
  }
}
