'use strict';

(() => {
  function setupNavigation() {
    const header = document.getElementById('siteHeader');
    const toggle = document.getElementById('mobileMenuToggle');
    const nav = document.getElementById('siteNav');
    if (!header || !toggle || !nav) return;
    const mobile = window.matchMedia('(max-width: 60rem)');
    const label = toggle.querySelector('.menu-label');
    let open = false;

    function setOpen(requested) {
      open = mobile.matches && requested;
      nav.hidden = mobile.matches && !open;
      toggle.hidden = !mobile.matches;
      toggle.setAttribute('aria-expanded', String(open));
      toggle.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
      if (label) label.textContent = open ? 'Close' : 'Menu';
    }

    toggle.addEventListener('click', () => setOpen(!open));
    nav.addEventListener('click', event => {
      if (event.target.closest('a')) setOpen(false);
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && open) {
        event.preventDefault();
        setOpen(false);
        toggle.focus();
      }
    });
    document.addEventListener('pointerdown', event => {
      if (open && !header.contains(event.target)) setOpen(false);
    });
    document.addEventListener('focusin', event => {
      if (open && !header.contains(event.target)) setOpen(false);
    });
    const resized = () => {
      const active = document.activeElement;
      setOpen(false);
      if (mobile.matches && nav.contains(active)) toggle.focus({ preventScroll: true });
      else if (!mobile.matches && active === toggle) nav.querySelector('a')?.focus({ preventScroll: true });
    };
    if (mobile.addEventListener) mobile.addEventListener('change', resized);
    else mobile.addListener(resized);
    header.classList.add('menu-ready');
    setOpen(false);
  }

  function setupCopy() {
    const status = document.getElementById('copyStatus');
    let statusTimer;
    function announce(message, duration) {
      if (!status) return;
      window.clearTimeout(statusTimer);
      status.textContent = message;
      statusTimer = window.setTimeout(() => { status.textContent = ''; }, duration);
    }

    function selectText(target) {
      try {
        const focusTarget = target.closest('pre') || target;
        if (!focusTarget.hasAttribute('tabindex')) focusTarget.setAttribute('tabindex', '-1');
        focusTarget.focus({ preventScroll: true });
        const selection = window.getSelection();
        if (!selection) return false;
        const range = document.createRange();
        range.selectNodeContents(target);
        selection.removeAllRanges();
        selection.addRange(range);
        return true;
      } catch {
        return false;
      }
    }

    document.querySelectorAll('[data-copy]').forEach(button => {
      const target = document.getElementById(button.dataset.copy);
      const label = button.querySelector('[data-copy-label]');
      if (!target || !label) return;
      // Capture the original label once; repeated clicks cannot save "Copied".
      const defaultLabel = label.textContent;
      const name = button.dataset.copyName || 'Text';
      let resetTimer;
      let copying = false;
      button.addEventListener('click', async () => {
        if (copying) return;
        copying = true;
        window.clearTimeout(resetTimer);
        button.setAttribute('aria-busy', 'true');
        button.setAttribute('aria-disabled', 'true');
        label.textContent = 'Copying…';
        try {
          if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
          await navigator.clipboard.writeText(target.textContent.trim());
          label.textContent = 'Copied';
          button.dataset.state = 'copied';
          announce(name + ' copied. ' + (button.dataset.copy === 'loadstringCode'
            ? 'Paste it into your executor.' : 'Paste it into UAI.'), 4000);
        } catch {
          const selected = selectText(target);
          label.textContent = selected ? 'Text selected' : 'Copy manually';
          button.dataset.state = 'manual';
          announce(selected
            ? name + ' selected. Use Ctrl+C, ⌘C, or your device’s Copy command.'
            : 'Clipboard unavailable. Select the ' + name.toLowerCase() + ' text and copy it manually.', 10000);
        } finally {
          copying = false;
          button.removeAttribute('aria-busy');
          button.removeAttribute('aria-disabled');
          resetTimer = window.setTimeout(() => {
            label.textContent = defaultLabel;
            delete button.dataset.state;
          }, 2500);
        }
      });
      button.hidden = false;
    });
  }

  function setupCatalog() {
    const toolbar = document.getElementById('toolFilters');
    const search = document.getElementById('toolSearch');
    const category = document.getElementById('toolCategory');
    const clear = document.getElementById('clearFilters');
    const status = document.getElementById('catalogStatus');
    const empty = document.getElementById('catalogEmpty');
    const catalog = document.getElementById('toolCatalog');
    if (!toolbar || !search || !category || !clear || !status || !empty || !catalog) return;

    const groups = [...catalog.querySelectorAll('.tool-group')].map(element => {
      const label = element.querySelector('.tool-group-label').textContent;
      return {
        element, label, id: element.dataset.group, browsingOpen: element.open,
        count: element.querySelector('.tool-group-count'),
        rows: [...element.querySelectorAll('.tool-row')].map(row => ({
          element: row, text: (label + ' ' + row.textContent).toLowerCase(),
        })),
      };
    });
    const total = groups.reduce((sum, group) => sum + group.rows.length, 0);
    let filtering = false;
    let timer;

    function applyFilters() {
      window.clearTimeout(timer);
      const words = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
      const active = words.length > 0 || category.value !== '';
      let found = 0;
      let visibleGroups = 0;
      for (const group of groups) {
        if (active && !filtering) group.browsingOpen = group.element.open;
        let count = 0;
        for (const row of group.rows) {
          const matches = (!category.value || category.value === group.id) &&
            words.every(word => row.text.includes(word));
          row.element.hidden = !matches;
          if (matches) count++;
        }
        group.element.hidden = count === 0;
        group.count.textContent = active
          ? count + ' / ' + group.rows.length + ' tools'
          : group.rows.length + ' tools';
        if (active) group.element.open = count > 0;
        else if (filtering) group.element.open = group.browsingOpen;
        found += count;
        if (count) visibleGroups++;
      }
      filtering = active;
      clear.disabled = !active;
      empty.hidden = found > 0;
      status.textContent = (active ? found + ' of ' + total : total) +
        (found === 1 && !active ? ' tool' : ' tools') + ' across ' + visibleGroups +
        (visibleGroups === 1 ? ' group' : ' groups');
    }

    search.addEventListener('input', () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(applyFilters, 80);
    });
    category.addEventListener('change', applyFilters);
    clear.addEventListener('click', () => {
      search.value = '';
      category.value = '';
      applyFilters();
      search.focus();
    });
    // Refresh restored form values when returning through browser history.
    window.addEventListener('pageshow', applyFilters);
    applyFilters();
    toolbar.hidden = false;
  }

  setupNavigation();
  setupCopy();
  setupCatalog();
})();
