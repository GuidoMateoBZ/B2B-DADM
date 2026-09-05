# Guía: Nearby Connections en B2B-DADM

Documento de referencia para integrar mensajería por BLE usando Google Nearby Connections.

---

## 1. El Paquete: `nearby_connections` (v4.3.0)

**¿Qué es?** Un wrapper de Flutter sobre la API nativa [Google Nearby Connections](https://developers.google.com/nearby/connections/overview) para Android. Permite comunicación peer-to-peer **completamente offline** entre dispositivos usando Bluetooth y/o Wi-Fi.

**¿Por qué este y no BLE directo (`flutter_blue_plus`)?**
- BLE directo sirve para conectar con hardware/periféricos (sensores, ESP32). Requiere implementar un protocolo GATT propio, manejar MTU (~512 bytes por escritura), y no tiene concepto de "descubrir otra app".
- `nearby_connections` abstrae todo eso: descubrimiento de dispositivos, negociación de conexión, y envío de datos (bytes o archivos) entre dos apps iguales.

**Limitaciones:**
- **Solo Android.** No tiene soporte iOS. Para iOS habría que evaluar `nearby_service` (usa Multipeer Connectivity de Apple) o una solución BLE directa.
- **No funciona en emuladores.** Se necesitan dispositivos Android físicos con Bluetooth real.
- **Requiere GPS encendido.** Android vincula el escaneo BLE con la ubicación. Si el GPS está apagado, el discovery puede fallar silenciosamente o desconectarse.

**Pub.dev:** https://pub.dev/packages/nearby_connections  
**Repo:** https://github.com/mannprerak2/nearby_connections

---

## 2. Configuración Android Necesaria

### 2.1. `android/app/build.gradle.kts`

El `minSdk` debe ser **al menos 24** (Android 7.0). El `compileSdk` debe ser **al menos 33** para acceder a los permisos modernos de Bluetooth.

```kotlin
// Actualmente el archivo usa flutter.minSdkVersion y flutter.compileSdkVersion.
// Si los defaults de Flutter son suficientes, no hace falta cambiar nada.
// Si no, hardcodear:
minSdk = 24            // en lugar de flutter.minSdkVersion
compileSdk = 34        // en lugar de flutter.compileSdkVersion
```

### 2.2. `android/app/src/main/AndroidManifest.xml`

Agregar estos permisos **antes** del tag `<application>`:

```xml
<!-- ========== Nearby Connections: Bluetooth ========== -->

<!-- Android ≤ 11 (API 30): permisos legacy de Bluetooth -->
<uses-permission android:maxSdkVersion="30" android:name="android.permission.BLUETOOTH" />
<uses-permission android:maxSdkVersion="30" android:name="android.permission.BLUETOOTH_ADMIN" />

<!-- Android 12+ (API 31): permisos granulares de Bluetooth -->
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />

<!-- ========== Nearby Connections: Wi-Fi ========== -->

<!-- Android ≤ 12 (API 31) -->
<uses-permission android:maxSdkVersion="31" android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:maxSdkVersion="31" android:name="android.permission.CHANGE_WIFI_STATE" />

<!-- Android 13+ (API 33) -->
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />

<!-- ========== Nearby Connections: Ubicación ========== -->

<!-- Requerida porque el escaneo BLE puede revelar ubicación -->
<uses-permission android:maxSdkVersion="28" android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

**¿Por qué tantos permisos?**
- Android fue fragmentando los permisos de Bluetooth a lo largo de las versiones. Los `maxSdkVersion` aseguran que solo se piden en las versiones donde aplican.
- `ACCESS_FINE_LOCATION` es obligatorio porque Android considera que el escaneo BLE puede usarse para triangular la posición del usuario.
- Sin estos permisos, la API falla silenciosamente o lanza excepciones de plataforma.

### 2.3. Permisos en Runtime

Estos son "dangerous permissions": no basta declararlos en el Manifest, hay que pedirlos al usuario con un diálogo en tiempo de ejecución. Para eso se usa el paquete `permission_handler`.

```dart
// Ejemplo de solicitud de permisos
import 'package:permission_handler/permission_handler.dart';

Future<bool> requestNearbyPermissions() async {
  final statuses = await [
    Permission.location,
    Permission.bluetooth,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.bluetoothScan,
    Permission.nearbyWifiDevices,
  ].request();

  return statuses.values.every((s) => s.isGranted);
}
```

---

## 3. Dependencias a Agregar en `pubspec.yaml`

```yaml
dependencies:
  nearby_connections: ^4.3.0    # API de Nearby Connections
  permission_handler: ^11.0.0   # Solicitud de permisos en runtime
```

---

## 4. Conceptos Clave de Nearby Connections

### 4.1. Estrategia

La estrategia define la topología de conexión. Se elige al iniciar advertising/discovery.

| Estrategia | Topología | Uso ideal |
|---|---|---|
| `P2P_CLUSTER` | Muchos ↔ Muchos (mesh) | **La que necesitamos.** Cada nodo puede ser advertiser y discoverer a la vez. Permite múltiples conexiones simultáneas. |
| `P2P_STAR` | 1 ↔ Muchos (hub-spoke) | Un host central con N clientes |
| `P2P_POINT_TO_POINT` | 1 ↔ 1 | Solo 2 dispositivos |

**Para B2B-DADM usamos `P2P_CLUSTER`** porque necesitamos que cada dispositivo pueda conectarse con varios vecinos simultáneamente (requisito para enrutamiento multi-hop).

### 4.2. Roles: Advertiser y Discoverer

- **Advertiser:** "Estoy acá, me llamo X, buscame"
- **Discoverer:** "¿Hay alguien cerca?"

En nuestra app, **cada dispositivo hace ambas cosas** al mismo tiempo para poder descubrirse mutuamente.

### 4.3. Service ID

Un string que identifica tu app de forma única (ej: `"com.b2b.dadm"`). Solo dispositivos con el mismo Service ID se ven entre sí.

### 4.4. Flujo de Conexión

```
1. Ambos dispositivos: startAdvertising() + startDiscovery()
2. Dispositivo A descubre B → onEndpointFound(idB)
3. A solicita conexión → Nearby().requestConnection(userName, idB, ...)
4. B recibe → onConnectionInitiated(idA, info)
5. Ambos aceptan → Nearby().acceptConnection(id, onPayloadReceived: ...)
6. onConnectionResult(id, Status.CONNECTED) en ambos
7. Ya pueden enviarse datos con sendBytesPayload()
```

### 4.5. Enviar y Recibir Texto

```dart
// ENVIAR: String → bytes
final bytes = Uint8List.fromList(utf8.encode("Hola!"));
Nearby().sendBytesPayload(endpointId, bytes);

// RECIBIR: bytes → String (en el callback de acceptConnection)
onPayloadReceived: (endpointId, payload) {
  final text = utf8.decode(payload.bytes!);
}
```

---

## 5. Arquitectura Propuesta

### 5.1. Estructura de Archivos

```
lib/
├── data/
│   ├── node_id_storage.dart           # Ya existe - UUID persistente
│   └── nearby_service.dart            # NUEVO - Wrapper de la API Nearby
├── providers/
│   ├── node_id_provider.dart          # Ya existe - Expone el Node ID
│   └── nearby_provider.dart           # NUEVO - Estado reactivo de Nearby
├── presentation/
│   ├── home_screen.dart               # MODIFICAR - Agregar botón al chat
│   └── chat_screen.dart               # NUEVO - UI de descubrimiento + chat
└── main.dart                          # MODIFICAR - Registrar NearbyProvider
```

### 5.2. Capa de Datos: `NearbyService`

Encapsula toda la interacción con `Nearby()`. Ningún widget ni provider importa `package:nearby_connections` directamente.

**Responsabilidades:**
- `startAdvertising(nodeId)` / `stopAdvertising()`
- `startDiscovery(nodeId)` / `stopDiscovery()`
- `requestConnection(endpointId)` / `acceptConnection(endpointId)`
- `sendMessage(endpointId, text)` → codifica y envía
- `disconnect(endpointId)` / `disconnectAll()`
- Expone callbacks/streams: endpoint descubierto, conexión aceptada, mensaje recibido, desconexión

### 5.3. Capa de Estado: `NearbyProvider`

Un `ChangeNotifier` que la UI observa con `context.watch<NearbyProvider>()`.

**Estado que mantiene:**
```dart
enum NearbyState { idle, searching, connecting, connected }

// Lista de endpoints descubiertos
List<DiscoveredEndpoint> discoveredEndpoints;

// Lista de endpoints conectados actualmente
List<String> connectedEndpoints;

// Historial de mensajes
List<ChatMessage> messages;

// Estado actual
NearbyState state;
```

**Métodos que expone a la UI:**
- `startSearching()` → pide permisos + advertising + discovery
- `connectTo(endpointId)` → solicita conexión
- `sendMessage(endpointId, text)` → envía texto
- `sendBroadcast(text)` → envía a todos los conectados (para SOS)
- `stopSearching()` → detiene advertising + discovery
- `disconnect(endpointId)` / `disconnectAll()`

### 5.4. Capa de Presentación: `ChatScreen`

Dos vistas en una misma pantalla:

**Vista Discovery (estado: idle/searching):**
- Botón "Buscar Dispositivos"
- Lista de endpoints descubiertos con nombre y botón "Conectar"
- Indicador de carga

**Vista Chat (estado: connected):**
- Lista de mensajes tipo burbujas (estilo WhatsApp)
- TextField + botón enviar abajo
- Botón desconectar en el AppBar

---

## 6. Modos de Comunicación

### 6.1. Chat 1-a-1 con Multi-Hop

**Objetivo:** Dispositivo A quiere chatear con Dispositivo C, pero C está fuera de rango. Dispositivo B está en rango de ambos y actúa como intermediario.

```
A ←BLE→ B ←BLE→ C
```

**Implementación a nivel de la app (routing por aplicación):**
- Nearby Connections NO tiene routing multi-hop nativo. Cada conexión es punto-a-punto.
- El multi-hop se implementa en la capa de aplicación: cuando B recibe un mensaje destinado a C, lo reenvía.
- Cada mensaje necesita un header con: `{from: nodeIdA, to: nodeIdC, payload: "texto", ttl: N}`
- Cada nodo mantiene una tabla de vecinos conocidos (endpoints conectados) y reenvía mensajes que no son para él.
- El TTL (time-to-live) evita loops infinitos: se decrementa en cada salto.

**Formato de mensaje para multi-hop:**
```dart
class RoutedMessage {
  final String messageId;   // UUID para deduplicación
  final String fromNodeId;  // Origen real del mensaje
  final String toNodeId;    // Destino final
  final String text;
  final int ttl;            // Se decrementa en cada salto
}

// Serializar a JSON → utf8.encode → sendBytesPayload
// Recibir: utf8.decode → JSON.decode → verificar si toNodeId == yo
//   Sí → mostrar mensaje
//   No → decrementar ttl, reenviar a todos los vecinos excepto el que lo envió
```

### 6.2. Broadcast Epidémico (SOS)

**Objetivo:** Un dispositivo envía un mensaje que se propaga a todos los dispositivos cercanos, y estos a su vez lo propagan a los suyos (difusión epidémica).

**Implementación:**
- Un mensaje broadcast tiene un `messageId` único (UUID) y no tiene `to` (destino)
- Cada dispositivo que lo recibe: (1) lo muestra al usuario, (2) lo reenvía a todos sus vecinos conectados
- Cada dispositivo mantiene un set de `messageIds` ya vistos para **no reenviar duplicados**
- El TTL limita la propagación geográfica

```dart
class BroadcastMessage {
  final String messageId;  // UUID único para deduplicar
  final String fromNodeId; // Quién originó el SOS
  final String text;
  final int ttl;           // Saltos restantes
}

// Algoritmo en cada nodo:
// 1. Recibir mensaje
// 2. ¿Ya vi este messageId? → Sí: descartar. No: continuar
// 3. Agregar messageId al set de vistos
// 4. Mostrar al usuario
// 5. Si ttl > 0: decrementar ttl, reenviar a todos los vecinos conectados
```

---

## 7. Hitos Sugeridos

### Hito 1: Chat Directo
- [ ] Configurar permisos Android (Manifest + build.gradle)
- [ ] Agregar dependencias (`nearby_connections`, `permission_handler`)
- [ ] Crear `NearbyService` con advertising, discovery, conexión, envío/recepción de bytes
- [ ] Crear `NearbyProvider` con estado reactivo
- [ ] Crear `ChatScreen` con discovery + chat 1-a-1 directo
- [ ] Probar en 2 dispositivos físicos

### Hito 2: Routing Multi-Hop
- [ ] Definir formato de mensaje con headers (`from`, `to`, `ttl`, `messageId`)
- [ ] Mantener tabla de vecinos conectados en cada nodo
- [ ] Implementar lógica de reenvío en `NearbyService`
- [ ] Implementar deduplicación de mensajes (set de IDs vistos)
- [ ] Probar con 3 dispositivos: A↔B↔C donde A y C no se ven directamente

### Hito 3: Broadcast Epidémico (SOS)
- [ ] Definir `BroadcastMessage` con `messageId` y sin destino
- [ ] Implementar flooding: reenviar a todos los vecinos excepto el remitente
- [ ] Implementar deduplicación para evitar loops
- [ ] Agregar UI de SOS (botón de emergencia, notificación especial)
- [ ] Probar con 3+ dispositivos

---

## 8. Referencia Rápida de la API

### Advertising
```dart
Nearby().startAdvertising(
  userName,                    // String visible para otros
  Strategy.P2P_CLUSTER,
  onConnectionInitiated: (id, info) { /* alguien quiere conectarse */ },
  onConnectionResult: (id, status) { /* conexión aceptada/rechazada */ },
  onDisconnected: (id) { /* se desconectó */ },
  serviceId: "com.b2b.dadm",
);
Nearby().stopAdvertising();
```

### Discovery
```dart
Nearby().startDiscovery(
  userName,
  Strategy.P2P_CLUSTER,
  onEndpointFound: (id, name, serviceId) { /* encontré un dispositivo */ },
  onEndpointLost: (id) { /* ya no lo veo */ },
  serviceId: "com.b2b.dadm",
);
Nearby().stopDiscovery();
```

### Conexión
```dart
// El que descubre solicita:
Nearby().requestConnection(userName, endpointId,
  onConnectionInitiated: ...,
  onConnectionResult: ...,
  onDisconnected: ...,
);

// Ambos lados aceptan:
Nearby().acceptConnection(endpointId,
  onPayloadReceived: (endpointId, payload) { /* datos recibidos */ },
  onPayloadTransferUpdate: (endpointId, update) { /* progreso */ },
);
```

### Envío de Datos
```dart
// Bytes (texto)
Nearby().sendBytesPayload(endpointId, Uint8List.fromList(utf8.encode("hola")));

// Archivos (futuro)
Nearby().sendFilePayload(endpointId, filePath);
```

### Desconexión
```dart
Nearby().disconnectFromEndpoint(endpointId);
Nearby().stopAllEndpoints();
```

---

## 9. Consideraciones de Testing

- **Siempre en dispositivos físicos.** Los emuladores no tienen hardware BLE.
- **GPS debe estar encendido** en ambos dispositivos.
- **Distancia:** BLE tiene alcance de ~10-30 metros en interiores, ~50-100 metros en exteriores.
- **Developer Mode en Windows:** Si desarrollás desde Windows, necesitás activar el Modo para Desarrolladores (`ms-settings:developers`) para que Flutter pueda usar symlinks de plugins.
- **Los permisos se piden una sola vez** (el usuario puede revocarlos desde Ajustes en cualquier momento, la app debe manejar ese caso).
