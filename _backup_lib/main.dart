import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/bridge_state.dart';
import 'storage/credentials_store.dart';
import 'ui/pair_page.dart';
import 'ui/sessions_page.dart';

void main() {
  runApp(const DshMobileApp());
}

class DshMobileApp extends StatelessWidget {
  const DshMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<BridgeState>(
      create: (_) => BridgeState(CredentialsStore())..bootstrap(),
      child: MaterialApp(
        title: 'DSH Mobile',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4C6FFF),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const RootGate(),
      ),
    );
  }
}

/// 未配对 → 配对页；已配对 → 会话列表。
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<BridgeState>(
      builder: (context, state, _) {
        return state.isPaired ? const SessionsPage() : const PairPage();
      },
    );
  }
}
