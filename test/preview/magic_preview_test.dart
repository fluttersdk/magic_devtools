import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluttersdk_wind/fluttersdk_wind.dart';
import 'package:magic_devtools/preview.dart';

/// Tests for the [MagicPreviewCatalog] dev-only component preview framework.
///
/// The catalog hosts auto-discovered [PreviewEntry] widgets. It renders a
/// scrollable sidebar next to a SINGLE active pane: only the selected entry is
/// built (so a large, screen-heavy catalog stays responsive), and the header
/// toggle flips light/dark. These tests mount the catalog with two fake
/// entries, prove single-pane rendering, exercise the theme toggle, and check
/// that a sidebar tap reports + shows the selected entry.

/// A trivial preview body that paints a brightness-derived label so a test can
/// read which [Brightness] the surrounding [WindTheme] resolved to.
class _BrightnessProbe extends StatelessWidget {
  const _BrightnessProbe({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = WindTheme.dataOf(context).brightness;
    final String mode = brightness == Brightness.dark ? 'dark' : 'light';
    return WText('$tag:$mode', className: 'text-fg');
  }
}

List<PreviewEntry> _fakeEntries() {
  return <PreviewEntry>[
    PreviewEntry(
      label: 'Alpha',
      slug: 'alpha',
      builder: (context) => const _BrightnessProbe(tag: 'alpha'),
    ),
    PreviewEntry(
      label: 'Beta',
      slug: 'beta',
      builder: (context) => const _BrightnessProbe(tag: 'beta'),
    ),
  ];
}

Widget _mountCatalog(
  List<PreviewEntry> entries, {
  String? slug,
  ValueChanged<PreviewEntry>? onSelect,
}) {
  return WindTheme(
    data: WindThemeData(brightness: Brightness.light, syncWithSystem: false),
    builder: (context, controller) => MaterialApp(
      theme: controller.toThemeData(),
      home: MagicPreviewCatalog(
        entries: entries,
        activeSlug: slug,
        onSelect: onSelect,
      ),
    ),
  );
}

void main() {
  setUp(WindParser.clearCache);

  group('PreviewEntry', () {
    test('carries label, slug, and builder', () {
      final entry = PreviewEntry(
        label: 'Button',
        slug: 'button',
        builder: (context) => const SizedBox.shrink(),
      );

      expect(entry.label, 'Button');
      expect(entry.slug, 'button');
      expect(entry.builder, isNotNull);
    });
  });

  group('MagicPreviewCatalog', () {
    testWidgets('renders only the active preview in the ambient brightness', (
      tester,
    ) async {
      await tester.pumpWidget(_mountCatalog(_fakeEntries(), slug: 'alpha'));
      await tester.pump();

      // Single pane: only the selected entry's body is mounted (light here).
      expect(find.text('alpha:light'), findsOneWidget);
      expect(find.text('beta:light'), findsNothing);
      expect(find.text('alpha:dark'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists every entry in the sidebar', (tester) async {
      await tester.pumpWidget(_mountCatalog(_fakeEntries()));
      await tester.pump();

      expect(find.text('Alpha'), findsWidgets);
      expect(find.text('Beta'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('defaults to the first entry when no slug is given', (
      tester,
    ) async {
      await tester.pumpWidget(_mountCatalog(_fakeEntries()));
      await tester.pump();

      expect(find.text('alpha:light'), findsOneWidget);
      expect(find.text('beta:light'), findsNothing);
    });

    testWidgets('toggling the wind theme flips the active pane brightness', (
      tester,
    ) async {
      await tester.pumpWidget(_mountCatalog(_fakeEntries(), slug: 'beta'));
      await tester.pump();

      final BuildContext context = tester.element(
        find.byType(MagicPreviewCatalog),
      );
      final WindThemeController controller = WindTheme.of(context);
      expect(controller.brightness, Brightness.light);

      await tester.tap(
        find.byKey(const ValueKey('magic-preview-theme-toggle')),
      );
      await tester.pump();

      expect(controller.brightness, Brightness.dark);
      expect(find.text('beta:dark'), findsOneWidget);
      expect(find.text('beta:light'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a sidebar item selects and shows that entry', (
      tester,
    ) async {
      PreviewEntry? selected;
      await tester.pumpWidget(
        _mountCatalog(_fakeEntries(), onSelect: (entry) => selected = entry),
      );
      await tester.pump();

      // Starts on the first entry.
      expect(find.text('alpha:light'), findsOneWidget);
      expect(find.text('beta:light'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('magic-preview-nav-beta')));
      await tester.pump();

      // Swaps the pane to the tapped entry and reports it.
      expect(selected, isNotNull);
      expect(selected!.slug, 'beta');
      expect(find.text('beta:light'), findsOneWidget);
      expect(find.text('alpha:light'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
