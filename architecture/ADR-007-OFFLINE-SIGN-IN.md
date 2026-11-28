# ADR-007 — Offline sign-in on the tablet

**Status:** Accepted (v0.8.10; no migration)
**Audit:** 2026-11-25 I-10
**Keeps:** the 14 Nov 2026 recovery policy — the sign-in form on every launch, no token restored at start-up (`SessionController.restore()`).

## Context

A worker who signed in, then lost the network and restarted the tablet, could not get back in: sign-in always needed the server. Their cached farm and their queued records were on the tablet, out of reach until the yard's Wi-Fi came back.

## Decision

1. **The server stays the only authority.** A sign-in is first sent to the server. Only when the server **cannot be reached** (no route, HTTP 0) does the tablet try offline.
2. **What the tablet keeps** after a sign-in the server accepted, for that server and that email only (`lib/auth/offline_credentials.dart`, app-private preferences): a random 16-byte salt and a PBKDF2-HMAC-SHA256 check of the password (20,000 iterations), the profile the server returned, and when. **Never the password, never the server's token.**
3. **An offline session** opens that user's cached farm (the local store is bound to the user: another account's cache is wiped, never shown), and records go to the outbox with their idempotency keys. It has **no server token**, so it can reach nothing on the server. The sync controller sends nothing without a token (`SyncOutcome.needsSignIn`, the queue untouched) and treats a 401 the same way, so an expired session never marks good records failed. After the next sign-in the server accepts, the queue is sent once.
4. **Limits.** The check expires **7 days** after the server last accepted the sign-in. A sign-in the server refuses (401/403 — password changed, account revoked) forgets it. Signing out forgets it. A different email, or a never-online tablet, cannot open offline.
5. **Browser:** never offline (no device-private storage); the web app signs in with the server as before.

## Consequences

- A stolen tablet in its first week can be opened by someone who knows the worker's password, showing that worker's cached farm and queuing records the server will judge (and refuse what the account may no longer do) when someone signs in. It cannot read or write anything on the server.
- PBKDF2 with a salt makes the stored check slow to brute-force but not impossible; it is the same strength as the password chosen. A PIN would be weaker and is not used.
- No new native dependency: `crypto` (pure Dart) for HMAC-SHA256.
- Tests: `test/auth/offline_signin_test.dart` (published PBKDF2 vectors; same server/email/password only; never stores the password or token; 7-day expiry; refused or signed-out forgets; browser; offline restart → feeding queued → sign-in → sent once; an expired token keeps the queue). A physical Android restart test is **not run** in CI.
