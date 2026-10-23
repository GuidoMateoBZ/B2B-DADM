# Análisis: servicio en segundo plano para Nearby Connections (B2B-DADM)

Documento de estado sobre el intento de mantener la red mesh activa en Android mediante un *foreground service*, los cambios realizados, el error encontrado y las alternativas para continuar.

---

## 1. Objetivo

El objetivo era permitir que el usuario iniciara y detuviera manualmente la red mesh desde la interfaz y que, una vez iniciada, la sesión de Nearby continuara aunque la actividad de Flutter dejara de estar visible. El caso de uso prioritario es poder quitar la aplicación de la pantalla de recientes y seguir anunciando el nodo, descubriendo peers y recibiendo mensajes.

La intención de arquitectura era que el servicio Android fuera el propietario de la sesión de red, mientras la UI actuaba como control y vista del estado:

```text
UI ── comandos ──> Foreground service ──> Nearby Connections
UI <── eventos ─── Foreground service
                         │
                         ├── SQLite: guardar mensajes recibidos
                         └── notificaciones locales
```

Un *foreground service* reduce la probabilidad de que Android termine el proceso mientras la actividad no está visible y muestra una notificación persistente del servicio. No garantiza supervivencia ante un cierre forzado desde Ajustes, una detención explícita del servicio o restricciones específicas del fabricante.

## 2. Consideraciones previas

- La red existente utiliza `nearby_connections: ^4.3.0`, `serviceId = 'com.b2b.dadm'` y la estrategia `Strategy.P2P_CLUSTER`.
- Los permisos de Nearby y de notificaciones se solicitan desde la UI antes de iniciar el servicio. El servicio foreground necesita además los permisos de Android y el tipo de servicio declarado en el manifest.
- Los isolates no comparten automáticamente objetos Dart ni estado en memoria. El isolate de servicio debe crear sus propias instancias de los componentes que utiliza; los mensajes y eventos entre UI y servicio deben cruzar por un canal o por una fuente persistente compartida.
- SQLite se mantiene como fuente de verdad para el historial. La UI puede volver a consultar el almacenamiento cuando el servicio comunica que se insertó un mensaje.
- La deduplicación de mensajes de `MessageRelay` continúa en memoria. La inserción en SQLite ignora IDs ya existentes, pero después de recrear el servicio el conjunto de IDs vistos se pierde. Esto puede permitir reenvíos repetidos en ciertos escenarios de reinicio; la persistencia de esa deduplicación queda para un hito posterior.


## 3. Cambios realizados

### 3.1. Configuración y arranque

#### `app/pubspec.yaml` y `app/pubspec.lock`

Se agregó `flutter_background_service` (resuelto a la versión 5.1.0) para gestionar el servicio foreground y la comunicación entre el isolate del servicio y la UI.

#### `app/android/app/src/main/AndroidManifest.xml`

Se declararon `FOREGROUND_SERVICE` y `FOREGROUND_SERVICE_CONNECTED_DEVICE`, junto con el servicio Android de `flutter_background_service` de tipo `connectedDevice`. Este tipo representa el uso de una conexión con dispositivos cercanos. La configuración permite que el servicio continúe cuando se quita la tarea de recientes (`stopWithTask=false` en la configuración Android del plugin).

#### `app/lib/main.dart`

Antes de `runApp`, se inicializa la integración del servicio en Android. La UI y los providers se crean después, como antes.

### 3.2. Separación del estado y la sesión de red

#### `app/lib/services/background_mesh_service.dart`

Se añadió el puente de la UI al servicio. Configura el modo foreground, el canal y la notificación persistente; inicia el servicio y envía comandos como iniciar/detener la malla, conectar, desconectar y enviar un sobre. También expone streams para estado, cambios de mensajes y errores.

El punto de entrada `backgroundMeshServiceEntrypoint` inicializa los plugins para el isolate secundario y crea allí el repositorio y el controlador de red. Se guarda el Node ID activo para intentar restaurar la sesión si el servicio vuelve a crearse.

#### `app/lib/services/mesh_network_controller.dart`

