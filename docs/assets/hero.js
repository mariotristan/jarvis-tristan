// The animated network in the home page hero. Decorative: the page reads the same without it.
(function () {
  var canvas = document.getElementById('hero-net');
  if (!canvas || !canvas.getContext) return;
  var ctx = canvas.getContext('2d');
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var nodes = [], edges = [], pulses = [], size = 0, visible = true, last = 0;

  var seed = 7;
  function rand() { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }

  function build() {
    nodes = []; edges = []; pulses = [];
    for (var i = 0; i < 56; i++) {
      var a = rand() * Math.PI * 2, r = Math.sqrt(rand()) * 0.9;
      nodes.push({ x: Math.cos(a) * r, y: Math.sin(a) * r, p: rand() * 6.28, gold: rand() < 0.25 });
    }
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        var dx = nodes[i].x - nodes[j].x, dy = nodes[i].y - nodes[j].y;
        if (dx * dx + dy * dy < 0.12) edges.push([i, j]);
      }
    }
  }

  function resize() {
    var box = canvas.getBoundingClientRect(), dpr = Math.min(window.devicePixelRatio || 1, 2);
    size = Math.max(1, box.width);
    canvas.width = canvas.height = Math.round(size * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function pos(n) { return [size / 2 + n.x * size * 0.46, size / 2 + n.y * size * 0.46]; }

  function draw(t) {
    ctx.clearRect(0, 0, size, size);
    var c = size / 2;
    ctx.lineWidth = 1;
    for (var k = 0; k < edges.length; k++) {
      var A = pos(nodes[edges[k][0]]), B = pos(nodes[edges[k][1]]);
      ctx.strokeStyle = 'rgba(255,255,255,.16)';
      ctx.beginPath(); ctx.moveTo(A[0], A[1]); ctx.lineTo(B[0], B[1]); ctx.stroke();
    }
    for (var i = 0; i < nodes.length; i++) {
      var P = pos(nodes[i]), glow = 0.55 + 0.45 * Math.sin(t / 900 + nodes[i].p);
      ctx.fillStyle = nodes[i].gold ? 'rgba(129,140,248,' + glow + ')' : 'rgba(255,255,255,' + (0.35 + glow * 0.4) + ')';
      ctx.beginPath(); ctx.arc(P[0], P[1], size * 0.006 + (nodes[i].gold ? 1.2 : 0.6), 0, 6.283); ctx.fill();
    }
    for (var q = pulses.length - 1; q >= 0; q--) {
      var u = pulses[q], e = edges[u.e], S = pos(nodes[e[0]]), E = pos(nodes[e[1]]);
      var f = u.f, x = S[0] + (E[0] - S[0]) * f, y = S[1] + (E[1] - S[1]) * f;
      var g = ctx.createRadialGradient(x, y, 0, x, y, size * 0.03);
      g.addColorStop(0, 'rgba(25,211,240,.95)'); g.addColorStop(1, 'rgba(25,211,240,0)');
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, size * 0.03, 0, 6.283); ctx.fill();
    }
    var core = ctx.createRadialGradient(c, c, 0, c, c, size * 0.2), beat = 0.85 + 0.15 * Math.sin(t / 700);
    core.addColorStop(0, 'rgba(255,255,255,' + beat + ')');
    core.addColorStop(0.18, 'rgba(25,211,240,' + 0.8 * beat + ')');
    core.addColorStop(0.5, 'rgba(99,102,241,.28)');
    core.addColorStop(1, 'rgba(99,102,241,0)');
    ctx.fillStyle = core; ctx.beginPath(); ctx.arc(c, c, size * 0.2, 0, 6.283); ctx.fill();
    ctx.strokeStyle = 'rgba(25,211,240,.7)'; ctx.setLineDash([4, 6]); ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(c, c, size * 0.5 - 2, t / 6000, t / 6000 + 6.283); ctx.stroke(); ctx.setLineDash([]);
  }

  function frame(t) {
    var dt = Math.min(t - last, 50); last = t;
    if (Math.random() < 0.08 && pulses.length < 10) pulses.push({ e: Math.floor(Math.random() * edges.length), f: 0 });
    for (var q = pulses.length - 1; q >= 0; q--) { pulses[q].f += dt / 900; if (pulses[q].f >= 1) pulses.splice(q, 1); }
    draw(t);
    if (visible && !document.hidden) requestAnimationFrame(frame);
  }

  build(); resize();
  window.addEventListener('resize', function () { resize(); if (reduce) draw(0); });
  if (reduce) { draw(0); return; }
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (en) {
      var was = visible; visible = en[0].isIntersecting;
      if (visible && !was) requestAnimationFrame(frame);
    }).observe(canvas);
  }
  document.addEventListener('visibilitychange', function () { if (!document.hidden && visible) requestAnimationFrame(frame); });
  requestAnimationFrame(frame);
})();

// Marks the menu link of the section being read.
(function () {
  var links = document.querySelectorAll('.pill nav a[href^="#"]');
  if (!links.length || !('IntersectionObserver' in window)) return;
  var byId = {};
  links.forEach(function (a) { byId[a.getAttribute('href').slice(1)] = a; });
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (!e.isIntersecting) return;
      links.forEach(function (a) { a.classList.remove('current'); a.removeAttribute('aria-current'); });
      var a = byId[e.target.id];
      if (a) { a.classList.add('current'); a.setAttribute('aria-current', 'true'); }
    });
  }, { rootMargin: '-40% 0px -55% 0px' });
  Object.keys(byId).forEach(function (id) { var el = document.getElementById(id); if (el) io.observe(el); });
})();
