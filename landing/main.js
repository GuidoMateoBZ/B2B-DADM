// B2B Mesh — Landing
// JS mínimo: el movimiento ligado al scroll lo resuelve CSS (scroll-driven animations).
// Acá: malla animada del hero, estados de las historias sticky, fallbacks, scrollspy,
// demo "La red sos vos" y botón compartir.

const root = document.documentElement;
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const supportsSDA = CSS.supports('(animation-timeline: view()) and (animation-range: entry)');

/* ------------------------------------------------------------------
   Pausa global de animaciones en bucle (WCAG 2.2.2)
------------------------------------------------------------------ */
const motionBtn = document.querySelector('[data-motion-toggle]');
const PAUSE_KEY = 'b2b-motion-paused';

function readPausePref() {
  try { return localStorage.getItem(PAUSE_KEY) === '1'; } catch { return false; }
}
function setPaused(paused) {
  root.classList.toggle('motion-paused', paused);
  if (motionBtn) motionBtn.textContent = paused ? 'Reanudar animaciones' : 'Pausar animaciones';
  try { localStorage.setItem(PAUSE_KEY, paused ? '1' : '0'); } catch { /* almacenamiento no disponible */ }
  mesh?.update();
}
motionBtn?.addEventListener('click', () => setPaused(!root.classList.contains('motion-paused')));

