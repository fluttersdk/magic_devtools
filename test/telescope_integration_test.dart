import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide EventDispatcher;
import 'package:fluttersdk_telescope/telescope.dart';
import 'package:magic/magic.dart';
import 'package:magic_devtools/magic_devtools.dart';
import 'package:magic_devtools/telescope.dart';

// ---------------------------------------------------------------------------
// Test-only stubs
// ---------------------------------------------------------------------------

/// [NetworkDriver] stub that captures interceptors added via [addInterceptor].
class _CapturingNetworkDriver implements NetworkDriver {
  final List<MagicNetworkInterceptor> interceptors =
      <MagicNetworkInterceptor>[];

  @override
  void addInterceptor(MagicNetworkInterceptor interceptor) {
    interceptors.add(interceptor);
  }

  @override
  Future<MagicResponse> get(
    String url, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> post(
    String url, {
    dynamic data,
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> put(
    String url, {
    dynamic data,
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> delete(String url, {Map<String, String>? headers}) =>
      throw UnimplementedError();

  @override
  Future<MagicResponse> upload(
    String url, {
    required Map<String, dynamic> data,
    required Map<String, dynamic> files,
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> index(
    String resource, {
    Map<String, dynamic>? filters,
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> show(
    String resource,
    String id, {
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> store(
    String resource,
    Map<String, dynamic> data, {
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> update(
    String resource,
    String id,
    Map<String, dynamic> data, {
    Map<String, String>? headers,
  }) => throw UnimplementedError();

  @override
  Future<MagicResponse> destroy(
    String resource,
    String id, {
    Map<String, String>? headers,
  }) => throw UnimplementedError();
}

MagicRequest _req(String url, {String method = 'GET', int? id}) =>
    MagicRequest(url: url, method: method, id: id);

MagicResponse _ok({int statusCode = 200, int? id}) =>
    MagicResponse(data: <String, dynamic>{}, statusCode: statusCode, id: id);

/// Stands in for dusk's `PerfInteraction`, whose constructor is private to
/// dusk: a host test has no way to open a real one outside a perf session
/// driven over the VM Service. Recognised through
/// [MagicPerfIntegration.zoneInteraction], the one seam that decides what a
/// zone value is; the zone key and the zone, frame, window order under test
/// are the production ones.
class _FakeInteraction {
  _FakeInteraction(this.id);

  final String id;

  bool open = true;
}

/// Points both interaction sources at [_FakeInteraction]: the zone value, and
/// the active slot a frame-zone read falls back to.
void _useFakeInteractions({_FakeInteraction? active}) {
  // An instant (these records carry no start time) needs an OPEN handle, so a
  // closed one only has to report that it closed.
  MagicPerfIntegration.zoneInteraction = (Object? value) =>
      value is _FakeInteraction
      ? (id: value.id, startUs: 0, closedAtUs: value.open ? null : 1)
      : null;
  MagicPerfIntegration.activeInteractionId = () =>
      active != null && active.open ? active.id : null;
}

/// Runs [body] the way dusk runs a gesture: with [interaction] as the zone
/// value under dusk's public `#fluttersdk_interaction` key.
R _inInteraction<R>(_FakeInteraction interaction, R Function() body) =>
    runZoned(
      body,
      zoneValues: <Object?, Object?>{#fluttersdk_interaction: interaction},
    );

class _NextPage extends StatefulWidget {
  const _NextPage();

  @override
  State<_NextPage> createState() => _NextPageState();
}

class _NextPageState extends State<_NextPage> {
  @override
  void initState() {
    super.initState();
    // The refetch a newly mounted screen fires: it runs in the frame zone,
    // which never carries the zone value of the tap that navigated here.
    EventDispatcher.instance.dispatch(
      QueryExecuted(
        sql: 'select * from next',
        bindings: <Object?>[],
        timeMs: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const Text('next');
}

void main() {
  group('MagicHttpFacadeAdapter.pendingCount', () {
    late _CapturingNetworkDriver driver;
    late MagicHttpFacadeAdapter adapter;

    setUp(() {
      MagicApp.reset();
      Magic.flush();
      TelescopeStore.resetForTesting();
      driver = _CapturingNetworkDriver();
      Magic.bind('network', () => driver);
      adapter = MagicHttpFacadeAdapter();
    });

    tearDown(() {
      TelescopeStore.resetForTesting();
      MagicApp.reset();
      Magic.flush();
    });

    test('returns 0 BEFORE install() (interceptor not yet attached)', () {
      // Pre-install, _interceptor is null; the getter must short-circuit to 0
      // rather than throw a null deref.
      expect(adapter.pendingCount, equals(0));
    });

    test('returns 0 after install() when no requests are in flight', () {
      adapter.install();
      expect(adapter.pendingCount, equals(0));
    });

    test('returns the count of in-flight requests post-install', () {
      adapter.install();
      final interceptor = driver.interceptors.first;

      // Three requests enter without a matching response/error.
      interceptor.onRequest(_req('/a'));
      interceptor.onRequest(_req('/b'));
      interceptor.onRequest(_req('/c'));

      expect(adapter.pendingCount, equals(3));
    });

    test('decrements as responses pair with pending requests (FIFO)', () {
      adapter.install();
      final interceptor = driver.interceptors.first;

      interceptor.onRequest(_req('/a'));
      interceptor.onRequest(_req('/b'));
      expect(adapter.pendingCount, equals(2));

      interceptor.onResponse(_ok());
      expect(adapter.pendingCount, equals(1));

      interceptor.onResponse(_ok(statusCode: 204));
      expect(adapter.pendingCount, equals(0));
    });

    test('an answer without an id never takes a request that has one', () {
      // It used to take the oldest request in flight whatever that was. When
      // that was a real request with an id, its own answer then found nothing
      // to pair with and was dropped, and the id-less answer was recorded
      // against the wrong URL.
      TelescopeStore.resetForTesting();
      adapter.install();
      final interceptor = driver.interceptors.first;

      interceptor.onRequest(_req('/real', id: 7));
      interceptor.onRequest(_req('/hand-built'));
      interceptor.onResponse(_ok(statusCode: 201));
      interceptor.onResponse(_ok(id: 7));

      final Map<String, HttpRequestRecord> byUrl = <String, HttpRequestRecord>{
        for (final HttpRequestRecord r in TelescopeStore.recentHttp()) r.url: r,
      };
      expect(byUrl['/hand-built']?.statusCode, 201);
      expect(byUrl['/hand-built']?.attributedHeuristically, isTrue);
      expect(byUrl['/real']?.statusCode, 200);
      expect(byUrl['/real']?.requestId, '7');
      expect(adapter.pendingCount, 0);
    });

    test(
      'returns 0 again after uninstall() clears the interceptor reference',
      () {
        adapter.install();
        final interceptor = driver.interceptors.first;

        interceptor.onRequest(_req('/a'));
        expect(adapter.pendingCount, equals(1));

        adapter.uninstall();
        // After uninstall the adapter drops its interceptor reference, so the
        // pre-install null-guard fires.
        expect(adapter.pendingCount, equals(0));
      },
    );

    test('flows through TelescopeStore.pendingHttpCount when registered', () {
      TelescopePlugin.registerHttpAdapter(adapter);
      final interceptor = driver.interceptors.first;

      interceptor.onRequest(_req('/sync'));
      interceptor.onRequest(_req('/queue'));

      expect(TelescopeStore.pendingHttpCount, equals(2));

      interceptor.onResponse(_ok());
      expect(TelescopeStore.pendingHttpCount, equals(1));
    });
  });

  group('HTTP pairing by request id', () {
    late HttpServer server;
    HttpOverrides? bindingOverrides;

    setUp(() async {
      // The widget binding a testWidgets case in this file creates installs a
      // global HttpClient override that answers every request 400; these
      // cases need the real loopback socket.
      bindingOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      MagicApp.reset();
      Magic.flush();
      TelescopeStore.resetForTesting();
      MagicPerfIntegration.resetForTesting();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final int delayMs = request.uri.path == '/slow' ? 400 : 0;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"path":"${request.uri.path}"}');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = bindingOverrides;
      TelescopeStore.resetForTesting();
      MagicPerfIntegration.resetForTesting();
      MagicApp.reset();
      Magic.flush();
    });

    test('two responses completing out of order each keep their own URL and '
        'duration', () async {
      final DioNetworkDriver driver = DioNetworkDriver(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      Magic.bind('network', () => driver);
      final MagicHttpFacadeAdapter adapter = MagicHttpFacadeAdapter()
        ..install();

      // /slow is sent first and answers last, which is exactly the order a
      // FIFO pairing gets wrong: it hands /fast's answer to /slow.
      final Future<MagicResponse> slow = driver.get('/slow');
      final Future<MagicResponse> fast = driver.get('/fast');
      await Future.wait(<Future<MagicResponse>>[slow, fast]);

      final Map<String, HttpRequestRecord> byUrl = <String, HttpRequestRecord>{
        for (final HttpRequestRecord r in TelescopeStore.recentHttp())
          Uri.parse(r.url).path: r,
      };
      expect(byUrl.keys, unorderedEquals(<String>['/slow', '/fast']));
      expect(byUrl['/slow']!.durationMs, greaterThanOrEqualTo(350));
      expect(byUrl['/fast']!.durationMs, lessThan(350));
      expect(byUrl['/slow']!.attributedHeuristically, isFalse);
      expect(byUrl['/slow']!.requestId, isNotNull);
      expect(byUrl['/slow']!.requestId, isNot(byUrl['/fast']!.requestId));
      expect(
        byUrl['/slow']!.endUs! - byUrl['/slow']!.startUs!,
        greaterThanOrEqualTo(350000),
      );
      expect(adapter.pendingCount, 0);
    });

    test('a request fired inside an interaction zone carries its id', () async {
      final DioNetworkDriver driver = DioNetworkDriver(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      Magic.bind('network', () => driver);
      MagicHttpFacadeAdapter().install();
      final _FakeInteraction tap = _FakeInteraction('i3');
      _useFakeInteractions();

      await _inInteraction(tap, () => driver.get('/fast'));

      final HttpRequestRecord record = TelescopeStore.recentHttp().single;
      expect(record.interactionId, 'i3');
      expect(record.linkedBy, 'zone');
    });
  });

  group('interaction links on records', () {
    setUp(() {
      MagicApp.reset();
      Magic.flush();
      MagicRouter.reset();
      EventDispatcher.instance.clear();
      TelescopeStore.resetForTesting();
      MagicPerfIntegration.resetForTesting();
    });

    tearDown(() {
      EventDispatcher.instance.clear();
      TelescopeStore.resetForTesting();
      MagicPerfIntegration.resetForTesting();
      MagicRouter.reset();
    });

    test('a QueryExecuted fired inside an open interaction zone is linked by '
        'zone, even while another interaction is active', () async {
      MagicQueryWatcher().install();
      final _FakeInteraction tap = _FakeInteraction('i7');
      _useFakeInteractions(active: _FakeInteraction('i8'));

      await _inInteraction(
        tap,
        () => EventDispatcher.instance.dispatch(
          QueryExecuted(sql: 'select 1', bindings: <Object?>[], timeMs: 2),
        ),
      );

      final QueryRecord record = TelescopeStore.recentQueries().single;
      expect(record.interactionId, 'i7');
      expect(record.linkedBy, 'zone');
    });

    test('a closed zone handle is absent: the active slot links by frame, '
        'and with neither the record is linked by window', () async {
      MagicModelWatcher().install();
      MagicCacheWatcher().install();
      MagicEventWatcher().install();
      final _FakeInteraction closed = _FakeInteraction('i1')..open = false;
      final _FakeInteraction active = _FakeInteraction('i2');
      _useFakeInteractions(active: active);

      await _inInteraction(
        closed,
        () => EventDispatcher.instance.dispatch(CacheHit('k', 1)),
      );
      active.open = false;
      await EventDispatcher.instance.dispatch(AuthLogout(null));

      final MagicCacheRecord cache = TelescopeStore.recentCaches().single;
      expect(cache.interactionId, 'i2');
      expect(cache.linkedBy, 'frame');
      final EventRecord event = TelescopeStore.recentEvents().single;
      expect(event.interactionId, isNull);
      expect(event.linkedBy, 'window');
    });

    testWidgets('a tap that navigates links by zone, and the next page\'s '
        'initState refetch links by frame to the same interaction', (
      WidgetTester tester,
    ) async {
      MagicQueryWatcher().install();
      final _FakeInteraction tap = _FakeInteraction('i4');
      _useFakeInteractions(active: tap);

      MagicRoute.page(
        '/',
        () => Scaffold(
          body: GestureDetector(
            onTap: () {
              EventDispatcher.instance.dispatch(
                QueryExecuted(
                  sql: 'select * from here',
                  bindings: <Object?>[],
                  timeMs: 1,
                ),
              );
              MagicRouter.instance.to('/next');
            },
            child: const Text('go'),
          ),
        ),
      );
      MagicRoute.page('/next', () => const _NextPage());
      await tester.pumpWidget(
        MaterialApp.router(routerConfig: MagicRouter.instance.routerConfig),
      );
      await tester.pumpAndSettle();

      // Dispatched the way dusk dispatches a gesture: inside the zone. The
      // pumps that build the next page run in the test's own zone, as frames
      // run in the binding's frame zone in an app.
      await _inInteraction(tap, () => tester.tap(find.text('go')));
      await tester.pumpAndSettle();

      expect(find.text('next'), findsOneWidget);
      final Map<String, QueryRecord> bySql = <String, QueryRecord>{
        for (final QueryRecord r in TelescopeStore.recentQueries()) r.sql: r,
      };
      expect(bySql['select * from here']!.interactionId, 'i4');
      expect(bySql['select * from here']!.linkedBy, 'zone');
      expect(bySql['select * from next']!.interactionId, 'i4');
      expect(bySql['select * from next']!.linkedBy, 'frame');
    });
  });
}
