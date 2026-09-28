import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show FlutterTimeline;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:fluttersdk_dusk/dusk.dart'
    show
        PerfInteraction,
        PerfMode,
        activeInteraction,
        framePerfReader,
        perfExtrasReader,
        perfInsightContributors,
        perfSessionBeginHook,
        perfSessionEndHook,
        perfTimelineReader;
import 'package:fluttersdk_telescope/telescope.dart';
import 'package:magic/magic.dart';

import 'perf_insight_rules.dart';

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
void Function(PerfMode mode)? _duskSessionBeginDefault;
void Function()? _duskSessionEndDefault;
List<Map<String, Object?>> Function()? _duskTimelineDefault;

/// Assembles the whole performance-diagnostic data path: magic's runtime
/// activity through `MagicPerfHooks`, wind's aggregate counters, telescope's
/// frame and record buffers, the wind and magic insight rules, and the dusk
/// pointers that read them all.
///
/// Host integration (the consumer gates with `!kReleaseMode`, so debug and
/// profile both carry it and release tree-shakes it; BEFORE `Magic.init()`,
/// see [install]):
/// ```dart
/// if (!kReleaseMode) MagicDevtools.installPre();
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
  ///
  /// `MagicPerfHooks.sink` is NOT assigned here: the session's begin hook
  /// installs it for an attribution session only and the end hook removes it,
  /// so an app between sessions, and a timing session, pay magic's single
  /// null check per site and allocate no event.
  static void install() {
    if (_installed) return;

    // 1. Registered once and tracked separately, because the guard below is
    //    armed at the END rather than here. Arming it early would make a retry
    //    after a throw in steps 2 to 3 a silent no-op, which is the failure
    //    this class exists to prevent; arming it late without this flag would
    //    register a second observer on that retry.
    if (!_observerRegistered) {
      MagicRouter.instance.addObserver(_observer);
      _observerRegistered = true;
    }

    // 2. wind and telescope: the two producers. Installing wind's resolver
    //    costs nothing on its own; counting stays off until a session's begin
    //    hook enables it.
    Wind.installPerfResolver();
    final FramePerfWatcher watcher = FramePerfWatcher();
    TelescopePlugin.registerWatcher(watcher);
    _watcher = watcher;

    // 3. The dusk pointers. Each returns exactly the key set pinned in
    //    `dusk/lib/src/utils/perf_readers.dart`; the consumer is in another
    //    repository, so a renamed key is invisible until a driven run.
    //
    //    dusk's own defaults are captured HERE, immediately before they are
    //    overwritten, because that is the last moment they are still readable.
    _duskFramePerfDefault ??= framePerfReader;
    _duskPerfExtrasDefault ??= perfExtrasReader;
    _duskSessionBeginDefault ??= perfSessionBeginHook;
    _duskSessionEndDefault ??= perfSessionEndHook;
    _duskTimelineDefault ??= perfTimelineReader;
    framePerfReader = () => <String, Object?>{
      'frames': TelescopeStore.recentFramePerf()
          .map<Map<String, Object?>>((FramePerfRecord r) => r.toJson())
          .toList(),
      'livenessCounter': FramePerfWatcher.livenessCounter,
    };
    perfExtrasReader = () => _session.extras(routeTransitions);
    perfTimelineReader = _timelineRows;
    perfSessionBeginHook = (PerfMode mode) {
      final bool attribution = mode == PerfMode.attribution;
      WindPerfCounters.reset();
      // Timing mode must not pay for counters: wind's sit on WindParser.parse
      // and magic's allocate an event per notify, both inside the very
      // durations a timing session exists to report.
      WindPerfCounters.enabled = attribution;
      MagicPerfHooks.sink = attribution ? _session.record : null;
      // clearFramePerf(), never clear(): the latter wipes the HTTP, log and
      // exception buffers a developer may be reading alongside the session,
      // and resetForTesting() is @visibleForTesting and would fail analysis.
      TelescopeStore.clearFramePerf();
      // The magic-side counters are session-scoped for the same reason wind's
      // are: without this, every session reports the sum of all previous ones.
      _session.open(FlutterTimeline.now);
      _routeTransitions.clear();
    };
    perfSessionEndHook = () {
      // Counting off, totals intact: `perf_end` reads them to build its
      // report, and `WindParser.parse` is too hot to leave instrumented.
      WindPerfCounters.enabled = false;
      MagicPerfHooks.sink = null;
    };
    if (!perfInsightContributors.contains(_contributeInsights)) {
      perfInsightContributors.add(_contributeInsights);
    }

    // 4. Last, so a throw anywhere above leaves the door open for a retry.
    _installed = true;
  }

  /// Whether [install] has been called at least once.
  @visibleForTesting
  static bool get isInstalled => _installed;

  /// Which interaction the calling code belongs to, and how that was
  /// established, in dusk's order:
  ///
  /// 1. `zone`: an open interaction read off `Zone.current`, for work a
  ///    gesture started (its callbacks, and the timers, microtasks and
  ///    streams they created).
  /// 2. `frame`: dusk's active interaction, for work in the binding's frame
  ///    zone that no zone reaches (a build, an `initState` refetch).
  /// 3. `window`: no interaction; the work belongs to the session window only.
  ///
  /// Every telescope record and every sink row this package writes is stamped
  /// with it, so one rule decides all of them.
  static ({String? interactionId, String linkedBy}) interactionLink() {
    final String? zoned = zoneInteractionId(
      Zone.current[PerfInteraction.zoneKey],
    );
    if (zoned != null) return (interactionId: zoned, linkedBy: 'zone');

    final String? active = activeInteractionId();
    if (active != null) return (interactionId: active, linkedBy: 'frame');

    return (interactionId: null, linkedBy: 'window');
  }

  /// The id of an OPEN interaction held as a zone value, or null.
  ///
  /// A closed handle is absent: timers and stream subscriptions created in
  /// the zone keep the handle forever, and without the check every later
  /// message on a socket opened during a tap would be attributed to that tap.
  ///
  /// Replaceable only because dusk's `PerfInteraction` has a private
  /// constructor: a host test cannot open a real one without driving a perf
  /// session over the VM Service, so it substitutes what counts as a handle.
  @visibleForTesting
  static String? Function(Object? zoneValue) zoneInteractionId =
      _duskZoneInteractionId;

  /// The id of dusk's active interaction, or null. Replaceable for the reason
  /// given on [zoneInteractionId].
  @visibleForTesting
  static String? Function() activeInteractionId = _duskActiveInteractionId;

  /// How many times each controller type has called `refreshUI()` since the
  /// last attribution session began, keyed by `runtimeType.toString()`.
  static Map<String, int> get controllerNotifyCounts =>
      Map<String, int>.of(_session.controllerNotifies);

  /// Route pushes observed since the last session began, oldest first. Each
  /// entry carries `route` (the page name magic stamps on its routes, which is
  /// the route name or else its path), `durationMicros` (push to the first
  /// post-frame callback after the new route built) and `time`.
  static List<Map<String, Object?>> get routeTransitions =>
      _routeTransitions.toList();

  /// Test-only reset. Drops the idempotency guard, clears the session state,
  /// removes the sink and this package's insight contributor, uninstalls the
  /// frame watcher, restores the interaction sources, and restores every dusk
  /// pointer to its no-op default so a later test asserting the
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
    _session.open(null);
    _routeTransitions.clear();
    MagicPerfHooks.sink = null;
    perfInsightContributors.remove(_contributeInsights);
    zoneInteractionId = _duskZoneInteractionId;
    activeInteractionId = _duskActiveInteractionId;
    _watcher?.uninstall();
    _watcher = null;
    WindPerfCounters.enabled = false;
    // Restored from the values dusk itself declared rather than hand-written
    // here. Re-typing them would let this package and its tests agree on a key
    // set that had drifted from dusk's, and the assertions would keep passing
    // while production drifted with them. See the fields at the top of this
    // file for why they are captured on the first install and not at load.
    //
    // Null only when install() never ran, in which case the pointers are
    // already at dusk's defaults and there is nothing to put back.
    if (_duskFramePerfDefault != null) {
      framePerfReader = _duskFramePerfDefault!;
      perfExtrasReader = _duskPerfExtrasDefault!;
      perfSessionBeginHook = _duskSessionBeginDefault!;
      perfSessionEndHook = _duskSessionEndDefault!;
      perfTimelineReader = _duskTimelineDefault!;
    }
  }

  static String? _duskZoneInteractionId(Object? zoneValue) =>
      zoneValue is PerfInteraction && zoneValue.isOpen ? zoneValue.id : null;

  static String? _duskActiveInteractionId() => activeInteraction()?.id;

  /// The contributor dusk's insight engine calls with the report built so
  /// far. Reads the uncut session state the report only carries the head of.
  static List<Map<String, Object?>> _contributeInsights(
    Map<String, Object?> report,
  ) => PerfInsightRules.evaluate(
    report,
    PerfRuleInputs(
      extras: _session.extras(routeTransitions),
      wind: const WindPerfResolverImpl().stats(),
      notifiesByCause: _session.notifiesByCause,
      uncachedReloads: _session.uncachedReloads,
      httpByInteraction: _httpByInteraction(),
    ),
  );

  /// `METHOD path` of every request an interaction sent since the session
  /// opened, per interaction id. Requests linked to no interaction are left
  /// out: "per interaction" means nothing for them.
  static Map<String, List<String>> _httpByInteraction() {
    final int since = _session.startUs ?? 0;
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final HttpRequestRecord r in TelescopeStore.recentHttp()) {
      final String? id = r.interactionId;
      if (id == null || (r.startUs ?? r.atUs) < since) continue;
      out.putIfAbsent(id, () => <String>[]).add('${r.method} ${_path(r.url)}');
    }
    return out;
  }

  /// perfTimelineReader rows: the sink rows this package aggregated, then one
  /// row per telescope record that has a time. dusk keeps the ones inside the
  /// session window, so the whole buffer is returned.
  static List<Map<String, Object?>> _timelineRows() => <Map<String, Object?>>[
    ..._session.rows,
    for (final HttpRequestRecord r in TelescopeStore.recentHttp())
      _row(
        kind: 'span',
        track: 'http',
        name: '${r.method} ${_path(r.url)}',
        startUs: r.startUs ?? r.atUs - r.durationMs * 1000,
        endUs: r.endUs ?? r.atUs,
        // An id makes it an async pair: requests overlap on their track.
        id: r.requestId == null ? null : 'http-${r.requestId}',
        interactionId: r.interactionId,
        linkedBy: r.linkedBy,
        args: <String, Object?>{
          'url': r.url,
          'statusCode': r.statusCode,
          'durationMs': r.durationMs,
        },
      ),
    for (final QueryRecord r in TelescopeStore.recentQueries())
      _row(
        kind: 'span',
        track: 'db',
        name: _clip(r.sql),
        startUs: r.atUs - r.timeMs * 1000,
        endUs: r.atUs,
        interactionId: r.interactionId,
        linkedBy: r.linkedBy,
        args: <String, Object?>{'sql': r.sql, 'timeMs': r.timeMs},
      ),
    for (final EventRecord r in TelescopeStore.recentEvents())
      _row(
        kind: 'instant',
        track: 'events',
        name: r.eventType,
        startUs: r.atUs,
        interactionId: r.interactionId,
        linkedBy: r.linkedBy,
      ),
    for (final MagicModelRecord r in TelescopeStore.recentModels())
      _row(
        kind: 'instant',
        track: 'models',
        name: '${r.modelClass} ${r.event}',
        startUs: r.atUs,
        interactionId: r.interactionId,
        linkedBy: r.linkedBy,
        args: <String, Object?>{'key': r.modelKey},
      ),
    for (final MagicCacheRecord r in TelescopeStore.recentCaches())
      _row(
        kind: 'instant',
        track: 'cache',
        name: '${r.operation} ${r.key}',
        startUs: r.atUs,
        interactionId: r.interactionId,
        linkedBy: r.linkedBy,
      ),
  ];

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
  static final _MagicPerfSession _session = _MagicPerfSession();
  static final Queue<Map<String, Object?>> _routeTransitions =
      Queue<Map<String, Object?>>();
}

