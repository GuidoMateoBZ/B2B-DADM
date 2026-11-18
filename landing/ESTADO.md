# Landing B2B Mesh — Idea, estado actual y pendientes

> Complementa a [`PLAN.md`](PLAN.md), donde está el plan original (marketing → diseño → implementación) y la Revisión 2.

## 1. La idea

Página de presentación pública de **B2B Mesh** para que la gente entienda la app, se interese y la descargue.

- **Mensaje central:** *"Hablá aunque no haya señal."*
- **Cierre:** *"Donde no llega la señal, llega tu mensaje."*
- **Posicionamiento:** la app de **todos los días en que la señal no alcanza**: recitales, montaña, viajes y subsuelos. Las emergencias se mencionan, pero como último caso de uso, no como gancho.
  - **Por qué:** una app vendida "por si hay una catástrofe" se instala y no se abre, y la red depende de que haya gente usándola alrededor. El uso diario es lo que hace que también funcione el día de la emergencia.
- **Tono:** voseo rioplatense, frases cortas, primero el beneficio y después la tecnología. No se promete nada que la app no haga hoy.
- **Estilo:** heredado de la presentación interactiva:
  - Paleta violeta/neón (`#9366E8`, `#B794F6`) sobre noche `#150E26` y superficies lavanda `#FBF9FF`.
  - Tipografías Inter y JetBrains Mono.
  - Glifo rúnico en contorno neón, igual al logo nuevo de la app.
  - Secciones que alternan fondo oscuro y claro, como pasar de diapositiva.

## 2. Estado actual

**Listo y probado** en Chrome de escritorio (1440 px) y de celular (390 px), y con movimiento reducido activado:

- No hay scroll horizontal ni errores en consola.
- Con movimiento reducido no queda ninguna animación activa y todo el contenido se ve.

### Tecnología
- HTML, CSS y JS puros, sin build ni dependencias: `index.html`, `styles.css`, `main.js` y `assets/favicon.svg`.
- Los efectos al scrollear usan *scroll-driven animations* de CSS. Para navegadores sin soporte hay alternativas con IntersectionObserver.
- Se siguieron las guías de la skill `modern-web-guidance`.

**Cómo verla:** `cd landing && python3 -m http.server 4321` y abrir http://127.0.0.1:4321.

### Secciones (en orden)
| Sección | Contenido | Qué se mueve al bajar |
|---|---|---|
| Inicio | Titular, descarga de la beta, "Gratis · Sin cuenta ni número · Sin Internet" | Malla de nodos animada; el glifo se dibuja al cargar y se agranda al salir |
| Por qué | Recital saturado → montaña → subsuelo → "y cuando se corta todo" | Tarjeta fija que cambia de lugar y pierde señal paso a paso |
| Cómo funciona | Node ID → escanear QR → escribir | Teléfono fijo que cambia de pantalla y paquete que salta A→B→C (ttl 3→2) |
| Usos | Eventos · Naturaleza · Viajes sin roaming · Campus y subsuelos · Emergencias | Tarjetas que se apilan (solo scroll vertical) |
| Funciones | Grilla de 6 tarjetas | Entrada escalonada |
| SOS | Casos cotidianos y aviso de que no reemplaza al 911/107/100 | Ondas que se expanden con el scroll |
| La red sos vos | Demo interactiva con 4 conversaciones a la vez | Slider: 0 personas extra → 2/4 conectadas; 1 → 3/4; 3 → 4/4 |
| Privacidad | Sin servidores · Sin cuentas · Sin rastreo | Palabras gigantes que se encienden |
| Para curiosos | Nearby Connections, BLE → Wi-Fi Direct, ttl 3, Flutter + Kotlin | Revelado |
| Lo que viene | Hoy vs. Próximamente (ver §4) | Revelado |
| Preguntas | 8 preguntas en acordeón nativo | Apertura animada |
| Cierre | "Donde no llega la señal, llega tu mensaje." + Descargar + Compartir | El glifo se dibuja con el scroll |

Hay otros elementos fijos:
- Barra de progreso arriba.
- Navbar tipo píldora que marca la sección actual.
- Link discreto "Pausar animaciones" en el pie de página. Se dejó por la pauta de accesibilidad WCAG 2.2.2 (animaciones que se repiten solas por más de 5 s).

