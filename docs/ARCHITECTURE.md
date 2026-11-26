# Architecture

Harvard University RP is a Discord roleplay community with a campus web application, a Workers API and a Discord bot.

| Component      | Target technology                         | Role                                                                                                       |
| -------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `hu-web`       | React, Vite, Cloudflare Pages             | Browser interface for campus features.                                                                     |
| `hu-api`       | Hono, TypeScript, Cloudflare Workers      | Public HTTP contracts and future versioned domain API.                                                     |
| `hu-bot`       | Discord.js, local Docker                  | Discord integration operated by the community.                                                             |
| Supabase       | PostgreSQL, Auth, Storage, SQL migrations | Future persistence, identity and file storage. Version SQL migrations in source control when introduced.   |
| Discord OAuth2 | Discord authorization flow                | Future user sign-in. A dedicated specification will define the integration with Supabase Auth and the API. |

In the target system, the browser and the bot call the API for domain operations. The API owns validation and future authorization at the HTTP boundary. Integration details and data access policies require mission specifications.

## API foundation

Wrangler loads `src/index.ts` as a Workers module. The entry point calls `createApp()`, which registers security headers, request logging, public route CORS, error handlers and the OpenAPI routes. Tests create fresh application instances and send Web API requests directly to Hono.

The health endpoint checks liveness independently of storage and external APIs. Public operations remain at their documented paths. Future domain operations use the `/api/v1` prefix. Define public operation metadata and reusable response schemas with Zod and the Hono OpenAPI integration.

Local development uses Wrangler's Workers runtime. The GitHub Actions workflow verifies the lockfile, formatting, lint, types, tests and dry-run Worker bundle. Releases are manually authorized.
