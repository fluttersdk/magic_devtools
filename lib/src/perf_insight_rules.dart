/// The wind and magic insight rules `ext.dusk.perf_end` runs through dusk's
/// `perfInsightContributors` seam.
///
/// They live here, not in dusk, because judging them needs to know what a
/// wind wrapper or a magic notify cause MEANS, and dusk may not import either
/// package. Every rule states the threshold it fired on in
/// `evidence.threshold` and normalises by painted frames (the report's
/// `coverage.framesSummarized`), the one denominator two sessions of
/// different length share. A rule that cannot compute its denominator stays
/// silent rather than guessing.
library;

/// Everything the rules read beyond the report dusk hands a contributor.
///
/// The report carries each counter family cut to its ranked head, so a rule
/// reading it would judge a truncated sum; these are the same families UNCUT,
/// plus the per-interaction joins the report does not carry at all.
final class PerfRuleInputs {
  const PerfRuleInputs({
    required this.extras,
    required this.wind,
    required this.notifiesByCause,
    required this.uncachedReloads,
    required this.httpByInteraction,
  });

  /// `perfExtrasReader()` as read for this report.
  final Map<String, Object?> extras;

  /// wind's `WindPerfResolver.stats()`, or null when no resolver is
  /// registered.
  final Map<String, Object?>? wind;

  /// Notify cause name to controller type to notifies.
  final Map<String, Map<String, int>> notifiesByCause;

  /// Interaction id to model type to reloads that issued their own request
  /// rather than joining one in flight.
  final Map<String, Map<String, int>> uncachedReloads;

  /// Interaction id to the `METHOD url` of every request it sent, in order.
  final Map<String, List<String>> httpByInteraction;
}

/// The rules. Stateless; [evaluate] is the contributor.
abstract final class PerfInsightRules {
  /// A wrapper type is reported once it is emitted this many times per
  /// W-widget build...
  static const double wrapperMinPerWidgetBuild = 0.5;

  /// ...and this many times per painted frame, so a screen of three buttons
  /// does not report its three MouseRegions.
  static const double wrapperMinPerFrame = 20;

  /// `MediaQuery` size reads per painted frame.
  static const double mediaQueryMinPerFrame = 10;

  /// Parse misses a warm surface may take before the rate is judged at all.
  static const int parseMinMisses = 20;

  /// Share of parses that missed the cache.
  static const double parseMinMissRate = 0.1;

  /// Notifies of one cause per painted frame. Past one, the frame coalesced
  /// the rest: work done for no pixel.
  static const double notifyMinPerFrame = 2;

  /// Timer-driven notifies per second of session. A one-second countdown is
  /// one; a poll or debounce firing faster is the storm.
  static const double timerNotifyMinPerSecond = 4;

  /// Reloads of one model type inside one interaction that each issued their
  /// own request. The first is the fetch; a second is a refetch.
  static const int uncachedReloadsMaxPerInteraction = 1;

  /// Computed attribute casts per painted frame.
  static const double castMinPerFrame = 50;

  /// Requests one interaction may send.
  static const int httpMaxPerInteraction = 4;

  /// Times one interaction may send the same request.
  static const int httpMaxSameRequestPerInteraction = 1;

  /// Why a wrapper is emitted, for the wrappers a W-widget adds on its own.
  static const Map<String, String> _wrapperCauses = <String, String>{
    'MouseRegion':
        'WAnchor emits a MouseRegion on every build (WButton wraps '
        'one), and WDiv adds another for any cursor-* class',
    'Focus': 'WAnchor emits a Focus on every build (WButton wraps one)',
    'WindAnchorStateProvider':
        'WAnchor emits its state provider on every '
        'build (WButton wraps one)',
    'Semantics':
        'WAnchor, WCheckbox, WRadio, WSwitch and WInput each emit a '
        'Semantics node',
    'WindFullHeightBox': 'WDiv emits one for every h-full class',
  };

  /// Runs every rule against [report] and returns the insights that fired, in
  /// the shape dusk's contributor seam takes.
  ///
  /// Nothing fires on a timing report: it carries no counters, and its
  /// milliseconds are the ones a rule must not tax.
  static List<Map<String, Object?>> evaluate(
    Map<String, Object?> report,
    PerfRuleInputs inputs,
  ) {
    final int painted = _int(_map(report['coverage'])['framesSummarized']);
    if (report['mode'] != 'attribution' || painted == 0) {
      return const <Map<String, Object?>>[];
    }
    final Map<String, Object?> summary = _map(report['summary']);
    final Object? routes = summary['routeTransitions'];
    final Object? durationMs = summary['durationMs'];

    return <Map<String, Object?>?>[
      _wrapperEmissions(inputs.wind, painted),
      _mediaQueryReads(inputs.wind, painted),
      _warmParseMisses(
        inputs.wind,
        painted,
        navigated: routes is List<Object?> && routes.isNotEmpty,
      ),
      _notifyStorm(inputs.notifiesByCause, painted),
      _timerNotifies(
        inputs.notifiesByCause,
        painted,
        durationMs is num ? durationMs.toDouble() : null,
      ),
      _uncachedReloads(inputs.uncachedReloads, painted),
      _casts(inputs.extras, painted),
      _httpPerInteraction(inputs.httpByInteraction, painted),
    ].whereType<Map<String, Object?>>().toList();
  }

