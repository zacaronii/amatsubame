// Book reader: pagination, position (Kavita's bookScrollId XPath), settings and
// gestures for one EPUB section. Swift drives it through window.bookReader and
// listens on the "book" message handler. Taps on text are handled by the shared
// TextTapBridge ("lookup" handler); taps elsewhere arrive here as {kind: 'miss'}.
(() => {
  const post = (message) => window.webkit?.messageHandlers?.book?.postMessage(message);
  const root = document.documentElement;

  const state = {
    settings: {layout: 'paged', writingMode: 'auto', fontSize: 20, lineHeight: 1.7, margin: 24, theme: 'light', font: 'book',
               insets: {top: 0, right: 0, bottom: 0, left: 0}},
    vertical: true,
    pages: [],      // [{start, used}] along the reading axis
    page: 0,
    moved: false,   // set by any page turn, so the app knows positions are now real reading
    place: null,    // {xpath, fraction} of the page last reported, for laying out again
    follow: null,   // facing pages, the left one: the page index Swift asked for (one past the right page)
  };

  // Facing pages (the iPhone Duo open). `spread`: this page turns two at a
  // time and spreads start on even pages. `companion`: the facing page, which only shows the
  // page Swift asks for (`follow`), or nothing past the section's end.
  const step = () => (state.settings.spread ? 2 : 1);
  const spreadStart = (index) => (state.settings.spread ? index - (index % 2) : index);

  // MARK: Settings

  function applySettings(settings) {
    Object.assign(state.settings, settings);
    const s = state.settings;
    root.dataset.kbLayout = s.layout;
    root.dataset.kbTheme = s.theme;
    root.dataset.kbFont = s.font;
    root.dataset.kbWriting = s.writingMode;
    root.dataset.kbFurigana = s.furigana || 'book';
    root.style.setProperty('--kb-font-size', `${s.fontSize}px`);
    root.style.setProperty('--kb-line-height', String(s.lineHeight));
    root.style.setProperty('--kb-margin', `${s.margin}px`);
    root.dataset.kbImagePage = isImagePage() ? 'true' : 'false';
    // Padding = margin + the screen's safe area (Dynamic Island, home indicator), per side.
    for (const side of ['top', 'right', 'bottom', 'left']) root.style.setProperty(`--kb-pad-${side}`, `${pad(side)}px`);
    if (root.dataset.kbImagePage === 'true') {
      // Covers are often an SVG stretched to the page; keep their shape, centered.
      document.querySelectorAll('svg').forEach((svg) => svg.setAttribute('preserveAspectRatio', 'xMidYMid meet'));
    }
    state.vertical = getComputedStyle(document.body).writingMode.startsWith('vertical');
    root.dataset.kbAxis = state.vertical ? 'vertical' : 'horizontal';
  }

  /// Space between the screen edge and the text: the margin setting on the left and right,
  /// a fixed small gap at the top and bottom (columns run as long as the screen allows),
  /// and a thin frame for picture pages. Always plus the screen's safe area.
  const lineEndMargin = 20, pictureMargin = 8;
  function pad(side) {
    const inset = state.settings.insets?.[side] ?? 0;
    if (root.dataset.kbImagePage === 'true') return inset + pictureMargin;
    return inset + (side === 'left' || side === 'right' ? state.settings.margin : lineEndMargin);
  }

  /// A section that is only pictures (cover, illustrations).
  function isImagePage() {
    const text = document.body.textContent.replace(/\s/g, '');
    return text.length === 0 && document.body.querySelector('img, svg, image') !== null;
  }

  /// The characters that count, as Hoshi Reader and ッツ count them (BookTextIndex.count in
  /// Swift): letters only, no punctuation or spaces. Furigana is left out by the walkers.
  const countedCharacter = /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ가-힣ㄱ-ㆎ\p{Radical}\p{Unified_Ideograph}]/u;
  const countedCharacters = new RegExp(countedCharacter.source, 'gu');
  const countOf = (text) => text.match(countedCharacters)?.length ?? 0;

  /// Characters of text that count before `limit` in the section, or all of it.
  function characters(limit) {
    let count = 0;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => node.parentElement?.closest('rt, rp, script, style, .kb-mask') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (limit && (limit === node || limit.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING || limit.contains(node))) break;
      count += countOf(node.textContent);
    }
    return count;
  }

  /// Each character of `text` with its UTF-16 offset (kanji outside the BMP take two units).
  function* characterOffsets(text) {
    let offset = 0;
    for (const character of text) {
      yield [offset, character];
      offset += character.length;
    }
  }

  /// Text nodes that count as the section's characters (as `characters` counts them).
  function countedTextNodes() {
    return document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => node.parentElement?.closest('rt, rp, script, style, .kb-mask') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
  }

  /// Characters before the first one on this page. Finer than the first element on screen: a
  /// page can start inside a long paragraph. Scrolling layouts use the first element.
  function charactersBeforePage() {
    if (state.settings.layout !== 'paged') { const first = firstVisibleElement(); return first ? characters(first) : 0; }
    const origin = startEdge(), visibleStart = state.pages[state.page].start;
    const walker = countedTextNodes(), range = document.createRange();
    let count = 0;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent, length = countOf(text);
      if (!length) continue;
      range.selectNodeContents(node);
      const ends = [...range.getClientRects()].filter((r) => r.width || r.height).map((r) => span(r, origin)[1]);
      if (!ends.length || Math.max(...ends) <= visibleStart + 1) { count += length; continue; }
      // This node reaches the page: its first character on it.
      for (const [i, character] of characterOffsets(text)) {
        if (!countedCharacter.test(character)) continue;
        range.setStart(node, i);
        range.setEnd(node, i + character.length);
        const rect = range.getBoundingClientRect();
        if ((rect.width || rect.height) && span(rect, origin)[1] > visibleStart + 1) return count;
        count++;
      }
    }
    return count;
  }

  /// The page holding the character after `target` characters (as `charactersBeforePage` counts).
  function pageOfCharacter(target) {
    const origin = startEdge(), walker = countedTextNodes(), range = document.createRange();
    let count = 0;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      for (const [i, character] of characterOffsets(node.textContent)) {
        if (!countedCharacter.test(character)) continue;
        if (count === target) {
          range.setStart(node, i);
          range.setEnd(node, i + character.length);
          const rect = range.getBoundingClientRect();
          if (!rect.width && !rect.height) return null;
          const [a] = span(rect, origin);
          let index = 0;
          state.pages.forEach((page, p) => { if (page.start <= a + 1) index = p; });
          return index;
        }
        count++;
      }
    }
    return null;
  }

  // MARK: Geometry
  // Positions along the reading axis are measured from the start of the content:
  // leftwards from the right edge for vertical-rl, downwards for horizontal text.

  /// Where the content starts on screen: the body's padding edge (it moves as the page scrolls).
  function startEdge() {
    const rect = document.body.getBoundingClientRect();
    const style = getComputedStyle(document.body);
    return state.vertical ? rect.right - parseFloat(style.paddingRight) : rect.top + parseFloat(style.paddingTop);
  }

  function span(rect, origin) {
    return state.vertical ? [origin - rect.right, origin - rect.left] : [rect.top - origin, rect.bottom - origin];
  }

  function contentLength() {
    return state.vertical ? window.innerWidth - pad('left') - pad('right') : window.innerHeight - pad('top') - pad('bottom');
  }

  /// The occupied stretches of the reading axis (text lines and images), merged.
  function lineSpans() {
    const origin = startEdge();
    const spans = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      // Furigana counts: it sits beside its line and must be on the same page. It's taken with
      // its ruby, base and all, so it can't land on the page before its line (where it showed,
      // with the next line's word marks, beside the last line without its text).
      if (!node.textContent.trim() || node.parentElement?.closest('rp, .kb-mask')) continue;
      const ruby = node.parentElement?.closest('rt')?.closest('ruby');
      const base = ruby ? [...ruby.getClientRects()].filter((r) => r.width > 0 && r.height > 0).map((r) => span(r, origin)) : [];
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (!(rect.width > 0 && rect.height > 0)) continue;
        const own = span(rect, origin);
        // Furigana joins the stretch of its ruby's base beside it.
        const beside = base.find(([a, b]) => Math.abs((a + b) / 2 - (own[0] + own[1]) / 2) < (b - a) + (own[1] - own[0]));
        spans.push(beside ? [Math.min(own[0], beside[0]), Math.max(own[1], beside[1])] : own);
      }
    }
    for (const element of document.body.querySelectorAll('img, svg, video, hr')) {
      const rect = element.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) spans.push(span(rect, origin));
    }
    spans.sort((a, b) => a[0] - b[0]);
    const merged = [];
    for (const [a, b] of spans) {
      const last = merged[merged.length - 1];
      if (last && a < last[1] - 0.5) last[1] = Math.max(last[1], b);
      else merged.push([a, b]);
    }
    return merged;
  }

  /// Greedy page breaks between lines, so no line is cut in half.
  function paginate() {
    const length = contentLength();
    const spans = lineSpans();
    const pages = [];
    let i = 0;
    while (i < spans.length) {
      const start = spans[i][0];
      let end = spans[i][1];
      if (end - start > length) {
        // Taller than a page (a big image): give it whole pages.
        for (let s = start; s < end; s += length) pages.push({start: s, used: Math.min(length, end - s)});
        i++;
        continue;
      }
      i++;
      while (i < spans.length && spans[i][1] - start <= length) { end = Math.max(end, spans[i][1]); i++; }
      pages.push({start, used: end - start});
    }
    state.pages = pages.length ? pages : [{start: 0, used: 0}];
  }

  // MARK: Showing pages

  const masks = {};
  function ensureMasks() {
    for (const side of ['start', 'end']) {
      if (masks[side]) continue;
      const mask = document.createElement('div');
      mask.className = `kb-mask kb-mask-${side}`;
      // Outside the body: the body moves with a transform (see `shift`), which would carry
      // fixed children along with it.
      document.documentElement.appendChild(mask);
      masks[side] = mask;
    }
  }

  function showPage(index) {
    const paged = state.settings.layout === 'paged';
    state.page = Math.max(0, Math.min(index, state.pages.length - 1));
    const page = state.pages[state.page];
    if (paged) {
      // Put the page's first line at the start edge of the content area.
      const target = state.vertical ? window.innerWidth - pad('right') : pad('top');
      const current = startEdge() + (state.vertical ? -page.start : page.start);
      shift(current - target);
      // Hide whatever doesn't fully fit after the last whole line.
      const spare = Math.max(0, contentLength() - page.used);
      masks.start.style.cssText = state.vertical ? `right:0;top:0;bottom:0;width:${pad('right')}px` : `left:0;right:0;top:0;height:${pad('top')}px`;
      masks.end.style.cssText = state.vertical
        ? `left:0;top:0;bottom:0;width:${pad('left') + spare}px` : `left:0;right:0;bottom:0;height:${pad('bottom') + spare}px`;
    }
    report();
  }

  /// Moves the content back by `delta` along the reading axis. A transform rather than a
  /// scroll: on iOS the web view applies a scroll a frame apart from the masks, and the next
  /// column's edge flashed at the page's edge on a turn.
  let shiftedBy = 0, written3D = false;
  function shift(delta) {
    const scale = window.devicePixelRatio || 1;
    shiftedBy = Math.round((shiftedBy - delta) * scale) / scale;
    writeShift(false);
  }

  function writeShift(as3D) {
    written3D = as3D;
    const [x, y] = state.vertical ? [shiftedBy, 0] : [0, shiftedBy];
    const transform = as3D ? `translate3d(${x}px, ${y}px, 0)` : state.vertical ? `translateX(${x}px)` : `translateY(${y}px)`;
    document.body.style.setProperty('transform', transform, 'important');
  }

  /// Back from the background, WebKit can go on showing parts of the page painted before
  /// (a lookup mark that's gone from the page came back on later repaints). Moving the body's
  /// layer, as a page turn does, paints it afresh: the same shift, written the other way.
  function repaint() {
    if (state.settings.layout !== 'paged' || root.dataset.kbImagePage === 'true') return;
    writeShift(!written3D);
  }

  function clearShift() {
    shiftedBy = 0;
    document.body.style.removeProperty('transform');
  }

  function report() {
    const first = firstVisibleElement();
    const xpath = first ? xpathTo(first) : '', before = charactersBeforePage(), total = characters(null);
    // Where to come back to when the page is laid out again (a resize).
    state.place = {xpath, fraction: total ? before / total : null};
    post({kind: 'position', page: state.page, pages: state.pages.length, xpath, vertical: state.vertical,
          moved: state.moved || state.settings.layout === 'scroll' && scrolledByUser,
          characters: before, total, atEnd: state.page >= state.pages.length - step()});
  }

  function next() {
    state.moved = true;
    if (state.page + step() < state.pages.length) showPage(state.page + step());
    else post({kind: 'edge', direction: 'next'});
  }

  function previous() {
    state.moved = true;
    if (state.page > 0) showPage(spreadStart(Math.max(state.page - step(), 0)));
    else post({kind: 'edge', direction: 'previous'});
  }

  /// The facing page: shows page `index` of this section, or a blank page past its end (a
  /// chapter's last page faces an empty one; the next chapter starts a new spread).
  function follow(index) {
    state.follow = index;
    if (state.settings.layout !== 'paged') return;
    // Measured again each time: the page may have been resized since (folding, the controls),
    // and stale page breaks show the wrong page, or a column cut in half.
    fitLineStarts();
    paginate();
    const blank = index >= state.pages.length;
    document.body.style.visibility = blank ? 'hidden' : '';
    if (!blank) showPage(index);
  }

  // MARK: Position (Kavita's getXPathTo format)

  function xpathTo(element) {
    if (element.id) return `id("${element.id}")`;
    const steps = [];
    for (let node = element; node && node !== document.body; node = node.parentElement) {
      const tag = node.localName;
      let index = 1;
      for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
        if (sibling.localName === tag) index++;
      }
      steps.unshift(`${tag}[${index}]`);
      if (!node.parentElement) return '';
    }
    return '//' + ['body', ...steps].join('/');
  }

  /// Evaluates Kavita XPaths in HTML or namespaced XHTML documents.
  function resolveXPath(path) {
    if (!path) return null;
    const id = /^id\("(.+)"\)$/.exec(path);
    if (id) return document.getElementById(id[1]);
    const attempt = (expression) => {
      try {
        const node = document.evaluate(expression, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
        return node?.nodeType === Node.ELEMENT_NODE ? node : null;
      } catch { return null; }
    };
    return attempt(path) ?? attempt(path.replace(/(\/\/?)([a-zA-Z][\w-]*)/g, (_, slashes, tag) => `${slashes}*[local-name()='${tag}']`));
  }

  const positionSelector = 'p, h1, h2, h3, h4, h5, h6, li, dt, dd, blockquote, figure, img, svg, table';

  /// The first element on screen in reading order.
  function firstVisibleElement() {
    const origin = startEdge();
    let visibleStart;
    if (state.settings.layout === 'paged') visibleStart = state.pages[state.page].start;
    else visibleStart = state.vertical ? origin - (window.innerWidth - pad('right')) : pad('top') - origin;
    const visibleEnd = visibleStart + contentLength();
    for (const element of document.body.querySelectorAll(positionSelector)) {
      const rect = element.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) continue;
      const [a, b] = span(rect, origin);
      if (b > visibleStart + 1 && a < visibleEnd - 1) return element;
    }
    return null;
  }

  function currentXPath() {
    const element = firstVisibleElement();
    return element ? xpathTo(element) : '';
  }

  function pageOf(element) {
    const [a] = span(element.getBoundingClientRect(), startEdge());
    let index = 0;
    state.pages.forEach((page, i) => { if (page.start <= a + 1) index = i; });
    return index;
  }

  function scrollTo(element) {
    element?.scrollIntoView({block: 'start', inline: 'start'});
  }

  // MARK: Opening

  /// `at`: 'start', 'end', {xpath}, {fragment}, or {xpath, fraction}: the place as a fraction of
  /// the section's characters (exact in paged layouts), the xpath for scrolling.
  async function open(settings, at) {
    ensureMasks();
    applySettings(settings);
    await document.fonts?.ready;
    await Promise.all([...document.images].filter((img) => !img.complete).map((img) => new Promise((done) => {
      img.addEventListener('load', done, {once: true});
      img.addEventListener('error', done, {once: true});
    })));
    layout(at);
    // Shown only once laid out and positioned (hidden from document start), so turning
    // into a new section doesn't flash the wrong page or an unstyled one.
    root.style.removeProperty('opacity');
    post({kind: 'ready', vertical: state.vertical});
  }

  /// Hanging indents (contents pages, lists) can push text past the top margin (the
  /// left one in horizontal books), into the Dynamic Island; pad by that much more.
  function fitLineStarts() {
    root.style.setProperty('--kb-indent', '0px');
    const limit = state.vertical ? pad('top') : pad('left');
    let first = Infinity;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.textContent.trim() || node.parentElement?.closest('.kb-mask')) continue;
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (rect.width > 0 && rect.height > 0) first = Math.min(first, state.vertical ? rect.top : rect.left);
      }
    }
    if (first < limit - 0.5) root.style.setProperty('--kb-indent', `${Math.ceil(limit - first)}px`);
  }

  /// The character a saved fraction points at. A count rounded on the way (Swift scales it to
  /// the book's index) can land on the last character of the page before, so this takes the
  /// next one: a page's first character, or one more on the same page.
  function placeCharacter(fraction) {
    const total = characters(null);
    return Math.max(0, Math.min(Math.round(fraction * total) + 1, total - 1));
  }

  function layout(at) {
    if (root.dataset.kbImagePage === 'true' || state.settings.layout !== 'paged') clearShift();
    if (root.dataset.kbImagePage === 'true') {
      // One picture, pinned and centered: a single page, nothing to scroll or mask.
      state.pages = [{start: 0, used: contentLength()}];
      state.page = 0;
      report();
      return;
    }
    fitLineStarts();
    if (state.settings.layout === 'paged') {
      paginate();
      if (at?.follow != null) state.follow = at.follow;
      if (state.settings.companion && state.follow != null) {
        follow(state.follow);
        return;
      }
      let index = 0;
      if (at === 'end') index = state.pages.length - 1;
      else if (at?.fraction != null && pageOfCharacter(placeCharacter(at.fraction)) != null) {
        index = pageOfCharacter(placeCharacter(at.fraction));
      } else if (at?.xpath) { const element = resolveXPath(at.xpath); if (element) index = pageOf(element); }
      else if (at?.fragment) { const element = document.getElementById(at.fragment); if (element) index = pageOf(element); }
      showPage(spreadStart(index));
    } else {
      state.pages = [{start: 0, used: 0}];
      state.page = 0;
      if (at === 'end') window.scrollTo(state.vertical ? -document.body.scrollWidth : 0, state.vertical ? 0 : document.body.scrollHeight);
      else if (at?.xpath) scrollTo(resolveXPath(at.xpath));
      else if (at?.fragment) scrollTo(document.getElementById(at.fragment));
      report();
    }
  }

  /// Applies new settings and keeps the reader on the same text.
  function update(settings) {
    // The place last read (`state.place`): after a resize it's still the character the reader
    // was on, while this page may start a little before it.
    const place = state.place ?? {xpath: currentXPath(), fraction: null};
    applySettings(settings);
    // Measuring forces the new layout, so this can run right away (animation frames
    // don't run while the view is off screen). The same first character stays on screen.
    relayout(place);
  }

  /// Lays out again at `place` and keeps it as the place: the new page starts at or before
  /// its character, and taking that start as the place would move back a little more on
  /// every resize (folding and unfolding). A page turn sets a new place.
  function relayout(place) {
    layout(place?.xpath ? place : 'start');
    if (place?.xpath) state.place = place;
  }

  // MARK: Gestures

  // Touch swipes are recognized natively (the web view's scroll gesture would swallow them here).

  // Trackpad swipes on the Mac.
  // One page per gesture: momentum events keep arriving after the turn, so wait for a pause.
  let wheel = 0, wheelLocked = false, wheelTimer = null;
  document.addEventListener('wheel', (event) => {
    if (state.settings.layout !== 'paged') return;
    event.preventDefault();
    clearTimeout(wheelTimer);
    wheelTimer = setTimeout(() => { wheel = 0; wheelLocked = false; }, 200);
    if (wheelLocked) return;
    // Horizontal swipes follow the fingers (right = forward in right-to-left books); vertical wheel = forward when down.
    const horizontal = Math.abs(event.deltaX) > Math.abs(event.deltaY);
    const rtl = state.settings.rtl || state.vertical;
    wheel += horizontal ? (rtl ? -event.deltaX : event.deltaX) : event.deltaY;
    if (Math.abs(wheel) > 50) {
      wheelLocked = true;
      wheel > 0 ? next() : previous();
      wheel = 0;
    }
  }, {passive: false});

  // Arrow keys follow the page order (left goes forward in right-to-left books); space and Page Down go forward.
  document.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const rtl = state.settings.rtl || state.vertical;
    let forward = null;
    switch (event.key) {
      case 'ArrowLeft': forward = rtl; break;
      case 'ArrowRight': forward = !rtl; break;
      case ' ': case 'PageDown': forward = !event.shiftKey; break;
      case 'PageUp': forward = false; break;
      case 'ArrowDown': if (state.settings.layout === 'paged') forward = true; break;
      case 'ArrowUp': if (state.settings.layout === 'paged') forward = false; break;
    }
    if (forward === null) return;
    if (state.settings.layout !== 'paged' && !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    event.preventDefault();
    forward ? next() : previous();
  });

  // fingerScrolled: since the last scroll settled, so read-along can tell your scrolling from its own.
  let scrollTimer = null, scrolledByUser = false, fingerScrolled = false;
  ['touchmove', 'wheel', 'keydown'].forEach((type) => document.addEventListener(type, () => { scrolledByUser = fingerScrolled = true; }, {passive: true}));
  window.addEventListener('scroll', () => {
    if (state.settings.layout === 'paged') return;
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => {
      if (fingerScrolled) post({kind: 'userScroll'});
      fingerScrolled = false;
      report();
    }, 300);
  });

  // Back to the first character on the page before the resize (measuring now would use the
  // old pages against the new layout).
  let resizeTimer = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    const place = state.place;
    resizeTimer = setTimeout(() => relayout(place), 150);
  });

  /// Test aid: how the picture of a picture page is drawn (its file's size vs. its box on screen).
  function pictureInfo() {
    if (root.dataset.kbImagePage !== 'true') return undefined;
    const img = document.querySelector('img, svg');
    if (!img) return undefined;
    const r = img.getBoundingClientRect(), cs = getComputedStyle(img);
    // Any part of the picture under a visible mask is cut off.
    const covered = [...document.querySelectorAll('.kb-mask')].some((m) => {
      if (getComputedStyle(m).display === 'none') return false;
      const k = m.getBoundingClientRect();
      return k.width > 0 && k.height > 0 && k.left < r.right && k.right > r.left && k.top < r.bottom && k.bottom > r.top;
    });
    return {tag: img.localName, natural: [img.naturalWidth, img.naturalHeight], box: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
            fit: cs.objectFit, maxW: cs.maxWidth, maxH: cs.maxHeight, vh: innerHeight, covered};
  }

  /// Test aid: steps through every page of the section and reports characters that are
  /// cut by the page edges or shown on two pages. Returns to the page it started on.
  function audit() {
    const start = state.page;
    const masksNow = [...document.querySelectorAll('.kb-mask')];
    const chars = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (n.parentElement.closest('.kb-mask, rp')) continue;
      for (let i = 0; i < n.textContent.length; i++) if (n.textContent[i].trim()) chars.push([n, i]);
    }
    const seen = new Map();
    let cut = 0, repeated = 0;
    const examples = [];
    for (let p = 0; p < state.pages.length; p++) {
      showPage(p);
      let left = 0, right = innerWidth, top = 0, bottom = innerHeight;
      for (const m of masksNow) {
        const r = m.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;
        if (r.height >= innerHeight - 1) { if (r.left <= 0) left = Math.max(left, r.right); else right = Math.min(right, r.left); }
        else { if (r.top <= 0) top = Math.max(top, r.bottom); else bottom = Math.min(bottom, r.top); }
      }
      chars.forEach(([n, i], id) => {
        const range = document.createRange(); range.setStart(n, i); range.setEnd(n, i + 1);
        const c = range.getBoundingClientRect();
        if (c.width === 0) return;
        const ix = Math.min(c.right, right) - Math.max(c.left, left), iy = Math.min(c.bottom, bottom) - Math.max(c.top, top);
        if (ix <= 0.5 || iy <= 0.5) return;
        if (ix < c.width - 0.5 || iy < c.height - 0.5) {
          cut++;
          if (examples.length < 4) examples.push(`p${p} cut ${n.textContent[i]} x${Math.round(c.left)}-${Math.round(c.right)} box ${Math.round(left)}-${Math.round(right)}`);
        }
        if (seen.has(id)) { repeated++; if (examples.length < 8) examples.push(`p${p} again ${n.textContent[i]} (p${seen.get(id)})`); }
        else seen.set(id, p);
      });
    }
    showPage(start);
    // The masks only work if they're painted in the page color.
    const clearMasks = masksNow.filter((m) => {
      const color = getComputedStyle(m).backgroundColor;
      return color === 'transparent' || /rgba\(.*,\s*0\)$/.test(color);
    }).length;
    if (clearMasks) { cut += clearMasks; examples.push(`${clearMasks} transparent mask(s)`); }
    if (pictureInfo()?.covered) { cut += 1; examples.push('picture covered by a mask'); }
    // Line pitch, for comparing layouts across devices.
    const lines = lineSpans().map(([a]) => a);
    const gaps = lines.slice(1).map((a, i) => Math.round((a - lines[i]) * 10) / 10).filter((g) => g > 1);
    const p = document.querySelector('p');
    const style = p ? getComputedStyle(p) : null;
    return JSON.stringify({pages: state.pages.length, width: innerWidth, height: innerHeight, cut, repeated, examples,
      pitch: gaps.sort((x, y) => x - y)[Math.floor(gaps.length / 2)], fontSize: style?.fontSize, lineHeight: style?.lineHeight,
      font: style?.fontFamily, picture: pictureInfo()});
  }

  // MARK: Word marks
  // Words are wrapped in <km-w class="km-new|km-learning">, an element name of its own, so
  // positions (XPaths count same-name siblings) don't change, and nor does the layout: the
  // marks are only underlines.

  const markBlockSelector = 'p, li, td, th, dd, dt, h1, h2, h3, h4, h5, h6, blockquote, figcaption, div, section, body';

  /// The section's text in runs: consecutive text nodes in the same block, without furigana.
  function textRuns() {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => node.parentElement?.closest('rt, rp, script, style, .kb-mask') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    const runs = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const block = node.parentElement.closest(markBlockSelector);
      const last = runs[runs.length - 1];
      if (last && last.block === block) last.nodes.push(node);
      else runs.push({block, nodes: [node]});
    }
    return runs;
  }

  function unmarkWords() {
    window.lookupBridge?.clearHighlight();
    const parents = new Set();
    for (const mark of document.querySelectorAll('km-w')) {
      const parent = mark.parentNode;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      mark.remove();
      parents.add(parent);
    }
    parents.forEach((parent) => parent.normalize());
  }

  /// The runs' texts, for Swift to split into words.
  function wordRuns() {
    unmarkWords();
    return textRuns().map((run) => run.nodes.map((node) => node.textContent).join(''));
  }

  /// `marks`: [run, offset, length, class] with UTF-16 offsets into the run's text.
  function markWords(marks, accent) {
    unmarkWords();
    document.documentElement.style.setProperty('--km-accent', accent);
    const runs = textRuns();
    const pieces = new Map(); // text node -> [{from, to, cls}]
    for (const [runIndex, offset, length, cls] of marks) {
      const run = runs[runIndex];
      if (!run) continue;
      let position = 0;
      for (const node of run.nodes) {
        const end = position + node.textContent.length;
        const from = Math.max(offset, position), to = Math.min(offset + length, end);
        if (from < to) {
          if (!pieces.has(node)) pieces.set(node, []);
          pieces.get(node).push({from: from - position, to: to - position, cls});
        }
        if (end >= offset + length) break;
        position = end;
      }
    }
    // Split from the end of each node backwards, so earlier offsets stay valid.
    for (const [node, list] of pieces) {
      list.sort((a, b) => b.from - a.from);
      for (const {from, to, cls} of list) {
        const middle = node.splitText(from);
        middle.splitText(to - from);
        const mark = document.createElement('km-w');
        mark.className = cls;
        middle.parentNode.insertBefore(mark, middle);
        mark.appendChild(middle);
      }
    }
  }

  // MARK: Read-along
  // The spoken sentence is wrapped in <km-ra>, an element name of its own like <km-w>, so
  // XPaths and the layout stay put. Positions are (run, UTF-16 offset), as for word marks.

  /// Where the last tap landed in the section's runs (set by TextTapBridge.js on each tap).
  let lastTap = null;
  if (window.lookupBridge) {
    window.lookupBridge.onTap = (node, index) => {
      lastTap = null;
      textRuns().some((run, runIndex) => {
        let position = 0;
        for (const candidate of run.nodes) {
          if (candidate === node) { lastTap = {run: runIndex, offset: position + index}; return true; }
          position += candidate.textContent.length;
        }
        return false;
      });
    };
  }

  function clearReadAlong() {
    const parents = new Set();
    for (const mark of document.querySelectorAll('km-ra')) {
      const parent = mark.parentNode;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      mark.remove();
      parents.add(parent);
    }
    parents.forEach((parent) => parent.normalize());
  }

  /// Highlights `length` characters from `offset` in run `runIndex`; with `follow`, turns to
  /// its page when it isn't on screen. Returns the page it's on, or -1.
  function showReadAlong(runIndex, offset, length, follow) {
    clearReadAlong();
    const run = textRuns()[runIndex];
    if (!run) return -1;
    const pieces = [];
    let position = 0;
    for (const node of run.nodes) {
      const end = position + node.textContent.length;
      const from = Math.max(offset, position), to = Math.min(offset + length, end);
      if (from < to) pieces.push({node, from: from - position, to: to - position});
      if (end >= offset + length) break;
      position = end;
    }
    const marks = [];
    for (const {node, from, to} of pieces) {
      const middle = node.splitText(from);
      middle.splitText(to - from);
      const mark = document.createElement('km-ra');
      middle.parentNode.insertBefore(mark, middle);
      mark.appendChild(middle);
      marks.push(mark);
    }
    if (!marks.length) return -1;
    if (state.settings.layout !== 'paged') {
      if (follow) marks[0].scrollIntoView({block: 'center', inline: 'center'});
      return 0;
    }
    const first = pageOf(marks[0]), last = pageOf(marks[marks.length - 1]);
    // Following the audio is reading, so the new place is kept as progress. Facing pages
    // turn once it's past the left page.
    if (follow && (state.page + step() - 1 < first || state.page > last)) {
      state.moved = true;
      showPage(spreadStart(first));
    }
    return first;
  }

  /// The first character on screen as {run, offset} (UTF-16, within the run's text): where
  /// listening starts from the page you're on. By position, so a page starting inside a
  /// paragraph is placed inside it.
  function firstVisiblePlace() {
    const origin = startEdge();
    const visibleStart = state.settings.layout === 'paged' ? state.pages[state.page].start
      : (state.vertical ? origin - (window.innerWidth - pad('right')) : pad('top') - origin);
    const nextStart = state.settings.layout === 'paged' ? state.pages[state.page + step()]?.start : visibleStart + contentLength();
    const first = placeAfter(visibleStart, origin) ?? {run: 0, offset: 0};
    // Where the next page starts (null on the section's last page): listening can start at
    // the first sentence on this page.
    const next = nextStart == null ? null : placeAfter(nextStart, origin);
    return {...first, nextRun: next?.run ?? null, nextOffset: next?.offset ?? null};
  }

  /// The first character whose box ends past `edge` along the reading axis, as {run, offset}.
  function placeAfter(edge, origin) {
    const range = document.createRange();
    const runs = textRuns();
    for (let r = 0; r < runs.length; r++) {
      let position = 0;
      for (const node of runs[r].nodes) {
        const text = node.textContent;
        range.selectNodeContents(node);
        const ends = [...range.getClientRects()].filter((rect) => rect.width || rect.height).map((rect) => span(rect, origin)[1]);
        if (ends.length && Math.max(...ends) > edge + 1) {
          for (let i = 0; i < text.length; i++) {
            if (/\s/.test(text[i])) continue;
            range.setStart(node, i);
            range.setEnd(node, i + 1);
            const rect = range.getBoundingClientRect();
            if ((rect.width || rect.height) && span(rect, origin)[1] > edge + 1) return {run: r, offset: position + i};
          }
        }
        position += text.length;
      }
    }
    return null;
  }

  /// Kavita's XPath for a run's block, for progress while listening.
  function xpathOfRun(runIndex) {
    const block = textRuns()[runIndex]?.block;
    const element = block?.closest(positionSelector) ?? block;
    return element ? xpathTo(element) : '';
  }

  window.bookReader = {open, update, repaint, next, previous, follow, currentXPath, resolveXPath, xpathTo, audit,
    wordRuns, markWords, unmarkWords,
    readAlong: {show: showReadAlong, clear: clearReadAlong, lastTap: () => lastTap, xpathOfRun, firstVisiblePlace},
    pageCount: () => state.pages.length, page: () => state.page};
})();
