import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _formKey = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _message = TextEditingController();
  String _category = 'experience';
  int? _rating;
  bool _submitting = false;
  late Future<List<Map<String, dynamic>>> _history;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _history = _loadHistory();
  }

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _loadHistory() async {
    final rows = await _client
        .from('user_feedback')
        .select('id, category, subject, status, created_at')
        .order('created_at', ascending: false)
        .limit(20);
    return (rows as List).map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    setState(() => _submitting = true);
    try {
      await _client.from('user_feedback').insert({
        'user_id': userId,
        'category': _category,
        'rating': _rating,
        'subject': _subject.text.trim(),
        'message': _message.text.trim(),
        'platform': 'android',
      });
      if (!mounted) return;
      _subject.clear();
      _message.clear();
      setState(() {
        _rating = null;
        _history = _loadHistory();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you. Your feedback has been received.')),
      );
    } on PostgrestException catch (error) {
      if (!mounted) return;
      final message = error.message.contains('Feedback limit reached')
          ? 'You have reached the feedback limit for today. Please try again later.'
          : 'Feedback could not be sent. Check your connection and try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Feedback could not be sent. Check your connection and try again.')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _categoryLabel(String value) {
    switch (value) {
      case 'bug':
        return 'Report a problem';
      case 'idea':
        return 'Suggest a feature';
      case 'support':
        return 'Account or support';
      default:
        return 'App experience';
    }
  }

  String _statusLabel(String value) {
    switch (value) {
      case 'reviewing':
        return 'Being reviewed';
      case 'planned':
        return 'Planned';
      case 'resolved':
        return 'Resolved';
      case 'closed':
        return 'Closed';
      default:
        return 'Received';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback & support')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Text(
            'Help us make Nipto better.',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: NiptoColors.ink),
          ),
          const SizedBox(height: 6),
          const Text(
            'Share an idea, report a problem or tell us how the app is working for you.',
            style: TextStyle(color: NiptoColors.muted, height: 1.45),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('What is this about?', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: _category,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'experience', child: Text('App experience')),
                        DropdownMenuItem(value: 'bug', child: Text('Report a problem')),
                        DropdownMenuItem(value: 'idea', child: Text('Suggest a feature')),
                        DropdownMenuItem(value: 'support', child: Text('Account or support')),
                      ],
                      onChanged: _submitting ? null : (value) {
                        if (value != null) setState(() => _category = value);
                      },
                    ),
                    const SizedBox(height: 18),
                    const Text('Rate your experience (optional)', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(
                      children: List.generate(5, (index) {
                        final value = index + 1;
                        final selected = (_rating ?? 0) >= value;
                        return IconButton(
                          tooltip: '$value out of 5',
                          onPressed: _submitting ? null : () => setState(
                            () => _rating = _rating == value ? null : value,
                          ),
                          icon: Icon(
                            selected ? Icons.star_rounded : Icons.star_outline_rounded,
                            color: selected ? NiptoColors.coral : NiptoColors.muted,
                            size: 30,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _subject,
                      maxLength: 100,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Subject',
                        hintText: 'A short summary',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final text = value?.trim() ?? '';
                        if (text.length < 3) return 'Enter at least 3 characters.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _message,
                      minLines: 4,
                      maxLines: 7,
                      maxLength: 4000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Tell us more',
                        hintText: 'Describe what happened or what you would like to see…',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final text = value?.trim() ?? '';
                        if (text.length < 10) return 'Please provide at least 10 characters.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send_rounded),
                        label: Text(_submitting ? 'Sending…' : 'Send feedback'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Your feedback', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _history,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return TextButton(
                  onPressed: () => setState(() => _history = _loadHistory()),
                  child: const Text('Could not load feedback history. Retry'),
                );
              }
              final rows = snapshot.data ?? [];
              if (rows.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Your submitted feedback will appear here.', style: TextStyle(color: NiptoColors.muted)),
                );
              }
              return Card(
                child: Column(
                  children: rows.map((row) {
                    final category = row['category'] as String? ?? 'experience';
                    final status = row['status'] as String? ?? 'received';
                    final subject = row['subject'] as String? ?? 'Feedback';
                    return ListTile(
                      leading: const Icon(Icons.chat_bubble_outline_rounded, color: NiptoColors.violet),
                      title: Text(subject, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_categoryLabel(category)),
                      trailing: Text(
                        _statusLabel(status),
                        style: const TextStyle(color: NiptoColors.muted, fontSize: 11),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          const Text(
            'Please do not include passwords, verification codes or sensitive personal information in feedback.',
            style: TextStyle(color: NiptoColors.muted, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}
