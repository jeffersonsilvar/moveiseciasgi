import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_');
  const key = env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();
  const rawUrl = env.VITE_SUPABASE_URL?.trim();

  // Browser bundles must never contain a Supabase secret key.
  if (key?.startsWith('sb_secret_')) {
    throw new Error(
      'Configuracao insegura: VITE_SUPABASE_PUBLISHABLE_KEY contem uma chave secreta. ' +
      'Revogue a chave exposta no Supabase e utilize uma chave sb_publishable_.'
    );
  }
  if (rawUrl) {
    let url: URL;
    try {
      url = new URL(rawUrl);
    } catch {
      throw new Error('VITE_SUPABASE_URL precisa ser uma URL valida, sem parametros.');
    }
    if (url.search || url.hash) {
      throw new Error('VITE_SUPABASE_URL nao deve conter query string nem fragmento. Use apenas https://<project-ref>.supabase.co');
    }
  }

  return { plugins: [react()] };
});
