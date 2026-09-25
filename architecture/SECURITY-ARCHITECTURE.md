# Security Architecture

## Principles
Least privilege, explicit farm/site scope, server-side authorization, auditable privileged actions and separation of duties where required.

## Authorization
Evaluate authenticated principal + farm/site scope + role/permission + domain authority + entity status for every mutation.

Initial roles may include Farm Manager, Worker, Veterinarian, Nutritionist, Storekeeper, Procurement Officer and Administrator. Roles are configurable; permissions should be capability/action based.

## Authentication
Use standards-based authentication. Do not store plaintext passwords/tokens. Secrets belong in environment/secret management, never source control.

## Data protection
TLS in transit. Protect backups and sensitive exports. Minimize personal data. Audit security-sensitive operations.

## Offline devices
Local data should be scoped to authorized farms/users. Device/session revocation and secure credential storage are required. Offline operation does not increase user authority.

## Audit
Capture actor, action, target, time, source/device/correlation where relevant and before/after or reason for sensitive master-data/authorization changes.