Se movió a este controlador la sesión Nearby que anteriormente estaba ligada al provider: iniciar anuncio y descubrimiento, mantener vecinos, gestionar conexiones, procesar y reenviar sobres, guardar mensajes entrantes y publicar cambios/errores hacia la UI.

#### `app/lib/providers/nearby_provider.dart`

El provider pasó a ser un adaptador de UI. Solicita permisos, envía comandos al servicio y traduce los snapshots recibidos en estado observable por las pantallas. Los controles manuales de iniciar y detener siguen estando en la UI.

### 3.3. Persistencia, mensajes y notificaciones

#### `app/lib/data/message_repository.dart`

Se añadió una fachada sencilla sobre `MessageStorage`, compartida por la UI y el isolate del servicio. No depende de `ChangeNotifier` ni de widgets.

#### `app/lib/data/message_storage.dart`

La operación de inserción ahora indica si realmente insertó el mensaje. Esto permite ignorar duplicados con el mismo ID y evitar notificaciones/actualizaciones innecesarias cuando SQLite descarta la inserción.

#### `app/lib/providers/chat_provider.dart`

El provider escucha el evento de cambio de mensajes publicado por el servicio y vuelve a consultar SQLite. De ese modo, una pantalla abierta puede reflejar mensajes que el servicio guardó sin enviar el objeto del mensaje como único estado compartido.

#### `app/lib/services/local_notification_service.dart`

Se agregó la inicialización de notificaciones para el isolate de fondo y métodos para notificar mensajes y alertas SOS sin depender de navegación o `BuildContext`. El servicio también publica un evento de cambio para que la UI refresque su estado cuando está activa.

#### `app/lib/services/nearby_permission_handler.dart`

Se ajustó la solicitud de permiso de notificaciones dentro del flujo de permisos que se ejecuta desde la UI.

## 4. Flujo esperado después de la refactorización

1. El usuario toca **Conectar** en la UI.
2. La UI solicita los permisos requeridos y pide iniciar el servicio.
3. El servicio crea su propio controlador y comienza el anuncio y el descubrimiento Nearby.
4. El servicio envía snapshots de estado (buscando, conectando, conectado, endpoints) a la UI.
5. Si llega un mensaje, el controlador lo procesa, lo guarda en SQLite y emite un evento. También solicita una notificación local para mensajes directos o SOS.
6. Si la UI sigue abierta, `ChatProvider` escucha el evento y recarga los datos desde SQLite. Si no está abierta, los mensajes siguen estando disponibles en el almacenamiento; al abrir la app, se cargan desde allí.
7. El usuario toca **Desconectar** para detener Nearby y el servicio desde la UI.

El diseño intenta mantener una única sesión de Nearby, propiedad del servicio, evitando que provider y servicio compitan por anunciar o descubrir. El flujo anterior no se confirmó en un dispositivo porque la llamada nativa a Nearby falla antes de completar el inicio de la sesión.

## 5. Resultado de la ejecución y diagnóstico

La compilación de Android se completó, pero al tocar **Conectar** se produjo una excepción de plataforma cuyo mensaje indicaba:

```text
Activity must not be null
```

El mensaje apareció en las operaciones de `startAdvertising` y `startDiscovery`. La causa identificada no es un permiso faltante: `nearby_connections` 4.3.0 implementa `ActivityAware`, conserva una referencia a `Activity` al adjuntarse a ella y la usa para obtener el `ConnectionsClient`. El isolate de `flutter_background_service` crea un `FlutterEngine` dentro del servicio Android sin adjuntar una `Activity`. Registrar los plugins en ese engine no crea ni proporciona una actividad.

Por lo tanto, el plugin actual no puede iniciar Nearby desde ese contexto headless. El mismo problema puede afectar otras operaciones del wrapper que dependan de esa referencia, como aceptar conexiones, solicitar conexiones, enviar datos o detener operaciones. La implementación actual **no satisface aún** el requisito de mantener la red activa en segundo plano, aunque el APK compile.

### Validación realizada y límites

