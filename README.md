# Harvard University RP API

The API serves the Harvard University RP Discord community and provides the HTTP backend for the campus web application. Hono handles requests in a Cloudflare Workers module. Node.js runs the development tools.

## Getting started

Install Node.js 24 LTS and pnpm 10.34.9. The `packageManager` field pins pnpm. If you use Corepack, run `corepack enable pnpm` in a writable Node.js installation.

```sh
pnpm install --frozen-lockfile
pnpm dev
```

Wrangler serves the Worker at `http://localhost:8787` by default. Both endpoints work with the default configuration. For database development, use [the Supabase guide](docs/DATABASE.md).

```sh
curl -i http://localhost:8787/health
curl -i http://localhost:8787/openapi.json
```

## Commands

| Command                 | Purpose                                                                             |
| ----------------------- | ----------------------------------------------------------------------------------- |
| `pnpm dev`              | Start the local Cloudflare Workers runtime.                                         |
| `pnpm build`            | Check the HTTP and test-only Supabase Worker bundles with Wrangler dry runs.        |
| `pnpm test`             | Run the test suite once.                                                            |
| `pnpm test:watch`       | Rerun tests as files change.                                                        |
| `pnpm lint`             | Check the source and tests with ESLint.                                             |
| `pnpm lint:fix`         | Apply ESLint fixes and report remaining issues.                                     |
| `pnpm format`           | Format supported project files with Prettier.                                       |
| `pnpm format:check`     | Check formatting with Prettier.                                                     |
| `pnpm typecheck`        | Check TypeScript types without emitting files.                                      |
| `pnpm supabase:start`   | Start the local Supabase stack on a loopback Docker bridge.                         |
| `pnpm supabase:stop`    | Stop the local stack and retain its data.                                           |
| `pnpm supabase:status`  | Show local services without credentials.                                            |
| `pnpm supabase:reset`   | Rebuild the local database from migrations and seed data.                           |
| `pnpm supabase:types`   | Generate types from the local PostgreSQL schema.                                    |
| `pnpm test:integration` | Run local database integration tests with Docker.                                   |
| `pnpm deploy`           | Publish the Worker to an authorized Cloudflare account when deployment is approved. |

## Database validation

The [Database tests workflow](.github/workflows/database-tests.yml) runs PostgreSQL 17 and pgTAP against a disposable Supabase stack on GitHub Actions when a push or pull request changes database, source, test or toolchain files. It also tests Supabase Auth with synthetic users, regenerates database types and checks for drift. See [the database guide](docs/DATABASE.md#automated-postgresql-validation) for the run and local reproduction instructions.

## HTTP API

| Endpoint                      | Response                                                                                                     |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `GET /health`                 | HTTP 200 with `{"status":"ok","service":"hu-api"}`. This checks liveness independently of external services. |
| `POST /api/v1/auth/bootstrap` | Initialize or retrieve the current player using their linked Discord identity.                               |
| `GET /api/v1/me`              | The current player context. Requires a Supabase Auth bearer token.                                           |
| `GET /openapi.json`           | HTTP 200 with the OpenAPI 3.0.3 document.                                                                    |

Every response carries a server-generated `X-Request-Id`. Unregistered routes return HTTP 404 with the following JSON structure. Unexpected failures use the same structure with HTTP 500, code `INTERNAL_ERROR` and a generic message.

```json
{
  "error": {
    "code": "NOT_FOUND",
    "message": "Route not found.",
    "requestId": "20e429f4-c3ab-4d28-9b14-e88b9403f9af"
  }
}
```

Future domain routes will live under `/api/v1`.

## Environment

| Variable               | Value                                                                                                                                                                                               | Default         |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| `CORS_ALLOWED_ORIGINS` | Comma-separated, exact HTTP(S) browser origins such as `http://localhost:5173,https://campus.example`. Use the serialized origin, including any non-default port, without a trailing slash or path. | Empty allowlist |

Use `cp .dev.vars.example .dev.vars` to configure a local frontend origin and restart Wrangler after editing. A blank setting or any invalid entry results in an empty allowlist. The public paths permit cross-origin GET requests from approved origins, expose `X-Request-Id` and support preflight without credentials or custom request headers. Same-origin and direct HTTP clients can call the public endpoints with the default configuration.

Set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` in your ignored `.dev.vars` when working on routes that query Supabase. Both variables are required for authenticated endpoints. [Authentication](docs/AUTHENTICATION.md) · [Database setup](docs/DATABASE.md)

## Code layout

- `src/index.ts` exports the Worker entry point.
- `src/app.ts` creates Hono instances and wires routes, middleware and error handling.
- `src/config/` defines the CORS allowlist and Worker binding type.
- `src/middleware/` assigns request IDs and writes sanitized request logs.
- `src/routes/` defines the OpenAPI operations and their response schemas.
- `src/lib/` holds shared OpenAPI response definitions and the Supabase client factory.
- `supabase/` holds the local database configuration, migration directory, seed and SQL tests.
- `tests/` exercises the HTTP contracts using fresh Hono instances.
- `docs/` records the target architecture, decisions and roadmap.

## Future Cloudflare deployment

For an approved release, authenticate Wrangler in the target Cloudflare account, review `wrangler.jsonc`, and configure approved browser origins as a Workers variable for the deployment. Verify the frozen install, quality checks and `pnpm build` before running `pnpm deploy`. Use Cloudflare secret bindings for any future sensitive configuration. The current Worker fits the Workers Free configuration and uses no remote service bindings.

GitHub Actions verifies changes on push and pull request. Deployment is manual.
