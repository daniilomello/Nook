// Nook: LinkedIn minimal view. config = { css, hidden: [words], columns }, see LinkedInTweaks.swift.
(function (config) {
  'use strict';
  if (location.hostname !== 'www.linkedin.com') return;
  const root = document.documentElement;
  const hides = (word) => config.hidden.includes(word);

  // Constructed sheets: the page's content security policy does not block them.
  const sheet = (css) => { const s = new CSSStyleSheet(); s.replaceSync(css); return s; };
  const pageSheet = sheet(config.css);
  const overlaySheet = sheet('.msg-overlay-list-bubble { display: none !important; }');
  const adopt = (scope, s) => {
    if (!scope.adoptedStyleSheets.includes(s)) scope.adoptedStyleSheets = [...scope.adoptedStyleSheets, s];
  };

  // LinkedIn changes pages without loading them, so the words follow the address.
  const pageKind = () => {
    const path = location.pathname;
    if (/^\/(feed\/update|posts)\//.test(path)) return 'post';
    const first = path.split('/')[1];
    return {
      feed: 'feed', notifications: 'notifications', search: 'search', in: 'profile',
      company: 'company', school: 'company', showcase: 'company',
    }[first] || 'other';
  };
  const centered = ['feed', 'post', 'notifications', 'search', 'profile'];
  const syncPage = () => {
    const page = pageKind();
    const words = [...config.hidden, `page-${page}`];
    if (config.columns && centered.includes(page)) words.push('columns');
    const value = words.join(' ');
    if (root.getAttribute('data-nook-linkedin') !== value) root.setAttribute('data-nook-linkedin', value);
    adopt(document, pageSheet);
  };

  // The Messaging list lives in the shadow root that carries LinkedIn's older components.
  const syncShadow = () => {
    const shadow = document.getElementById('interop-outlet')?.shadowRoot;
    if (shadow) adopt(shadow, overlaySheet);
  };

  // A label is the only thing that tells these posts apart; it is in the interface language.
  const PROMOTED = /^(promoted|promovid[oa]|patrocinad[oa]|promocionad[oa]|publicidad|sponsorisé|post sponsorisé|anzeige|gesponsert|sponsorizzato|post sponsorizzato|gepromoot)(?![\p{L}\p{N}])/iu;
  const SUGGESTED = /^(suggested|sugerid[oa]s?|sugestão|sugestões|sugerencia|recommended for you|recomendad[oa]s? para você|recomendad[oa]s? para ti|suggestion|suggéré|vorgeschlagen|consigliato|voorgesteld)(?![\p{L}\p{N}])/iu;

  const done = new WeakSet();
  const reason = (card) => {
    if (hides('promoted') && card.querySelector('a[href*="li_fat_id="]')) return 'promoted';
    const body = card.querySelector('[data-testid="expandable-text-box"]');
    for (const p of card.querySelectorAll('p')) {
      // Only the header, above the post's own text.
      if (body && (p.contains(body) || body.compareDocumentPosition(p) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
      const text = p.textContent.trim();
      if (!text || text.length > 80) continue;
      if (hides('promoted') && PROMOTED.test(text)) return 'promoted';
      if (hides('suggested') && SUGGESTED.test(text)) return 'suggested';
    }
    return null;
  };
  const syncFeed = () => {
    if (!hides('promoted') && !hides('suggested')) return;
    for (const card of document.querySelectorAll('[data-testid="mainFeed"] [componentkey^="update-card-focus"]')) {
      if (done.has(card)) continue;
      const why = reason(card);
      const box = card.closest('[componentkey^="expanded"]')?.parentElement || card;
      if (why) box.setAttribute('data-nook-linkedin-hidden', why);
      // The action bar comes last, so the header above it is complete.
      if (why || card.querySelector('svg[id$="-feed-compact"]')) done.add(card);
    }
  };

  let queued = false;
  const sync = () => {
    queued = false;
    syncPage();
    if (hides('messagingWindow')) syncShadow();
    syncFeed();
  };
  const queue = () => {
    if (queued) return;
    queued = true;
    setTimeout(sync, 60);
  };
  sync();
  new MutationObserver(queue).observe(root, { childList: true, subtree: true });
  addEventListener('popstate', queue);
})
