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
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      fetch: (input, init) => transport(input, { ...init, redirect: 'error' }),
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
