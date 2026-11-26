# Technical decisions

## HU-001 — Worker runtime and reproducible tooling

Use Hono as a Workers module. Keep Node.js 24 LTS as the toolchain runtime and use Web Platform APIs in request handling. Pin pnpm and direct dependencies and commit the lockfile. Use TypeScript 6.0 for compatibility with the supported TypeScript range of typescript-eslint. Set the Worker compatibility date to 2026-11-26, the foundation implementation date.

## HU-001 — Public contracts and observability

Keep liveness and OpenAPI at `/health` and `/openapi.json`. Start domain versioning at `/api/v1`. Generate OpenAPI 3.0.3 from the route registry and validate the served document against the OpenAPI specification in tests.

Generate a UUID per request and return it in `X-Request-Id`. Include it in public error bodies and log it with the status code. Route misses and unexpected exceptions share the same JSON envelope and use fixed public messages.

## HU-001 — Browser policy

Use Hono security headers with a restrictive content security policy for JSON responses. Apply a CORS allowlist to the public paths. Match configured origins exactly and disable cross-origin access when the setting is empty or invalid. Allow GET and expose the request ID header. Cross-origin credentials and custom request headers are disabled.

## HU-001 — Verification and releases

Use Vitest for in-process app tests and Wrangler for the local runtime and dry-run bundle. GitHub Actions uses read-only repository access and checks the frozen lockfile and all verification commands on pushes and pull requests. Keep Cloudflare releases manual.

## HU-003 — Local PostgreSQL and API access

Pin Supabase CLI 3.4.0 and use its JSONC configuration for local PostgreSQL 17. Run the local stack on a loopback Docker bridge. Disable automatic Data API grants for new public objects so future migrations have to opt in explicitly. Use a separate pgTAP smoke test for Docker checks and keep the default CI independent of local services.

Pin Supabase JS 2.119.2 and create a stateless publishable-key client per request when a route needs it. Validate configuration lazily and pass a future verified user JWT per client. Keep SDK failures behind a generic query error. Bundle a test-only Worker during the existing build step to exercise SDK compatibility without wiring Supabase into the public HTTP application.

## HU-004 — Closed domain schema and transactional reservations

Separate player identity, HRP actors, character review, use status and candidate public profile fields. Keep the Data API closed to all new domain objects until functional policies are specified in HU-005. Record boost counts as absolute confirmations and derive the allowed slot count from the latest entry. Use constrained, unique reservations for active club slots and seats. The database enforces both caps without a read-count race or a privileged function.

Version the server reference catalogs in migrations and keep synthetic test data in database tests. Check pinned CLI type generation for schema drift after a clean reset. See [database schema](DATABASE_SCHEMA.md) and [business rules](BUSINESS_RULES.md).
