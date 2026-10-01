import 'package:app/presentation/home_screen.dart';
import 'package:app/presentation/chat_screen.dart';
import 'package:app/providers/nearby_provider.dart';
import 'package:app/providers/node_id_provider.dart';
import 'package:app/services/local_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final launchedFromNotification = await localNotificationService.initialize();
  runApp(const MyApp());
  if (launchedFromNotification) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      localNotificationService.openChat();
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
          create: (_) => NearbyProvider(),
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
        },
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        ),
      ),
    );
  }
}
