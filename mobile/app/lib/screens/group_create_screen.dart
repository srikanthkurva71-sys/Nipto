import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';
import 'conversation_screen.dart';

class GroupCreateScreen extends StatefulWidget {
  const GroupCreateScreen({super.key});

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final _titleController = TextEditingController();
  final _searchController = TextEditingController();
  final Map<String, Map<String, dynamic>> _selected = {};
  List<Map<String, dynamic>> _results = [];
  Timer? _debounce;
  int _searchVersion = 0;
  bool _searching = false;
  bool _creating = false;
  String? _error;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void dispose() {
    _debounce?.cancel();
    _titleController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scheduleSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String value) async {
    final version = ++_searchVersion;
    final query = value.trim().replaceFirst('@', '').toLowerCase();
    if (query.length < 2) {
      if (mounted) {
        setState(() {
          _results = [];
          _searching = false;
          _error = null;
        });
      }
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final rows = await _client.rpc(
        'search_profiles',
        params: {'p_query': query, 'p_limit': 25},
      );
      if (!mounted || version != _searchVersion) return;
      setState(() {
        _results = (rows as List)
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        _searching = false;
      });
    } catch (_) {
      if (!mounted || version != _searchVersion) return;
      setState(() {
        _error = 'People could not be loaded. Please try again.';
        _searching = false;
      });
    }
  }

  void _toggle(Map<String, dynamic> profile) {
    final id = profile['id'] as String;
    if (_selected.containsKey(id)) {
      setState(() => _selected.remove(id));
      return;
    }
    if (_selected.length >= 49) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A group can have up to 50 people, including you.'),
        ),
      );
      return;
    }
    setState(() => _selected[id] = profile);
  }

  Future<void> _createGroup() async {
    final title = _titleController.text.trim();
    if (title.isEmpty || title.length > 80) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a group name between 1 and 80 characters.'),
        ),
      );
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose at least one person.')),
      );
      return;
    }

    setState(() => _creating = true);
    try {
      final result = await _client.rpc(
        'create_group_conversation',
        params: {'p_title': title, 'p_member_ids': _selected.keys.toList()},
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ConversationScreen(
            conversationId: result as String,
            title: title,
            subtitle: 'Group conversation',
            // Group calls require an SFU and are intentionally out of scope.
            enableCalls: false,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The group could not be created. Check the selected accounts and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  String _initials(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'N';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: Column(
              children: [
                TextField(
                  controller: _titleController,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Group name',
                    prefixIcon: Icon(Icons.groups_outlined),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchController,
                  onChanged: _scheduleSearch,
                  decoration: const InputDecoration(
                    hintText: 'Find people by Nipto ID',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ],
            ),
          ),
          if (_selected.isNotEmpty)
            SizedBox(
              height: 76,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                children: _selected.values.map((profile) {
                  final handle = profile['nipto_id'] as String? ?? '';
                  return Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Chip(
                      label: Text('@$handle'),
                      onDeleted: () => _toggle(profile),
                    ),
                  );
                }).toList(),
              ),
            ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: NiptoColors.danger),
                    ),
                  )
                : _results.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'Search for people, then select who to invite.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: NiptoColors.muted),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 60),
                    itemBuilder: (context, index) {
                      final profile = _results[index];
                      final id = profile['id'] as String;
                      final name =
                          profile['display_name'] as String? ?? 'Nipto member';
                      final handle = profile['nipto_id'] as String? ?? '';
                      final selected = _selected.containsKey(id);
                      return CheckboxListTile(
                        value: selected,
                        onChanged: (_) => _toggle(profile),
                        controlAffinity: ListTileControlAffinity.trailing,
                        secondary: CircleAvatar(
                          backgroundColor: NiptoColors.violetSoft,
                          child: Text(
                            _initials(name),
                            style: const TextStyle(
                              color: NiptoColors.violet,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        title: Text(name),
                        subtitle: Text(
                          '@$handle',
                          style: const TextStyle(color: NiptoColors.muted),
                        ),
                        activeColor: NiptoColors.violet,
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
              child: FilledButton(
                onPressed: _creating ? null : _createGroup,
                child: _creating
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'Create group (' + _selected.length.toString() + ')',
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
