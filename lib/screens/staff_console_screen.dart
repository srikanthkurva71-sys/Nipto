import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';

class StaffConsoleScreen extends StatefulWidget {
  const StaffConsoleScreen({super.key});

  @override
  State<StaffConsoleScreen> createState() => _StaffConsoleScreenState();
}

class _StaffConsoleScreenState extends State<StaffConsoleScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late Future<bool> _access;
  bool _busy = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _access = _checkAccess();
  }

  Future<bool> _checkAccess() async => await _client.rpc('staff_can_access') == true;

  Future<List<Map<String, dynamic>>> _load(
    String function,
    Map<String, dynamic> params,
  ) async {
    final result = await _client.rpc(function, params: params);
    return (result as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() {});
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<String?> _askNote(String title, String hint) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLength: 2000,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Continue')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _act(Future<dynamic> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Review action saved.')),
      );
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save this review action. Check staff access and retry.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _feedback(Map<String, dynamic> row, String status) async {
    final response = await _askNote('Update feedback', 'Optional response visible to the user');
    if (response == null || !mounted) return;
    final note = await _askNote('Internal note', 'Optional staff-only note');
    if (note == null || !mounted) return;
    await _act(() => _client.rpc('staff_review_feedback', params: {
      'p_feedback_id': row['id'],
      'p_status': status,
      'p_response_message': response.isEmpty ? null : response,
      'p_staff_note': note.isEmpty ? null : note,
    }));
  }

  Future<void> _report(Map<String, dynamic> row, String status) async {
    final note = await _askNote('Review report', 'Optional resolution note');
    if (note == null || !mounted) return;
    await _act(() => _client.rpc('staff_review_report', params: {
      'p_report_id': row['id'],
      'p_status': status,
      'p_resolution_note': note.isEmpty ? null : note,
    }));
  }

  Future<void> _content(Map<String, dynamic> row, String decision) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(decision == 'approved' ? 'Approve content?' : 'Reject content?'),
        content: const Text('This decision will be recorded in the staff audit log.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final reason = await _askNote('Moderation reason', 'Optional reason recorded in the audit log');
    if (reason == null || !mounted) return;
    await _act(() => _client.rpc('staff_review_content', params: {
      'p_kind': row['content_type'],
      'p_content_id': row['content_id'],
      'p_decision': decision,
      'p_reason': reason.isEmpty ? null : reason,
    }));
  }

  Widget _queue({
    required String function,
    required Map<String, dynamic> params,
    required Widget Function(Map<String, dynamic>) cardBuilder,
    required String emptyText,
  }) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _load(function, params),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Queue could not load.'),
                TextButton(onPressed: () => setState(() {}), child: const Text('Retry')),
              ],
            ),
          );
        }
        final rows = snapshot.data ?? [];
        if (rows.isEmpty) return Center(child: Text(emptyText));
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(14),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, index) => cardBuilder(rows[index]),
          ),
        );
      },
    );
  }

  Widget _button(String label, VoidCallback callback) => OutlinedButton(
    onPressed: _busy ? null : callback,
    child: Text(label),
  );

  Widget _status(String value) => Chip(
    label: Text(value, style: const TextStyle(fontSize: 11)),
    visualDensity: VisualDensity.compact,
    backgroundColor: NiptoColors.violetSoft,
    side: BorderSide.none,
  );

  Widget _feedbackCard(Map<String, dynamic> row) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(row['subject']?.toString() ?? 'Feedback', style: const TextStyle(fontWeight: FontWeight.w800))),
            _status(row['status']?.toString() ?? 'received'),
          ]),
          Text('@' + (row['nipto_id']?.toString() ?? 'member') + ' · ' + (row['category']?.toString() ?? 'feedback')),
          const SizedBox(height: 8),
          Text(row['message']?.toString() ?? ''),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            _button('Reviewing', () => _feedback(row, 'reviewing')),
            _button('Planned', () => _feedback(row, 'planned')),
            _button('Resolved', () => _feedback(row, 'resolved')),
            _button('Closed', () => _feedback(row, 'closed')),
          ]),
        ]),
      ),
    );
  }

  Widget _reportCard(Map<String, dynamic> row) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(row['reason']?.toString() ?? 'Safety report', style: const TextStyle(fontWeight: FontWeight.w800))),
            _status(row['status']?.toString() ?? 'received'),
          ]),
          Text('Reporter: @' + (row['reporter_nipto_id']?.toString() ?? 'member')),
          Text('Reported account: @' + (row['reported_nipto_id']?.toString() ?? 'unavailable')),
          if ((row['details']?.toString() ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(row['details'].toString()),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            _button('Reviewing', () => _report(row, 'reviewing')),
            _button('Actioned', () => _report(row, 'actioned')),
            _button('Dismiss', () => _report(row, 'dismissed')),
          ]),
        ]),
      ),
    );
  }

  Widget _contentCard(Map<String, dynamic> row) {
    final kind = row['content_type']?.toString() ?? 'content';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(kind.toUpperCase() + ' · @' + (row['nipto_id']?.toString() ?? 'member'),
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text((row['caption']?.toString().isNotEmpty == true) ? row['caption'].toString() : 'No caption'),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            _button('Approve', () => _content(row, 'approved')),
            _button('Reject', () => _content(row, 'rejected')),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _access,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasError || snapshot.data != true) {
          return Scaffold(
            appBar: AppBar(title: const Text('Staff tools')),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text('Staff access is not enabled for this account.', textAlign: TextAlign.center),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Staff review'),
            bottom: TabBar(
              controller: _tabs,
              tabs: const [Tab(text: 'Feedback'), Tab(text: 'Reports'), Tab(text: 'Content')],
            ),
          ),
          body: Stack(children: [
            TabBarView(
              controller: _tabs,
              children: [
                _queue(function: 'staff_list_feedback', params: {'p_status': null, 'p_limit': 50},
                    cardBuilder: _feedbackCard, emptyText: 'No feedback is waiting for review.'),
                _queue(function: 'staff_list_reports', params: {'p_limit': 50},
                    cardBuilder: _reportCard, emptyText: 'No reports are waiting for review.'),
                _queue(function: 'staff_list_pending_content', params: {'p_kind': 'all', 'p_limit': 50},
                    cardBuilder: _contentCard, emptyText: 'No content is waiting for review.'),
              ],
            ),
            if (_busy) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
          ]),
        );
      },
    );
  }
}
