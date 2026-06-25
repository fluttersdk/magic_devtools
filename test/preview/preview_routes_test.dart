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
    test('registers the /preview page and the :component deep link', () {
      // In the test runtime kReleaseMode is false and kPreviewEnabled defaults
      // to kDebugMode (true), so the guarded body runs.
      MagicPreview.register(_entries());
      MagicPreview.registerRoutes();

      final paths = MagicRouter.instance.routes
          .map((RouteDefinition r) => r.fullPath)
          .toList();

      // Two plain pages render the catalog directly (no persistent shell): the
      // index and the slug deep link. The :component builder rebuilds on nav so
      // direct navigation to /preview/<slug> selects the right entry.
      expect(paths, contains('/preview'));
      expect(paths, contains('/preview/:component'));

      // Regression guard for the boot crash: go_router asserts a route path may
      // not end with '/' (except the root). A '/preview/' here blanks the whole
      // app at router-config build time.
      expect(
        paths.where((String p) => p != '/' && p.endsWith('/')),
        isEmpty,
        reason: 'no registered route path may end with "/"',
      );
    });

    test('registers before the router locks (no StateError)', () {
      MagicPreview.register(_entries());

      // Registration must succeed because we have not accessed routerConfig
      // yet; doing so would lock the route table and make addLayout throw.
      expect(MagicPreview.registerRoutes, returnsNormally);
    });
  });
}
