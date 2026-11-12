// Word marks, as in Yomu's books: words not in the mining deck underlined in Hiku's accent,
// ones being learned dotted grey, known ones left alone (Settings ▸ Lookup ▸ word marks).
// Paragraphs are split into words on the native side as they scroll into view. Each word gets
// its own short line, with a gap to the next as in the apps, drawn in a layer over the page
// (ranges over the page's own text), so the page's HTML is never changed.
(() => {
  let enabled = true;
  browser.storage.local.get(['enabled']).then((stored) => {
    enabled = stored.enabled !== false;
    if (enabled) start(); else clear();
  });
  browser.storage.onChanged.addListener((changes) => {
    if (!changes.enabled) return;
    enabled = changes.enabled.newValue !== false;
    if (enabled) start(); else clear();
  });

  const japanese = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u;
  const blockSelector = 'p, li, td, th, dd, dt, h1, h2, h3, h4, h5, h6, blockquote, figcaption, caption, div, section, article, body';
  const skipped = 'rt, rp, script, style, noscript, textarea, input, select, [contenteditable], svg, math';
  /// Marked words: a live range each (so a relayout moves it) and its kind.
  let marked = [];
  let layer = null;
  /// Blocks seen (observed), and blocks marked or on their way.
  const seen = new WeakSet();
  const requested = new WeakSet();
  let queue = [];
  let sending = false;
  let started = false;
  let off = false;

  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting || requested.has(entry.target)) continue;
      requested.add(entry.target);
      observer.unobserve(entry.target);
      queue.push(entry.target);
    }
    flush();
  }, {rootMargin: '600px 0px'});

  function start() {
    if (started || off) return;
    started = true;
    layer = document.createElement('div');
    layer.setAttribute('aria-hidden', 'true');
    layer.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:0;';
    document.documentElement.appendChild(layer);
    // The page's layout changes (a resize, fonts, a section opening): draw the lines again.
    let redrawing = null;
    const later = () => { clearTimeout(redrawing); redrawing = setTimeout(draw, 200); };
    new ResizeObserver(later).observe(document.body);
    window.addEventListener('resize', later);
    scan(document.body);
    // Pages that add text later (feeds, infinite scroll, single-page apps).
    let pending = null;
    new MutationObserver((mutations) => {
      if (!enabled || off) return;
      clearTimeout(pending);
      pending = setTimeout(() => {
        for (const mutation of mutations) {
          for (const node of mutation.addedNodes) if (node.nodeType === Node.ELEMENT_NODE) scan(node);
        }
      }, 500);
    }).observe(document.body, {childList: true, subtree: true});
  }

  function clear() {
    marked = [];
    layer?.replaceChildren();
  }

  /// The block a text node belongs to (its paragraph, list item, cell…).
  function blockOf(node) {
    return node.parentElement?.closest(blockSelector) ?? null;
  }

  /// Text nodes of a block that count, in order, without furigana (as TextTapBridge reads text).
  function textNodes(block) {
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => {
        const parent = node.parentElement;
        if (!parent || parent.closest(skipped)) return NodeFilter.FILTER_REJECT;
        // Only this block's own text: a nested block is marked on its own.
        return blockOf(node) === block ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      },
    });
    const nodes = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node);
    return nodes;
  }

  /// Watches the blocks under `root` that hold Japanese text.
  function scan(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => (japanese.test(node.textContent) && !node.parentElement?.closest(skipped))
        ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const block = blockOf(node);
      if (!block || seen.has(block)) continue;
      seen.add(block);
      observer.observe(block);
    }
  }

  /// Sends what's waiting, 20 blocks at a time, one message after another.
  async function flush() {
    if (sending || !enabled || off) return;
    sending = true;
    try {
      while (queue.length && enabled && !off) {
        const blocks = queue.splice(0, 20).filter((block) => block.isConnected);
        const items = blocks.map((block) => {
          const nodes = textNodes(block);
          return {nodes, text: nodes.map((node) => node.textContent).join('')};
        }).filter((item) => japanese.test(item.text));
        if (!items.length) continue;
        const response = await browser.runtime.sendMessage({action: 'marks', texts: items.map((item) => item.text)})
          .catch(() => null);
        if (!response || response.error) return;
        if (response.off) {
          off = true;
          clear();
          return;
        }
        if (response.accent) document.documentElement.style.setProperty('--hiku-accent', response.accent);
        items.forEach((item, index) => apply(item, response.marks?.[index] ?? []));
      }
    } finally {
      sending = false;
    }
  }

  /// Turns [offset, length, class] (UTF-16, in the block's text) into marked ranges.
  function apply(item, marks) {
    for (const [offset, length, kind] of marks) {
      if (kind !== 'km-new' && kind !== 'km-learning') continue;
      let position = 0;
      for (const node of item.nodes) {
        const end = position + node.textContent.length;
        const from = Math.max(offset, position), to = Math.min(offset + length, end);
        if (from < to && node.isConnected) {
          const range = document.createRange();
          range.setStart(node, from - position);
          range.setEnd(node, to - position);
          marked.push({range, kind});
          drawOne(range, kind);
        }
        if (end >= offset + length) break;
        position = end;
      }
    }
  }

  /// A short line under each line box of the word: inset at both ends, so neighbours don't join.
  function drawOne(range, kind) {
    if (!range.startContainer.isConnected) return;
    const accent = getComputedStyle(document.documentElement).getPropertyValue('--hiku-accent').trim() || '#ee4f6b';
    for (const rect of range.getClientRects()) {
      if (rect.width < 2 || rect.height < 2) continue;
      const inset = Math.min(rect.width * 0.12, 3);
      const line = document.createElement('div');
      const thickness = Math.max(1.5, rect.height * 0.08);
      line.style.cssText = `position:absolute;left:${rect.left + scrollX + inset}px;top:${rect.bottom + scrollY - thickness}px;` +
        `width:${rect.width - inset * 2}px;height:0;border-bottom:${thickness}px ${kind === 'km-new' ? 'solid ' + accent : 'dotted #aeaeb2'};`;
      layer.appendChild(line);
    }
  }

  function draw() {
    if (!layer) return;
    layer.replaceChildren();
    marked = marked.filter(({range}) => range.startContainer.isConnected);
    for (const {range, kind} of marked) drawOne(range, kind);
  }

})();
