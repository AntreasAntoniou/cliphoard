(() => {
  const section = document.getElementById('all-features');
  if (!section) return;
  const button = section.querySelector('[data-expand-features]');
  const groups = [...section.querySelectorAll('.feature-group')];
  if (!button || !groups.length) return;
  button.hidden = false;
  button.setAttribute('aria-controls', groups.map(group => group.id).join(' '));
  const update = () => {
    const allOpen = groups.every(group => group.open);
    button.textContent = allOpen ? 'Collapse all' : 'Expand all';
    button.setAttribute('aria-expanded', String(allOpen));
  };
  button.addEventListener('click', () => {
    const open = !groups.every(group => group.open);
    groups.forEach(group => { group.open = open; });
    update();
  });
  groups.forEach(group => group.addEventListener('toggle', update));
  update();
})();
