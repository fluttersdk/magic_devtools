import 'dart:ui' show FrameTiming, PlatformDispatcher, TimingsCallback;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluttersdk_dusk/dusk.dart'
    show
        framePerfReader,
        perfExtrasReader,
        perfSessionBeginHook,
        perfSessionEndHook;
import 'package:fluttersdk_telescope/telescope.dart';
import 'package:magic/magic.dart';
import 'package:magic_devtools/magic_devtools.dart';

/// Tests for [MagicPerfIntegration], the single place dusk, telescope, wind and
/// magic meet.
///
/// The failure mode this file exists to prevent is silent: an unassigned reader
/// pointer or an unregistered observer produces a structurally complete report
/// of zeros, with no error, in a different repository. So every test here
/// asserts on the DATA that reaches the pointer, never on `install()` merely
/// returning.

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

class _AlphaController extends MagicController {}

class _BetaController extends MagicController {}

/// Builds a [FrameTiming] from the raw microsecond stamps its public factory
/// takes; that factory's own docstring says it exists for unit tests, and
/// `tester.pump()` delivers no timing of its own.
FrameTiming _timing({required int frameNumber}) {
  const int vsyncStart = 0;
  const int buildStart = 1000;
  const int buildFinish = buildStart + 4000;
  const int rasterFinish = buildFinish + 2000;

  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: buildFinish,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
    frameNumber: frameNumber,
  );
}

/// Fires a timings batch the way the engine would.
///
/// Asserts the dispatcher is armed first: with no timings callback registered
/// `onReportTimings` is null, and a silently-null `?.call` would make every
/// count below vacuous.
void _fireTimings(List<FrameTiming> timings) {
  final TimingsCallback? report = PlatformDispatcher.instance.onReportTimings;
  expect(
    report,
    isNotNull,
    reason:
        'the platform dispatcher must be armed for an injected batch to '
        'reach the frame watcher at all',
  );
  report!(timings);
}

FramePerfRecord _frameRecord(int frameNumber) => FramePerfRecord(
  frameNumber: frameNumber,
  buildMicros: 4000,
  rasterMicros: 2000,
  vsyncOverheadMicros: 1000,
  totalSpanMicros: 7000,
  time: DateTime(2026, 8, 25),
  blocks: const <String, ({int micros, int count})>{},
);

/// Moves wind's counters the way the app does: by building a real W-widget.
///
/// The `record*` entry points are `@internal` to `fluttersdk_wind`, since they
/// exist for its own parse path, so reaching for them here would assert
/// against a surface no consumer is meant to touch. A pump is also the honest
/// version of this setup: it is what actually moves these numbers in an app.
Future<void> _buildOneWidget(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WindTheme(
        data: WindThemeData(),
        child: const WDiv(className: 'p-4'),
      ),
    ),
  );
}

