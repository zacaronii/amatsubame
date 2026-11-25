// Tap-to-look-up bridge shared by the lookup popup, EPUB reader and browser.
// Sends the tapped block's text and the tapped character's UTF-16 offset in it
// to Swift (message handler "lookup"), which scans from there.
(() => {
  // Apps receive messages through a WKWebView handler; the Safari extension sets lookupBridgePost.
  const post = (message) => window.lookupBridgePost
    ? window.lookupBridgePost(message)
    : window.webkit?.messageHandlers?.lookup?.postMessage(message);
  const blockSelector = 'p, li, td, th, dd, dt, h1, h2, h3, h4, h5, h6, blockquote, figcaption, ' +
    '[data-sc-content], .gloss-content, .expression, .entry, body';

  function caretAt(x, y) {
    if (document.caretRangeFromPoint) {
      const range = document.caretRangeFromPoint(x, y);
      return range ? {node: range.startContainer, offset: range.startOffset} : null;
    }
    const position = document.caretPositionFromPoint?.(x, y);
    return position ? {node: position.offsetNode, offset: position.offset} : null;
  }

  // caretRangeFromPoint picks the nearest gap, which can be after the last
  // character of the tapped one; check which character's box contains the point.
  function characterAt(node, offset, x, y) {
    const text = node.textContent;
    for (const candidate of [offset, offset - 1]) {
      if (candidate < 0 || candidate >= text.length) continue;
      const range = document.createRange();
      range.setStart(node, candidate);
      range.setEnd(node, candidate + 1);
      for (const rect of range.getClientRects()) {
        if (x >= rect.left - 1 && x <= rect.right + 1 && y >= rect.top - 1 && y <= rect.bottom + 1) return candidate;
      }
    }
    return null;
  }

  document.addEventListener('click', (event) => {
    // In a web page (the Safari extension) taps come through lookupBridge.tapAt instead:
    // iOS Safari doesn't send page-wide clicks for taps on plain text.
    if (window.lookupBridgePost) return;
    const target = event.target;
    const action = target.closest?.('[data-action]');
    if (action) {
      event.preventDefault();
      if (action.classList.contains('status-button')) toggleStatus(action);
      post({kind: action.dataset.action, index: Number(action.dataset.index)});
      return;
    }
    const link = target.closest?.('a.gloss-link');
    if (link && link.dataset.lookup !== undefined) {
      event.preventDefault();
      post({kind: 'query', query: link.dataset.lookup});
      return;
    }
    if (link) return; // external links are opened by the native navigation delegate
    tapAt(event.clientX, event.clientY);
  });

  // Known and Ignore toggle like Hachidori's: pressing the pressed one clears the word's mark.
  // Every entry of the same headword follows (the native side keeps the same rule).
  function toggleStatus(button) {
    const pressed = button.getAttribute('aria-pressed') !== 'true';
    for (const other of document.querySelectorAll('.status-button')) {
      if (other.dataset.headword !== button.dataset.headword) continue;
      other.setAttribute('aria-pressed', String(pressed && other.dataset.action === button.dataset.action));
    }
  }

  // Looks up the character at a point (viewport coordinates), or reports a miss.
  function tapAt(x, y) {
    lookAt(x, y, false);
  }

  // `hovering`: the pointer rests there (the Mac's Look Up on Hover). Unlike a tap it never
  // reports a miss (a miss turns the page), and it leaves the word that's showing alone.
  function lookAt(x, y, hovering) {
    if (window.getSelection()?.toString()) return;

    // Taps that land on no character (margins, pictures) go to the host: readers turn pages with them.
    const miss = () => { if (!hovering) post({kind: 'miss', x, y}); };
    const caret = caretAt(x, y);
    if (!caret || caret.node.nodeType !== Node.TEXT_NODE) return miss();
    // Ignore furigana: look up from the base text instead.
    if (caret.node.parentElement?.closest('rt, rp')) return;
    const index = characterAt(caret.node, caret.offset, x, y);
    if (index === null) return miss();
    if (hovering) {
      // Letters, kana, kanji and digits only, and not the word already looked up.
      if (!/[\p{L}\p{N}]/u.test(caret.node.textContent[index])) return;
      if (caret.node.parentElement?.closest('span.lookup-highlight')) return;
    }

    const block = caret.node.parentElement.closest(blockSelector) ?? document.body;
    lastBlock = block;
    // A reader can note where in its own text the tap landed (Yomu's read-along).
    window.lookupBridge?.onTap?.(caret.node, index);
    const before = document.createRange();
    before.setStart(block, 0);
    before.setEnd(caret.node, index);
    const offset = textWithoutRuby(before.cloneContents()).length;
    const rect = (() => {
      const range = document.createRange();
      range.setStart(caret.node, index);
      range.setEnd(caret.node, index + 1);
      const r = range.getBoundingClientRect();
      return {x: r.left, y: r.top, width: r.width, height: r.height};
    })();
    post({kind: 'tap', text: textWithoutRuby(block), offset, rect});
  }

  // Text as read, without furigana (<rt>/<rp>), so offsets line up with the base text.
  function textWithoutRuby(root) {
    const clone = root.cloneNode ? root.cloneNode(true) : root;
    clone.querySelectorAll?.('rt, rp').forEach((node) => node.remove());
    return clone.textContent ?? '';
  }

  let lastBlock = null;

  // Look Up on Hover (the Mac; Settings ▸ Popup): 'off', a key that must be held ('shift',
  // 'option', 'control', 'command'), or 'always'. Off until the host turns it on (setHover),
  // so the popup's own pages and the Safari extension don't scan under the pointer.
  let hoverMode = 'off';
  let hoverTimer = null;
  let pointer = null;

  function hoverAllowed(event) {
    switch (hoverMode) {
      case 'shift': return event.shiftKey;
      case 'option': return event.altKey;
      case 'control': return event.ctrlKey;
      case 'command': return event.metaKey;
      case 'always': return true;
      default: return false;
    }
  }

  // After a short rest, so the pointer crossing the text on its way elsewhere looks nothing up.
  function hoverSoon(event) {
    clearTimeout(hoverTimer);
    if (!pointer || !hoverAllowed(event)) return;
    const at = pointer;
    hoverTimer = setTimeout(() => lookAt(at.x, at.y, true), hoverMode === 'always' ? 180 : 60);
  }

  document.addEventListener('mousemove', (event) => {
    if (hoverMode === 'off') return;
    pointer = {x: event.clientX, y: event.clientY};
    hoverSoon(event);
  });
  // The key pressed with the pointer already on a word.
  document.addEventListener('keydown', (event) => {
    if (hoverMode !== 'off' && !event.repeat) hoverSoon(event);
  });
  document.addEventListener('mouseleave', () => {
    pointer = null;
    clearTimeout(hoverTimer);
  });

  /// Marks `length` characters from `offset` in the last tapped block (offsets as sent,
  /// i.e. without furigana) by wrapping them in <span class="lookup-highlight">. (The CSS
  /// Custom Highlight API registers but doesn't paint in some EPUB pages.)
  function highlight(offset, length) {
    clearHighlight();
    if (!lastBlock || length <= 0) return;
    const walker = document.createTreeWalker(lastBlock, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => node.parentElement?.closest('rt, rp') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    const pieces = [];
    let position = 0;
    for (let node = walker.nextNode(); node && position < offset + length; node = walker.nextNode()) {
      const end = position + node.textContent.length;
      const start = Math.max(offset, position), stop = Math.min(offset + length, end);
      if (start < stop) pieces.push({node, from: start - position, to: stop - position});
      position = end;
    }
    for (const {node, from, to} of pieces) {
      const middle = node.splitText(from);
      middle.splitText(to - from);
      const mark = document.createElement('span');
      mark.className = 'lookup-highlight';
      middle.parentNode.insertBefore(mark, middle);
      mark.appendChild(middle);
    }
  }

  function clearHighlight() {
    for (const mark of document.querySelectorAll('span.lookup-highlight')) {
      const parent = mark.parentNode;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      mark.remove();
      parent.normalize();
    }
  }

  window.lookupBridge = {
    tapAt,
    setHover: (mode) => { hoverMode = mode; },
    scrollToTop: () => window.scrollTo(0, 0),
    highlight,
    clearHighlight,
  };
})();