- `flutter analyze`: pasó.
- Las 16 pruebas automatizadas existentes: pasaron.
- `flutter build apk --debug`: pasó y el manifest fusionado incluye el servicio foreground de tipo `connectedDevice`.
- La prueba en dispositivo físico reveló la excepción `Activity must not be null`.
- No se validaron en dispositivo la conexión real, recepción de mensajes, notificaciones en segundo plano, cierre desde recientes ni restauración del servicio. La ruta de Nearby en el isolate de servicio falla antes de poder probar esos comportamientos.

## 6. Alternativas para continuar

### Opción A: adaptar o bifurcar `nearby_connections`

Es la alternativa más alineada con el diseño actual: conservar un único propietario de Nearby en el servicio, pero modificar el plugin Android o implementar un plugin propio para operar desde el contexto del servicio.

Aunque la propuesta de cambiar referencias de `Activity` a `Context` es una hipótesis útil para investigar, no una solución confirmada. Antes de hacer el fork hay que comprobar las firmas disponibles de `Nearby.getConnectionsClient`, los requisitos de Google Play Services para cada operación y cómo se gestionan callbacks, ciclo de vida y permisos sin una Activity. Puede no bastar con reemplazar el tipo: quizás haya que ajustar más partes del plugin o usar una implementación nativa propia.

**Ventajas:** mantiene el modelo de servicio como dueño de la sesión y podría preservar Nearby Connections y el protocolo actual.  
**Costos/riesgos:** mantener un fork, probar todas las operaciones y versiones de Android, y verificar que el plugin funcione correctamente como servicio headless.

### Opción B: reemplazar Nearby por APIs de red de menor nivel

Evaluar Wi-Fi Direct, sockets TCP/UDP u otra biblioteca que documente soporte en un servicio Android sin Activity. No se debe asumir que un paquete alternativo soporta ejecución headless: esa compatibilidad también debe verificarse en una PoC.

**Ventajas:** control directo del ciclo de vida nativo y menor dependencia de un wrapper que exige Activity.  
**Costos/riesgos:** habría que implementar o adaptar descubrimiento, negociación, transporte, reconexión y topología mesh; supone un cambio considerable de arquitectura y protocolo.

### Opción C: conservar Nearby en el isolate principal

Mantener las llamadas de Nearby en el engine asociado a la Activity y desistir, por ahora, de mover esa sesión al isolate del servicio. Se puede investigar un foreground service nativo que mantenga vivo el proceso, pero eso por sí solo no resuelve el requisito de la Activity del plugin.

**Ventajas:** es la alternativa con menor cambio para conservar el flujo Nearby existente.  
**Limitaciones:** no ofrece la garantía buscada de continuar tras quitar la actividad/tarea de recientes. `wakelock_plus` puede evitar que la pantalla o el dispositivo entren en ciertos estados de suspensión, pero no sustituye un servicio que mantenga el proceso y no resuelve la ausencia de Activity.

## 7. Recomendación y próximos pasos

Antes de refactorizar más código, conviene hacer una PoC acotada con el mismo `nearby_connections: ^4.3.0`, `serviceId` y `Strategy.P2P_CLUSTER` del proyecto:

1. Reproducir el error en un ejemplo mínimo con `flutter_background_service`.
2. Inspeccionar la API nativa exacta utilizada por `nearby_connections` y comprobar si `ConnectionsClient` puede crearse con un `Context` de servicio en la versión de Google Play Services que se usa.
3. Si es viable, implementar una prueba mínima en una rama/fork o plugin de prueba, sin modificar todavía el flujo principal de producción.
4. Validar con dos dispositivos Android físicos: iniciar el servicio, quitar la app de recientes, apagar la pantalla y comprobar descubrimiento, conexión y mensajes en ambos sentidos.
5. Probar por separado permisos, notificaciones, reconexión, detención manual y límites del sistema/fabricante.
6. Solo tras confirmar la compatibilidad, decidir si mantener el fork, crear un plugin nativo propio o migrar el transporte.


---

**Estado:** refactorización del puente UI/servicio implementada y compilable; Nearby desde el isolate headless bloqueado por la dependencia nativa actual. La decisión sobre fork/plugin nativo frente a cambio de transporte queda pendiente de la PoC.
