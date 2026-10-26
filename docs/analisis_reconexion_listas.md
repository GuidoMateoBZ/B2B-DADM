# Reconexión tras un cambio de medio: por qué los nodos no se vuelven a encontrar

> **Objetivo:** explicar por qué, después de un cambio de medio (modo avión), un vecino desconectado no se vuelve a conectar aunque el advertising y el discovery sigan activos. Incluye la solución parcial ya implementada y las alternativas, para decidir cómo seguir.
>
> **Base:** logs de `adb logcat` del celular que activó el modo avión (SM‑A256E, Android 16), prueba del 23/10/2026 a las 21:06, y el código actual de `app/lib/providers/nearby_provider.dart`.

---

## 1. Resumen

- Nearby **no** reporta de forma continua a quién ve: avisa con `onEndpointFound` **una sola vez** por endpoint y no lo repite mientras ese endpoint siga anunciándose.
- La app **solo** intenta conectarse dentro de `onEndpointFound`.
- Cuando un enlace se cae y el par sigue en rango, Nearby no emite `onEndpointLost` ni un nuevo `onEndpointFound`. Por eso **nadie vuelve a pedir la conexión**.
- Las listas de vecinos de la app empeoran el problema: al conectarse, el par sale de la lista de descubiertos, y al desconectarse no vuelve a entrar. La app "olvida" que lo sigue viendo.
- La solución parcial actual (reiniciar el discovery tras una caída) todavía **no se validó en dispositivos** y además actúa también en el dispositivo que no tuvo el cambio. Se proponen alternativas en la §6.

---

## 2. Cómo informa Nearby a quién ve

El discovery es un **flujo de eventos**, no una consulta periódica:

| Evento | Cuándo lo emite Nearby |
|---|---|
| `onEndpointFound(id, nombre)` | La primera vez que ve un endpoint en esta sesión de discovery |
| `onEndpointLost(id)` | Cuando deja de ver ese endpoint (por ejemplo, porque se alejó) |
| *(nada)* | Mientras el endpoint siga visible, aunque la conexión con él se haya caído |

Para que Nearby vuelva a emitir `onEndpointFound` de un endpoint que sigue en rango hay solo dos caminos:

1. que antes emita `onEndpointLost` (el par se aleja y vuelve), o
2. que se reinicie el discovery (`stopDiscovery` → `startDiscovery`), lo que borra lo ya reportado.

**Por eso funcionaba la prueba de "fuera de rango y vuelta":** al alejarse llega `onEndpointLost`; al volver, un `onEndpointFound` nuevo, y ahí se dispara la auto‑conexión.

### 2.1. Cuándo llega `onEndpointLost`

Lo emite el **discovery** de un dispositivo cuando deja de ver un endpoint que antes reportó. Depende de que el par **deje de anunciarse**, no de que se corte la conexión.

| Situación | ¿Llega `onEndpointLost`? | ¿A quién? |
|---|---|---|
| El par se aleja fuera de rango | Sí | A los que lo estaban viendo |
| El par **deja de anunciarse** (`stopAdvertising`, `stopAll`, cierra la app, apaga el Bluetooth) | Sí, tras unos segundos | A los que lo estaban viendo |
| El par reinicia el advertising y cambia de `endpointId` | Sí, del `endpointId` viejo | A los que lo estaban viendo |
| Se cae el **enlace** pero el par sigue anunciándose (el caso del modo avión) | **No** | A nadie |
| Desconexión de un solo vecino (`disconnectFromEndpoint`, botón del modal de vecinos) | **No**: el advertising sigue | A nadie |
| El propio dispositivo detiene su discovery (`stopDiscovery`, `stopAll`) | **No**: sin discovery no hay eventos | Al propio dispositivo no le llega nada |

El último caso explica por qué se vacía `_discoveredEndpoints` en los reinicios: al detener el discovery, Nearby no avisa la pérdida de lo que ya había reportado.

### 2.2. Qué pasa con el botón Desconectar (`stopSearching` → `stopAll`)

| Dispositivo | `onDisconnected` | `onEndpointLost` |
|---|---|---|
| El que pulsa el botón | **Sí**, de cada vecino. En el log de las 21:05:56, a `stopAllEndpoints` le siguen `ad.onDisconnected AMHR` y `ad.onDisconnected WOVK` | **No**: su propio discovery se detuvo en la misma llamada |
| Sus pares | Sí, se cerró la conexión | **Sí**, del dispositivo, porque dejó de anunciarse |

