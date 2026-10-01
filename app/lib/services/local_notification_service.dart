import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'nearby_permission_handler.dart';

/// Ruta única del chat, también usada al abrir una notificación.
const chatRouteName = '/chat';

/// Navegación raíz disponible desde callbacks sin `BuildContext`.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Informa qué ruta está visible y si la app está activa.
final appNavigationObserver = AppNavigationObserver();

/// Servicio compartido para permisos y notificaciones locales.
final localNotificationService = LocalNotificationService();

/// Observa la pila de rutas y el ciclo de vida de la aplicación.
class AppNavigationObserver extends NavigatorObserver
    with WidgetsBindingObserver {
  AppNavigationObserver() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Rutas activas, ordenadas desde la raíz hasta la pantalla superior.
  final List<Route<dynamic>> _routes = [];

  /// Último estado de ciclo de vida recibido por Flutter.
  AppLifecycleState _lifecycleState =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.detached;

  String? get currentRouteName =>
      _routes.isEmpty ? null : _routes.last.settings.name;

  /// Indica si el chat está arriba y la app está en primer plano.
  bool get isChatVisible =>
      _lifecycleState == AppLifecycleState.resumed &&
      currentRouteName == chatRouteName;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      final index = _routes.indexOf(oldRoute);
      if (index >= 0) {
        _routes[index] = newRoute!;
        return;
      }
    }
    if (newRoute != null) _routes.add(newRoute);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }
}

class LocalNotificationService {
  static const _channelId = 'chat_messages';
  static const _channelName = 'Mensajes';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Inicializa Android y devuelve si la app se abrió desde una notificación.
  Future<bool> initialize() async {
    if (!Platform.isAndroid) return false;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (_) => openChat(),
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: 'Notificaciones de mensajes recibidos',
            importance: Importance.high,
          ),
        );

    _initialized = true;
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    return launchDetails?.didNotificationLaunchApp ?? false;
  }

  /// Solicita el permiso nativo cuando la pantalla de chat lo requiere.
  Future<void> requestPermission() async {
    await PermissionService.requestNotificationPermission();
  }

  /// Publica un aviso si la app no está mostrando el chat activo.
  Future<void> showIncomingMessage(String senderName) async {
    if (!_initialized || appNavigationObserver.isChatVisible) return;

    await _plugin.show(
      id: 0,
      title: 'Mensaje de $senderName',
      body: 'Tienes un mensaje nuevo',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Notificaciones de mensajes recibidos',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  /// Abre el chat sin apilarlo si ya es la ruta superior.
  void openChat() {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null ||
        appNavigationObserver.currentRouteName == chatRouteName) {
      return;
    }
    navigator.pushNamed(chatRouteName);
  }
}
