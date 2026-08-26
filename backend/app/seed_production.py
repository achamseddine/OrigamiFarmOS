"""Seeds a REAL deployment database with nothing but the farm record, its
module licenses, and the 5 real staff accounts — no fabricated animals,
batches, bookings, or any other example data (that's what app/seed.py's
demo dataset is for).

Idempotent: if the farm already exists, this does nothing and prints a
notice rather than resetting anyone's password. Run it once per
environment, right after `alembic upgrade head`:

    python -m app.seed_production

Each account's password is generated fresh at seed time and printed to
stdout ONCE — it is never written to the database in plaintext (only its
bcrypt hash is stored) and never committed to source control. Save it
somewhere safe immediately; if you lose it, an owner/manager account can
reset it directly in the database, or you can drop and re-seed on an
otherwise-empty database.
"""
from __future__ import annotations

import secrets
import string

from sqlalchemy.orm import Session

from app.core.security import hash_password
from app.db.base import Base, SessionLocal, engine
from app.domain import models
from app.domain import mouneh_models
from app.domain import visits_models  # noqa: F401 - ensures Visits tables are registered on Base.metadata
from app.repositories.base import new_id

FARM_ID = "farm-origami"

# (email, display name, role, department) — department is a UI/task-
# assignment concern only (see schemas/users.py), not an RBAC role.
ACCOUNTS = [
    ("manager@origamifarms.com", "Farm Manager", "owner", None),
    ("animals@origamifarms.com", "Animal Care Lead", "worker", "animals"),
    ("produce@origamifarms.com", "Vegetables & Produce Lead", "worker", "produce"),
    ("mouneh@origamifarms.com", "Mouneh Production Lead", "mouneh_operator", "mouneh"),
    ("visits@origamifarms.com", "Visitor & Booking Lead", "visitor_coordinator", "visits"),
]


def _generate_password(length: int = 14) -> str:
    # Avoid visually-ambiguous characters (0/O, 1/l/I) so a manager can
    # read a printed password aloud to an employee without confusion.
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def seed_production_data(db: Session) -> None:
    if db.get(models.Farm, FARM_ID) is not None:
        print(f"Farm '{FARM_ID}' already exists — skipping (no passwords were changed).")
        return

    farm = models.Farm(id=FARM_ID, name="Origami Farms", country="Lebanon", region="Bekaa Valley", timezone="Asia/Beirut", default_currency="USD")
    db.add(farm)
    db.flush()

    for module_code in ("mouneh", "visits_agritourism"):
        db.add(mouneh_models.ModuleLicense(id=new_id(), farm_id=FARM_ID, module_code=module_code, status="active", plan="standard"))

    print("Created accounts (save these passwords now — they are not stored anywhere in plaintext):\n")
    print(f"{'Email':<32} {'Role':<20} {'Department':<10} Password")
    for email, name, role, department in ACCOUNTS:
        password = _generate_password()
        db.add(
            models.User(
                id=new_id(),
                farm_id=FARM_ID,
                name=name,
                email=email,
                password_hash=hash_password(password),
                role=role,
                department=department,
                language="en",
            )
        )
        print(f"{email:<32} {role:<20} {department or '—':<10} {password}")

    db.commit()
    print("\nDone. Every account above can now log in against POST /api/v1/auth/login.")


if __name__ == "__main__":
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as session:
        seed_production_data(session)