/// One perfTimelineReader row, in the schema dusk documents on that pointer.
Map<String, Object?> _row({
  required String kind,
  required String track,
  required String name,
  required int startUs,
  int? endUs,
  String? id,
  String? interactionId,
  String? linkedBy,
  Map<String, Object?>? args,
}) => <String, Object?>{
  'kind': kind,
  'track': track,
  'name': name,
  'startUs': startUs,
  'endUs': ?endUs,
  'id': ?id,
  'interactionId': ?interactionId,
  'linkedBy': ?linkedBy,
  'args': ?args,
};

String _path(String url) {
  final Uri? uri = Uri.tryParse(url);
  return uri == null || uri.path.isEmpty ? url : uri.path;
}

/// A SQL string short enough to read as a slice name; the whole of it stays
/// in the row's args.
String _clip(String sql) =>
    sql.length <= 60 ? sql : '${sql.substring(0, 60)}...';

/// Everything `MagicPerfHooks.sink` delivered during one attribution session,
/// aggregated the way the report, the trace and the rules read it.
class _MagicPerfSession {
  /// Sink rows kept for the trace. A session drives a handful of
  /// interactions; this is minutes of notifies, not a memory concern.
  static const int _maxRows = 2000;

  /// `FlutterTimeline.now` when the session opened, null before any has.
  int? startUs;

