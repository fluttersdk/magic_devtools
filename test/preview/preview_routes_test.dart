import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic/magic.dart';
import 'package:magic_devtools/preview.dart';

/// Tests for [MagicPreview]'s registration entrypoint and the `/preview`
/// ShellRoute it wires into [MagicRouter].
///
/// The release boundary itself (the `kReleaseMode` early return + tree-shaking)
/// is asserted by Step 19 (a release-bundle symbol grep); these tests cover the
/// debug-mode behavior: entries round-trip, and `registerRoutes` adds exactly
/// one `magic-preview` layout BEFORE the router locks.

List<PreviewEntry> _entries() {
  return <PreviewEntry>[
    PreviewEntry(
      label: 'Alpha',
      slug: 'alpha',
      builder: (context) => const SizedBox.shrink(),
    ),
    PreviewEntry(
      label: 'Beta',
      slug: 'beta',
      builder: (context) => const SizedBox.shrink(),
    ),
  ];
}

void main() {
  setUp(() {
    MagicRouter.reset();
    MagicPreview.resetForTesting();
  });

  tearDown(() {
    MagicRouter.reset();
    MagicPreview.resetForTesting();
  });

  group('MagicPreview.register', () {
    test('round-trips the registered entries', () {
      final entries = _entries();
      MagicPreview.register(entries);

      expect(MagicPreview.entries, hasLength(2));
      expect(MagicPreview.entries.map((e) => e.slug), ['alpha', 'beta']);
    });

    test('exposes an unmodifiable view of the entries', () {
      MagicPreview.register(_entries());

      expect(
        () => MagicPreview.entries.add(
          PreviewEntry(
            label: 'X',
            slug: 'x',
            builder: (context) => const SizedBox.shrink(),
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('MagicPreview.registerRoutes', () {
    test('registers a single magic-preview layout in debug builds', () {
      // In the test runtime kReleaseMode is false and kPreviewEnabled defaults
      // to kDebugMode (true), so the guarded body runs.
      MagicPreview.register(_entries());
      MagicPreview.registerRoutes();

      final layouts = MagicRouter.instance.mergedLayouts;
      final previewLayouts = layouts
          .where((l) => l.id == 'magic-preview')
          .toList();

      expect(previewLayouts, hasLength(1));
      // The shell wraps an index page plus one `:component` child page.
      expect(previewLayouts.single.children, hasLength(2));
    });

    test('registers before the router locks (no StateError)', () {
      MagicPreview.register(_entries());

      // Registration must succeed because we have not accessed routerConfig
      // yet; doing so would lock the route table and make addLayout throw.
      expect(MagicPreview.registerRoutes, returnsNormally);
    });
  });
}