/* ------------------------------------------------------------------
   Hero: malla de nodos con paquetes que saltan (máx. 3 saltos, como el TTL real)
------------------------------------------------------------------ */
const mesh = (() => {
  const canvas = document.querySelector('.hero__mesh');
  const hero = document.querySelector('.hero');
  if (!canvas || !hero) return null;
  const ctx = canvas.getContext('2d');

  let w = 0, h = 0, dpr = 1, linkDist = 150;
  let nodes = [];
  let packets = [];
  let raf = 0, last = 0, spawnTimer = 0;
  let visible = true;
  const pointer = { x: -9999, y: -9999, active: false };

  function seed() {
    const count = Math.round(Math.min(85, Math.max(26, (w * h) / 15000)));
    nodes = Array.from({ length: count }, () => ({
      x: Math.random() * w,
      y: Math.random() * h,
      vx: (Math.random() - 0.5) * 0.18,
      vy: (Math.random() - 0.5) * 0.18,
      r: 1.6 + Math.random() * 1.8,
      glow: 0,
    }));
    packets = [];
  }

  function resize() {
    const rect = hero.getBoundingClientRect();
    dpr = Math.min(2, devicePixelRatio || 1);
    w = rect.width; h = rect.height;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    linkDist = Math.max(110, Math.min(170, w * 0.14));
    seed();
    draw(0);
  }

  const dist2 = (a, b) => (a.x - b.x) ** 2 + (a.y - b.y) ** 2;

  function neighbors(node) {
    const max = linkDist * linkDist;
    return nodes.filter((n) => n !== node && dist2(n, node) < max);
  }

  function spawnPacket() {
    const from = nodes[Math.floor(Math.random() * nodes.length)];
    const options = neighbors(from);
    if (!options.length) return;
    from.glow = 1;
    packets.push({ from, to: options[Math.floor(Math.random() * options.length)], t: 0, ttl: 3, prev: null });
  }

  function step(dt) {
    for (const n of nodes) {
      n.x += n.vx * dt * 0.06;
      n.y += n.vy * dt * 0.06;
      if (n.x < -20) n.x = w + 20; else if (n.x > w + 20) n.x = -20;
      if (n.y < -20) n.y = h + 20; else if (n.y > h + 20) n.y = -20;
      n.glow = Math.max(0, n.glow - dt * 0.0012);
    }
    spawnTimer -= dt;
    if (spawnTimer <= 0) { spawnPacket(); spawnTimer = 650 + Math.random() * 700; }

    for (const p of packets) {
      p.t += dt / 650;
      if (p.t >= 1) {
        p.to.glow = 1;
        p.ttl -= 1; // como el Envelope: cada salto descuenta TTL
        if (p.ttl <= 0) { p.done = true; continue; }
        const next = neighbors(p.to).filter((n) => n !== p.from);
        if (!next.length) { p.done = true; continue; }
        p.prev = p.from; p.from = p.to; p.to = next[Math.floor(Math.random() * next.length)]; p.t = 0;
      }
    }
    packets = packets.filter((p) => !p.done);
  }

  function draw() {
    ctx.clearRect(0, 0, w, h);
    const max = linkDist * linkDist;
    const all = pointer.active ? [...nodes, pointer] : nodes;

    ctx.lineWidth = 1;
    for (let i = 0; i < all.length; i++) {
      for (let j = i + 1; j < all.length; j++) {
        const d = dist2(all[i], all[j]);
        if (d < max) {
          const a = (1 - Math.sqrt(d) / linkDist) * (all[j] === pointer ? 0.7 : 0.32);
          ctx.strokeStyle = `rgba(167, 139, 250, ${a.toFixed(3)})`;
          ctx.beginPath(); ctx.moveTo(all[i].x, all[i].y); ctx.lineTo(all[j].x, all[j].y); ctx.stroke();
        }
      }
    }

    for (const n of nodes) {
      if (n.glow > 0.02) {
        const g = ctx.createRadialGradient(n.x, n.y, 0, n.x, n.y, 18);
        g.addColorStop(0, `rgba(183, 148, 246, ${0.55 * n.glow})`);
        g.addColorStop(1, 'rgba(183, 148, 246, 0)');
        ctx.fillStyle = g;
        ctx.beginPath(); ctx.arc(n.x, n.y, 18, 0, Math.PI * 2); ctx.fill();
      }
      ctx.fillStyle = n.glow > 0.02 ? '#E9DDFF' : 'rgba(183, 148, 246, 0.85)';
      ctx.beginPath(); ctx.arc(n.x, n.y, n.r, 0, Math.PI * 2); ctx.fill();
    }

    for (const p of packets) {
      const x = p.from.x + (p.to.x - p.from.x) * p.t;
      const y = p.from.y + (p.to.y - p.from.y) * p.t;
      const g = ctx.createRadialGradient(x, y, 0, x, y, 14);
      g.addColorStop(0, 'rgba(255, 255, 255, 1)');
      g.addColorStop(0.25, 'rgba(183, 148, 246, 0.9)');
      g.addColorStop(1, 'rgba(147, 102, 232, 0)');
      ctx.fillStyle = g;
      ctx.beginPath(); ctx.arc(x, y, 14, 0, Math.PI * 2); ctx.fill();
    }
  }

  function frame(now) {
    const dt = Math.min(48, now - (last || now));
    last = now;
    step(dt);
    draw();
    raf = requestAnimationFrame(frame);
  }

  function shouldRun() {
    return visible && !document.hidden && !reducedMotion.matches && !root.classList.contains('motion-paused');
  }

  function update() {
    if (shouldRun()) {
      if (!raf) { last = 0; raf = requestAnimationFrame(frame); }
    } else if (raf) {
      cancelAnimationFrame(raf); raf = 0;
    }
  }

  new ResizeObserver(() => resize()).observe(hero);
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; update(); }).observe(hero);
  document.addEventListener('visibilitychange', update);
  reducedMotion.addEventListener('change', () => { update(); draw(); });

  hero.addEventListener('pointermove', (e) => {
    const rect = hero.getBoundingClientRect();
    pointer.x = e.clientX - rect.left; pointer.y = e.clientY - rect.top; pointer.active = true;
    if (!raf) draw();
  });
  hero.addEventListener('pointerleave', () => { pointer.active = false; if (!raf) draw(); });

  return { update };
})();

setPaused(readPausePref());

/* ------------------------------------------------------------------
   Historias sticky: el paso centrado define el estado del visual
------------------------------------------------------------------ */
for (const story of document.querySelectorAll('[data-story]')) {
  const visual = story.querySelector('.story__visual');
  const steps = [...story.querySelectorAll('.step')];
  const activate = (step) => {
    steps.forEach((s) => s.classList.toggle('is-active', s === step));
    visual.dataset.stage = step.dataset.step;
  };
  activate(steps[0]);
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) activate(entry.target);
  }, { rootMargin: '-52% 0px -38% 0px' });
  steps.forEach((s) => io.observe(s));
}