  final Map<String, int> controllerNotifies = <String, int>{};
  final Map<String, int> notifyCauses = <String, int>{};
  final Map<String, int> queryReloads = <String, int>{};
  final Map<String, int> actions = <String, int>{};
  final Map<String, int> events = <String, int>{};
  final Map<String, int> casts = <String, int>{};
  final Map<String, int> timerTicks = <String, int>{};
  final Map<String, int> broadcasts = <String, int>{};

  /// Cause name to controller type to notifies.
  final Map<String, Map<String, int>> notifiesByCause =
      <String, Map<String, int>>{};

  /// Interaction id to model type to reloads that issued their own request.
  final Map<String, Map<String, int>> uncachedReloads =
      <String, Map<String, int>>{};

  final Queue<Map<String, Object?>> rows = Queue<Map<String, Object?>>();

  /// Row ids are never reused, so two sessions' spans cannot pair up in a
  /// trace that happens to hold both.
  int _rowSequence = 0;

  void open(int? atUs) {
    startUs = atUs;
    for (final Map<String, Object?> counts in <Map<String, Object?>>[
      controllerNotifies,
      notifyCauses,
      queryReloads,
      actions,
      events,
      casts,
      timerTicks,
      broadcasts,
      notifiesByCause,
      uncachedReloads,
    ]) {
      counts.clear();
    }
    rows.clear();
  }

