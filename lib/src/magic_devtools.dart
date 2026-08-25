import 'package:fluttersdk_dusk/dusk.dart';
import 'package:fluttersdk_telescope/telescope.dart';

import 'dusk_integration.dart';
import 'perf_integration.dart';
import 'telescope_integration.dart';

export 'perf_integration.dart';

/// One-call wiring for the Magic dev-tooling bundle: fluttersdk_dusk +
/// fluttersdk_telescope and their Magic integrations, installed in the two
/// phases that straddle [Magic.init].
///
/// The two tools cannot install in a single call because half of the work
/// has to happen BEFORE `Magic.init()` and half AFTER:
///
/// - [installPre] boots both plugins (VM Service extensions, capture hooks,
///   the dusk snapshot pipeline) and registers telescope's opt-in
///   [ExceptionWatcher] + [DumpWatcher]. It MUST run before `Magic.init()`
///   so the snapshot pipeline and ExceptionWatcher are already live while
///   Magic boots (they capture boot-time errors and the first route resolve).
/// - [installPost] wires Magic's runtime into both tools
///   ([MagicTelescopeIntegration] + [MagicDuskIntegration]). It MUST run
///   after `Magic.init()` because the watchers, the HTTP adapter, and the
///   snapshot enrichers resolve dependencies through the IoC container
///   (`Magic.find` / `Magic.bound`).
///
/// Keep both calls inside a `kDebugMode` guard AT THE CALL SITE. Do not move
/// the guard inside these methods: a live (unguarded) call defeats the
/// release tree-shake and pulls dusk + telescope into the production bundle,
/// which is the whole reason this wiring lives outside `magic` core.
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///
///   if (kDebugMode) MagicDevtools.installPre();
///
///   await Magic.init(configFactories: [...]);
///
///   if (kDebugMode) MagicDevtools.installPost();
///
///   runApp(const MyApp());
/// }
/// ```
///
/// This is the umbrella entry point; reach for the finer-grained
/// `dusk.dart`, `telescope.dart`, or `preview.dart` barrels only when you
/// need a non-standard watcher set or want to wire one tool without the
/// other.
class MagicDevtools {
  MagicDevtools._();

  /// Pre-`Magic.init()` half: boot both tool plugins and register the
  /// standard opt-in telescope watchers.
  ///
  /// Installs [DuskPlugin] (Semantics tree, `ext.dusk.*` extensions,
  /// error/log capture) and [TelescopePlugin] (`ext.telescope.*`
  /// extensions, auto [LogWatcher]), then registers [ExceptionWatcher] and
  /// [DumpWatcher]: the two watchers telescope leaves opt-in but every Magic
  /// dev session wants (uncaught exceptions and `debugPrint` dumps).
  ///
  /// Also installs [MagicPerfIntegration], the performance data path. It
  /// belongs in this half rather than [installPost] because it registers a
  /// [NavigatorObserver] through `MagicRouter.addObserver`, which throws once
  /// the router has been built; the rest of its wiring would work from either
  /// half and is kept with it at the one install site.
  ///
  /// Each underlying install is idempotent, so a second call in the same
  /// isolate is safe. Register additional watchers after this call via
  /// [TelescopePlugin.registerWatcher].
  ///
  /// It is NOT safe to call late, though, and that is new: the perf
  /// integration registers a [NavigatorObserver], and `MagicRouter.addObserver`
  /// throws a [StateError] once the router has been built. A host that installs
  /// this behind a lazy debug toggle after `runApp` used to get harmless
  /// no-ops and now crashes. The throw is deliberate, since a silently
  /// unregistered observer would produce a report with no route transitions
  /// and nothing to explain their absence, but it means this belongs at boot
  /// and nowhere else.
  static void installPre() {
    DuskPlugin.install();

    TelescopePlugin.install();
    TelescopePlugin.registerWatcher(ExceptionWatcher());
    TelescopePlugin.registerWatcher(DumpWatcher());

    MagicPerfIntegration.install();
  }

  /// Post-`Magic.init()` half: wire Magic's runtime into both tools.
  ///
  /// Installs [MagicTelescopeIntegration] (5 Magic watchers +
  /// `MagicHttpFacadeAdapter` + the dusk-to-telescope bridge readers) and
  /// [MagicDuskIntegration] (14 Magic-aware snapshot enrichers + the
  /// [MagicRouter] navigate adapter). Both resolve their dependencies
  /// through the IoC container, so [Magic.init] must have completed first.
  ///
  /// Both integrations are idempotent.
  static void installPost() {
    MagicTelescopeIntegration.install();
    MagicDuskIntegration.install();
  }
}
