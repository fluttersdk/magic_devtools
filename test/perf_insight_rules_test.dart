import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluttersdk_dusk/dusk.dart'
    show
        PerfMode,
        buildPerfReport,
        framePerfReader,
        perfExtrasReader,
        perfSessionBeginHook,
        perfSessionEndHook;
import 'package:fluttersdk_telescope/telescope.dart';
import 'package:magic/magic.dart';
import 'package:magic_devtools/magic_devtools.dart';

/// Tests for [PerfInsightRules], the wind and magic rules `perf_end` runs
/// through dusk's contributor seam.
///
/// Every rule is pinned twice, once just past its threshold and once just
/// short of it: a rule that only has a firing case would pass with no
/// threshold at all.

class _StormController extends MagicController {}

/// A report as dusk hands it to a contributor, cut to the keys the rules read.
Map<String, Object?> _report({
  int painted = 10,
  double? durationMs = 1000,
  List<Object?> routeTransitions = const <Object?>[],
  String mode = 'attribution',
}) => <String, Object?>{
  'mode': mode,
  'coverage': <String, Object?>{'framesSummarized': painted},
  'summary': <String, Object?>{
    'durationMs': durationMs,
    'routeTransitions': routeTransitions,
  },
};

PerfRuleInputs _inputs({
  Map<String, Object?> extras = const <String, Object?>{},
  Map<String, Object?>? wind,
  Map<String, Map<String, int>> notifiesByCause =
      const <String, Map<String, int>>{},
  Map<String, Map<String, int>> uncachedReloads =
      const <String, Map<String, int>>{},
  Map<String, List<String>> httpByInteraction = const <String, List<String>>{},
}) => PerfRuleInputs(
  extras: extras,
  wind: wind,
  notifiesByCause: notifiesByCause,
  uncachedReloads: uncachedReloads,
  httpByInteraction: httpByInteraction,
);

List<String> _metrics(List<Map<String, Object?>> insights) => insights
    .map(
      (Map<String, Object?> i) =>
          (i['evidence']! as Map<String, Object?>)['metric']! as String,
    )
    .toList();

FramePerfRecord _frame(int frameNumber) => FramePerfRecord(
  frameNumber: frameNumber,
  buildMicros: 4000,
  rasterMicros: 2000,
  vsyncOverheadMicros: 1000,
  totalSpanMicros: 7000,
  time: DateTime(2026, 9, 28),
  blocks: const <String, ({int micros, int selfMicros, int count})>{},
);