  // -------------------------------------------------------------------------
  // wind
  // -------------------------------------------------------------------------

  static Map<String, Object?>? _wrapperEmissions(
    Map<String, Object?>? wind,
    int painted,
  ) {
    final int builds = _sum(_counts(wind?['widgetBuilds']));
    if (builds == 0) return null;

    final List<MapEntry<String, int>> qualifying =
        _ranked(_counts(wind?['wrapperEmissions']))
            .where(
              (MapEntry<String, int> e) =>
                  e.value / builds >= wrapperMinPerWidgetBuild &&
                  e.value / painted >= wrapperMinPerFrame,
            )
            .toList();
    if (qualifying.isEmpty) return null;

    final MapEntry<String, int> top = qualifying.first;
    final double perBuild = _round(top.value / builds);
    final String cause =
        _wrapperCauses[top.key] ??
        'find the W-widget whose className asks for it';

    return _insight(
      title: '${top.key} emitted $perBuild times per W-widget build',
      summary:
          'wind emitted ${top.value} ${top.key} wrappers against $builds '
          'W-widget builds over $painted painted frames. Each is an element '
          'built, laid out and (for MouseRegion) hit-tested on every pointer '
          'move. Cause: $cause.',
      metric: 'wind.wrapperEmissions.${top.key}',
      value: top.value,
      painted: painted,
      threshold: <String, Object?>{
        'minPerWidgetBuild': wrapperMinPerWidgetBuild,
        'minPerFrame': wrapperMinPerFrame,
      },
      nextStep:
          'Find the repeated rows that emit ${top.key} ($cause) and '
          'whether each row needs it; widgetBuilds names the W-widget types.',
      detail: <String, Object?>{
        'wrappers': _rows(qualifying, painted),
        'widgetBuilds': _rows(_ranked(_counts(wind?['widgetBuilds'])), painted),
      },
    );
  }

  static Map<String, Object?>? _mediaQueryReads(
    Map<String, Object?>? wind,
    int painted,
  ) {
    final int reads = _counts(wind?['inheritedReads'])['mediaQuerySize'] ?? 0;
    if (reads / painted < mediaQueryMinPerFrame) return null;

    return _insight(
      title: '${_round(reads / painted)} MediaQuery size reads per frame',
      summary:
          'wind read MediaQuery size $reads times over $painted painted '
          'frames. WDiv reads it for every h-full box and for a grid laid out '
          'under unbounded width, through MediaQuery.sizeOf, which subscribes '
          'the widget to the size aspect only: a resize or a rotation '
          'rebuilds each one, not a keyboard inset.',
      metric: 'wind.inheritedReads.mediaQuerySize',
      value: reads,
      painted: painted,
      threshold: <String, Object?>{'minPerFrame': mediaQueryMinPerFrame},
      nextStep:
          'Find the repeated h-full boxes (or unbounded grids) and give '
          'them a bounded parent or a fixed height, so a resize or a '
          'rotation stops rebuilding each of them.',
    );
  }

  static Map<String, Object?>? _warmParseMisses(
    Map<String, Object?>? wind,
    int painted, {
    required bool navigated,
  }) {
    if (navigated || wind == null) return null;
    final int misses = _int(wind['cacheMisses']);
    final int parses = misses + _int(wind['cacheHits']);
    if (misses < parseMinMisses || misses / parses < parseMinMissRate) {
      return null;
    }
    final double rate = _round(misses / parses);

    return _insight(
      title: 'wind missed its parse cache on $misses of $parses parses',
      summary:
          'No route was pushed during the session, so the surface was '
          'already built, yet ${(rate * 100).round()}% of className parses '
          'missed the style cache. On a warm surface a miss means a className '
          'string that changes between builds (an interpolated value, a '
          'per-row color), so it is parsed again every time.',
      metric: 'wind.cacheMisses',
      value: misses,
      painted: painted,
      threshold: <String, Object?>{
        'minMisses': parseMinMisses,
        'minMissRate': parseMinMissRate,
        'requiresNoRouteTransition': true,
      },
      nextStep:
          'Find the className built by interpolation in the rebuilt rows '
          'and move the varying part to a fixed token set.',
    );
  }