**Por eso Desconectar → Conectar siempre funcionaba:** al pulsar Conectar, el dispositivo arranca un discovery nuevo y recibe `onEndpointFound` de todos. Los pares, que ya lo habían "perdido", reciben un `onEndpointFound` nuevo cuando vuelve a anunciarse. Los dos lados vuelven a pasar por la auto‑conexión. En un cambio de medio, en cambio, nadie deja de anunciarse, así que no hay ni pérdida ni reencuentro.

### 2.3. Observación: Nearby parece postergar la pérdida mientras hay conexión

En los logs de las 21:02:52:

```
dis.onDisconnected 8VPF
onEndpointLost 8VPF        ← 50 ms después
```

`8VPF` era un `endpointId` viejo del nodo `d39e7ff0`, que ya se anunciaba como `WOVK`. Que el `onEndpointLost` llegue pegado al `onDisconnected` sugiere que Nearby **no emite la pérdida de un endpoint mientras hay una conexión activa con él**, y la emite recién al cortarse. No está documentado por Nearby: se deduce de este único caso y conviene confirmarlo (§7).

---

## 3. Las listas de vecinos

Hay **dos vistas** del vecindario: la interna de Nearby, que la app no puede consultar, y las listas propias de la app.

### 3.1. Vista de Nearby (interna)

| Concepto | Qué contiene |
|---|---|
| Endpoints vistos | Los que reportó con `onEndpointFound` y que todavía no reportó con `onEndpointLost` |
| Endpoints conectados | Los enlaces activos |

La app no tiene acceso a estas listas; solo se entera de los cambios por los eventos.

### 3.2. Listas de la app (`NearbyProvider`)

| Lista | Tipo | Qué representa | Dónde cambia |
|---|---|---|---|
| `_discoveredEndpoints` | `List<DiscoveredEndpoint>` | Pares **vistos y no conectados** | **Se agrega** en `_onEndpointFound` (`:320`) solo si **no** está conectado. **Se quita** en `_onEndpointLost` (`:362`) y al conectarse en `_onConnectionResult` (`:405`). **Se vacía** en los reinicios (`:156`, `:543`, `:556`, `:604`, `:628`). |
| `_connectedEndpoints` | `Map<endpointId, nodeId>` | Vecinos **conectados** | **Se agrega** en `_onConnectionResult` (`:403`). **Se quita** en `_onDisconnected` (`:419`) y en la deduplicación (`:397`). |
| `_connectingEndpoints` | `Set<endpointId>` | Solicitudes de conexión en curso | Auxiliar |
| `_endpointNames` | `Map<endpointId, nodeId>` | Node ID de cada endpoint | Auxiliar; se borra en `_onDisconnected` |

**El hueco:** un par pasa de `_discoveredEndpoints` a `_connectedEndpoints` al conectarse, pero **al desconectarse no vuelve** a `_discoveredEndpoints`. Queda fuera de las dos listas, aunque Nearby lo siga viendo:

```
           onEndpointFound                 onConnectionResult(CONNECTED)
(nada) ───────────────────▶ descubiertos ─────────────────────────────▶ conectados
  ▲                                                                         │
  └──────────────────────────── onDisconnected ─────────────────────────────┘
                     (vuelve a "nada", no a descubiertos)
```

Aunque la lista estuviera bien, **nada la recorre para conectar**: el único disparador de la auto‑conexión es `_onEndpointFound` (`:312`).

---

## 4. Caso real: modo avión con un vecino por Wi‑Fi y otro por Bluetooth

**Nodos:**
- **A:** el celular que activa el modo avión. Su ID es el menor de los tres, así que nunca es el iniciador primario.
- **B:** endpoint `WOVK`, Node ID `d39e7ff0…`, conectado por **Wi‑Fi**.
- **C:** endpoint `AMHR`, Node ID `f606c69c…`, conectado por **Bluetooth**.

### 4.1. Línea de tiempo (logs del celular A)

```
21:06:19  Medios: wifi=false, airplane=true        ← modo avión ON (Bluetooth sigue encendido)
21:06:23  Medios -> MediaDecision.softRestart       ← tras 3 s de estabilidad; hay 2 vecinos
21:06:23  stopAdvertising / startAdvertising
21:06:24  stopDiscovery / startDiscovery
21:06:26  onEndpointFound WOVK (d39e7ff0-7ea0)      ← todavía figura conectado: no se hace nada
21:06:26  onEndpointFound AMHR (f606c69c-f11d)      ← conectado: no se hace nada
21:06:28  onDisconnected WOVK                       ← el enlace Wi‑Fi recién cae acá (~9 s después)
          (no hay más eventos: ni onEndpointLost ni onEndpointFound de WOVK)
```

