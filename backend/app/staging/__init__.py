"""The PostgreSQL 16 staging chain (master prompt Package 6,
docs/runbooks/STAGING-POSTGRES.md): API smoke tests over synthetic farm
records and table snapshots for backup/restore checks. Never production:
`smoke` refuses any server that is not this machine or a host named for
staging, and the staging script builds its own database."""
