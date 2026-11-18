# Landing B2B Mesh — Plan

## Fase 1 · Marketing: qué decir para que la gente quiera usarla

### Público
1. **Gente común preocupada por emergencias** (zonas sísmicas, inundables, incendios forestales en la Patagonia). Motivación: *poder avisar "estoy bien" o pedir ayuda*.
2. **Grupos al aire libre**: trekking, camping, pesca, rutas y campo sin cobertura.
3. **Eventos masivos y lugares cerrados**: recitales, estadios, subsuelos, campus.
4. **Curiosos técnicos / docentes / jurado de la cátedra**: quieren ver que hay ingeniería real atrás.

### Mensaje central
> **"Hablá aunque no haya señal."** Cuando se cae la red, tu teléfono *es* la red.

Lema de cierre: **"Donde no llega la señal, llega tu mensaje."** (ver Revisión 2).

### Estructura persuasiva (problema → solución → prueba → acción)
| # | Sección | Objetivo | Contenido clave |
|---|---------|----------|-----------------|
| 0 | **Hero** | Gancho en 3 s | Titular, bajada de 1 frase, CTA "Descargar para Android" + "Ver cómo funciona", chips de confianza: *Gratis · Sin cuenta ni número · Sin Internet* |
| 1 | **El problema** | Generar tensión | La señal cae paso a paso mientras se scrollea: 4G → 3G → E → *Sin servicio*. Causas: caen torres y la luz, la red se satura cuando todos llaman, no hay cobertura. Remate: *"Justo cuando más la necesitás."* |
| 2 | **Cómo funciona** | Bajar la barrera ("es fácil") | 3 pasos: (1) Abrís la app y tenés tu Node ID — sin número ni email. (2) Escaneás el QR de tu gente. (3) Escribís: el mensaje salta de teléfono en teléfono hasta llegar. |
| 3 | **Funciones** | Prueba de valor | 100 % sin Internet · Multi-salto · SOS + ubicación GPS · Identidad sin cuenta · Sigue funcionando con la pantalla bloqueada · Tus chats quedan en tu teléfono |
| 4 | **Para qué sirve** | Identificación ("esto es para mí") | Emergencias · Naturaleza y rutas · Recitales y eventos · Subsuelos y campus |
| 5 | **SOS** | Momento emocional | "Un toque. Todos los que estén cerca." Alerta a todos los teléfonos alcanzables con tu ubicación lista para abrir en el mapa. |
| 6 | **La red sos vos** | Viralidad / efecto red | Demo interactiva: sumás personas y el mensaje de A llega a C. Honestidad: cada salto cubre 10–100 m. Llamado: *invitá a tu gente* (botón Compartir). |
| 7 | **Privacidad** | Quitar objeciones | Sin servidores · Sin cuentas · Sin rastreo. Los chats viven en el teléfono. |
| 8 | **Para curiosos** | Credibilidad técnica | Google Nearby Connections (P2P_CLUSTER), BLE + Wi-Fi Direct, Flutter + Kotlin, Foreground Service, proyecto DADM · UNPSJB. |
| 9 | **Preguntas frecuentes** | Resolver dudas finales | ¿Necesito Internet? ¿Qué alcance tiene? ¿Funciona en iPhone? ¿Gasta mucha batería? ¿Mis mensajes son privados? ¿Es gratis? |
| 10 | **CTA final** | Conversión | "Instalala hoy. Ojalá nunca la necesites." + Descargar + Compartir |

### Reglas de copy
- Voseo rioplatense, frases cortas, verbos en 2.ª persona ("escribí", "escaneá").
- Beneficio primero, tecnología después (la jerga técnica queda en "Para curiosos").
- **Nada de promesas falsas**: no se habla de cifrado de extremo a extremo (no está implementado), ni de cifras inventadas; el alcance se explica con límites reales (10–100 m por salto, hasta 3 saltos, solo Android).

## Fase 2 · Diseño: cómo se ve

### Identidad (heredada de la presentación)
- **Colores**: noche `#150E26`, tarjeta oscura `#22173B`, neón `#9366E8`, neón claro `#B794F6`, superficie `#FBF9FF`, tarjeta clara `#EAE6F3`, píldora `#E8DDFB`, encabezado `#523B78`, tinta `#1C1B1F`, SOS `#E53935`.
- **Tipografía**: Inter (900 para titulares grandes y apretados, tracking negativo) + JetBrains Mono para etiquetas técnicas y "píldoras".
- **Marca**: el glifo rúnico en **contorno neón** (logo nuevo de la app), con resplandor.
- **Componentes**: píldoras en mayúsculas, tarjetas de 24–32 px de radio, bordes neón al 30 %, mockups de teléfono.

