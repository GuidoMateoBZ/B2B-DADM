import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'nearby_permission_handler.dart';

/// Rutas usadas al abrir notificaciones.
const chatRouteName = '/chat';
const broadcastRouteName = '/broadcast';

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

  Route<dynamic>? get currentRoute => _routes.isEmpty ? null : _routes.last;
  String? get currentRouteName => currentRoute?.settings.name;
  Object? get currentRouteArguments => currentRoute?.settings.arguments;

  /// Indica si el chat con un peer específico está activo y en primer plano.
  bool isChatVisibleFor(String peerNodeId) =>
      _lifecycleState == AppLifecycleState.resumed &&
      currentRouteName == chatRouteName &&
      currentRouteArguments == peerNodeId;

  /// Indica si la pantalla de broadcast/SOS está visible y en primer plano.
  bool get isBroadcastVisible =>
      _lifecycleState == AppLifecycleState.resumed &&
      currentRouteName == broadcastRouteName;

  /// Indica si alguna pantalla de chat está visible.
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

  static const _sosChannelId = 'sos_alerts';
  static const _sosChannelName = 'Alertas SOS';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  String? _initialPayload;

  String? get initialPayload => _initialPayload;

  /// Inicializa Android y devuelve si la app se abrió desde una notificación.
  Future<bool> initialize() async {
    if (!Platform.isAndroid) return false;

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == 'all') {
          openBroadcast();
        } else if (payload != null && payload.isNotEmpty) {
          openChat(payload);
        } else {
          openChat();
        }
      },
    );

    final androidImplementation = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    await androidImplementation?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Notificaciones de mensajes recibidos',
        importance: Importance.high,
      ),
    );

    await androidImplementation?.createNotificationChannel(
      const AndroidNotificationChannel(
        _sosChannelId,
        _sosChannelName,
        description: 'Alertas de emergencia SOS',
        importance: Importance.max,
      ),
    );

    _initialized = true;
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _initialPayload = launchDetails?.notificationResponse?.payload;
      return true;
    }
    return false;
  }

  /// Solicita el permiso nativo cuando la pantalla de chat lo requiere.
  Future<void> requestPermission() async {
    await PermissionService.requestNotificationPermission();
  }

  /// Publica un aviso si la app no está mostrando la conversación activa.
  Future<void> showIncomingMessage(String senderNodeId) async {
    if (!_initialized || appNavigationObserver.isChatVisibleFor(senderNodeId)) {
      return;
    }

    await _plugin.show(
      id: 0,
      title: 'Mensaje de $senderNodeId',
      body: 'Tienes un mensaje nuevo',
      payload: senderNodeId,
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

  /// Publica una alerta de emergencia SOS.
  Future<void> showSosAlert(String fromNodeId, String text) async {
    if (!_initialized || appNavigationObserver.isBroadcastVisible) return;

    await _plugin.show(
      id: 1,
      title: '🚨 SOS de $fromNodeId',
      body: text,
      payload: 'all',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _sosChannelId,
          _sosChannelName,
          channelDescription: 'Alertas de emergencia SOS',
          importance: Importance.max,
          priority: Priority.max,
        ),
      ),
    );
  }

  /// Abre el chat con [targetNodeId] sin apilarlo si ya es la ruta superior.
  void openChat([String? targetNodeId]) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    if (targetNodeId != null) {
      if (appNavigationObserver.currentRouteName == chatRouteName &&
          appNavigationObserver.currentRouteArguments == targetNodeId) {
        return;
      }
      navigator.pushNamed(chatRouteName, arguments: targetNodeId);
    } else {
      if (appNavigationObserver.currentRouteName == chatRouteName) {
        return;
      }
      navigator.pushNamed(chatRouteName);
    }
  }

  /// Abre la pantalla de SOS/Broadcast sin apilarla si ya es la superior.
  void openBroadcast() {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null ||
        appNavigationObserver.currentRouteName == broadcastRouteName) {
      return;
    }
    navigator.pushNamed(broadcastRouteName);
  }
}
