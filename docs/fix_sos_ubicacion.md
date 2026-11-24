# Corrección: SOS con ubicación sin señal GPS (modo avión)

Rama: `fix/sos-ubicacion-timeout` · Archivo: `app/lib/presentation/broadcast_screen.dart` (`_sendSosWithLocation`)

## Síntoma

Con el teléfono en modo avión, el botón **SOS** no enviaba nada: después de unos segundos aparecía el aviso `No se pudo obtener la ubicación: TimeoutException…` y el mensaje nunca salía a la red mesh.

## Causa

- El SOS pedía una ubicación **nueva** con `Geolocator.getCurrentPosition` (precisión alta) y un límite de 12 s. Si no llegaba a tiempo, se cancelaba el envío.
- Con Wi‑Fi o datos, Android ubica el teléfono por red en ~10 s (en la prueba del 20/11/2026 tardó 11 s, casi al límite).
- En modo avión solo queda el GPS. Bajo techo, el GPS no ve satélites suficientes: en los logs del 20/11/2026 vio **un solo satélite y usó cero** (`visibleSv=1, usedSv=0`; hacen falta al menos 4), con señal débil (25–27 dB‑Hz, estado `SHADOW`).
- Ampliar el límite a 30 s **no lo resolvió**: el GPS siguió sin satélites y el envío volvió a fallar. Bajo techo, esperar más no sirve.
- El error solo se mostraba en un SnackBar y no quedaba en el log, lo que dificultaba el diagnóstico.

## Corrección

1. **Límite de 15 s** para obtener una ubicación nueva. Deja margen para la ubicación por red (~11 s) sin demorar demasiado un pedido de ayuda.
2. **Respaldo con la última ubicación conocida.** Si se vence el tiempo, se usa `Geolocator.getLastKnownPosition()`, que devuelve la última ubicación que guardó el teléfono (por ejemplo, la de cuando tenía Wi‑Fi). El mensaje lo aclara con la hora de esa ubicación:

   ```
   🆘 SOS — Necesito ayuda
   ⚠️ Última ubicación conocida, de las 16:30
   📍 Mi ubicación: https://maps.google.com/?q=…
   ```

   - Se indica la **hora** y no "hace X min", porque el mensaje puede tardar en propagarse por la mesh y el "hace" quedaría desactualizado.
   - La aclaración va en **una línea aparte** para que la tarjeta SOS, incluso en versiones anteriores de la app, siga extrayendo el link de la línea 📍 y mostrando el botón **Ver ubicación en Google Maps**.
3. **Sin ninguna ubicación guardada,** el SOS no se envía y se muestra un aviso claro: *"no hay señal GPS ni una ubicación guardada. Probá al aire libre o cerca de una ventana."*
4. **Registro en logcat** con la etiqueta `[BroadcastScreen]`: ubicación obtenida (con su precisión), uso de la última ubicación conocida, cancelación por servicio de ubicación apagado y cualquier error con su traza.

## Por qué así

En una emergencia importa más que el aviso salga rápido con una ubicación aproximada que esperar indefinidamente una ubicación exacta que bajo techo puede no llegar nunca. Quien recibe el SOS sabe, por la línea ⚠️, que la posición puede no ser la actual.

## Pendiente

- **Probar en el dispositivo** el respaldo con la última ubicación conocida (modo avión, bajo techo).
- **Tiempo según el estado de la red:** dar más tiempo al GPS solo en modo avión (por ejemplo, al aire libre puede tardar 20–40 s en un arranque en frío) y mantener el límite corto cuando hay red.
- **Decidir si enviar el SOS sin ubicación** cuando no hay ninguna guardada: hoy se cancela, pero el pedido de ayuda podría ser útil igual.
