import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:fluttersdk_dusk/dusk.dart'
    show
        framePerfReader,
        perfExtrasReader,
        perfSessionBeginHook,
        perfSessionEndHook;
import 'package:fluttersdk_telescope/telescope.dart';
import 'package:magic/magic.dart';

/// Assembles the whole performance-diagnostic data path: magic's controller and
/// route activity, wind's aggregate counters, telescope's frame buffer, and the
/// four pointers `fluttersdk_dusk` reads them all through.
///
/// Host integration (debug-only, and BEFORE `Magic.init()`; see [install]):
/// ```dart
/// if (kDebugMode) MagicDevtools.installPre();
/// ```
///
/// This package is the only place in the ecosystem where dusk, telescope, wind
/// and magic are all visible at once, which is why the pointer assignment can
/// only live here: dusk's frozen dependency contract forbids it from importing
/// any of the three packages whose data it reports.
///
/// The failure mode this class exists to prevent is silent. Every pointer has a
/// structurally-complete no-op default, so an unassigned one produces a report
/// of zeros rather than an error, in a different repository, at the end of a
/// driven run that looked like it worked.
///
/// `fluttersdk_wind` is reached through magic's barrel, which re-exports it
/// wholesale (`magic/lib/magic.dart:4`); importing it directly here would be
/// flagged as an unnecessary import.
/// dusk's own no-op defaults, captured the first time [MagicPerfIntegration]
/// is about to overwrite them.
///
/// Captured rather than re-typed here, so a change to dusk's declared shape
/// reaches the reset instead of leaving this package and its tests agreeing
/// with each other about a contract that had moved.
///
/// NOT top-level `final`s, which is the version this replaces and which did
/// not work: a top-level `final` in Dart initialises on first READ, and the
/// only reader is `resetForTesting()`, which runs after `install()` has
/// already assigned over the pointers. It captured this package's own closures
/// and restored them, so every "back to the default" assertion was really
/// asserting that install had happened. Verified with a standalone repro
/// before replacing it.
Map<String, Object?> Function()? _duskFramePerfDefault;
Map<String, Object?> Function()? _duskPerfExtrasDefault;
void Function()? _duskSessionBeginDefault;
void Function()? _duskSessionEndDefault;

class MagicPerfIntegration {
  MagicPerfIntegration._();

  /// How many route transitions are retained. A long session navigates far
  /// more than a report can rank, and the recent ones are the ones near the
  /// interaction the operator just drove.
  static const int _maxRouteTransitions = 200;

  /// Idempotent install. Safe to call multiple times within the same isolate
  /// lifetime.
  ///
  /// MUST run before the router is built, i.e. from
  /// `MagicDevtools.installPre()` ahead of `Magic.init()`:
  /// [MagicRouter.addObserver] throws a [StateError] once `routerConfig` has
  /// been read (`magic/lib/src/routing/magic_router.dart:158`). That throw is
  /// deliberately not caught. A swallowed one would leave the report with no
  /// route transitions and nothing to explain their absence.
  static void install() {
    if (_installed) return;

    // 1. Registered once and tracked separately, because the guard below is
    //    armed at the END rather than here. Arming it early would make a retry
    //    after a throw in steps 2 to 4 a silent no-op, which is the failure
    //    this class exists to prevent; arming it late without this flag would
    //    register a second observer on that retry.
    if (!_observerRegistered) {
      MagicRouter.instance.addObserver(_observer);
      _observerRegistered = true;
    }

    // 2. magic: one hook on the single notifyListeners() call site in
    //    MagicController, counted per controller runtime type so the report can
    //    name which controller is rebuilding the screen.
    MagicController.onRefreshUI = _recordNotify;

    // 3. wind and telescope: the two producers. Installing wind's resolver
    //    costs nothing on its own; counting stays off until a session's begin
    //    hook enables it.
    Wind.installPerfResolver();
    final FramePerfWatcher watcher = FramePerfWatcher();
    TelescopePlugin.registerWatcher(watcher);
    _watcher = watcher;

    // 4. The four dusk pointers. Each returns exactly the key set pinned in
    //    `dusk/lib/src/utils/perf_readers.dart`; the consumer is in another
    //    repository, so a renamed key is invisible until a driven run.
    //
    //    dusk's own defaults are captured HERE, immediately before they are
    //    overwritten, because that is the last moment they are still readable.
    _duskFramePerfDefault ??= framePerfReader;
    _duskPerfExtrasDefault ??= perfExtrasReader;
    _duskSessionBeginDefault ??= perfSessionBeginHook;
    _duskSessionEndDefault ??= perfSessionEndHook;
    framePerfReader = () => <String, Object?>{
      'frames': TelescopeStore.recentFramePerf()
          .map<Map<String, Object?>>((FramePerfRecord r) => r.toJson())
          .toList(),
      'livenessCounter': FramePerfWatcher.livenessCounter,
    };
    perfExtrasReader = () => <String, Object?>{
      'controllerNotifies': controllerNotifyCounts,
      'routeTransitions': routeTransitions,
    };
    perfSessionBeginHook = () {
      WindPerfCounters.reset();
      WindPerfCounters.enabled = true;
      // clearFramePerf(), never clear(): the latter wipes the HTTP, log and
      // exception buffers a developer may be reading alongside the session,
      // and resetForTesting() is @visibleForTesting and would fail analysis.
      TelescopeStore.clearFramePerf();
      // The magic-side counters are session-scoped for the same reason wind's
      // are: without this, every session reports the sum of all previous ones.
      _controllerNotifies.clear();
      _routeTransitions.clear();
    };
    perfSessionEndHook = () {
      // Counting off, totals intact: `perf_end` reads them to build its
      // report, and `WindParser.parse` is too hot to leave instrumented.
      WindPerfCounters.enabled = false;
    };

    // 5. Last, so a throw anywhere above leaves the door open for a retry.
    _installed = true;
  }

