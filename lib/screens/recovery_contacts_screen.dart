import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';

class RecoveryContactsScreen extends StatefulWidget {
  const RecoveryContactsScreen({super.key, this.initialNiptoId});

  final String? initialNiptoId;

  @override
  State<RecoveryContactsScreen> createState() => _RecoveryContactsScreenState();
}

class _RecoveryContactsScreenState extends State<RecoveryContactsScreen> {
  final _niptoIdController = TextEditingController();
  bool _busy = false;
  late Future<List<Map<String, dynamic>>> _contacts;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _niptoIdController.text = widget.initialNiptoId ?? '';
    _contacts = _loadContacts();
    if (widget.initialNiptoId != null && widget.initialNiptoId!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _submitRequest());
    }
  }

  @override
  void dispose() {
    _niptoIdController.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _loadContacts() async {
    final rows = await _client.rpc('list_my_recovery_contacts');
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _contacts = _loadContacts());
    await _contacts;
  }

  Future<void> _submitRequest() async {
    if (_busy) return;
    final handle = _niptoIdController.text.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    if (!RegExp(r'^[a-z0-9_]{3,24}$').hasMatch(handle)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid Nipto ID.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await _client.rpc('request_recovery_contact', params: {'p_nipto_id': handle});
      if (!mounted) return;
      _niptoIdController.clear();
      setState(() => _contacts = _loadContacts());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recovery request sent. The other account must accept it.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_friendlyError(error))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains('up to three pending')) return 'You can have up to three pending recovery requests.';
    if (message.contains('Choose another')) return 'Choose a different Nipto account.';
    if (message.contains('could not be selected')) return 'That Nipto account is unavailable.';
    return 'The request could not be completed. Please try again.';
  }

  Future<void> _respond(String requestId, bool accept) async {
    setState(() => _busy = true);
    try {
      await _client.rpc('respond_recovery_contact', params: {
        'p_request_id': requestId,
        'p_accept': accept,
      });
      if (mounted) setState(() => _contacts = _loadContacts());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That recovery request could not be updated.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String requestId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove recovery contact?'),
        content: const Text('This will end the recovery-contact relationship for this account.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await _client.rpc('remove_recovery_contact', params: {'p_request_id': requestId});
      if (mounted) setState(() => _contacts = _loadContacts());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recovery contact could not be removed.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = NiptoSessionManager.instance.userId;
    return Scaffold(
      appBar: AppBar(title: const Text('Recovery Nipto account')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Icon(Icons.shield_outlined, size: 42, color: NiptoColors.violet),
            const SizedBox(height: 12),
            Text(
              'Choose someone you trust',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Add another Nipto account as a trusted recovery contact. They must accept your request. You can remove the contact at any time.',
              textAlign: TextAlign.center,
              style: TextStyle(color: NiptoColors.muted, height: 1.45),
            ),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    TextField(
                      controller: _niptoIdController,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.none,
                      decoration: const InputDecoration(
                        labelText: 'Recovery Nipto ID',
                        prefixText: '@',
                        hintText: 'trusted_person',
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : _submitRequest,
                        child: Text(_busy ? 'Please wait…' : 'Send recovery request'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('RECOVERY CONTACTS & REQUESTS',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: NiptoColors.muted,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                )),
            const SizedBox(height: 8),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _contacts,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Card(
                    child: ListTile(
                      title: const Text('Recovery contacts could not load'),
                      trailing: TextButton(
                        onPressed: () => setState(() => _contacts = _loadContacts()),
                        child: const Text('Retry'),
                      ),
                    ),
                  );
                }
                final rows = snapshot.data ?? [];
                if (rows.isEmpty) {
                  return const Card(
                    child: ListTile(
                      leading: Icon(Icons.person_add_alt_1_outlined),
                      title: Text('No recovery contacts yet'),
                      subtitle: Text('You can add one now or do it later.'),
                    ),
                  );
                }
                return Column(
                  children: rows.map((row) {
                    final incoming = row['recovery_user_id'] == myId;
                    final status = row['status'] as String? ?? 'pending';
                    final name = incoming
                        ? row['owner_display_name'] as String? ?? 'Nipto member'
                        : row['recovery_display_name'] as String? ?? 'Nipto member';
                    final handle = incoming
                        ? row['owner_nipto_id'] as String? ?? ''
                        : row['recovery_nipto_id'] as String? ?? '';
                    final requestId = row['request_id'] as String;
                    final subtitle = incoming
                        ? 'Requested you as a recovery contact · $status'
                        : 'Your recovery contact · $status';
                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: NiptoColors.violetSoft,
                          child: Icon(Icons.person_outline_rounded, color: NiptoColors.violet),
                        ),
                        title: Text('$name  @$handle'),
                        subtitle: Text(subtitle),
                        trailing: incoming && status == 'pending'
                            ? Wrap(
                                spacing: 0,
                                children: [
                                  IconButton(
                                    tooltip: 'Accept request',
                                    onPressed: _busy ? null : () => _respond(requestId, true),
                                    icon: const Icon(Icons.check_circle_outline, color: NiptoColors.violet),
                                  ),
                                  IconButton(
                                    tooltip: 'Decline request',
                                    onPressed: _busy ? null : () => _respond(requestId, false),
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                                ],
                              )
                            : IconButton(
                                tooltip: 'Remove recovery contact',
                                onPressed: _busy ? null : () => _remove(requestId),
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Important: a recovery contact is an additional trusted-account link, not a password-reset method yet. Password resets still use your verified email. Nipto will not let another account change your password just because it is listed here.',
              style: TextStyle(color: NiptoColors.muted, fontSize: 12, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
