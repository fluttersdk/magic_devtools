import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluttersdk_wind/fluttersdk_wind.dart';
import 'package:magic_devtools/preview.dart';

/// Tests for the [MagicPreviewCatalog] dev-only component preview framework.
///
/// The catalog is the host surface for auto-discovered [PreviewEntry] widgets.
/// The catalog renders a single pane in the ambient brightness; the header
/// toggle flips light/dark. These tests mount the catalog with two fake
/// entries, prove single-pane rendering, and exercise the theme toggle binding.

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

Widget _mountCatalog(List<PreviewEntry> entries, {String? slug}) {
  return WindTheme(
    data: WindThemeData(brightness: Brightness.light, syncWithSystem: false),
    builder: (context, controller) => MaterialApp(
      theme: controller.toThemeData(),
      home: MagicPreviewCatalog(entries: entries, activeSlug: slug),
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
    testWidgets('renders the active preview once in the ambient brightness', (
      tester,
    ) async {
      await tester.pumpWidget(_mountCatalog(_fakeEntries(), slug: 'alpha'));
      await tester.pump();

      // The catalog shows a SINGLE pane in the ambient brightness (light here);
      // the header toggle flips it. There is no side-by-side dark pane.
      expect(find.text('alpha:light'), findsOneWidget);
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
      expect(find.text('alpha:dark'), findsNothing);
    });

    testWidgets('toggling the wind theme flips the pane brightness', (
      tester,
    ) async {
      await tester.pumpWidget(_mountCatalog(_fakeEntries(), slug: 'beta'));
      await tester.pump();

      // 1. Capture the controller through the catalog subtree.
      final BuildContext context = tester.element(
        find.byType(MagicPreviewCatalog),
      );
      final WindThemeController controller = WindTheme.of(context);
      expect(controller.brightness, Brightness.light);

      // 2. The toggle control drives WindTheme.of(context).toggleTheme().
      await tester.tap(
        find.byKey(const ValueKey('magic-preview-theme-toggle')),
      );
      await tester.pump();

      expect(controller.brightness, Brightness.dark);
      // The single pane re-renders in the toggled (dark) brightness.
      expect(find.text('beta:dark'), findsOneWidget);
      expect(find.text('beta:light'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