### Ritmo visual
Alternancia **oscuro ↔ claro** como en las diapositivas: cada cambio de sección se siente como "pasar de slide" al scrollear.

| Sección | Fondo | Movimiento al bajar |
|---|---|---|
| Hero | Noche + malla de nodos animada (canvas) | El glifo se dibuja al cargar; al salir, el glifo se agranda y el texto sube con parallax |
| Problema | Claro | Visual fijo (sticky): las barras de señal se apagan una a una según el paso que estás leyendo |
| Cómo funciona | Oscuro | Mockup de teléfono fijo que cambia de pantalla (Node ID → QR → paquete saltando A→B→C con TTL 3→2) |
| Funciones | Claro | Tarjetas "bento" que entran escalonadas |
| Usos | Oscuro | Scroll vertical → desplazamiento horizontal de tarjetas grandes |
| SOS | Rojo profundo | Ondas de alerta que se expanden a medida que scrolleás |
| La red sos vos | Claro | Demo interactiva con slider |
| Privacidad | Oscuro | Tres palabras gigantes que se encienden una a una |
| Curiosos + FAQ | Claro | Revelado suave; acordeón animado |
| CTA final | Noche + glifo | Glifo con brillo pulsante |

Elementos persistentes: barra de progreso neón arriba, navbar flotante tipo "píldora" (como la barra de la presentación) que resalta la sección actual.

### Accesibilidad y rendimiento
- `prefers-reduced-motion`: todo queda en su estado final, sin movimiento espacial; la malla del hero se dibuja estática.
- Botón para pausar la animación del hero (WCAG 2.2.2).
- Contraste AA, foco visible, HTML semántico, `aria-current` en la navegación.

## Fase 3 · Implementación

**Tecnología elegida: HTML + CSS + JS puros, sin build.**
- Es una sola página estática: Astro sumaría dependencias y un paso de build sin aportar mucho (no hay CMS, ni varias páginas, ni componentes reutilizados entre rutas).
- Se publica tal cual en GitHub Pages / Netlify / cualquier hosting estático.
- El CSS moderno hace el trabajo pesado: **scroll-driven animations** (`animation-timeline: view()/scroll()`), `scroll-target-group` para scrollspy, `::details-content` + `interpolate-size` para el acordeón, `text-wrap: balance`, `oklch`/`color-mix`.
- JS mínimo: malla del hero (canvas), estados de las secciones sticky (IntersectionObserver), demo de "la red sos vos", fallbacks para navegadores sin scroll-driven animations.
- Guiado por la skill **modern-web-guidance** (guías: `scroll-entry-exit-effects`, `scrollytelling`, `parallax-scroll-effects`, `motion`, `scrollspy`, `scroll-progress-indicator`, `shrinking-header-on-scroll`, `accordion`).

Archivos: `landing/index.html`, `landing/styles.css`, `landing/main.js`, `landing/assets/`.

---

## Revisión 2 · Posicionamiento cotidiano

**Decisión:** el centro del mensaje pasa de "emergencias" a **"todos los días en que la señal no alcanza"**. Las catástrofes siguen apareciendo, pero como el último caso de uso ("y si se complica"), no como gancho.

- **Problema:** recital saturado → montaña/camping → subsuelos → "y cuando se corta todo". La tarjeta de señal muestra el lugar que cambia al bajar.
- **Usos (antes horizontal, ahora tarjetas apiladas verticales):** Eventos · Naturaleza · Viajes sin roaming · Campus y subsuelos · Emergencias (último).
- **SOS:** encuadrado en situaciones cotidianas (alguien se lastima en el cerro, un chico perdido en el festival) + aviso: no reemplaza al 911/107/100.
- **Efecto red:** la demo muestra 4 conversaciones simultáneas. Sin nadie extra ya hay 2/4 conectadas (los que chatean hacen de puente para otros); con 1 persona más 3/4; con 3, 4/4. Mensaje: "nadie hace de antena, todos se ayudan sin darse cuenta".
- **Cierre:** "Donde no llega la señal, llega tu mensaje." (positivo, invita al uso frecuente).
- **Transparencia "beta / en desarrollo":** sección *Lo que viene* (cifrado E2E con claves intercambiadas por QR, ubicación en chats directos, multimedia), etiqueta *Beta* en hero, footer y CTA, y FAQ actualizadas.
- **Pausa de animaciones:** sale del navbar y queda como enlace de texto en el footer (WCAG 2.2.2).
- **Legal (mitigaciones en la página):** aviso de marcas de terceros en el footer; se quitó "código abierto" mientras el repo no tenga LICENSE; aviso de herramienta complementaria en SOS y FAQ.
