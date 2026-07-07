// claude-box.dev — progressive enhancement only. Page works fully without this file.
(function () {
  'use strict';
  var REPO = 'rcrvano/claude-box';

  // 1) copy-to-clipboard (event delegation, works for all [data-copy])
  document.addEventListener('click', function (e) {
    var btn = e.target.closest('[data-copy]');
    if (!btn) return;
    var text = btn.getAttribute('data-copy');
    var icon = btn.querySelector('[data-copy-icon]');
    function ok() { if (icon) { var p = icon.textContent; icon.textContent = 'Copied!'; setTimeout(function(){ icon.textContent = p; }, 1400); } }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(ok).catch(function(){});
    } else {
      var ta = document.createElement('textarea'); ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); ok(); } catch (_) {} document.body.removeChild(ta);
    }
  });

  // 2) live GitHub star count -> every [data-stars]
  function fmt(n){ return n >= 1000 ? (n/1000).toFixed(1).replace(/\.0$/,'') + 'k' : String(n); }
  fetch('https://api.github.com/repos/' + REPO).then(function(r){ return r.ok ? r.json() : null; })
    .then(function(d){ if (!d || typeof d.stargazers_count !== 'number') return;
      var s = fmt(d.stargazers_count);
      document.querySelectorAll('[data-stars]').forEach(function(el){ el.textContent = s; });
    }).catch(function(){});

  // 3) contributors avatars (image strip; static link fallback already in DOM)
  var cont = document.querySelector('[data-contributors]');
  if (cont) {
    var img = new Image();
    img.src = 'https://contrib.rocks/image?repo=' + REPO;
    img.alt = 'claude-box contributors';
    img.className = 'max-h-12';
    img.onload = function(){ cont.appendChild(img); };
  }

  // 4) mobile nav toggle
  var t = document.getElementById('nav-toggle'), m = document.getElementById('nav-menu');
  if (t && m) t.addEventListener('click', function(){
    var open = m.classList.toggle('hidden') === false;
    m.classList.toggle('flex', open); m.classList.toggle('flex-col', open);
    m.classList.toggle('absolute', open); m.classList.toggle('right-5', open); m.classList.toggle('top-14', open);
    m.classList.toggle('rounded-xl', open); m.classList.toggle('border', open); m.classList.toggle('border-line', open);
    m.classList.toggle('bg-panel', open); m.classList.toggle('shadow-board', open); m.classList.toggle('p-4', open);
    t.setAttribute('aria-expanded', String(open));
  });

  // 5) features "See all" expand + nav "Features" opens the full list
  var moreBtn = document.getElementById('see-all-features');
  var moreRows = document.querySelector('[data-more]');
  function expandFeatures(){
    if (!moreRows) return;
    moreRows.classList.add('is-open');
    moreRows.querySelectorAll('.spec').forEach(function(el){ el.classList.add('reveal','in'); });
    if (moreBtn){
      moreBtn.setAttribute('aria-expanded','true');
      var lbl = moreBtn.querySelector('[data-more-label]'); if (lbl) lbl.textContent = 'Show less';
      var ic  = moreBtn.querySelector('[data-more-icon]');  if (ic)  ic.textContent = '↑';
    }
  }
  function collapseFeatures(){
    if (!moreRows) return;
    moreRows.classList.remove('is-open');
    if (moreBtn){
      moreBtn.setAttribute('aria-expanded','false');
      var lbl = moreBtn.querySelector('[data-more-label]'); if (lbl) lbl.textContent = 'See all features';
      var ic  = moreBtn.querySelector('[data-more-icon]');  if (ic)  ic.textContent = '↓';
    }
  }
  if (moreBtn) moreBtn.addEventListener('click', function(){
    if (moreRows && !moreRows.classList.contains('is-open')) expandFeatures(); else collapseFeatures();
  });
  // any link that points at the full list (nav + footer) expands it first
  document.querySelectorAll('[data-open-features]').forEach(function(a){
    a.addEventListener('click', function(){ expandFeatures(); });
  });

  // 6) scroll-reveal (respects prefers-reduced-motion via CSS)
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function(es){ es.forEach(function(en){ if (en.isIntersecting){ en.target.classList.add('in'); io.unobserve(en.target); } }); }, { threshold: 0.12 });
    document.querySelectorAll('.reveal').forEach(function(el){ io.observe(el); });
  } else {
    document.querySelectorAll('.reveal').forEach(function(el){ el.classList.add('in'); });
  }
})();
