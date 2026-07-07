import 'package:flutter_test/flutter_test.dart';
import 'package:fluttersdk_dusk/dusk.dart';
import 'package:fluttersdk_telescope/telescope.dart';
import 'package:magic/magic.dart';
import 'package:magic_devtools/dusk.dart';
import 'package:magic_devtools/magic_devtools.dart';
import 'package:magic_devtools/telescope.dart';

/// Tests for the [MagicDevtools] umbrella wiring.
///
/// [installPre] and [installPost] delegate to the underlying plugin +
/// integration installs (each covered in depth by dusk_integration_test /
/// telescope_integration_test). These tests assert only that the umbrella
/// groups them into the correct pre/post halves and that the composed calls
/// stay idempotent.
void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() {
    MagicApp.reset();
    Magic.flush();
    MagicRouter.reset();
    MagicDuskIntegration.resetForTesting();
    MagicTelescopeIntegration.resetForTesting();
    TelescopeStore.resetForTesting();
  });

  tearDown(() {
    MagicDuskIntegration.resetForTesting();
    MagicTelescopeIntegration.resetForTesting();
  });

  group('MagicDevtools.installPre', () {
    test('boots both tool plugins', () {
      MagicDevtools.installPre();

      expect(DuskPlugin.installCount, greaterThan(0));
      expect(TelescopePlugin.installCount, greaterThan(0));
    });
  });

  group('MagicDevtools.installPost', () {
    test('installs both Magic integrations', () {
      expect(DuskPlugin.enrichers, isEmpty);

      MagicDevtools.installPost();

      expect(MagicDuskIntegration.isInstalled, isTrue);
      expect(MagicTelescopeIntegration.isInstalled, isTrue);
      // MagicDuskIntegration registers its full 14-enricher chain.
      expect(DuskPlugin.enrichers, hasLength(14));
    });

    test('is idempotent on a second call', () {
      MagicDevtools.installPost();
      MagicDevtools.installPost();

      expect(DuskPlugin.enrichers, hasLength(14));
    });
  });
}
