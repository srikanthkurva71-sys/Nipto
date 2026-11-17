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