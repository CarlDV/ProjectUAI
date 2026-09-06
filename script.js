document.addEventListener('DOMContentLoaded', () => {
  const copyBtn = document.getElementById('copyLoadstringBtn');
  const codeEl = document.getElementById('loadstringCode');
  
  if (copyBtn && codeEl) {
    copyBtn.addEventListener('click', async () => {
      const codeText = codeEl.textContent.trim();
      try {
        await navigator.clipboard.writeText(codeText);
        const originalText = copyBtn.innerHTML;
        copyBtn.classList.add('copied');
        copyBtn.innerHTML = `
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <polyline points="20 6 9 17 4 12"></polyline>
          </svg>
          Copied!
        `;
        setTimeout(() => {
          copyBtn.classList.remove('copied');
          copyBtn.innerHTML = originalText;
        }, 2200);
      } catch (err) {
        console.error('Failed to copy to clipboard', err);
      }
    });
  }

  const mobileToggle = document.getElementById('mobileMenuToggle');
  const siteNav = document.getElementById('siteNav');
  
  if (mobileToggle && siteNav) {
    mobileToggle.addEventListener('click', () => {
      const isOpen = siteNav.classList.toggle('open');
      mobileToggle.setAttribute('aria-expanded', isOpen);
      mobileToggle.innerHTML = isOpen ? `
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <line x1="18" y1="6" x2="6" y2="18"></line>
          <line x1="6" y1="6" x2="18" y2="18"></line>
        </svg>
      ` : `
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <line x1="3" y1="12" x2="21" y2="12"></line>
          <line x1="3" y1="6" x2="21" y2="6"></line>
          <line x1="3" y1="18" x2="21" y2="18"></line>
        </svg>
      `;
    });

    siteNav.querySelectorAll('.nav-link').forEach(link => {
      link.addEventListener('click', () => {
        siteNav.classList.remove('open');
        mobileToggle.setAttribute('aria-expanded', 'false');
      });
    });
  }
});
