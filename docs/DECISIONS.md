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
