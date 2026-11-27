# HTTP authentication

Protected requests carry a Supabase Auth user access token in the `Authorization: Bearer <token>` header. Configure the Worker with the project's canonical API origin in `SUPABASE_URL` and its publishable key in `SUPABASE_PUBLISHABLE_KEY`. The expected issuer is that origin followed by `/auth/v1`. Use the canonical origin that matches the project's token issuer. Local development uses `http://127.0.0.1:54321`.

1. The Hono middleware checks the header and sends the token to the configured project's Auth service with `auth.getUser(token)`. It uses a fresh Auth-capable client from Supabase JS, with persistence, URL session detection and refresh disabled. The request uses a timeout and refuses redirects.
2. After Auth verifies the token, the middleware checks the issuer, audience, authenticated role, session ID, expiration and subject against the verified user. Both the user and the token must represent a permanent account. The verified Auth identity and access token stay in that request's context.
3. The route uses a separate request-scoped Data API client with the same user token and the publishable key. PostgreSQL resolves the linked player from `auth.uid()` and applies row-level security on every read. `GET /api/v1/me` reads the context without creating or updating any account.

`/health` uses no Supabase settings or network requests. CORS on the protected endpoint uses the existing exact-origin allowlist and permits the `Authorization` header for GET requests from approved origins. Cross-origin credentials are disabled.

## GET /api/v1/me

A successful response contains `playerId`, `capabilities`, `characters` and `canAccessCampus`. Each character entry contains `id`, `validationStatus`, `useStatus` and `canAccessCampus`. The account-level eligibility is true when at least one owned character is approved and active. An account can retrieve its context even when it has no eligible characters.

| Status | Code                   | Meaning                                                                                                                            |
| ------ | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| 200    |                        | Linked player and minimal authorization context.                                                                                   |
| 401    | `UNAUTHENTICATED`      | A missing or invalid token, wrong issuer, unavailable session or anonymous user. The response includes `WWW-Authenticate: Bearer`. |
| 403    | `PLAYER_LINK_REQUIRED` | Auth verified the token but the account has no visible player link.                                                                |
| 503    | `SERVICE_UNAVAILABLE`  | The verifier or player context dependency cannot provide a trustworthy result.                                                     |
| 500    | `INTERNAL_ERROR`       | An unexpected application error.                                                                                                   |

All responses from the protected path carry `Cache-Control: no-store` and `X-Request-Id`. Errors retain the standard JSON envelope. The contract excludes Auth subject IDs, Discord IDs, emails, tokens and character sheet contents. See the OpenAPI description at `/openapi.json`.

## Sessions and threat model

The Worker trusts the configured Auth service to verify signatures and looks up the user on each request. It rejects expired tokens and any session the service reports as missing or invalid. It never exchanges refresh tokens or creates a local session cache. Access tokens are bearer credentials. A copied token can be replayed while it remains accepted, and a revocation cannot undo an in-flight request. Direct PostgREST access applies JWT validation and RLS independently. Depending on Supabase session settings and revocation behavior, a previously issued access token may remain usable there until its expiry. The direct interface exposes only the caller's bounded context. Player unlinking and capability revocation take effect on the next database resolution independently of token claims.

A caller may submit another player's identifiers, modify user metadata or invoke the Data API directly. The route accepts no identity selectors, and the SQL interface takes no arguments. Linkage, ownership and permissions are determined from trusted database state. Requests fail closed if credentials or the dependency response cannot be validated.

HU-007A adds [Discord identity and player bootstrap](DISCORD_AUTH.md). HU-007B will implement client-side OAuth and session handling. Public signup, anonymous sign-in and manual identity linking remain disabled in local configuration.

## Worker transport and diagnostics

Workers throws a `TypeError` before sending a request with `redirect: 'error'`. Supabase JS 2.119.2 wraps that transport exception in `AuthRetryableFetchError` with status `0`. Both clients now use `redirect: 'manual'` and reject all 3xx responses before the SDK can process them. This prevents credentials from being sent to a redirect destination. The bootstrap route accepts a zero-byte POST even when workerd represents it as an empty stream. It still rejects query parameters and any request body content. [Cloudflare Request API](https://developers.cloudflare.com/workers/runtime-apis/request/)

Request logs contain the server-generated `requestId` and the HTTP `status`. A 503 from the Auth verifier also carries `authFailure.reason` and, for an Auth HTTP error, the numeric `authFailure.upstreamStatus`. The fixed reasons distinguish invalid bindings (`invalid_configuration`), SDK status `0` (`transport_failure`), upstream HTTP failures (`upstream_http_error`), invalid provider responses (`invalid_response`) and otherwise unexpected exceptions (`unexpected_error`). Use the `X-Request-Id` response header to find the corresponding entry. The logs exclude provider messages, exception stacks, credentials, request contents and account identifiers.

## Local verification

`pnpm test` exercises the HTTP contracts with simulated provider responses. The Workers regression suite also starts the production entry point in Wrangler/workerd with the project's compatibility settings. It uses a loopback HTTP fixture for Auth and the Data API, tests the runtime's outgoing requests and redirect handling, and checks the captured runtime logs. `pnpm exec vitest run tests/auth-workers.test.mjs` runs that suite on its own.

`pnpm test:auth:local` requires the project's disposable local Supabase stack after a reset. It reads the local publishable key without displaying it, creates synthetic Auth users and links through the local PostgreSQL container, and exchanges their passwords with the running Auth service for signed access tokens. It then calls the Hono app and the Data API, tests modified signatures, checks permission revocation, and initializes a synthetic Discord identity through concurrent HTTP and direct PostgREST calls. It verifies that a deleted Auth session cannot bootstrap through either path. The fixture uses no administrative HTTP key and is removed after the run.

References [Supabase JS getUser](https://supabase.com/docs/reference/javascript/auth-getuser), [sessions](https://supabase.com/docs/guides/auth/sessions) and [JWT claims](https://supabase.com/docs/guides/auth/jwt-fields).
