// Tap-to-look-up bridge shared by the lookup popup, EPUB reader and browser.
// Sends the tapped block's text and the tapped character's UTF-16 offset in it
// to Swift (message handler "lookup"), which scans from there.
(() => {
  // Apps receive messages through a WKWebView handler; the Safari extension sets lookupBridgePost.
  const post = (message) => window.lookupBridgePost
    ? window.lookupBridgePost(message)
    : window.webkit?.messageHandlers?.lookup?.postMessage(message);
  const blockSelector = '.source, p, li, td, th, dd, dt, h1, h2, h3, h4, h5, h6, blockquote, figcaption, ' +
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

  // Looks up the character at a point (viewport coordinates), or reports a miss.
  function tapAt(x, y) {
    if (window.getSelection()?.toString()) return;

    // Taps that land on no character (margins, pictures) go to the host: readers turn pages with them.
    const miss = () => post({kind: 'miss', x, y});
    const caret = caretAt(x, y);
    if (!caret || caret.node.nodeType !== Node.TEXT_NODE) return miss();
    // Ignore furigana: look up from the base text instead.
    if (caret.node.parentElement?.closest('rt, rp')) return;
    const index = characterAt(caret.node, caret.offset, x, y);
    if (index === null) return miss();

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
    scrollToTop: () => window.scrollTo(0, 0),
    highlight,
    clearHighlight,
  };
})();
