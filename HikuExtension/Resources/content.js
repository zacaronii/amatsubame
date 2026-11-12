// Tap Japanese text in a page: the shared tap bridge (TextTapBridge.js) finds the tapped
// block and character, the native side looks it up, and the result shows in a popup frame
// (an extension page, so the site's styles and scripts can't touch it).
(() => {
  let enabled = true;
  // Japanese text only (on by default): a tap on English, digits or punctuation looks nothing up.
  let japaneseOnly = true;
  browser.storage.local.get(['enabled', 'japaneseOnly']).then((stored) => {
    enabled = stored.enabled !== false;
    japaneseOnly = stored.japaneseOnly !== false;
  });
  browser.storage.onChanged.addListener((changes) => {
    if (changes.enabled) {
      enabled = changes.enabled.newValue !== false;
      if (!enabled) hide();
    }
    if (changes.japaneseOnly) japaneseOnly = changes.japaneseOnly.newValue !== false;
  });

  // Kana (half-width too), kanji, 々〆ヶ, ー and full-width letters and digits.
  const japanese = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}\u3005\u3006\u30FC\uFF70\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A]/u;

  /// Whether the character at a UTF-16 offset is Japanese (offsets can land on a surrogate pair's second half).
  function isJapaneseAt(text, offset) {
    const unit = text.charCodeAt(offset);
    const start = unit >= 0xDC00 && unit <= 0xDFFF && offset > 0 ? offset - 1 : offset;
    const point = text.codePointAt(start);
    return point !== undefined && japanese.test(String.fromCodePoint(point));
  }

  // Taps come from pointer events: iOS Safari doesn't send page-wide clicks for taps on
  // plain text. A tap is a short press that barely moves (not a scroll, drag or long press).
  const controls = 'a, button, input, textarea, select, label, summary, [contenteditable], [role="button"]';
  let down = null;
  // Set when a tap only closed the popup, so the click it makes doesn't also follow a link.
  let swallowsClick = false;
  document.addEventListener('pointerdown', (event) => {
    down = event.isPrimary ? {x: event.clientX, y: event.clientY, time: event.timeStamp} : null;
    swallowsClick = false;
  }, true);
  document.addEventListener('click', (event) => {
    if (!swallowsClick) return;
    swallowsClick = false;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);
  document.addEventListener('pointerup', (event) => {
    const start = down;
    down = null;
    if (!enabled || !start || !event.isPrimary) return;
    if (Math.hypot(event.clientX - start.x, event.clientY - start.y) > 10 || event.timeStamp - start.time > 500) return;
    // With a popup open, a tap on the page only closes it: on a page full of text
    // nearly every tap lands on a word. The next tap looks up. Links and buttons too: the tap
    // closes the popup instead of following them.
    if (popupOpen()) {
      request++;
      swallowsClick = true;
      return hide();
    }
    if (event.target.closest?.(controls)) return;
    window.lookupBridge?.tapAt(event.clientX, event.clientY);
  }, true);
  document.addEventListener('pointercancel', () => { down = null; }, true);

  let host = null;
  let frame = null;
  let toast = null;
  let request = 0;

  window.lookupBridgePost = (message) => {
    if (message.kind === 'miss') return hide();
    if (message.kind !== 'tap') return;
    if (japaneseOnly && !isJapaneseAt(message.text, message.offset)) return hide();
    const current = ++request;
    // The first lookup prepares the dictionaries, which can take a while.
    const slow = setTimeout(() => current === request && say('Looking up… (the first time prepares the dictionaries)'), 700);
    browser.runtime.sendMessage({
      action: 'lookup', text: message.text, offset: message.offset, title: document.title, url: location.href,
    }).then((response) => {
      clearTimeout(slow);
      if (current !== request) return;
      say(null);
      if (!response || response.error) {
        hide();
        say('Hiku: ' + (response?.error ?? 'no answer from the extension'), 4000);
        return;
      }
      if (!response.found) return hide();
      window.lookupBridge?.highlight(message.offset, response.matchLength);
      // Pages don't have the apps' highlight style; colour the marks directly.
      for (const mark of document.querySelectorAll('span.lookup-highlight')) {
        mark.style.setProperty('background-color', 'rgba(255, 204, 0, 0.45)', 'important');
        mark.style.setProperty('border-radius', '3px', 'important');
      }
      show(response.id, message.rect, response.stats);
    }, (error) => {
      clearTimeout(slow);
      say('Hiku: ' + error, 4000);
    });
  };

  /// Shown and at least partly on screen (one scrolled out of sight doesn't swallow a tap).
  function popupOpen() {
    if (!host || host.style.getPropertyValue('display') === 'none') return false;
    const box = host.getBoundingClientRect();
    return box.bottom > 0 && box.top < window.innerHeight && box.right > 0 && box.left < window.innerWidth;
  }

  function hide() {
    window.lookupBridge?.clearHighlight();
    if (host) host.style.setProperty('display', 'none', 'important');
  }

  function important(rules) {
    return rules.map((rule) => rule + ' !important').join(';');
  }

  /// A small message at the bottom of the screen (nil hides it).
  function say(text, duration) {
    if (!toast) {
      toast = document.createElement('div');
      document.documentElement.append(toast);
    }
    if (!text) return toast.style.setProperty('display', 'none', 'important');
    toast.textContent = text;
    toast.setAttribute('style', important([
      'position:fixed', 'left:50%', 'bottom:24px', 'transform:translateX(-50%)', 'max-width:90vw',
      'padding:8px 14px', 'border-radius:10px', 'background:rgba(0,0,0,.8)', 'color:#fff',
      'font:14px -apple-system,sans-serif', 'z-index:2147483647', 'display:block',
    ]));
    if (duration) setTimeout(() => toast.textContent === text && say(null), duration);
  }

  function show(id, rect, stats) {
    if (!host) {
      host = document.createElement('div');
      const shadow = host.attachShadow({mode: 'closed'});
      frame = document.createElement('iframe');
      frame.setAttribute('style', 'border:0;width:100%;height:100%;border-radius:12px;background:Canvas;color-scheme:light dark;');
      shadow.append(frame);
      document.documentElement.append(host);
    }
    const width = Math.min(420, window.innerWidth - 16);
    const height = Math.min(Math.round(window.innerHeight * 0.45), 420);
    const left = Math.max(8, Math.min(rect.x + window.scrollX - width / 2, window.scrollX + window.innerWidth - width - 8));
    const below = rect.y + rect.height + 8;
    const top = (below + height < window.innerHeight ? below : Math.max(8, rect.y - height - 8)) + window.scrollY;
    host.setAttribute('style', important([
      'position:absolute', `left:${left}px`, `top:${top}px`, `width:${width}px`, `height:${height}px`,
      'z-index:2147483647', 'display:block', 'box-shadow:0 6px 24px rgba(0,0,0,.35)', 'border-radius:12px',
    ]));
    const query = stats ? '?' + new URLSearchParams(Object.entries(stats)).toString() : '';
    frame.src = browser.runtime.getURL('popup-frame.html') + query + '#' + id;
  }
})();
