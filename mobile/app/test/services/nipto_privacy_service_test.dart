import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:nipto/services/nipto_privacy_service.dart';

class _Call {
  const _Call(this.path, this.body, this.method);

  final String path;
  final Object? body;
  final HttpMethod method;
}

NiptoPrivacyService _serviceWith(
  Future<FunctionResponse> Function(
    String path, {
    Object? body,
    HttpMethod? method,
  })
  responder,
  List<_Call> calls,
) {
  return NiptoPrivacyService(
    transport: NiptoPrivacySupabaseTransport(
      invoker: (path, {body, method}) async {
        calls.add(_Call(path, body, method ?? HttpMethod.post));
        return responder(path, body: body, method: method ?? HttpMethod.post);
      },
    ),
  );
}

void main() {
  const requestId = '22222222-2222-4222-8222-222222222222';
  const otherId = '33333333-3333-4333-8333-333333333333';

  group('NiptoPrivacyService', () {
    test('status parses sanitized rows through POST /status', () async {
      final calls = <_Call>[];
      final service = _serviceWith((path, {body, method}) async {
        return const FunctionResponse(
          data: {
            'requests': [
              {
                'id': requestId,
                'kind': 'deletion',
                'status': 'pending',
                'requested_at': '2026-01-01T00:00:00.000Z',
                'execute_after': '2026-01-15T00:00:00.000Z',
                'completed_at': null,
                'canceled_at': null,
                'attempts': 0,
              },
            ],
          },
          status: 200,
        );
      }, calls);

      final requests = await service.status();

      expect(calls.single.path, 'status');
      expect(calls.single.body, isEmpty);
      expect(calls.single.method, HttpMethod.post);
      expect(requests, hasLength(1));
      expect(requests.single.id, requestId);
      expect(requests.single.kind, NiptoPrivacyKind.deletion);
      expect(requests.single.status, NiptoPrivacyStatus.pending);
      expect(requests.single.isPendingDeletion, isTrue);
      expect(
        requests.single.executeAfter.toUtc().toIso8601String(),
        '2026-01-15T00:00:00.000Z',
      );
    });

    test(
      'request sends the exact kind and parses the sanitized result',
      () async {
        final calls = <_Call>[];
        final service = _serviceWith((path, {body, method}) async {
          return const FunctionResponse(
            data: {'request_id': requestId, 'status': 'pending'},
            status: 200,
          );
        }, calls);

        final created = await service.request(NiptoPrivacyKind.export);

        expect(created, requestId);
        expect(calls.single.path, 'request');
        expect(calls.single.body, {'kind': 'export'});
        expect(calls.single.method, HttpMethod.post);
      },
    );

    test('cancel and export URL use the documented payloads', () async {
      final calls = <_Call>[];
      final service = _serviceWith((path, {body, method}) async {
        if (path == 'cancel') {
          return const FunctionResponse(data: {'canceled': true}, status: 200);
        }
        return const FunctionResponse(
          data: {
            'signed_url': 'https://example.test/export?token=short-lived',
            'expires_at': '2026-01-01T01:00:00.000Z',
          },
          status: 200,
        );
      }, calls);

      expect(await service.cancelDeletion(), isTrue);
      final url = await service.exportUrl(requestId);

      expect(calls[0].path, 'cancel');
      expect(calls[0].body, isEmpty);
      expect(calls[1].path, 'export-url');
      expect(calls[1].body, {'request_id': requestId});
      expect(url.signedUrl, contains('token=short-lived'));
      expect(
        url.expiresAt.toUtc().toIso8601String(),
        '2026-01-01T01:00:00.000Z',
      );
    });

    test(
      'FunctionException details become a clear NiptoPrivacyException',
      () async {
        final service = _serviceWith((path, {body, method}) async {
          throw const FunctionException(
            status: 404,
            details: {
              'error': {
                'message': 'Export is unavailable or expired',
                'code': 'export_not_found',
              },
            },
          );
        }, <_Call>[]);

        expect(
          () => service.exportUrl(requestId),
          throwsA(
            isA<NiptoPrivacyException>()
                .having(
                  (error) => error.message,
                  'message',
                  'Export is unavailable or expired',
                )
                .having((error) => error.statusCode, 'statusCode', 404),
          ),
        );
      },
    );

    test('malformed responses and identifiers are rejected', () async {
      final malformed = _serviceWith((path, {body, method}) async {
        return const FunctionResponse(
          data: {
            'requests': [
              {'id': otherId},
            ],
          },
          status: 200,
        );
      }, <_Call>[]);
      expect(() => malformed.status(), throwsA(isA<NiptoPrivacyException>()));

      final invalidId = _serviceWith((path, {body, method}) async {
        return const FunctionResponse(
          data: {'request_id': 'not-a-uuid'},
          status: 200,
        );
      }, <_Call>[]);
      expect(
        () => invalidId.request(NiptoPrivacyKind.deletion),
        throwsA(isA<NiptoPrivacyException>()),
      );
      expect(
        () => invalidId.exportUrl('not-a-uuid'),
        throwsA(isA<NiptoPrivacyException>()),
      );
    });
  });
}
