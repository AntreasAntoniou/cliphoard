// Serialized only into the device claim page; private URL values stay in memory.
export function deviceSetupRecoveryClient(runtime = globalThis) {
  const button = runtime.document.getElementById('recover-setup');
  const status = runtime.document.getElementById('recovery-status');
  if (!button || !status) return;
  let requestID;
  button.hidden = false;
  button.addEventListener('click', async () => {
    if (button.disabled) return;
    button.disabled = true;
    status.textContent = 'Requesting your setup email…';
    let timer;
    try {
      const url = new URL(runtime.location.href);
      if (url.pathname !== '/pro/claim' || url.searchParams.size !== 2 || !url.searchParams.has('order') || !url.searchParams.has('token')) throw Error();
      if (!requestID) requestID = runtime.btoa(String.fromCharCode(...runtime.crypto.getRandomValues(new Uint8Array(16)))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
      const controller = new runtime.AbortController();
      timer = runtime.setTimeout(() => controller.abort(), 10000);
      const response = await runtime.fetch('/pro/recover', {
        method: 'POST', credentials: 'same-origin', redirect: 'error', cache: 'no-store', referrerPolicy: 'no-referrer',
        headers: { 'Content-Type': 'application/json' }, signal: controller.signal,
        body: JSON.stringify({ orderRef: url.searchParams.get('order'), token: url.searchParams.get('token'), requestID }),
      });
      const body = await response.json();
      if (response.status !== 202 || body?.result !== 'delivery_requested') throw Error();
      status.textContent = 'Setup email requested. Check the email address you used at checkout, including spam.';
      button.textContent = 'Email requested';
    } catch {
      // Keep the same request ID after uncertain delivery, including timeout.
      status.textContent = 'We couldn’t confirm the request. Try again or contact support; you don’t need to buy again.';
      button.disabled = false;
    } finally { if (timer !== undefined) runtime.clearTimeout(timer); }
  });
}
