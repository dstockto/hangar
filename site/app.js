// The whole of the landing page's JavaScript: a mobile menu and copy buttons.
// Both are enhancements. With scripting off the page still reads, every link
// still works, and the panel still shows its narrowed fleet.
//
// There is deliberately no typing animation. The panel is worth more composed
// and still than mid-keystroke, and a static panel cannot shift layout.

(() => {
  'use strict';

  /* ---------- Mobile menu ---------- */

  const burger = document.getElementById('burger');
  const sheet = document.getElementById('sheet');

  if (burger && sheet) {
    const setOpen = (open) => {
      sheet.dataset.open = String(open);
      burger.setAttribute('aria-expanded', String(open));
      // Only lock scrolling while the sheet covers the page.
      document.body.style.overflow = open ? 'hidden' : '';
    };

    burger.addEventListener('click', () => {
      setOpen(sheet.dataset.open !== 'true');
    });

    // Escape closes it and returns focus to the control that opened it.
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && sheet.dataset.open === 'true') {
        setOpen(false);
        burger.focus();
      }
    });

    // Choosing a section closes the sheet, otherwise the anchor scrolls behind it.
    sheet.addEventListener('click', (event) => {
      if (event.target.closest('a')) setOpen(false);
    });

    // A window widened past the breakpoint shows the real nav again, so the
    // sheet must not stay open and keep the body locked.
    window.addEventListener('resize', () => {
      if (window.innerWidth > 940 && sheet.dataset.open === 'true') setOpen(false);
    });
  }

  /* ---------- Copy buttons ---------- */

  document.querySelectorAll('.copy').forEach((button) => {
    const label = button.querySelector('[data-label]');
    const original = label ? label.textContent : '';

    button.addEventListener('click', async () => {
      const text = button.dataset.copy || '';
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        // Clipboard is refused without a secure context or permission. Select
        // the block instead so the keyboard can finish the job.
        const pre = button.closest('.code')?.querySelector('pre');
        if (pre) {
          const range = document.createRange();
          range.selectNodeContents(pre);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        }
        if (label) label.textContent = 'Press ⌘C';
        button.dataset.done = 'true';
        setTimeout(() => {
          if (label) label.textContent = original;
          delete button.dataset.done;
        }, 2400);
        return;
      }
      if (label) label.textContent = 'Copied';
      button.dataset.done = 'true';
      // Announced because the only other signal is colour.
      button.setAttribute('aria-label', 'Commands copied to clipboard');
      setTimeout(() => {
        if (label) label.textContent = original;
        delete button.dataset.done;
        button.removeAttribute('aria-label');
      }, 1800);
    });
  });

})();