  // -------------------------------------------------------------------------
  // magic
  // -------------------------------------------------------------------------

  static Map<String, Object?>? _notifyStorm(
    Map<String, Map<String, int>> byCause,
    int painted,
  ) {
    // Timer ticks are judged per second below; counted here too they would
    // report the same notifies twice under two thresholds.
    final List<MapEntry<String, int>> causes = _ranked(<String, int>{
      for (final MapEntry<String, Map<String, int>> e in byCause.entries)
        if (e.key != 'timerTick') e.key: _sum(e.value),
    });
    if (causes.isEmpty || causes.first.value / painted < notifyMinPerFrame) {
      return null;
    }
    final MapEntry<String, int> top = causes.first;
    final List<MapEntry<String, int>> controllers = _ranked(byCause[top.key]!);

    return _insight(
      title:
          '${controllers.first.key} notified '
          '${_round(top.value / painted)} times per frame (${top.key})',
      summary:
          '${top.value} ${top.key} notifies over $painted painted frames. '
          'A frame coalesces every notify before it, so all but one per frame '
          'rebuilt listeners for no new pixel.',
      metric: 'magic.notifyCauses.${top.key}',
      value: top.value,
      painted: painted,
      threshold: <String, Object?>{'minPerFrame': notifyMinPerFrame},
      nextStep:
          'Batch the state changes in ${controllers.first.key} behind '
          'one setState, or narrow what listens to it.',
      detail: <String, Object?>{'controllers': _rows(controllers, painted)},
    );
  }

  static Map<String, Object?>? _timerNotifies(
    Map<String, Map<String, int>> byCause,
    int painted,
    double? durationMs,
  ) {
    final Map<String, int> ticks =
        byCause['timerTick'] ?? const <String, int>{};
    final int total = _sum(ticks);
    if (durationMs == null || durationMs <= 0 || total == 0) return null;
    final double perSecond = total / (durationMs / 1000);
    if (perSecond < timerNotifyMinPerSecond) return null;
    final List<MapEntry<String, int>> controllers = _ranked(ticks);

    return _insight(
      title:
          '${controllers.first.key} notified ${_round(perSecond)} times '
          'per second from timers',
      summary:
          '$total notifies ran inside a Countdown, Debouncer or Poll '
          'tick over ${_round(durationMs / 1000)}s, each rebuilding every '
          'listener of the controller whether or not what it shows changed.',
      metric: 'magic.notifyCauses.timerTick',
      value: total,
      painted: painted,
      threshold: <String, Object?>{'minPerSecond': timerNotifyMinPerSecond},
      nextStep:
          'Slow the timer in ${controllers.first.key}, or notify only '
          'when the displayed value changes.',
      detail: <String, Object?>{
        'perSecond': _round(perSecond),
        'controllers': _rows(controllers, painted),
      },
    );
  }

  static Map<String, Object?>? _uncachedReloads(
    Map<String, Map<String, int>> byInteraction,
    int painted,
  ) {
    ({String interaction, String type, int count})? worst;
    int total = 0;
    for (final MapEntry<String, Map<String, int>> i in byInteraction.entries) {
      for (final MapEntry<String, int> t in i.value.entries) {
        total += t.value;
        if (worst == null || t.value > worst.count) {
          worst = (interaction: i.key, type: t.key, count: t.value);
        }
      }
    }
    if (worst == null || worst.count <= uncachedReloadsMaxPerInteraction) {
      return null;
    }

    return _insight(
      title:
          '${worst.type} reloaded ${worst.count} times in interaction '
          '${worst.interaction}',
      summary:
          'Interaction ${worst.interaction} reloaded ${worst.type} '
          '${worst.count} times, each issuing its own request instead of '
          'joining the first one in flight.',
      metric: 'magic.queryReloads.uncached',
      value: worst.count,
      perFrameValue: total,
      painted: painted,
      threshold: <String, Object?>{
        'maxUncachedPerInteraction': uncachedReloadsMaxPerInteraction,
      },
      nextStep:
          'Mount-time reads should call ensureFresh(), which joins a '
          'load in flight; find which screen calls reload() on mount.',
      detail: <String, Object?>{'byInteraction': byInteraction},
    );
  }

