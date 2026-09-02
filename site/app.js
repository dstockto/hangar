// The whole of the landing page's JavaScript: a mobile menu, copy buttons, and
// the panel's typing animation. All three are enhancements. With scripting off
// the page still reads, every link still works, and the panel still shows its
// narrowed fleet, because the markup ships in the final state.

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

  /* ---------- The panel narrows while you watch ---------- */

  // The point of the product is the narrowing, so the panel types the query and
  // drops the rows that stop matching. It plays when it first scrolls into view
  // and then stops, rather than looping forever: continuous motion in a hero is
  // its own kind of rude, and there is a Replay button for a second look.
  const panel = document.getElementById('panel');

  if (panel) {
    const QUERY = 'payments prod web';
    // Character index at which each token finishes, and the stage it produces.
    const TOKEN_DONE = { 8: 1, 13: 2, 17: 3 };
    const STAGES = [
      { total: '2,847 hosts', group: '2,847' },
      { total: '31 of 2,847', group: '31' },
      { total: '12 of 2,847', group: '12' },
      { total: '3 of 2,847', group: '3' },
    ];

    const queryEl = panel.querySelector('[data-query]');
    const totalEl = panel.querySelector('[data-total]');
    const groupCountEl = panel.querySelector('[data-group-count]');
    const caret = panel.querySelector('.caret');
    const rows = [...panel.querySelectorAll('.row')];
    const marks = [...panel.querySelectorAll('.alias mark')];
    const groups = [...panel.querySelectorAll('.group')];
    const replay = document.querySelector('[data-replay]');
    const still = window.matchMedia('(prefers-reduced-motion: reduce)');

    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    const setStage = (stage) => {
      panel.dataset.stage = String(stage);
      totalEl.textContent = STAGES[stage].total;
      groupCountEl.textContent = STAGES[stage].group;
      rows.forEach((row) => {
        const out = Number(row.dataset.out || 99) <= stage;
        row.toggleAttribute('data-gone', out);
      });
      marks.forEach((mark) => {
        mark.toggleAttribute('data-on', Number(mark.dataset.t) <= stage);
      });
      groups.forEach((group) => {
        const only = group.dataset.stageOnly;
        const from = group.dataset.stageFrom;
        group.hidden = only !== undefined
          ? stage !== Number(only)
          : stage < Number(from);
      });
    };

    let playing = false;

    const play = async () => {
      if (playing) return;
      playing = true;
      if (replay) replay.disabled = true;
      setStage(0);
      queryEl.textContent = '';
      caret.dataset.typing = 'true';
      await wait(700);
      for (let i = 1; i <= QUERY.length; i += 1) {
        queryEl.textContent = QUERY.slice(0, i);
        if (TOKEN_DONE[i]) {
          await wait(140);
          setStage(TOKEN_DONE[i]);
          await wait(620);
        } else {
          // Spaces read as a beat between words rather than a keystroke.
          await wait(QUERY[i - 1] === ' ' ? 130 : 62);
        }
      }
      delete caret.dataset.typing;
      playing = false;
      if (replay) replay.disabled = false;
    };

    // Reduced motion gets the finished panel and no Replay button: the answer
    // without the performance.
    if (still.matches) {
      setStage(3);
    } else {
      setStage(3);
      if (replay) {
        replay.hidden = false;
        replay.addEventListener('click', play);
      }
      const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          observer.disconnect();
          play();
        });
        // A low threshold on purpose: an ancestor clips the panel, so the
        // observed ratio never reaches a half even when it is plainly on screen.
      }, { threshold: 0.1 });
      observer.observe(panel);
    }
  }

})();
