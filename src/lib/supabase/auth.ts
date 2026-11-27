import {
  isAuthApiError,
  isAuthSessionMissingError,
} from '@supabase/supabase-js';
import { z } from 'zod';

import type { SupabaseBindings } from '../../config/bindings';
import { createSupabaseAuthClient } from './client';

export type VerifiedAuth = {
  readonly authUserId: string;
  readonly accessToken: string;
};

const claimsSchema = z.object({
  iss: z.string(),
  sub: z.uuid(),
  aud: z.union([z.string(), z.array(z.string())]),
  exp: z.number(),
  role: z.literal('authenticated'),
  session_id: z.uuid(),
  is_anonymous: z.literal(false),
});

function readClaims(token: string) {
  const payload = token.split('.')[1] ?? '';
  try {
    const bytes = Uint8Array.from(
      atob(payload.replaceAll('-', '+').replaceAll('_', '/')),
      (value) => value.charCodeAt(0),
    );
    return claimsSchema.safeParse(JSON.parse(new TextDecoder().decode(bytes)))
      .data;
  } catch {
    return undefined;
  }
}

type Verification =
  | { status: 'verified'; identity: VerifiedAuth }
  | { status: 'invalid' | 'unavailable' };

export async function verifyAccessToken(
  bindings: SupabaseBindings | undefined,
  authorization: string | undefined,
): Promise<Verification> {
  const accessToken = /^Bearer +([\w-]+\.[\w-]+\.[\w-]+)$/i.exec(
    authorization ?? '',
  )?.[1];
  if (!accessToken) return { status: 'invalid' };

  try {
    const { auth, issuer } = createSupabaseAuthClient(bindings);
    const { data, error } = await auth.getUser(accessToken);
    if (error) {
      const denied =
        isAuthSessionMissingError(error) ||
        (isAuthApiError(error) &&
          (error.status === 401 ||
            error.status === 403 ||
            error.code === 'bad_jwt' ||
            error.code === 'session_not_found' ||
            error.code === 'user_not_found'));
      return { status: denied ? 'invalid' : 'unavailable' };
    }

    const userId = z.uuid().safeParse(data.user?.id);
    if (!userId.success) return { status: 'unavailable' };

    // These checks only narrow acceptance after the configured Auth server
    // has verified this token. Identity comes from the verified user response.
    const claims = readClaims(accessToken);
    if (
      !claims ||
      claims.iss !== issuer ||
      claims.sub !== userId.data ||
      ![claims.aud].flat().includes('authenticated') ||
      claims.exp <= Date.now() / 1000 ||
      data.user?.is_anonymous !== false
    )
      return { status: 'invalid' };

    return {
      status: 'verified',
      identity: { authUserId: userId.data, accessToken },
    };
  } catch {
    return { status: 'unavailable' };
  }
}
