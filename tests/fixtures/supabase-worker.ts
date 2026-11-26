import type { SupabaseBindings } from '../../src/config/bindings';
import {
  createSupabaseClient,
  runSupabaseQuery,
} from '../../src/lib/supabase/client';

export default {
  async fetch(_request, env) {
    const client = createSupabaseClient(env, {
      fetch: async () => Response.json([{ id: 'synthetic' }]),
    });
    const data = await runSupabaseQuery(() =>
      client.from('fixtures').select('id'),
    );
    return Response.json(data);
  },
} satisfies ExportedHandler<SupabaseBindings>;
