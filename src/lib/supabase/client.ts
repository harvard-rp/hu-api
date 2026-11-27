import { createClient } from '@supabase/supabase-js';
import { z } from 'zod';

import type { SupabaseBindings } from '../../config/bindings';
import { readSupabaseConfig } from './config';

type SupabaseClientOptions = {
  /** A request-scoped user JWT from the caller's authentication flow. */
  accessToken?: string;
  fetch?: typeof fetch;
};

const jwt = z.jwt();
const statelessAuth = {
  persistSession: false,
  autoRefreshToken: false,
  detectSessionInUrl: false,
};

async function fetchWithoutRedirects(
  transport: typeof fetch,
  input: Parameters<typeof fetch>[0],
  init?: RequestInit,
) {
  // Workers rejects redirect: 'error' before sending the request.
  const response = await transport(input, { ...init, redirect: 'manual' });
  if (response.status >= 300 && response.status < 400) {
    await response.body?.cancel();
    throw new Error('Unexpected Supabase redirect.');
  }
  return response;
}

export function createSupabaseAuthClient(
  bindings: SupabaseBindings | undefined,
) {
  const { url, publishableKey } = readSupabaseConfig(bindings);
  const client = createClient(url, publishableKey, {
    auth: { ...statelessAuth, skipAutoInitialize: true },
    global: {
      fetch: (input, init) =>
        fetchWithoutRedirects(fetch, input, {
          ...init,
          signal: AbortSignal.timeout(5000),
        }),
    },
  });
  return { auth: client.auth, issuer: `${url}/auth/v1` };
}

export function createSupabaseClient(
  bindings: SupabaseBindings | undefined,
  { accessToken, fetch: transport = fetch }: SupabaseClientOptions = {},
) {
  const { url, publishableKey } = readSupabaseConfig(bindings);
  if (accessToken !== undefined && !jwt.safeParse(accessToken).success) {
    throw new Error('Invalid Supabase user access token.');
  }

  return createClient(url, publishableKey, {
    accessToken: async () => accessToken ?? null,
    auth: statelessAuth,
    global: {
      fetch: (input, init) => fetchWithoutRedirects(transport, input, init),
    },
  });
}

export class SupabaseQueryError extends Error {
  constructor() {
    super('Supabase query failed.');
    this.name = 'SupabaseQueryError';
  }
}

export async function runSupabaseQuery<T>(
  query: () => PromiseLike<{ data: T; error: unknown }>,
): Promise<T> {
  let result;
  try {
    result = await query();
  } catch {
    throw new SupabaseQueryError();
  }

  if (result.error) {
    throw new SupabaseQueryError();
  }

  return result.data;
}
