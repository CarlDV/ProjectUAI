/* ==========================================================================
   Project UAI · Cowork — pre-paint theme initializer.

   Loaded BLOCKING in <head> BEFORE the stylesheet so the light/dark decision
   is made before first paint (no theme flash). No framework, no dependency,
   no CDN — a tiny synchronous IIFE plus the shared window.UAI surface.

   Persists the operator's choice in localStorage['uai.theme'] as one of
   'system' | 'light' | 'dark' | 'game' (default 'system'). 'system' is resolved from
   matchMedia('(prefers-color-scheme: dark)') and RE-resolved live while the
   choice stays 'system'. Sets documentElement.dataset.theme = 'light' | 'dark'
   (and dataset.themeChoice so a toggle control can show the raw choice).

   window.UAI.theme = { get(), set(mode), toggle(), resolved() }
     get()       -> 'system' | 'light' | 'dark' | 'game' (the stored choice)
     resolved()  -> 'light' | 'dark'              (what is actually painted)
     set(mode)   -> persists + reapplies, returns the resolved value
     toggle()    -> flips light<->dark from the CURRENT resolved value
   ========================================================================== */
(function (root) {
  'use strict';

  var KEY = 'uai.theme';
  var VALID = { system: 1, light: 1, dark: 1, game: 1 };
  var gameDark = true;
  var doc = root.document;
  var el = doc && doc.documentElement;

  function readChoice() {
    try {
      var stored = root.localStorage && root.localStorage.getItem(KEY);
      return VALID[stored] ? stored : 'system';
    } catch (e) {
      return 'system';
    }
  }

  function writeChoice(mode) {
    try {
      if (root.localStorage) root.localStorage.setItem(KEY, mode);
    } catch (e) {
      /* private mode / disabled storage: keep the in-memory choice only. */
    }
  }

  function systemDark() {
    try {
      return !!(root.matchMedia && root.matchMedia('(prefers-color-scheme: dark)').matches);
    } catch (e) {
      return false;
    }
  }

  function resolve(mode) {
    if (mode === 'game') return gameDark ? 'dark' : 'light';
    if (mode === 'light') return 'light';
    if (mode === 'dark') return 'dark';
    return systemDark() ? 'dark' : 'light';
  }

  var choice = readChoice();

  function apply() {
    var resolved = resolve(choice);
    if (el) {
      el.setAttribute('data-theme', resolved);
      el.setAttribute('data-theme-choice', choice);
    }
    // Let interested UI (e.g. the header toggle) react without polling.
    try {
      doc.dispatchEvent(new CustomEvent('uai:theme', {
        detail: { choice: choice, resolved: resolved }
      }));
    } catch (e) {
      /* CustomEvent unavailable (very old engine): the attribute is enough. */
    }
    return resolved;
  }

  // Resolve synchronously, before the stylesheet paints.
  apply();

  // While following the OS, repaint when the OS preference flips.
  try {
    var mq = root.matchMedia && root.matchMedia('(prefers-color-scheme: dark)');
    if (mq) {
      var onChange = function () { if (choice === 'system') apply(); };
      if (mq.addEventListener) mq.addEventListener('change', onChange);
      else if (mq.addListener) mq.addListener(onChange);
    }
  } catch (e) {
    /* no matchMedia: system mode simply falls back to light. */
  }

  root.UAI = root.UAI || {};
  root.UAI.theme = {
    get: function () {
      return choice;
    },
    resolved: function () {
      return resolve(choice);
    },
    set: function (mode) {
      choice = VALID[mode] ? mode : 'system';
      writeChoice(choice);
      return apply();
    },
    toggle: function () {
      return this.set(resolve(choice) === 'dark' ? 'light' : 'dark');
    },
    game: function (dark) {
      if (gameDark === dark) return;
      gameDark = dark;
      if (choice === 'game') apply();
    }
  };
})(typeof window !== 'undefined' ? window : this);
