# Database

## Data access

Supabase provides the future PostgreSQL Data API. Worker code uses `createSupabaseClient(bindings)` from `src/lib/supabase/client.ts` only when a route needs it. The factory validates the bindings on use. The HTTP application and its liveness endpoint start independently of Supabase.

| Worker binding             | Expected value                                                                                                                                                       |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SUPABASE_URL`             | Canonical HTTPS API origin, with an optional trailing slash. Local HTTP is accepted for `localhost`, `127.0.0.1` and `[::1]`. Use the API gateway URL from Supabase. |
| `SUPABASE_PUBLISHABLE_KEY` | The matching `sb_publishable_` API key. The factory accepts only the publishable key format.                                                                         |

Create a client within the request that uses it. For a future authenticated request, pass `{ accessToken }` with the user JWT supplied by the authentication flow. The factory checks JWT syntax. Token verification and access decisions belong to the authentication flow and Supabase policies. Each factory call closes over its own token. The SDK uses the request token callback with storage, refresh and URL session detection disabled.

Wrap awaited Data API queries in `runSupabaseQuery(() => client.from(...).select(...))`. It returns the data or raises a generic error without the SDK error payload. Missing or invalid configuration raises `SupabaseConfigurationError` before any network call. The factory accepts a test fetch and rejects HTTP redirects. API logs may contain the request ID and status only. Keep real configuration in ignored local files or deployment bindings. Keep JWTs, passwords and administrative credentials out of fixtures, source and logs.

## Local Supabase

Use Node.js 24 LTS, the pinned pnpm version and a running **local** Docker Engine. Docker Engine 28 or newer is recommended for loopback port isolation on shared networks. Run these commands from the repository root.

```sh
pnpm install --frozen-lockfile
docker info
pnpm supabase:start
pnpm supabase:status
```

The start script creates or validates the `supabase_network_hu-api` Docker bridge with the host binding set to `127.0.0.1`. Use this script to keep the stack on loopback. The local API listens on `127.0.0.1:54321`, PostgreSQL on port `54322`, and Studio on port `54323`. Keep these ports off tunnels and public proxies. The CLI provides its own local credentials. Project signup and Data API auto-grants are disabled in `supabase/config.jsonc`.

Create `.dev.vars` from the example and keep its CORS setting as needed. To retrieve only the local Worker settings without printing the CLI status payload, create an ignored file with the following command and copy its two lines into your `.dev.vars`. Remove the temporary file when finished.

```sh
pnpm exec supabase status --output json | node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
const { API_URL, PUBLISHABLE_KEY } = JSON.parse(readFileSync(0, "utf8"));
if (API_URL !== "http://127.0.0.1:54321" || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(PUBLISHABLE_KEY)) {
  throw new Error("Expected local Supabase API settings.");
}
writeFileSync(".dev.vars.supabase-local",
  `SUPABASE_URL=${API_URL}\nSUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}\n`,
  { flag: "wx", mode: 0o600 });
