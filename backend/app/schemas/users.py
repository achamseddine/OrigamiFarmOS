from __future__ import annotations

from app.schemas.common import ORMModel

DEPARTMENTS = {"animals", "produce", "mouneh", "visits"}


class UserProfileOut(ORMModel):
    """Canonical user-facing shape — used by /auth/login, /auth/me, and
    GET /users, so the mobile app has exactly one profile shape to parse
    regardless of which endpoint produced it.

    `department` (nullable) is a mobile-UI/task-assignment concern only —
    it drives which nav entries an employee sees and who a task can be
    assigned to for a given area; it never gates a backend permission
    (that's still `role`, checked by api/deps.py).
    """

    id: str
    farm_id: str
    name: str
    email: str | None = None
    phone: str | None = None
    role: str
    department: str | None = None
    language: str
    active: bool