/// Builds the widget once against a COLD parse cache, so the build that
/// follows is guaranteed to be a hit.
///
/// `WindParser._styleCache` is a static map keyed by className plus theme
/// state, so every test in this isolate shares it. Without pinning it, whether
/// a build counts as a hit or a miss depends on which test ran first: these two
/// cases used to pass together and fail when either was run alone, because one
/// warmed the key the other asserted on.
Future<void> _warmTheParseCache(WidgetTester tester) async {
  WindParser.clearCache();
  await _buildOneWidget(tester);
  // Pump something else in between: pumping an identical tree does not rebuild
  // it, so the next _buildOneWidget would parse nothing at all and the hit the
  // caller is waiting for would never happen.
  await tester.pumpWidget(const SizedBox.shrink());
  WindPerfCounters.reset();
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  // `MagicDevtools.installPre()` installs telescope's DumpWatcher, which
  // replaces the global `debugPrint`. Nothing used to put it back, so Flutter's
  // own post-test check ("the value of a foundation debug variable was changed
  // by the test") fired on whichever `testWidgets` case happened to run NEXT.
  // That made the failure land on an innocent test and only under some
  // orderings, which is why it survived a green suite.
  //
  // The restore has to happen INSIDE the test body, which is what
  // [restoreDebugPrint] is for. `_verifyInvariants()` runs immediately after
  // `await testBody()` in `AutomatedTestWidgetsFlutterBinding.runTest`
  // (`flutter_test/lib/src/binding.dart:1974`), so both `tearDown` and
  // `addTearDown` are too late: a `testWidgets` case that installs the watcher
  // fails on ITSELF before either runs. The `tearDown` below is a net for the
  // plain `test()` cases, which have no invariant check.
  late void Function(String?, {int? wrapWidth}) originalDebugPrint;

  /// Puts the global `debugPrint` back, from inside the test body.
  void restoreDebugPrint() => debugPrint = originalDebugPrint;

  setUp(() {
    originalDebugPrint = debugPrint;
    MagicApp.reset();
    Magic.flush();
    MagicRouter.reset();
    MagicPerfIntegration.resetForTesting();
    TelescopeStore.resetForTesting();
  });

  tearDown(() {
    MagicPerfIntegration.resetForTesting();
    MagicRouter.reset();
    TelescopeStore.resetForTesting();
    WindPerfCounters.enabled = false;
    WindPerfCounters.reset();
    debugPrint = originalDebugPrint;
  });

  group('MagicPerfIntegration.install', () {
    test('registers exactly one observer and one watcher when called twice', () {
      MagicPerfIntegration.install();
      MagicPerfIntegration.install();

      expect(MagicPerfIntegration.isInstalled, isTrue);
      expect(MagicRouter.instance.observers, hasLength(1));

      // TelescopePlugin keeps its watcher list private, so the watcher count is
      // asserted through its only observable effect: a second FramePerfWatcher
      // would add a second timings callback and record the same frame twice.
      _fireTimings(<FrameTiming>[_timing(frameNumber: 7)]);
      expect(TelescopeStore.recentFramePerf(), hasLength(1));
    });

    test('attributes notify counts to each controller runtime type', () {
      MagicPerfIntegration.install();

      final _AlphaController alpha = _AlphaController();
      final _BetaController beta = _BetaController();
      alpha.refreshUI();
      alpha.refreshUI();
      beta.refreshUI();

      expect(MagicPerfIntegration.controllerNotifyCounts, <String, int>{
        '_AlphaController': 2,
        '_BetaController': 1,
      });
    });

    testWidgets('surfaces the StateError when the router is already built', (
      WidgetTester tester,
    ) async {
      MagicRoute.page('/', () => const SizedBox());
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: MagicRouter.instance.routerConfig),
      );
      await tester.pumpAndSettle();

      // A swallowed StateError would leave the report with no route
      // transitions and no explanation for why.
      expect(MagicPerfIntegration.install, throwsStateError);
      expect(MagicPerfIntegration.isInstalled, isFalse);
    });
  });

  group('the dusk pointers', () {
    test('framePerfReader returns the recorded frames and the counter', () {
      TelescopeStore.recordFramePerf(_frameRecord(11));
      TelescopeStore.recordFramePerf(_frameRecord(12));

      MagicPerfIntegration.install();

      final Map<String, Object?> payload = framePerfReader();
      expect(
        payload.keys,
        unorderedEquals(<String>['frames', 'livenessCounter']),
      );

      final List<Object?> frames = payload['frames']! as List<Object?>;
      expect(frames, hasLength(2));
      expect(
        frames.cast<Map<String, Object?>>().map(
          (Map<String, Object?> f) => f['frameNumber'],
        ),
        <int>[11, 12],
      );
      expect(payload['livenessCounter'], isA<int>());
    });

    test('perfExtrasReader returns the notify counts', () {
      MagicPerfIntegration.install();
      _AlphaController().refreshUI();

      final Map<String, Object?> payload = perfExtrasReader();
      expect(
        payload.keys,
        unorderedEquals(<String>['controllerNotifies', 'routeTransitions']),
      );
      expect(payload['controllerNotifies'], <String, int>{
        '_AlphaController': 1,
      });
      expect(payload['routeTransitions'], isEmpty);
    });

    testWidgets('perfExtrasReader carries a named, timed route transition', (
      WidgetTester tester,
    ) async {
      MagicRoute.page('/', () => const SizedBox());
      MagicRoute.page('/monitors', () => const SizedBox());

      // Before the router is built, which is the whole reason the observer
      // registration lives in installPre().
      MagicPerfIntegration.install();

      await tester.pumpWidget(
        MaterialApp.router(routerConfig: MagicRouter.instance.routerConfig),
      );
      await tester.pumpAndSettle();

      MagicRouter.instance.to('/monitors');
      await tester.pumpAndSettle();

      final List<Object?> transitions =
          perfExtrasReader()['routeTransitions']! as List<Object?>;
      expect(transitions, isNotEmpty);

      final Map<String, Object?> last =
          transitions.last! as Map<String, Object?>;
      expect(last['route'], '/monitors');
      expect(last['durationMicros'], isA<int>());
      expect(last['durationMicros']! as int, greaterThanOrEqualTo(0));
    });

    testWidgets('perfSessionBeginHook clears only the perf state', (
      WidgetTester tester,
    ) async {
      WindPerfCounters.enabled = true;
      await _warmTheParseCache(tester);
      await _buildOneWidget(tester);
      // A non-zero before the hook runs is the whole point: asserting zero
      // afterwards proves nothing if it was already zero, which is what this
      // case did while it happened to run first.
      expect(WindPerfCounters.cacheHits, greaterThan(0));
      TelescopeStore.recordFramePerf(_frameRecord(3));
      TelescopeStore.recordDump(
        DumpRecord(message: 'sibling buffer', time: DateTime(2026, 8, 25)),
      );

      MagicPerfIntegration.install();
      _AlphaController().refreshUI();
      perfSessionBeginHook();

      expect(WindPerfCounters.cacheHits, 0);
      expect(TelescopeStore.recentFramePerf(), isEmpty);
      expect(MagicPerfIntegration.controllerNotifyCounts, isEmpty);
      // TelescopeStore.clear() would have taken this with it, which is why the
      // hook calls clearFramePerf() instead.
      expect(
        TelescopeStore.recentDumps().map((DumpRecord r) => r.message),
        contains('sibling buffer'),
      );
    });

    testWidgets('the session pair turns wind counting on and back off', (
      WidgetTester tester,
    ) async {
      // Warmed here rather than inherited from whichever test ran before, so
      // the build below is a hit whatever the order or the shuffle seed.
      await _warmTheParseCache(tester);
      MagicPerfIntegration.install();
      expect(WindPerfCounters.enabled, isFalse);

      perfSessionBeginHook();

      // Zeroing without enabling would report a wind section of all zeros
      // beside populated frame and magic sections, with no error to say why.
      expect(WindPerfCounters.enabled, isTrue);
      expect(WindPerfCounters.cacheHits, 0);

      await _buildOneWidget(tester);
      perfSessionEndHook();

      // The end hook stops the counting but leaves the totals alone, because
      // `perf_end` reads them to build its report.
      expect(WindPerfCounters.enabled, isFalse);
      expect(WindPerfCounters.cacheHits, 1);
    });
  });

  group('MagicPerfIntegration.resetForTesting', () {
    test('restores the hook, the counters and all four pointers', () {
      MagicPerfIntegration.install();
      _AlphaController().refreshUI();
      perfSessionBeginHook();
      TelescopeStore.recordFramePerf(_frameRecord(5));

      MagicPerfIntegration.resetForTesting();

      expect(MagicPerfIntegration.isInstalled, isFalse);
      expect(MagicController.onRefreshUI, isNull);
      expect(MagicPerfIntegration.controllerNotifyCounts, isEmpty);
      // A reset that left counting on would tax every later test in the suite.
      expect(WindPerfCounters.enabled, isFalse);
      expect(framePerfReader(), <String, Object?>{
        'frames': <Map<String, Object?>>[],
        'livenessCounter': 0,
      });
      expect(perfExtrasReader(), <String, Object?>{
        'controllerNotifies': <String, int>{},
        'routeTransitions': <Map<String, Object?>>[],
      });

      // The restored hooks are no-ops: the frame buffer survives the begin
      // hook and counting stays off after the end hook.
      perfSessionBeginHook();
      perfSessionEndHook();
      expect(TelescopeStore.recentFramePerf(), hasLength(1));
      expect(WindPerfCounters.enabled, isFalse);
    });
  });

  group('MagicDevtools.installPre', () {
    test('installs the perf integration before the router is built', () {
      MagicDevtools.installPre();
      // A net, not the mechanism. The restore that matters is the inline call
      // at the end of this body, for the reason on [restoreDebugPrint]; this
      // case is a plain `test()` today, so a tearDown would serve either way,
      // but the day it becomes a `testWidgets` it would fail on itself before
      // any tearDown runs.
      //
      // If you do convert it, note that `installPre()` also leaves a
      // SemanticsHandle active (dusk's snapshot pipeline enables semantics),
      // which is a second end-of-test invariant and needs its own dispose.
      // Measured by converting this case as a probe.
      addTearDown(restoreDebugPrint);

      expect(MagicPerfIntegration.isInstalled, isTrue);
      expect(MagicRouter.instance.observers, hasLength(1));
      restoreDebugPrint();
    });
  });
  group('route transitions', () {
    test('an anonymous push is not recorded', () {
      // showDialog and showModalBottomSheet push unnamed routes through the
      // same navigator. Recording them would let a dialog-heavy session evict
      // the real page transitions out of the bounded list the report ranks.
      MagicPerfIntegration.install();
      addTearDown(MagicPerfIntegration.resetForTesting);

      final int before = MagicPerfIntegration.routeTransitions.length;

      MagicRouter.instance.observers.first.didPush(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        null,
      );

      // No pump needed and that is the point: an unnamed push returns before
      // scheduling the post-frame callback that would close the span, so
      // there is nothing in flight to wait for.
      expect(MagicPerfIntegration.routeTransitions, hasLength(before));
    });
  });
}
