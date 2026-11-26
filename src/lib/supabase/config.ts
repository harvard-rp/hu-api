import { z } from 'zod';

import type { SupabaseBindings } from '../../config/bindings';

const loopbackHosts = new Set(['localhost', '127.0.0.1', '[::1]']);

const configuration = z.object({
  SUPABASE_URL: z.string().refine((value) => {
    const url = URL.parse(value);
    return (
      url !== null &&
      (url.protocol === 'https:' ||
        (url.protocol === 'http:' && loopbackHosts.has(url.hostname))) &&
      (value === url.origin || value === `${url.origin}/`)
    );
  }),
  SUPABASE_PUBLISHABLE_KEY: z.string().regex(/^sb_publishable_[A-Za-z0-9_-]+$/),
});

export class SupabaseConfigurationError extends Error {
  constructor() {
    super('Supabase configuration is missing or invalid.');
    this.name = 'SupabaseConfigurationError';
  }
}

export function readSupabaseConfig(bindings: SupabaseBindings | undefined) {
  const result = configuration.safeParse(bindings);
  if (!result.success) {
    throw new SupabaseConfigurationError();
  }

  return {
    url: new URL(result.data.SUPABASE_URL).origin,
    publishableKey: result.data.SUPABASE_PUBLISHABLE_KEY,
  };
}