### 4.2. Estado de las listas en cada momento

| Momento | Nearby: vistos | Nearby: conectados | `_discoveredEndpoints` | `_connectedEndpoints` |
|---|---|---|---|---|
| Antes de 21:06:19 | WOVK, AMHR | WOVK (Wi‑Fi), AMHR (BT) | *(vacía)* | `{WOVK: d39e…, AMHR: f606…}` |
| 21:06:23 reinicio suave | *(se borra lo reportado)* | WOVK, AMHR | *(vacía; se vacía en el reinicio)* | `{WOVK, AMHR}` |
| 21:06:26 `onEndpointFound` ×2 | WOVK, AMHR | WOVK, AMHR | *(vacía; no se agregan porque están conectados)* | `{WOVK, AMHR}` |
| **21:06:28 `onDisconnected WOVK`** | **WOVK**, AMHR | AMHR | **(vacía: WOVK no vuelve)** | `{AMHR}` |
| Después | WOVK, AMHR (ya reportados, sin eventos nuevos) | AMHR | *(vacía)* | `{AMHR}` |

A partir de 21:06:28:

- **Nearby** sigue viendo a WOVK, pero ya lo reportó y no lo va a reportar de nuevo.
- **La app** no tiene a WOVK en ninguna lista y no tiene ningún evento que la lleve a conectarse.
- **El control de seguridad** (cada 60 s) no actúa, porque solo lo hace con **0 vecinos** y AMHR sigue conectado.

El resultado coincide con lo observado: A queda conectado solo con C por Bluetooth y nunca recupera a B.

### 4.3. Por qué el reinicio por medios no alcanzó

El reinicio por cambio de medios ocurre **3 s después del último evento de medios**, pero el enlace Wi‑Fi tardó **~9 s** en caer. El reinicio llegó **antes** de la caída y, cuando la caída ocurrió, ya no quedaba nada que provocara un nuevo `onEndpointFound`.

---

## 5. Solución parcial implementada (sin validar en dispositivos)

**Qué hace:** cuando llega un `onDisconnected` **involuntario** (no por el botón de desconectar), 2 s después se reinicia **solo el discovery**. No toca el advertising ni los enlaces vivos. Así Nearby vuelve a emitir `onEndpointFound` del par y se aplica la lógica normal del iniciador: el ID mayor pide la conexión al instante y el menor la pide con el fallback de 8 s.

**Dónde:** `_onDisconnected` → `_scheduleRediscovery` → `_rediscover` (`nearby_provider.dart:416-447`).

**Línea de tiempo esperada en el caso real:**

```
21:06:28  onDisconnected WOVK
21:06:30  A reinicia discovery → onEndpointFound WOVK → A es el menor → fallback 8 s
21:06:38  A pide la conexión a WOVK

En paralelo, si B también recibe onDisconnected:
21:06:30  B reinicia discovery → onEndpointFound de A → B es el mayor → pide la conexión al instante
```

**Observaciones:**

| Punto | Detalle |
|---|---|
| ⚠️ Actúa también en el dispositivo que **no** tuvo el cambio | Cualquier dispositivo que reciba una caída involuntaria reinicia su discovery. Contradice el criterio de que "solo reinicia quien cambió". |
| ⚠️ Desconexión manual | El par recibe la caída sin poder distinguirla de una involuntaria; si su ID es mayor, vuelve a conectarse. |
| Ataca el síntoma, no el hueco de las listas | La app sigue olvidando al par; se depende de que Nearby lo vuelva a reportar. |
| Costo | Un reinicio de discovery (~1 s) por caída, agrupando las caídas que llegan juntas. |

---

## 6. Alternativas

### Opción A: mantener la solución actual

Reiniciar el discovery tras cualquier caída involuntaria, en todos los dispositivos (§5).

### Opción B (propuesta): corregir las listas y conectar sin reiniciar el discovery

Mientras Nearby no emita `onEndpointLost`, el `endpointId` del par **sigue siendo válido** para `requestConnection`. Entonces, ante una caída involuntaria:

1. Volver a poner al par en `_discoveredEndpoints`, usando el `endpointId` y el Node ID que ya teníamos (hay que leer `_endpointNames` **antes** de borrarlo).
2. Aplicar la misma lógica del iniciador que en `_onEndpointFound`: el ID mayor pide la conexión al instante y el menor programa el fallback de 8 s.
3. Si llega `onEndpointLost`, se cancela todo como hoy, porque el par realmente se fue.
4. Solo si `requestConnection` falla porque Nearby ya no reconoce el endpoint, reiniciar el discovery una vez, como respaldo.