void main() {
  group('wind rules', () {
    test('a wrapper emitted at or past half a W-widget build per build and 20 '
        'per frame is named, one short of either is not', () {
      Map<String, Object?> wind(int mouseRegions) => <String, Object?>{
        'widgetBuilds': <String, int>{'WDiv': 300, 'WButton': 100},
        'wrapperEmissions': <String, int>{
          'MouseRegion': mouseRegions,
          'Padding': 50,
        },
      };

      final List<Map<String, Object?>> fired = PerfInsightRules.evaluate(
        _report(),
        _inputs(wind: wind(200)),
      );
      expect(_metrics(fired), contains('wind.wrapperEmissions.MouseRegion'));
      expect(
        PerfInsightRules.evaluate(_report(), _inputs(wind: wind(199))),
        isEmpty,
      );
      expect(
        PerfInsightRules.evaluate(
          _report(painted: 11),
          _inputs(wind: wind(200)),
        ),
        isEmpty,
        reason: '200 over 11 frames is under 20 per frame',
      );
    });

    test('mediaQuerySize reads at 10 per painted frame fire, below do not', () {
      Map<String, Object?> wind(int reads) => <String, Object?>{
        'inheritedReads': <String, int>{'mediaQuerySize': reads},
      };

      expect(
        _metrics(
          PerfInsightRules.evaluate(_report(), _inputs(wind: wind(100))),
        ),
        <String>['wind.inheritedReads.mediaQuerySize'],
      );
      expect(
        PerfInsightRules.evaluate(_report(), _inputs(wind: wind(99))),
        isEmpty,
      );
    });

    test('the mediaQuerySize summary describes a size-only subscription', () {
      final Map<String, Object?> insight = PerfInsightRules.evaluate(
        _report(),
        _inputs(
          wind: <String, Object?>{
            'inheritedReads': <String, int>{'mediaQuerySize': 100},
          },
        ),
      ).single;

      // wind reads MediaQuery.sizeOf: a resize or a rotation rebuilds the
      // reader, a keyboard inset does not. The old text said the opposite.
      final String summary = insight['summary']! as String;
      expect(summary, contains('MediaQuery.sizeOf'));
      expect(summary, contains('resize'));
      expect(summary, contains('not a keyboard inset'));
      expect(summary, isNot(contains('MediaQuery.of')));
      expect(summary, isNot(contains('EVERY')));
    });

    test('parse misses on a warm surface fire; a session that navigated, or '
        'a low miss rate, does not', () {
      final Map<String, Object?> misses = <String, Object?>{
        'cacheHits': 180,
        'cacheMisses': 20,
      };

      expect(
        _metrics(PerfInsightRules.evaluate(_report(), _inputs(wind: misses))),
        <String>['wind.cacheMisses'],
      );
      expect(
        PerfInsightRules.evaluate(
          _report(
            routeTransitions: <Object?>[
              <String, Object?>{'route': '/monitors', 'ms': 12.0},
            ],
          ),
          _inputs(wind: misses),
        ),
        isEmpty,
        reason: 'a first visit to a route is expected to miss',
      );
      expect(
        PerfInsightRules.evaluate(
          _report(),
          _inputs(wind: <String, Object?>{'cacheHits': 181, 'cacheMisses': 20}),
        ),
        isEmpty,
      );
      expect(
        PerfInsightRules.evaluate(
          _report(),
          _inputs(wind: <String, Object?>{'cacheHits': 0, 'cacheMisses': 19}),
        ),
        isEmpty,
      );
    });
  });

  group('magic rules', () {
    test('a notify cause at 2 per painted frame fires and names its '
        'controller; below does not', () {
      final List<Map<String, Object?>> fired = PerfInsightRules.evaluate(
        _report(),
        _inputs(
          notifiesByCause: <String, Map<String, int>>{
            'repositoryQuery': <String, int>{'MonitorController': 20},
          },
        ),
      );
      expect(_metrics(fired), <String>['magic.notifyCauses.repositoryQuery']);
      expect(fired.single['title'], contains('MonitorController'));

      expect(
        PerfInsightRules.evaluate(
          _report(),
          _inputs(
            notifiesByCause: <String, Map<String, int>>{
              'repositoryQuery': <String, int>{'MonitorController': 19},
            },
          ),
        ),
        isEmpty,
      );
    });

    test('timer-tick notifies at 4 per second fire, and are not reported a '
        'second time as a per-frame storm', () {
      Map<String, Map<String, int>> ticks(int n) => <String, Map<String, int>>{
        'timerTick': <String, int>{'CountdownController': n},
      };

      expect(
        _metrics(
          PerfInsightRules.evaluate(
            _report(painted: 2, durationMs: 5000),
            _inputs(notifiesByCause: ticks(20)),
          ),
        ),
        <String>['magic.notifyCauses.timerTick'],
      );
      expect(
        PerfInsightRules.evaluate(
          _report(painted: 2, durationMs: 5000),
          _inputs(notifiesByCause: ticks(19)),
        ),
        isEmpty,
      );
    });

    test('a query reloaded twice without cache in one interaction fires', () {
      expect(
        _metrics(
          PerfInsightRules.evaluate(
            _report(),
            _inputs(
              uncachedReloads: <String, Map<String, int>>{
                'i2': <String, int>{'Monitor': 2},
              },
            ),
          ),
        ),
        <String>['magic.queryReloads.uncached'],
      );
      expect(
        PerfInsightRules.evaluate(
          _report(),
          _inputs(
            uncachedReloads: <String, Map<String, int>>{
              'i2': <String, int>{'Monitor': 1},
              'i3': <String, int>{'Monitor': 1},
            },
          ),
        ),
        isEmpty,
      );
    });

    test('casts at 50 per painted frame fire, below do not', () {
      expect(
        _metrics(
          PerfInsightRules.evaluate(
            _report(),
            _inputs(
              extras: <String, Object?>{
                'casts': <String, int>{'datetime': 400, 'json': 100},
              },
            ),
          ),
        ),
        <String>['magic.casts'],
      );
      expect(
        PerfInsightRules.evaluate(
          _report(),
          _inputs(
            extras: <String, Object?>{
              'casts': <String, int>{'datetime': 499},
            },
          ),
        ),
        isEmpty,
      );
    });

    test(
      'five requests in one interaction, or the same request twice, fire',
      () {
        expect(
          _metrics(
            PerfInsightRules.evaluate(
              _report(),
              _inputs(
                httpByInteraction: <String, List<String>>{
                  'i1': <String>[
                    'GET /a',
                    'GET /b',
                    'GET /c',
                    'GET /d',
                    'GET /e',
                  ],
                },
              ),
            ),
          ),
          <String>['magic.httpPerInteraction'],
        );
        expect(
          _metrics(
            PerfInsightRules.evaluate(
              _report(),
              _inputs(
                httpByInteraction: <String, List<String>>{
                  'i1': <String>['GET /a', 'GET /a'],
                },
              ),
            ),
          ),
          <String>['magic.httpPerInteraction'],
        );
        expect(
          PerfInsightRules.evaluate(
            _report(),
            _inputs(
              httpByInteraction: <String, List<String>>{
                'i1': <String>['GET /a', 'GET /b', 'GET /c', 'GET /d'],
              },
            ),
          ),
          isEmpty,
        );
      },
    );

    test('a timing report gets no rule at all', () {
      expect(
        PerfInsightRules.evaluate(
          _report(mode: 'timing'),
          _inputs(
            extras: <String, Object?>{
              'casts': <String, int>{'datetime': 5000},
            },
          ),
        ),
        isEmpty,
      );
    });
  });

  group('conformance through dusk buildPerfReport', () {
    setUp(() {
      MagicApp.reset();
      Magic.flush();
      MagicRouter.reset();
      MagicPerfIntegration.resetForTesting();
      TelescopeStore.resetForTesting();
      WindParser.clearCache();
      WindPerfCounters.reset();
    });

    tearDown(() {
      MagicPerfIntegration.resetForTesting();
      MagicRouter.reset();
      TelescopeStore.resetForTesting();
      WindPerfCounters.enabled = false;
      WindPerfCounters.reset();
    });

    testWidgets('a report built from the real readers carries a wind and a '
        'magic insight, each well formed', (WidgetTester tester) async {
      MagicPerfIntegration.install();
      perfSessionBeginHook(PerfMode.attribution);

      // 1. wind: forty h-full boxes read MediaQuery size forty times.
      await tester.pumpWidget(
        MaterialApp(
          home: WindTheme(
            data: WindThemeData(),
            child: Column(
              children: <Widget>[
                for (int i = 0; i < 40; i++)
                  const Expanded(child: WDiv(className: 'h-full')),
              ],
            ),
          ),
        ),
      );

      // 2. magic: one controller notifying far more often than frames paint.
      final _StormController controller = _StormController();
      for (int i = 0; i < 20; i++) {
        controller.refreshUI();
      }

      // 3. Two painted frames, as telescope's frame watcher records them.
      TelescopeStore.recordFramePerf(_frame(1));
      TelescopeStore.recordFramePerf(_frame(2));

      final Map<String, Object?> report = buildPerfReport(
        framePerfReader(),
        perfExtrasReader(),
        const WindPerfResolverImpl().stats(),
        env: const <String, Object?>{'platform': 'test'},
        framesDrawn: 2,
        durationMs: 500,
      );
      perfSessionEndHook();

      final List<Map<String, Object?>> insights =
          (report['insights']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        insights.map((Map<String, Object?> i) => i['title']),
        isNot(contains(startsWith('Insight contributor'))),
        reason: 'a malformed contributed insight becomes a failure insight',
      );
      for (final Map<String, Object?> insight in insights) {
        expect(
          insight.keys,
          containsAll(<String>[
            'id',
            'severity',
            'title',
            'evidence',
            'nextStep',
          ]),
        );
      }
      final List<String> metrics = _metrics(insights);
      expect(metrics, contains('wind.inheritedReads.mediaQuerySize'));
      expect(metrics, contains('magic.notifyCauses.direct'));
      for (final Map<String, Object?> insight in insights.where(
        (Map<String, Object?> i) =>
            _metrics(<Map<String, Object?>>[i]).single.contains('.'),
      )) {
        expect(
          (insight['evidence']! as Map<String, Object?>)['threshold'],
          isA<Map<String, Object?>>(),
          reason: 'a contributed rule states the threshold it fired on',
        );
      }
    });
  });
}