'
```

| Command                 | Purpose                                                                                                     |
| ----------------------- | ----------------------------------------------------------------------------------------------------------- |
| `pnpm supabase:start`   | Start the local stack using the loopback bridge.                                                            |
| `pnpm supabase:stop`    | Stop the `hu-api` local stack and keep its database volume.                                                 |
| `pnpm supabase:status`  | Show local container status without credentials.                                                            |
| `pnpm supabase:reset`   | Discard local database data, replay Git migrations and run the local seed.                                  |
| `pnpm supabase:types`   | Regenerate `src/lib/supabase/database.types.ts` from the local `public` schema after successful CLI output. |
| `pnpm test:integration` | Run pgTAP against the running local database.                                                               |

The scripts accept no additional arguments. Supabase CLI v3 treats `db reset`, `gen types` and `test db` as local unless a remote target is selected. The scripts omit all remote targets. The reset script uses the same loopback network as startup.

## Migrations and fixtures

1. Create a timestamped migration with `pnpm exec supabase migration new <snake_case_name>`.
2. Write the SQL under `supabase/migrations/`. Keep each migration focused and review it in Git. Add another migration to evolve a migration that has already been applied to a shared environment.
3. Apply pending migrations to the running local stack with `pnpm exec supabase migration up`. Use `pnpm supabase:reset` to verify the entire migration history and seed on a clean local database.
4. Run `pnpm test:integration` and regenerate types with `pnpm supabase:types`. Review and commit the generated types with the schema changes that require them.

Use `snake_case` for SQL objects. Use UUID primary keys for domain entities, `timestamptz` for timestamps and explicit foreign keys and integrity constraints. Seed only deterministic, synthetic data in `supabase/seed.sql`. Place database assertions in `supabase/tests/` and keep probes transactional so their schema changes roll back.

### Grants and row-level security

Publish only approved tables and views in the API schema. Put private data in unexposed schemas and grant access to the smallest set of roles and operations. Enable RLS on every table exposed through the Data API. In the same migration, add specific PostgreSQL grants and policies for each required action and role. Use `USING` for row visibility and `WITH CHECK` for new values where applicable. Include positive and negative tests for anonymous access, authenticated access and cross-user access. The default is to deny access until both the grant and the policy authorize it.

## Validation

Run `pnpm test` for SDK and HTTP tests with synthetic data and injected fetch. Run `pnpm build` for two Wrangler dry runs: the HTTP Worker and a test-only Worker that exercises the Supabase SDK bundle. Both commands work without Docker or remote credentials.

### Automated PostgreSQL validation

The [Database tests workflow](../.github/workflows/database-tests.yml) runs on a standard Ubuntu 24.04 runner for changes to Supabase configuration, migrations, the database script, the application, tests or the toolchain. Review the **Database tests** check on the pull request or in the repository's **Actions** tab. Once the workflow is present on the default branch, use **Actions → Database tests → Run workflow** for a manual run.

The job checks Docker, starts the local Supabase stack on the runner, reports container names and status, rebuilds the local database, runs pgTAP, generates `src/lib/supabase/database.types.ts` on the runner and runs TypeScript checking. The cleanup step runs after any failed step once Docker has been verified. All database operations use the runner's local stack and the job requires only read access to repository contents.

Use the same commands to reproduce the job on a machine with Docker.

```sh
pnpm supabase:start
pnpm supabase:status
pnpm supabase:reset
pnpm test:integration
pnpm supabase:types
pnpm typecheck
pnpm supabase:stop
```

Run the stop command after an unsuccessful local run as well. The pgTAP smoke test checks PostgreSQL 17 and verifies that a new table receives no default CRUD grants for `anon` and `authenticated`. The probe rolls back.

## Environments

| Environment       | Purpose                                                               | Credentials and changes                                                                            |
| ----------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Local             | Disposable PostgreSQL 17 stack for development, resets and SQL tests. | Only CLI-issued local settings and synthetic data.                                                 |
| `hu-development`  | Existing hosted project in `eu-west-1` with PostgreSQL 17.            | Use separate bindings. Remote linking or migrations require an approved shared-environment change. |
| Future production | Separate environment for live data.                                   | Use independent bindings, access controls and a reviewed release process.                          |

For future access to `hu-development`, retrieve the API URL and publishable key from the authorized project's Dashboard and set the Worker bindings in the target environment. Linking is a separate CLI operation for maintainers who need remote migration management. After authorization, authenticate with the CLI locally, verify the intended project, and run `pnpm exec supabase link --project-ref <approved-project-ref>`. Review migration history and the SQL to apply before a manually approved release. The repository scripts and CI target the local stack only.

Official references [local development](https://supabase.com/docs/guides/local-development), [CLI v3 targeting](https://supabase.com/docs/guides/local-development/cli/migrating-to-v3), [API keys](https://supabase.com/docs/guides/getting-started/api-keys) and [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).