**Línea de tiempo esperada en el caso real:**

```
21:06:28  A: onDisconnected WOVK → WOVK vuelve a descubiertos → A es el menor → fallback 8 s
21:06:28  B: onDisconnected de A → A vuelve a descubiertos → B es el mayor → pide la conexión al instante
21:06:36  (si B no pudo) A pide la conexión a WOVK
```

**Ventajas:**
- Cierra el hueco de las listas: la app refleja lo que Nearby realmente ve.
- **Ningún dispositivo reinicia advertising ni discovery** por una caída. Solo hay una solicitud de conexión.
- Es más rápido que la opción A (no hay reinicio de ~1 s ni espera de 2 s).
- Reutiliza la lógica del iniciador sin cambios.

**Desventajas:**
- Es, en la práctica, un **reintento de conexión tras una caída**, algo que el plan v4 había dejado para la próxima versión. Sin embargo, es un único intento por caída, no un ciclo de reintentos.
- Tiene la misma limitación con la desconexión manual que la opción A.

### Opción C: restringir la acción al dispositivo que tuvo el cambio

Cualquiera de las dos opciones anteriores, pero que actúe **solo si ese dispositivo tuvo un cambio de medios reciente** (por ejemplo, en los últimos 30 s). El otro no hace nada.

- **Ventaja:** respeta estrictamente el criterio de que solo actúa quien cambió.
- **Desventajas:**
  - Si el intento del que cambió falla, el otro no ayuda.
  - Con otro vecino conectado, el control de seguridad tampoco actúa, así que la reconexión depende de un solo intento.
  - En el caso real, A es el ID menor: la reconexión tarda siempre 8 s más.

### Comparación

| Criterio | A: actual | B: listas + conexión directa | C: solo quien cambió |
|---|---|---|---|
| ¿El dispositivo sin cambios reinicia adv/dis? | Sí (solo discovery) | **No** | No |
| ¿El dispositivo sin cambios actúa? | Sí | Sí (solo una solicitud de conexión) | No |
| Corrige las listas | No | **Sí** | Según la variante |
| Tiempo estimado en el caso real | ~2–10 s | **~0–8 s** | ~10 s, con un solo intento |
| Robustez si un intento falla | Alta (actúan ambos) | Alta (actúan ambos + respaldo) | Baja |
| Coherencia con el plan v4 ("sin reintentos") | Media | Baja (un intento por caída) | Media |
| Desconexión manual respetada en el par | No | No | Sí, salvo que el par haya cambiado de medio |

**Recomendación:** la **opción B**. Es la que ataca la causa (las listas desactualizadas y la dependencia exclusiva de `onEndpointFound`), no reinicia el advertising ni el discovery del dispositivo que no cambió y es la más rápida. La desconexión manual queda como pendiente común a todas las opciones, y se resuelve con un mensaje de despedida (próxima versión, plan §6.3).

---

## 7. Pendiente de validar

- [ ] Logs del **otro** dispositivo (B) en la misma prueba: ¿recibe `onDisconnected` cuando A activa el modo avión? Si **no** lo recibe, B queda con una conexión fantasma y solo A puede recuperar el enlace. Eso cambia el peso de la robustez en la comparación.
- [ ] Confirmar la observación de la §2.3: pulsar Desconectar en un dispositivo y medir, en sus pares, cuánto tarda el `onEndpointLost` después del `onDisconnected`.
- [ ] Con la opción elegida, repetir la prueba de 3 nodos (A↔B por Wi‑Fi, A↔C por Bluetooth, modo avión en A) y verificar en ambos dispositivos:

```
adb logcat | grep -E "NearbyService|NearbyProvider|nearby_connections"
```

---

## 8. Decisión

Se aplica la **opción B** con el condicional de `onEndpointLost`: tras una caída involuntaria el par vuelve a `_discoveredEndpoints` y se programa un único intento (ID mayor: 2 s; ID menor: 8 s) que se cancela si llega `onEndpointLost` o una conexión entrante. Respaldo: ante cualquier fallo de la reconexión (≠ `8003`) se reinicia el discovery una vez.

Para la desconexión manual de un vecino se usa la **lista de bloqueo local** (solución 1), **temporal** y sin vencimiento, hasta implementar el mensaje de despedida. La ventana de 2 s es **provisoria y hay que testearla**. Ver [2.1.1_H6_ESTADO.md](2.1.1_H6_ESTADO.md).
