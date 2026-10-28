import { WorkerEntrypoint } from 'cloudflare:workers';
export class SyntheticEmail extends WorkerEntrypoint {
  async send(message) { return (await fetch('https://mail.synthetic.invalid', { method: 'POST', body: JSON.stringify(message) })).json(); }
}
export class SyntheticRateLimit extends WorkerEntrypoint {
  async limit() { return { success: true }; }
}
export default { fetch() { return new Response(null, { status: 404 }); } };