  /// The perfExtrasReader payload: exactly dusk's documented key set.
  Map<String, Object?> extras(List<Map<String, Object?>> routeTransitions) =>
      <String, Object?>{
        'controllerNotifies': Map<String, int>.of(controllerNotifies),
        'notifyCauses': Map<String, int>.of(notifyCauses),
        'queryReloads': Map<String, int>.of(queryReloads),
        'actions': Map<String, int>.of(actions),
        'events': Map<String, int>.of(events),
        'casts': Map<String, int>.of(casts),
        'timerTicks': Map<String, int>.of(timerTicks),
        'broadcasts': Map<String, int>.of(broadcasts),
        'routeTransitions': routeTransitions,
      };

  /// The sink. Counts every event and keeps a trace row for each one with a
  /// time on it; casts are counted only, since one runs per attribute read.
  void record(MagicPerfEvent event) {
    // Casts run once per attribute read, far too often to pay for a link
    // lookup that no cast row would carry.
    if (event is AttributeCast) {
      _bump(casts, event.castType);
      return;
    }
    final ({String? interactionId, String linkedBy}) link =
        MagicPerfIntegration.interactionLink();

    switch (event) {
      case ControllerNotified(:final MagicController controller, :final cause):
        final String type = controller.runtimeType.toString();
        _bump(controllerNotifies, type);
        _bump(notifyCauses, cause.name);
        _bump(
          notifiesByCause.putIfAbsent(cause.name, () => <String, int>{}),
          type,
        );
        _addRow(
          'instant',
          'magic.notify',
          type,
          link,
          args: <String, Object?>{'cause': cause.name},
        );
      case RepositoryUpserted(:final Type type, :final int count):
        _addRow(
          'instant',
          'magic.repository',
          '$type',
          link,
          args: <String, Object?>{'count': count},
        );
      case QueryReloaded(
        :final Type type,
        :final int startUs,
        :final int endUs,
        :final bool fromCache,
      ):
        _bump(queryReloads, '$type');
        final String? interaction = link.interactionId;
        if (!fromCache && interaction != null) {
          _bump(
            uncachedReloads.putIfAbsent(interaction, () => <String, int>{}),
            '$type',
          );
        }
        _addRow(
          'span',
          'magic.query',
          '$type',
          link,
          startUs: startUs,
          endUs: endUs,
          args: <String, Object?>{'fromCache': fromCache},
        );
      case ActionRan(
        :final Type type,
        :final int startUs,
        :final int endUs,
        :final ActionOutcome<Object?> outcome,
      ):
        _bump(actions, '$type');
        _addRow(
          'span',
          'magic.action',
          '$type',
          link,
          startUs: startUs,
          endUs: endUs,
          args: <String, Object?>{
            'outcome': outcome.succeeded ? 'succeeded' : 'failed',
          },
        );
      case EventDispatched(
        :final Type type,
        :final int listenerCount,
        :final int startUs,
        :final int endUs,
      ):
        _bump(events, '$type');
        _addRow(
          'span',
          'magic.event',
          '$type',
          link,
          startUs: startUs,
          endUs: endUs,
          args: <String, Object?>{'listeners': listenerCount},
        );
      case AttributeCast():
        // Counted before the link lookup.
        break;
      case TimerTicked(:final Type ownerType):
        _bump(timerTicks, '$ownerType');
        _addRow('instant', 'magic.timer', '$ownerType', link);
      case BroadcastReceived(:final String event):
        _bump(broadcasts, event);
        _addRow('instant', 'magic.broadcast', event, link);
    }
  }

  void _addRow(
    String kind,
    String track,
    String name,
    ({String? interactionId, String linkedBy}) link, {
    int? startUs,
    int? endUs,
    Map<String, Object?>? args,
  }) {
    rows.addLast(
      _row(
        kind: kind,
        track: track,
        name: name,
        startUs: startUs ?? FlutterTimeline.now,
        endUs: endUs,
        // Spans overlap on their track (two queries reloading at once), so
        // each gets an id and becomes an async pair in the trace.
        id: kind == 'span' ? 'magic-${++_rowSequence}' : null,
        interactionId: link.interactionId,
        linkedBy: link.linkedBy,
        args: args,
      ),
    );
    while (rows.length > _maxRows) {
      rows.removeFirst();
    }
  }

  static void _bump(Map<String, int> counts, String key) =>
      counts.update(key, (int n) => n + 1, ifAbsent: () => 1);
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