### Lo que la página aclara explícitamente (por honestidad)
- Es una **beta en desarrollo** y solo funciona en **Android 7.0 o superior**.
- **Alcance:** 10–100 m por salto y como máximo **3 saltos** (TTL del `Envelope`).
- **No hay cifrado de extremo a extremo todavía.** Los mensajes pueden pasar por teléfonos de otras personas, así que no conviene mandar datos sensibles.
- **Hoy la ubicación solo viaja en el SOS**, no en los chats directos.
- El SOS es una **herramienta complementaria**: no reemplaza a los servicios de emergencia ni garantiza que el mensaje llegue.

## 3. Aclaraciones legales (relevadas en noviembre 2026, no es asesoramiento legal)

| Tema | Situación | Qué hacer |
|---|---|---|
| **Marca "B2B Mesh"** | No apareció ningún registro con ese nombre. Sí hay marcas "MESH" y "B2B" por separado en otros rubros, sobre todo en EE.UU. **No se revisó el INPI argentino.** | Búsqueda gratuita de idénticos y búsqueda fonética paga (unas 24 h) en el INPI, clases 9 (software) y 38 (telecomunicaciones). |
| **Nombre, desde marketing** | "B2B" se lee como *business-to-business*. Buscar "B2B Mesh" solo devuelve empresas de pagos o de identidad, lo que confunde y complica aparecer en buscadores. | Evaluar otro nombre si todavía se puede. |
| **Logo** | Igual que el de Bluetooth, es una combinación de runas (comparte la runa Hagall) y la app usa Bluetooth. Bluetooth SIG solo licencia sus marcas a miembros y controla cómo se usan. | Diferenciar el glifo para evitar un posible reclamo por confusión. |
| **Palabras Bluetooth, Android, Google Nearby** | Mencionarlas para describir la app está bien. | ✅ Hecho: aviso de marcas de terceros y de no afiliación en el pie de página. |
| **Licencia del repo** | No hay archivo `LICENSE`: aunque el repo sea público, legalmente no es "código abierto". | ✅ Se quitó "código abierto" de la página. Si se quiere decir, agregar una licencia (por ejemplo MIT). |
| **Dependencias** | `nearby_connections` (y el fork) usan BSD-2-Clause, que exige incluir el aviso de copyright en el APK distribuido. | Mostrar la pantalla de licencias en la app (`showLicensePage` / `AboutDialog`). |
| **Privacidad** | La app pide ubicación (también en segundo plano), cámara y Bluetooth. Aplica la Ley 25.326. Si se publica en Google Play, la política de privacidad es obligatoria. | Publicar una política de privacidad corta y linkearla desde la página y desde la app. |
| **SOS / responsabilidad** | Promete comunicación en emergencias. | ✅ Hecho: aviso en la sección SOS y en las preguntas frecuentes. |
| **Nombre de la universidad** | La página menciona "Proyecto académico · DADM · UNPSJB". | Confirmar con la cátedra que se puede usar en un sitio público. |

## 4. Funciones de la app por agregar (anunciadas en "Lo que viene")

1. **Cifrado de extremo a extremo:** las claves se intercambian al escanear el QR del contacto durante el agendado. Solo emisor y receptor pueden leer, aunque el mensaje pase por otros teléfonos.
2. **Compartir ubicación en chats directos:** hoy solo existe en el SOS (`broadcast_screen.dart`). Prioridad alta.
3. **Envío de multimedia:** fotos, audios y archivos.

> Cuando alguna se implemente, mover el ítem de "Próximamente" a "Hoy" en la sección `#roadmap` y actualizar las preguntas *¿Quién puede leer mis mensajes?* y *¿Puedo mandar fotos o mi ubicación?*.

## 5. Pendientes

### Para poder publicar la página
- [ ] **Publicar un release en GitHub con el APK.** Los botones apuntan a `releases/latest` y hoy dan 404.
- [ ] Decidir el hosting (GitHub Pages, Netlify, etc.) y, si hace falta, un dominio.
- [ ] Revisar la marca en el INPI y decidir sobre el nombre y el logo (ver §3).
- [ ] Publicar la política de privacidad y linkearla en el pie de página.
- [ ] Confirmar el uso del nombre UNPSJB.
- [ ] Agregar `LICENSE` al repo (opcional, solo si se quiere comunicar que es código abierto).

### Mejoras opcionales de la página
- [ ] Imagen para compartir en redes (`og:image`).
- [ ] Capturas o video reales de la app en lugar de los mockups.
- [ ] Alojar las fuentes en el propio sitio (hoy se cargan desde Google Fonts).
- [ ] Si se decide quitar del todo el link "Pausar animaciones", hacer que la malla del inicio se detenga sola a los pocos segundos.
