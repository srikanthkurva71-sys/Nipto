import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_media_service.dart';

class FakeMediaTransport implements NiptoMediaTransport {
  final List<String> calls = <String>[];
  Object? enqueueResult;
  Object? statusResult;
  Object? nextStatusResult;
  bool inspectFails = false;

  @override
  Future<Object?> enqueue(String bucket, String path) async {
    calls.add('enqueue:$bucket:$path');
    return enqueueResult;
  }

  @override
  Future<Object?> status(String bucket, String path) async {
    calls.add('status:$bucket:$path');
    if (nextStatusResult != null) {
      final result = nextStatusResult;
      nextStatusResult = null;
      return result;
    }
    return statusResult;
  }

  @override
  Future<void> inspect(String bucket, String path) async {
    calls.add('inspect:$bucket:$path');
    if (inspectFails) throw StateError('function_unavailable');
  }
}

void main() {
  group('NiptoMediaState parsing', () {
    test('parses every real server state without guessing', () {
      expect(NiptoMediaState.parse('uploaded'), NiptoMediaState.uploaded);
      expect(NiptoMediaState.parse('queued'), NiptoMediaState.queued);
      expect(NiptoMediaState.parse('scanning'), NiptoMediaState.scanning);
      expect(NiptoMediaState.parse('clean'), NiptoMediaState.clean);
      expect(
        NiptoMediaState.parse('needs_review'),
        NiptoMediaState.needsReview,
      );
      expect(NiptoMediaState.parse('processing'), NiptoMediaState.processing);
      expect(NiptoMediaState.parse('ready'), NiptoMediaState.ready);
      expect(NiptoMediaState.parse('rejected'), NiptoMediaState.rejected);
      expect(NiptoMediaState.parse('failed'), NiptoMediaState.failed);
    });

    test('unknown and missing states never imply approval', () {
      expect(NiptoMediaState.parse('approved'), NiptoMediaState.unknown);
      expect(NiptoMediaState.parse(null), NiptoMediaState.unknown);
      expect(NiptoMediaState.unknown.isApproved, isFalse);
      expect(NiptoMediaState.needsReview.isApproved, isFalse);
      expect(NiptoMediaState.processing.isApproved, isFalse);
      expect(NiptoMediaState.clean.isApproved, isTrue);
      expect(NiptoMediaState.ready.isApproved, isTrue);
    });
  });

  group('NiptoMediaStatus.fromRpc', () {
    test('reads real fields from the status RPC', () {
      final status = NiptoMediaStatus.fromRpc({
        'bucket': 'shorts',
        'path': 'owner/1700000000123456.mp4',
        'state': 'processing',
        'mime': 'video/mp4',
        'size': 1234,
        'sha256': 'abc',
        'attempts': '2',
        'last_error': null,
        'thumbnail_path': 'owner/thumb.jpg',
        'rendition_path': null,
        'updated_at': '2026-11-27T00:00:00Z',
      });
      expect(status.exists, isTrue);
      expect(status.state, NiptoMediaState.processing);
      expect(status.state.isSettled, isFalse);
      expect(status.mime, 'video/mp4');
      expect(status.size, 1234);
      expect(status.attempts, 2);
      expect(status.thumbnailPath, 'owner/thumb.jpg');
      expect(status.pendingLabel, 'Processing');
    });

    test('absent or malformed rows stay unknown', () {
      expect(NiptoMediaStatus.fromRpc(null).exists, isFalse);
      expect(NiptoMediaStatus.fromRpc(null).state, NiptoMediaState.unknown);
      expect(NiptoMediaStatus.fromRpc('clean').state, NiptoMediaState.unknown);
      expect(
        NiptoMediaStatus.fromRpc({'state': null}).state,
        NiptoMediaState.unknown,
      );
    });
  });

  group('NiptoMediaService', () {
    test(
      'enqueues, invokes real validation and reports server state',
      () async {
        final transport = FakeMediaTransport()
          ..statusResult = {
            'bucket': 'posts',
            'path': 'owner/1700000000123456.jpg',
            'state': 'needs_review',
          };
        final service = NiptoMediaService(transport: transport);

        final result = await service.enqueue(
          'posts',
          'owner/1700000000123456.jpg',
        );

        expect(transport.calls, [
          'enqueue:posts:owner/1700000000123456.jpg',
          'inspect:posts:owner/1700000000123456.jpg',
          'status:posts:owner/1700000000123456.jpg',
        ]);
        expect(result.state, NiptoMediaState.needsReview);
        expect(result.pendingLabel, 'Awaiting human review');
      },
    );

    test('function failure leaves the queued asset honest', () async {
      final transport = FakeMediaTransport()
        ..inspectFails = true
        ..statusResult = {'state': 'queued'};
      final service = NiptoMediaService(transport: transport);

      final result = await service.enqueue(
        'statuses',
        'owner/1700000000123456.mp4',
      );

      expect(result.state, NiptoMediaState.queued);
      expect(result.isApprovedForDisplay, isFalse);
    });

    test('poll stops on server-reported settled states', () async {
      final transport = FakeMediaTransport()
        ..nextStatusResult = {'state': 'scanning'}
        ..statusResult = {'state': 'rejected', 'last_error': 'magic_mismatch'};
      final service = NiptoMediaService(transport: transport);

      final result = await service.poll(
        'posts',
        'owner/1700000000123456.jpg',
        interval: Duration.zero,
      );

      expect(result.state, NiptoMediaState.rejected);
      expect(result.lastError, 'magic_mismatch');
      expect(
        transport.calls.where((call) => call.startsWith('status:')).length,
        2,
      );
    });
  });
}

extension on NiptoMediaStatus {
  bool get isApprovedForDisplay => state.isApproved;
}
