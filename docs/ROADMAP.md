# Roadmap

## HU-001 — API foundation

Establish the Cloudflare Workers module, the public health and OpenAPI contracts, request metadata and error handling, local tooling, tests and GitHub Actions verification.

## HU-002 — Paused

Cloudflare deployment work is paused pending resolution of the deployment blockers.

## HU-003 — Supabase foundation

Prepare local PostgreSQL 17, the migration and fixture conventions, a stateless client factory and Docker-only integration checks.

## HU-004 — Domain data foundation

Model players, boost confirmations, fictional character sheets, reviews and university catalogs. Enforce club capacity with transactional reservations. See [business rules](BUSINESS_RULES.md) and the [schema](DATABASE_SCHEMA.md).

## HU-005 — Functional access policies

Define staff and player authorization, the Auth link and scoped policies for domain reads and writes. Resolve open workflow decisions before exposing write operations.

## Future mission candidates

- Specify Discord OAuth2, its integration with Supabase Auth and session handling.
- Define the initial `/api/v1` domain contracts and authorization rules.
- Plan the first Cloudflare release and the approved browser origins.

The architect assigns mission identifiers, scope and acceptance criteria before implementation.
