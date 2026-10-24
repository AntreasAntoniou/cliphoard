/* Local example clips only; appearance is owned by appearance.js. */
(() => {
  const iconURL = new URL('../img/icon.png', document.currentScript.src).href;
  let serial = 0;
  class ClipDemo extends HTMLElement {
    connectedCallback() {
      if (this.dataset.ready) return;
      this.dataset.ready = 'true';
      const everyday = this.dataset.examples === 'everyday';
      const id = `clip-search-${++serial}`;
      const asset = iconURL;
      this.innerHTML = `<div class="clip-demo"><div class="demo-toolbar"><span class="demo-brand"><img src="${asset}" alt="">Cliphoard</span><span class="demo-status">On your Mac</span></div><label class="sr-only" for="${id}">Search the example clips</label><div class="demo-search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/></svg><input id="${id}" type="search" placeholder="Find something you copied…" autocomplete="off"><kbd>⌃⌥⌘V</kbd></div><div class="demo-chips" aria-label="Try an example search"><button type="button" data-query="revert my last commit">revert my last commit</button><button type="button" data-query="catchy">catchy</button><button type="button" data-query="blue">blue</button><button type="button" data-query="">All clips</button></div><div class="demo-grid" role="region" aria-label="Example clips" tabindex="0"></div><p class="demo-mobile-hint">Swipe through clips, or choose a search above.</p><p class="demo-answer" aria-live="polite"></p></div><p class="demo-label">Interactive preview with example clips. Nothing is read from your clipboard.</p>`;
      const input = this.querySelector('input');
      const examples = everyday ? ['dinner recipe', 'where to meet', 'birthday'] : ['revert my last commit', 'catchy', 'blue'];
      this.querySelectorAll('[data-query]').forEach((button, i) => {
        if (i < examples.length) button.textContent = button.dataset.query = examples[i];
      });
      const cards = everyday ? [
        {kind:'Link',time:'Earlier today',text:'https://example.com/lemon-pasta',origin:'Safari',type:'text',keys:['dinner','recipe','pasta','lemon','food']},
        {kind:'Message',time:'10 minutes ago',text:'I’ll meet you by the station at 6.',origin:'Messages',type:'text',keys:['where','meet','station','6','message']},
        {kind:'Note',time:'Just copied',text:'Remember to bring the birthday candles.',origin:'Notes',type:'text',keys:['birthday','candles','party','note']}
      ] : [
        {kind:'Code',time:'2 minutes ago',text:'git reset --soft HEAD~1',origin:'Terminal',type:'code',keys:['revert','commit','git','reset','undo','soft']},
        {kind:'Text',time:'Today',text:'Copy anything. Hoard everything.',origin:'Notes',type:'text',keys:['catchy','copy','hoard','tagline','slogan','text']},
        {kind:'Colour',time:'Today',text:'#61AFEF',origin:'Design notes',type:'colour',keys:['blue','colour','color','61afef','design']}
      ];
      const render = () => {
        const q = input.value.toLowerCase().trim();
        const found = q ? cards.filter(card => card.keys.some(key => q.includes(key))) : cards;
        const grid = this.querySelector('.demo-grid'); grid.replaceChildren();
        found.forEach(card => {
          const node = document.createElement('article'); node.className = `demo-card${q ? ' is-match' : ''}`;
          const meta = document.createElement('span'); meta.className = 'demo-kind'; meta.textContent = `${card.kind} · ${card.time}`;
          const value = document.createElement(card.type === 'code' ? 'code' : 'strong'); value.textContent = card.text;
          node.append(meta);
          if(card.type === 'colour') { const colour = document.createElement('div'); colour.className='demo-colour'; colour.setAttribute('aria-hidden','true'); node.append(colour); }
          node.append(value);
          const origin = document.createElement('footer'); origin.textContent = card.origin; node.append(origin); grid.append(node);
        });
        if(!found.length) { const empty=document.createElement('p'); empty.className='demo-empty'; empty.textContent='This preview has three example clips. Try one of the searches above.'; grid.append(empty); }
        this.querySelector('.demo-answer').textContent = q ? (found.length ? `${found.length} example ${found.length === 1 ? 'clip' : 'clips'} found. The app runs meaning-based text search locally.` : 'No example clips match. Try revert my last commit, catchy or blue.') : '3 example clips. Copy normally. Open Cliphoard. Find the text, link or idea you need again.';
        this.querySelectorAll('[data-query]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.query === q)));
        if (everyday) this.querySelector('.demo-answer').textContent = q ? (found.length ? `${found.length} example ${found.length === 1 ? 'clip' : 'clips'} found. In the app, choose it and paste it where you need it.` : 'No examples match. Try dinner recipe, where to meet or birthday.') : 'You copied three things. All three are still here. Try finding the recipe again.';
      };
      this.querySelectorAll('[data-query]').forEach(button => button.addEventListener('click', () => { input.value = button.dataset.query; render(); }));
      input.addEventListener('input',render); render();
    }
  }
  if (!customElements.get('clip-demo')) customElements.define('clip-demo', ClipDemo);
})();
