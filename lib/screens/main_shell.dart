import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';
import 'chats_screen.dart';
import 'call_screen.dart';
import 'home_feed_screen.dart';
import 'profile_screen.dart';
import 'shorts_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  late final PageController _pageController;
  int _index = 0;
  int _unreadCount = 0;
  RealtimeChannel? _notificationChannel;
  Timer? _incomingCallTimer;
  bool _incomingDialogOpen = false;
  bool _pollingIncomingCalls = false;
  final Set<String> _handledIncomingCalls = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _incomingCallTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _pollIncomingCalls(),
    );
    unawaited(_pollIncomingCalls());
    _pageController = PageController(initialPage: _index);
    _loadUnreadCount();
    _notificationChannel = Supabase.instance.client
        .channel('nipto-notifications-badge')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient_id',
            value: Supabase.instance.client.auth.currentUser!.id,
          ),
          callback: (_) => _loadUnreadCount(),
        )
        .subscribe();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_pollIncomingCalls());
    }
  }

  Future<void> _pollIncomingCalls() async {
    if (!mounted || _incomingDialogOpen || _pollingIncomingCalls ||
        Supabase.instance.client.auth.currentUser == null) {
      return;
    }
    _pollingIncomingCalls = true;
    try {
      final result = await Supabase.instance.client.rpc('list_my_incoming_calls');
      final calls = List<Map<String, dynamic>>.from(result as List);
      for (final call in calls) {
        final callId = call['call_id']?.toString();
        if (callId == null || _handledIncomingCalls.contains(callId)) continue;
        _handledIncomingCalls.add(callId);
        _incomingDialogOpen = true;
        if (!mounted) return;
        final accepted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              call['media_type'] == 'video' ? 'Incoming video call' : 'Incoming voice call',
            ),
            content: Text(
              (call['caller_display_name'] as String? ?? 'Nipto user') +
                  ' is calling you.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Accept'),
              ),
            ],
          ),
        );
        _incomingDialogOpen = false;
        if (!mounted) return;
        if (accepted == true) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CallScreen(
                callId: callId,
                mediaType: call['media_type'] as String? ?? 'audio',
                isCaller: false,
                peerTitle: call['caller_display_name'] as String? ?? 'Nipto user',
              ),
            ),
          );
        } else {
          await Supabase.instance.client.rpc(
            'decline_nipto_call',
            params: {'p_call_id': callId},
          );
        }
        return;
      }
    } catch (_) {
      // Foreground call discovery is best-effort; push wake-up is a separate release gate.
    } finally {
      _pollingIncomingCalls = false;
    }
  }

  Future<void> _loadUnreadCount() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('notifications')
          .select('id')
          .eq('recipient_id', userId)
          .isFilter('read_at', null)
          .limit(100);
      if (mounted) setState(() => _unreadCount = (rows as List).length);
    } catch (_) {
      // Badge failure must not block navigation.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingCallTimer?.cancel();
    _pageController.dispose();
    final channel = _notificationChannel;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    super.dispose();
  }

  void _selectPage(int value) {
    setState(() => _index = value);
    _pageController.animateToPage(
      value,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NiptoColors.canvas,
      appBar: null,
      body: PageView(
        controller: _pageController,
        onPageChanged: (value) => setState(() => _index = value),
        children: [
          const HomeFeedScreen(),
          const ChatsScreen(),
          const ShortsScreen(),
          ProfileScreen(unreadCount: _unreadCount),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _selectPage,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Chats',
          ),
          const NavigationDestination(
            icon: Icon(Icons.play_circle_outline_rounded),
            selectedIcon: Icon(Icons.play_circle_fill_rounded),
            label: 'Shorts',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'You',
          ),
        ],
      ),
    );
  }
}
