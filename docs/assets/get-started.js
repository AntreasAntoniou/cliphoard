(() => {
  const section = document.querySelector('.install-options');
  if (!section) return;
  const button = section.querySelector('[data-copy-install]');
  const command = section.querySelector('.install-command code');
  const status = section.querySelector('[data-install-status]');
  if (!button || !command || !status) return;
  button.hidden = false;
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      await navigator.clipboard.writeText(command.textContent.trim());
      status.textContent = 'Copied. Paste it into Terminal to install.';
    } catch {
      status.textContent = 'Select the command and copy it, then paste it into Terminal.';
    } finally {
      button.disabled = false;
    }
  });
})();
