# Security

Report suspected vulnerabilities privately to a Harvard University RP maintainer through an established project contact. Include affected versions or commits, impact and sufficient reproduction detail. Use synthetic data and redact credentials and personal information. For discussions that contain sensitive details, use a private channel.

Only sanitized examples belong in Git. Keep local environment files on your machine and store any future deployment credentials in Cloudflare secret bindings. If a credential is exposed, revoke or rotate it promptly and contact a maintainer to coordinate remediation.

The foundation generates request IDs on the server and limits logs to the request ID and HTTP status. Public HTTP errors use fixed messages. CORS is opt-in through an explicit origin allowlist. Future user access controls belong in the API.