  /// Whether [install] has been called at least once.
  @visibleForTesting
  static bool get isInstalled => _installed;

  /// How many times each controller type has called `refreshUI()` since the
  /// last session began, keyed by `runtimeType.toString()`.
  static Map<String, int> get controllerNotifyCounts =>
      Map<String, int>.of(_controllerNotifies);

  /// Route pushes observed since the last session began, oldest first. Each
  /// entry carries `route` (the page name magic stamps on its routes, which is
  /// the route name or else its path), `durationMicros` (push to the first
  /// post-frame callback after the new route built) and `time`.
  static List<Map<String, Object?>> get routeTransitions =>
      _routeTransitions.toList();

  /// Test-only reset. Drops the idempotency guard, clears the magic-side
  /// counters, uninstalls the frame watcher, and restores all four dusk
  /// pointers to their no-op defaults so a later test asserting the
  /// missing-integration behaviour does not see a leaked binding.
  ///
  /// Also forces wind's counting off: a test that ran the begin hook would
  /// otherwise leave `WindParser.parse` instrumented for every later test.
  ///
  /// Does NOT unregister the observer (a fresh `MagicRouter.reset()` drops it
  /// with the router instance) and cannot unregister the watcher from
  /// [TelescopePlugin], whose list is private; uninstalling the watcher is
  /// what stops it recording.
  @visibleForTesting
  static void resetForTesting() {
    _installed = false;
    _observerRegistered = false;
    _controllerNotifies.clear();
    _routeTransitions.clear();
    MagicController.onRefreshUI = null;
    _watcher?.uninstall();
    _watcher = null;
    WindPerfCounters.enabled = false;
    // Restored from the values dusk itself declared, captured once at load,
    // rather than hand-written here. Re-typing them would let this package and
    // its tests agree on a key set that had drifted from dusk's, and the
    // assertions would keep passing while production drifted with them.
    // Null only when install() never ran, in which case the pointers are
    // already at dusk's defaults and there is nothing to put back.
    if (_duskFramePerfDefault != null) {
      framePerfReader = _duskFramePerfDefault!;
      perfExtrasReader = _duskPerfExtrasDefault!;
      perfSessionBeginHook = _duskSessionBeginDefault!;
      perfSessionEndHook = _duskSessionEndDefault!;
    }
  }

  static void _recordNotify(MagicController controller) {
    _controllerNotifies.update(
      controller.runtimeType.toString(),
      (int count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  static void _recordRouteTransition(String route, int durationMicros) {
    _routeTransitions.addLast(<String, Object?>{
      'route': route,
      'durationMicros': durationMicros,
      'time': DateTime.now().toIso8601String(),
    });
    while (_routeTransitions.length > _maxRouteTransitions) {
      _routeTransitions.removeFirst();
    }
  }

  static bool _installed = false;
  static bool _observerRegistered = false;
  static FramePerfWatcher? _watcher;
  static final _RouteTransitionObserver _observer = _RouteTransitionObserver();
  static final Map<String, int> _controllerNotifies = <String, int>{};
  static final Queue<Map<String, Object?>> _routeTransitions =
      Queue<Map<String, Object?>>();
}

/// Times a route push from the moment the navigator reports it to the first
/// post-frame callback after it, which is the first point the new route has
/// actually built and laid out.
///
/// Only pushes are timed. A pop tears a route down rather than building one, so
/// it has no equivalent span, and go_router replaces the whole page stack on a
/// `go()`, which the navigator reports as a push of the incoming route.
class _RouteTransitionObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);

    // An anonymous push is a dialog or a bottom sheet, not a page transition.
    // showDialog and showModalBottomSheet both go through the navigator, so in
    // a dialog-heavy session they would share the bounded list with the real
    // transitions and evict the very entries the report is ranking. Skipped
    // rather than bucketed: a duration nobody can attribute to a screen is not
    // one an agent can act on.
    final String? name = route.settings.name;
    if (name == null) return;

    final Stopwatch watch = Stopwatch()..start();

    // One-shot by design, one per push: unlike a per-frame drain there is
    // nothing to re-register, because the span closes on the next frame.
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      watch.stop();
      MagicPerfIntegration._recordRouteTransition(
        name,
        watch.elapsedMicroseconds,
      );
    });
  }
}
