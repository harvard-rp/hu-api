# Development instructions

- Keep changes scoped to the current mission and this repository. Use English for source code, comments and technical documentation.
- Use Node.js 24 LTS, the pinned pnpm version, strict TypeScript, Hono on Cloudflare Workers, Wrangler, Zod, OpenAPI, Vitest, ESLint, Prettier and GitHub Actions.
- Keep `src/index.ts` as the Worker module and keep `createApp()` independently instantiable. Use Web Platform APIs inside runtime code and group features into focused modules.
- Put new domain routes under `/api/v1`. Keep public routes and schemas represented in OpenAPI and document observable HTTP changes.
- Keep `/health` independent of external services. Preserve the JSON error envelope and use the server-generated request ID for correlation.
- Commit only sanitized configuration examples. Keep real configuration, credentials and personal data out of Git and use Worker secret bindings for future sensitive configuration.
- Keep raw errors, stacks, request paths, headers, bodies and query strings out of logs. Log only the approved request metadata and keep cross-origin access limited to specific approved origins.
- Install dependencies with `pnpm install --frozen-lockfile`. Run `pnpm format:check`, `pnpm lint`, `pnpm typecheck`, `pnpm test` and `pnpm build` before submitting changes.
- Update automated coverage when public behavior changes. Use synthetic data in tests and keep tests independent of remote services.
- Keep CI permissions read-only and reserve deployments or remote resource creation for explicitly authorized work.
- Use the pinned Supabase CLI and publishable-key SDK for data access through the Data API. Construct a fresh client for each request that needs it and use the shared query error boundary.
- Manage local Supabase with the repository scripts. Use synthetic fixtures, version migrations, require explicit database grants and enable RLS on exposed tables. See [the database guide](docs/DATABASE.md).
- For database changes, validate the migration history and SQL tests with Docker when available and report any checks that could not run. Reserve hosted changes for explicit authorization.
- Configure the repository-local Git author name and email as specified by the owner. Verify author and committer before publication, omit automatic co-author trailers, and require authorization before rewriting history.
