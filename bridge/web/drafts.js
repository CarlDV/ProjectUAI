/* Draft bodies use asynchronous storage, never multi-megabyte sessionStorage writes. */
(function (root) {
  'use strict';
  root.UAI = root.UAI || {};
  let db;
  const ready = new Promise(resolve => {
    try {
      const request = indexedDB.open('uai-cowork', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('drafts', { keyPath: 'id' });
      request.onsuccess = () => { db = request.result; resolve(db); };
      request.onerror = request.onblocked = () => resolve(null);
    } catch { resolve(null); }
  });
  async function load(id) {
    if (!await ready) return null;
    return new Promise(resolve => {
      try {
        const request = db.transaction('drafts').objectStore('drafts').get(id);
        request.onsuccess = () => resolve(request.result?.value || null);
        request.onerror = () => resolve(null);
      } catch { resolve(null); }
    });
  }
  async function save(id, value) {
    if (!await ready) return false;
    return new Promise(resolve => {
      try {
        const transaction = db.transaction('drafts', 'readwrite'), store = transaction.objectStore('drafts');
        if (!value.text && !value.uploads?.length) store.delete(id);
        else store.put({ id, value, updatedAt: Date.now() });
        const request = store.getAll();
        request.onsuccess = () => {
          const list = request.result.sort((a, b) => b.updatedAt - a.updatedAt);
          let bytes = 0;
          for (let i = 0; i < list.length; i++) {
            const item = list[i];
            bytes += (item.value.text?.length || 0) * 2 + (item.value.uploads || []).reduce((n, f) => n + (f.text?.length || 0) * 2, 0);
            if (i >= 20 || (bytes > 32 * 1024 * 1024 && item.id !== id)) store.delete(item.id);
          }
        };
        transaction.oncomplete = () => resolve(true);
        transaction.onerror = transaction.onabort = () => resolve(false);
      } catch { resolve(false); }
    });
  }
  root.UAI.drafts = { load, save };
})(window);
