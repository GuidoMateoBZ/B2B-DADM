import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'presentation/broadcast_screen.dart';
import 'presentation/chat_screen.dart';
import 'presentation/home_screen.dart';
import 'providers/chat_provider.dart';
import 'providers/nearby_provider.dart';
import 'providers/node_id_provider.dart';
import 'services/local_notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final launchedFromNotification = await localNotificationService.initialize();
  runApp(const MyApp());
  if (launchedFromNotification) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initialPayload = localNotificationService.initialPayload;
      if (initialPayload == 'all') {
        localNotificationService.openBroadcast();
      } else if (initialPayload != null && initialPayload.isNotEmpty) {
        localNotificationService.openChat(initialPayload);
      } else {
        localNotificationService.openChat();
      }
    });
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => NodeIdProvider()..loadId(),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider()..loadConversations(),
        ),
        ChangeNotifierProxyProvider<ChatProvider, NearbyProvider>(
          create: (_) => NearbyProvider(),
          update: (_, chatProvider, nearbyProvider) =>
              (nearbyProvider ?? NearbyProvider())..setChatProvider(chatProvider),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'B2B',
        navigatorKey: appNavigatorKey,
        navigatorObservers: [appNavigationObserver],
        routes: {
          '/': (_) => const HomeScreen(),
          chatRouteName: (_) => const ChatScreen(),
          broadcastRouteName: (_) => const BroadcastScreen(),
        },
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
      ),
    );
  }
}