/* ------------------------------------------------------------------
   Fallback de revelado para navegadores sin scroll-driven animations
------------------------------------------------------------------ */
if (!supportsSDA && !reducedMotion.matches) {
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) { entry.target.classList.add('is-in'); io.unobserve(entry.target); }
    }
  }, { threshold: 0.15 });
  document.querySelectorAll('.reveal').forEach((el) => io.observe(el));
}

/* ------------------------------------------------------------------
   Scrollspy: nativo con scroll-target-group, o IntersectionObserver
------------------------------------------------------------------ */
{
  const links = [...document.querySelectorAll('.nav__links a')];
  const setCurrent = (current) => {
    for (const link of links) {
      if (link === current) link.setAttribute('aria-current', 'true');
      else link.removeAttribute('aria-current');
    }
  };

  if (CSS.supports('scroll-target-group: auto')) {
    const sync = () => setCurrent(document.querySelector('.nav__links a:target-current'));
    sync();
    if ('onscrollend' in window) document.addEventListener('scrollend', sync);
    else {
      let t; document.addEventListener('scroll', () => { clearTimeout(t); t = setTimeout(sync, 150); }, { passive: true });
    }
  } else {
    const byId = new Map(links.map((a) => [a.hash.slice(1), a]));
    const io = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const link = byId.get(entry.target.id);
        links.forEach((a) => a.classList.toggle('is-current', a === link));
        setCurrent(link);
      }
    }, { rootMargin: '-45% 0px -50% 0px' });
    byId.forEach((_, id) => { const el = document.getElementById(id); if (el) io.observe(el); });
  }
}