  static Map<String, Object?>? _casts(
    Map<String, Object?> extras,
    int painted,
  ) {
    final Map<String, int> casts = _counts(extras['casts']);
    final int total = _sum(casts);
    if (total / painted < castMinPerFrame) return null;
    final List<MapEntry<String, int>> ranked = _ranked(casts);

    return _insight(
      title:
          '${_round(total / painted)} attribute casts per frame, mostly '
          '${ranked.first.key}',
      summary:
          'Model.getAttribute computed $total casts over $painted painted '
          'frames. A cast is recomputed on every read that is not memoised, '
          'so a row reading a datetime or json attribute in build pays it on '
          'every rebuild.',
      metric: 'magic.casts',
      value: total,
      painted: painted,
      threshold: <String, Object?>{'minPerFrame': castMinPerFrame},
      nextStep:
          'Read the ${ranked.first.key} attribute once per build into a '
          'local, or out of build altogether.',
      detail: <String, Object?>{'casts': _rows(ranked, painted)},
    );
  }

  static Map<String, Object?>? _httpPerInteraction(
    Map<String, List<String>> byInteraction,
    int painted,
  ) {
    ({String interaction, int count, String? repeated, int repeats})? worst;
    int total = 0;
    for (final MapEntry<String, List<String>> i in byInteraction.entries) {
      total += i.value.length;
      final Map<String, int> same = <String, int>{};
      for (final String request in i.value) {
        same.update(request, (int n) => n + 1, ifAbsent: () => 1);
      }
      final MapEntry<String, int> most = _ranked(same).first;
      final bool over =
          i.value.length > httpMaxPerInteraction ||
          most.value > httpMaxSameRequestPerInteraction;
      if (over && (worst == null || i.value.length > worst.count)) {
        worst = (
          interaction: i.key,
          count: i.value.length,
          repeated: most.value > 1 ? most.key : null,
          repeats: most.value,
        );
      }
    }
    if (worst == null) return null;

    return _insight(
      title:
          'Interaction ${worst.interaction} sent ${worst.count} requests'
          '${worst.repeated == null ? '' : ', ${worst.repeated} '
                    '${worst.repeats} times'}',
      summary:
          'One interaction sent ${worst.count} HTTP requests. Every one '
          'is a round trip the screen may wait on, and the same request sent '
          'twice is a fetch nothing reused.',
      metric: 'magic.httpPerInteraction',
      value: worst.count,
      perFrameValue: total,
      painted: painted,
      threshold: <String, Object?>{
        'maxPerInteraction': httpMaxPerInteraction,
        'maxSameRequestPerInteraction': httpMaxSameRequestPerInteraction,
      },
      nextStep:
          'Export the trace (dusk:perf_trace) and read the http track '
          'under ${worst.interaction}: which screen sends each request, and '
          'which could share one.',
      detail: <String, Object?>{'requests': byInteraction[worst.interaction]},
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// One insight in the contributor shape. [perFrameValue] is the count the
  /// per-frame figure divides when it is not [value] itself (a worst case
  /// reported against a session total).
  static Map<String, Object?> _insight({
    required String title,
    required String summary,
    required String metric,
    required int value,
    required int painted,
    required Map<String, Object?> threshold,
    required String nextStep,
    int? perFrameValue,
    Map<String, Object?>? detail,
  }) => <String, Object?>{
    'severity': 'warn',
    'title': title,
    'summary': summary,
    'evidence': <String, Object?>{
      'metric': metric,
      'value': value,
      'perFrame': _round((perFrameValue ?? value) / painted),
      'threshold': threshold,
    },
    'nextStep': nextStep,
    'detail': ?detail,
  };

  static List<List<Object?>> _rows(
    List<MapEntry<String, int>> ranked,
    int painted,
  ) => ranked
      .map(
        (MapEntry<String, int> e) => <Object?>[
          e.key,
          e.value,
          _round(e.value / painted),
        ],
      )
      .toList();

  static List<MapEntry<String, int>> _ranked(Map<String, int> counts) =>
      counts.entries.toList()..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) => b.value != a.value
            ? b.value.compareTo(a.value)
            : a.key.compareTo(b.key),
      );

  static Map<String, int> _counts(Object? raw) => <String, int>{
    if (raw is Map<Object?, Object?>)
      for (final MapEntry<Object?, Object?> e in raw.entries)
        if (e.value is int) '${e.key}': e.value! as int,
  };

  static Map<String, Object?> _map(Object? raw) =>
      raw is Map<String, Object?> ? raw : const <String, Object?>{};

  static int _sum(Map<String, int> counts) =>
      counts.values.fold<int>(0, (int sum, int n) => sum + n);

  static int _int(Object? value) => value is num ? value.toInt() : 0;

  static double _round(num value) => (value * 100).round() / 100;
}
