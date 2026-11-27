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

Verify Supabase Auth bearer tokens and serve a read-only player context with explicit HRP capabilities and owned character eligibility. The [authorization boundary](PERMISSIONS.md) leaves grant management and character writes to later workflows.

## Upcoming work

- HU-007 will integrate Discord OAuth2, securely create or link player accounts, and define client session handling.
- HU-009 will add authorized character creation and review operations once the remaining workflow decisions are settled.
- Plan the first Cloudflare release and the approved browser origins.

The architect assigns mission identifiers, scope and acceptance criteria before implementation.