/* ------------------------------------------------------------------
   Demo "La red sos vos": varias conversaciones a la vez.
   Los que chatean también hacen de puente para los demás.
------------------------------------------------------------------ */
{
  const input = document.getElementById('net-people');
  const svg = document.querySelector('.net-demo__svg');
  if (input && svg) {
    const NS = 'http://www.w3.org/2000/svg';
    const RANGE = 100; // metros por salto (aprox. tope de BLE / Wi-Fi Direct)
    const MAX_HOPS = 3; // TTL por defecto del Envelope
    const P = (name, x, y) => ({ name, x, y });
    const people = {
      ana: P('Ana', 40, 40), beto: P('Beto', 95, 60), caro: P('Caro', 60, 118), dani: P('Dani', 215, 122),
      gabi: P('Gabi', 140, 95), hugo: P('Hugo', 280, 25), eli: P('Eli', 18, 82), fede: P('Fede', 272, 138),
    };
    const PAIRS = [
      { a: people.ana, b: people.beto, color: '#9366E8' },
      { a: people.caro, b: people.dani, color: '#10B981' },
      { a: people.gabi, b: people.hugo, color: '#F59E0B' },
      { a: people.eli, b: people.fede, color: '#EC4899' },
    ];
    // Personas que solo tienen la app abierta (en el orden en que se suman)
    const EXTRA = [[232, 62], [120, 22], [182, 102], [200, 35], [250, 95], [75, 140], [160, 140], [30, 140]]
      .map(([x, y]) => P('otra persona', x, y));

    const layers = {
      ranges: svg.querySelector('.net-ranges'),
      links: svg.querySelector('.net-links'),
      path: svg.querySelector('.net-path'),
      nodes: svg.querySelector('.net-nodes'),
    };
    const out = document.getElementById('net-count');
    const status = document.getElementById('net-status');
    const legend = document.querySelector('.net-legend');
    let prevCount = 0;

    const el = (name, attrs, parent) => {
      const node = document.createElementNS(NS, name);
      for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
      parent?.append(node);
      return node;
    };
    const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

    function shortestPath(graph, from, to) {
      const prev = new Map([[from, null]]);
      const queue = [from];
      while (queue.length) {
        const cur = queue.shift();
        if (cur === to) break;
        for (const n of graph) {
          if (!prev.has(n) && dist(cur, n) <= RANGE) { prev.set(n, cur); queue.push(n); }
        }
      }
      if (!prev.has(to)) return null;
      const path = [];
      for (let n = to; n; n = prev.get(n)) path.unshift(n);
      return path;
    }

    function describe(path) {
      if (!path) return 'Sin camino todavía';
      const hops = path.length - 1;
      if (hops === 1) return 'Directo';
      if (hops > MAX_HOPS) return `Necesita ${hops} saltos (máx. ${MAX_HOPS})`;
      const via = path.slice(1, -1).map((n) => n.name);
      const names = via.length > 1 ? `${via.slice(0, -1).join(', ')} y ${via.at(-1)}` : via[0];
      return `${hops} saltos, vía ${names}`;
    }

    function render() {
      const count = Number(input.value);
      out.textContent = count;
      const extra = EXTRA.slice(0, count);
      const graph = [...Object.values(people), ...extra];

      Object.values(layers).forEach((g) => g.replaceChildren());
      legend.replaceChildren();

      for (const n of graph) el('circle', { cx: n.x, cy: n.y, r: RANGE }, layers.ranges);
      for (let i = 0; i < graph.length; i++) {
        for (let j = i + 1; j < graph.length; j++) {
          if (dist(graph[i], graph[j]) <= RANGE) {
            el('line', { x1: graph[i].x, y1: graph[i].y, x2: graph[j].x, y2: graph[j].y }, layers.links);
          }
        }
      }

      let connected = 0;
      const relays = new Set();
      for (const pair of PAIRS) {
        const path = shortestPath(graph, pair.a, pair.b);
        const ok = Boolean(path) && path.length - 1 <= MAX_HOPS;
        if (ok) {
          connected++;
          path.slice(1, -1).forEach((n) => relays.add(n));
          el('path', { d: 'M' + path.map((n) => `${n.x} ${n.y}`).join(' L'), style: `--c:${pair.color}` }, layers.path);
        }
        const li = document.createElement('li');
        li.style.setProperty('--c', pair.color);
        li.classList.toggle('is-ok', ok);
        li.innerHTML = '<i></i><b></b><span></span>';
        li.querySelector('b').textContent = `${pair.a.name} ↔ ${pair.b.name}`;
        li.querySelector('span').textContent = describe(path);
        legend.append(li);
      }

      extra.forEach((p, i) => {
        const g = el('g', {}, layers.nodes);
        if (relays.has(p)) g.classList.add('on-path');
        if (i >= prevCount) g.classList.add('is-new');
        el('circle', { cx: p.x, cy: p.y, r: 3.5 }, g);
      });
      for (const pair of PAIRS) {
        for (const end of [pair.a, pair.b]) {
          const g = el('g', { class: 'end', style: `--c:${pair.color}` }, layers.nodes);
          el('circle', { cx: end.x, cy: end.y, r: 7 }, g);
          el('text', { x: end.x, y: end.y + 2.1, 'text-anchor': 'middle' }, g).textContent = end.name[0];
        }
      }
      prevCount = count;

      const all = connected === PAIRS.length;
      status.classList.toggle('is-ok', all);
      status.classList.toggle('is-far', !all);
      if (all) {
        status.textContent = `¡Las ${PAIRS.length} conversaciones conectadas, con solo ${count} ${count === 1 ? 'persona' : 'personas'} más!`;
      } else if (count === 0) {
        status.textContent = `${connected} de ${PAIRS.length} conversaciones ya conectadas sin nadie más: Gabi hace de puente entre Caro y Dani mientras chatea con Hugo.`;
      } else {
        status.textContent = `${connected} de ${PAIRS.length} conversaciones conectadas. Sumá a alguien más para acercar al resto.`;
      }
    }

    input.addEventListener('input', render);
    render();
  }
}

/* ------------------------------------------------------------------
   Compartir
------------------------------------------------------------------ */
for (const btn of document.querySelectorAll('[data-share]')) {
  btn.addEventListener('click', async () => {
    const msg = btn.closest('section')?.querySelector('[data-share-msg]');
    const url = location.href.split('#')[0];
    const data = {
      title: 'B2B Mesh',
      text: 'Mensajería sin Internet: tu teléfono habla directo con los de alrededor. Para recitales, la montaña, viajes y cuando no hay señal.',
      url,
    };
    try {
      if (navigator.share && (!navigator.canShare || navigator.canShare(data))) {
        await navigator.share(data);
        return;
      }
      await navigator.clipboard.writeText(url);
      if (msg) msg.textContent = '¡Link copiado! Pegalo donde quieras.';
    } catch (err) {
      if (err?.name === 'AbortError') return;
      if (msg) msg.textContent = `Copiá este link: ${url}`;
    }
  });
}
