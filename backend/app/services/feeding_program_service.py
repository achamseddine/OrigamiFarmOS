"""Feeding programs: who gets what (feed architecture §4, §5, §9–§11, §14).

    subject state ──► rules ──► eligible programs ──► best match (explained)

The subject is an Animal or an AnimalGroup; its state is read from the
generic animal model (species, sex, life stage, management profile,
pregnant / lactating flags) plus what production and growth data say
(7-day milk average, weight, age). A program's version carries the
ration and the rules; the resolver never looks at a species name in code
— a horse and a hen are matched by the same loop.

What a subject is *on* is an assignment. A group's explicit assignment is
inherited by every animal in the group that has none of its own;
inheritance is computed here, never stored, so an individual supplement,
override or restriction sits on top of the group program without
replacing it. A change in the animal's state raises a review — an event
and a task — and never rewrites the assignment by itself (§10).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from app.core import permissions as perms
from app.core import read_cache
from app.domain import feed_models as fm
from app.domain import livestock_models as lm
from app.domain import models
from app.feeding import catalog, uom
from app.core.record_time import not_in_future
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.services import feed_inventory_service as inv
from app.services import farm_time
from app.services import feed_policy_service as policy
from app.services.feed_inventory_service import FeedError, Purpose

MILK_METRIC = "milk_l_per_day"
EGG_METRIC = "eggs_per_day"


@dataclass
class SubjectState:
    subject_type: str
    subject_id: str
    name: str
    farm_id: str
    species_code: str
    sex: str | None
    life_stage: str
    management_profile: str | None
    reproductive_state: str | None
    lactation_state: str | None
    age_days: int | None
    weight_kg: float | None
    production: dict[str, float] = field(default_factory=dict)
    head_count: int = 1
    group_name: str | None = None

    def to_dict(self) -> dict:
        return {
            "subject_type": self.subject_type, "subject_id": self.subject_id, "name": self.name,
            "species_code": self.species_code, "sex": self.sex, "life_stage": self.life_stage,
            "management_profile": self.management_profile, "reproductive_state": self.reproductive_state,
            "lactation_state": self.lactation_state, "age_days": self.age_days, "weight_kg": self.weight_kg,
            "production": self.production, "head_count": self.head_count, "group_name": self.group_name,
        }

    def policy_target(self) -> policy.Target:
        return policy.Target(
            species_code=self.species_code, management_profile=self.management_profile, life_stage=self.life_stage,
            reproductive_state=self.reproductive_state, age_days=self.age_days, label=self.name,
        )


# --------------------------------------------------------------- subjects
def load_subject(db: Session, subject_type: str, subject_id: str, farm_id: str):
    if subject_type == "animal":
        row = db.get(models.Animal, subject_id)
    elif subject_type == "group":
        row = db.get(models.Flock, subject_id)
    else:
        raise FeedError("subject_type must be animal or group")
    if row is None or row.farm_id != farm_id:
        raise FeedError(f"{subject_type.capitalize()} not found", 404)
    return row


def find_subject(db: Session, subject_id: str, farm_id: str) -> tuple[str, object]:
    """For the `/livestock-subjects/{id}` routes: an id is an animal or a group."""
    animal = db.get(models.Animal, subject_id)
    if animal is not None and animal.farm_id == farm_id:
        return "animal", animal
    group = db.get(models.Flock, subject_id)
    if group is not None and group.farm_id == farm_id:
        return "group", group
    raise FeedError("Livestock subject not found", 404)


def _milk_per_day(db: Session, animal_id: str, days: int = 7) -> float | None:
    prefetched = read_cache.peek(db, ("milk_per_day", days))
    if prefetched is not None:
        return prefetched.get(animal_id)
    since = now() - timedelta(days=days)
    rows = db.execute(
        select(func.sum(models.MilkRecord.liters), func.count(func.distinct(func.date(models.MilkRecord.recorded_at))))
        .where(models.MilkRecord.animal_id == animal_id, models.MilkRecord.recorded_at >= since)
    ).one()
    total, day_count = rows[0], rows[1]
    if not total or not day_count:
        return None
    return round(float(total) / int(day_count), 2)


def _eggs_per_day(db: Session, flock_id: str, days: int = 7) -> float | None:
    since = now() - timedelta(days=days)
    rows = db.execute(
        select(func.sum(models.EggRecord.total_eggs), func.count(func.distinct(func.date(models.EggRecord.recorded_at))))
        .where(models.EggRecord.flock_id == flock_id, models.EggRecord.recorded_at >= since)
    ).one()
    total, day_count = rows[0], rows[1]
    if not total or not day_count:
        return None
    return round(float(total) / int(day_count), 1)


def _sex_code(raw: str | None) -> str | None:
    code = (raw or "").strip().upper()
    return {"F": "F", "FEMALE": "F", "M": "M", "MALE": "M"}.get(code)


def _group_sex(composition: str | None) -> str | None:
    c = (composition or "").strip().lower()
    if c in ("female", "f", "hens", "all_female", "females"):
        return "F"
    if c in ("male", "m", "all_male", "males"):
        return "M"
    return None


def subject_state(db: Session, subject_type: str, subject) -> SubjectState:
    if subject_type == "animal":
        a: models.Animal = subject
        sex = _sex_code(a.sex)
        age = (now() - ensure_utc(a.birth_date)).days if a.birth_date else None
        production: dict[str, float] = {}
        milk = _milk_per_day(db, a.id)
        if milk is not None:
            production[MILK_METRIC] = milk
        return SubjectState(
            subject_type="animal", subject_id=a.id, name=a.name, farm_id=a.farm_id, species_code=a.species, sex=sex,
            life_stage=a.life_stage or "adult", management_profile=a.management_profile,
            reproductive_state=("pregnant" if a.pregnant else "open") if sex == "F" else None,
            lactation_state=("lactating" if a.lactating else "dry") if sex == "F" else None,
            age_days=age, weight_kg=a.weight_kg, production=production, head_count=1, group_name=a.group_name,
        )
    g: models.Flock = subject
    production = {}
    eggs = _eggs_per_day(db, g.id)
    if eggs is not None:
        production[EGG_METRIC] = eggs
    # A group of individually tracked animals is described by its members:
    # the herd is lactating when most of its cows are, and its yield is
    # their average — so the herd matches the same rules a cow would.
    members = animals_in_group(db, g)
    sex = _group_sex(g.sex_composition)
    lactation_state = None
    reproductive_state = None
    if members:
        females = [m for m in members if _sex_code(m.sex) == "F"]
        if females:
            lactation_state = "lactating" if sum(1 for m in females if m.lactating) * 2 >= len(females) else "dry"
            reproductive_state = "pregnant" if sum(1 for m in females if m.pregnant) * 2 > len(females) else "open"
        yields = [y for y in (_milk_per_day(db, m.id) for m in members) if y is not None]
        if yields:
            production[MILK_METRIC] = round(sum(yields) / len(yields), 2)
        if sex is None:
            sexes = {_sex_code(m.sex) for m in members}
            sex = sexes.pop() if len(sexes) == 1 else None
    return SubjectState(
        subject_type="group", subject_id=g.id, name=g.name, farm_id=g.farm_id, species_code=g.species, sex=sex,
        life_stage=g.life_stage or "adult", management_profile=g.management_profile, reproductive_state=reproductive_state,
        lactation_state=lactation_state, age_days=None, weight_kg=None, production=production,
        head_count=max(g.count or 0, len(members)), group_name=g.name,
    )


def group_for_animal(db: Session, animal: models.Animal) -> models.Flock | None:
    """The group an animal inherits a program from: its current
    exclusive membership (herd / flock / pen — LIVESTOCK-SCHEMA §7). An
    animal with no membership rows yet (one registered before memberships
    existed) falls back to the group its `group_name` names."""
    from app.services import group_service

    group = group_service.exclusive_group_of(db, animal)
    if group is not None:
        return group
    if group_service.memberships_of_animal(db, animal.id):
        return None
    if not animal.group_name:
        return None
    # Same farm, same name — and the same species: a goat penned with the
    # cows shares their group name, not their ration.
    return db.scalar(select(models.Flock).where(
        models.Flock.farm_id == animal.farm_id, func.lower(models.Flock.name) == animal.group_name.strip().lower(),
        models.Flock.species == animal.species,
    ))


def animals_in_group(db: Session, group: models.Flock, at: datetime | None = None) -> list[models.Animal]:
    """The group's members at [at] (now), plus any same-named animal that
    has no membership history at all (registered before memberships existed)."""
    from app.domain import livestock_models as lm
    from app.services import group_service

    members = [a for _m, a in group_service.current_members(db, group, at) if a.active]
    seen = {a.id for a in members}
    legacy = db.scalars(select(models.Animal).where(
        models.Animal.farm_id == group.farm_id, models.Animal.active.is_(True), models.Animal.species == group.species,
        func.lower(models.Animal.group_name) == group.name.strip().lower(),
        ~select(lm.AnimalGroupMembership.id).where(lm.AnimalGroupMembership.animal_id == models.Animal.id).exists(),
    )).all()
    return members + [a for a in legacy if a.id not in seen]


# --------------------------------------------------------------- resolver
@dataclass
class Match:
    program: fm.FeedingProgram
    version: fm.FeedingProgramVersion
    rule: fm.FeedingProgramRule
    specificity: int
    reasons: list[str]

    def to_dict(self) -> dict:
        return {
            "program_id": self.program.id, "program_code": self.program.code, "program_name": self.program.name,
            "program_name_ar": self.program.name_ar, "category": self.program.category,
            "version_id": self.version.id, "version": self.version.version, "rule_id": self.rule.id,
            "specificity": self.specificity, "priority": self.rule.priority, "reasons": self.reasons,
        }


def _in_range(value, lo, hi) -> bool:
    if lo is not None and value < lo:
        return False
    if hi is not None and value > hi:
        return False
    return True


def _match_rule(rule: fm.FeedingProgramRule, state: SubjectState, program_name: str, warnings: list[str]) -> tuple[bool, int, list[str]]:
    reasons: list[str] = []
    specificity = 0
    checks = [
        ("species_code", rule.species_code, state.species_code, "species"),
        ("sex", rule.sex, state.sex, "sex"),
        ("life_stage", rule.life_stage, state.life_stage, "life stage"),
        ("management_profile", rule.management_profile, state.management_profile, "profile"),
        ("reproductive_state", rule.reproductive_state, state.reproductive_state, "reproductive state"),
        ("lactation_state", rule.lactation_state, state.lactation_state, "lactation"),
    ]
    for _, wanted, actual, label in checks:
        if wanted is None:
            continue
        if wanted != actual:
            return False, 0, []
        specificity += 1
        reasons.append(f"{label} = {wanted}")
    if rule.production_min is not None or rule.production_max is not None:
        metric = rule.production_metric or MILK_METRIC
        value = state.production.get(metric)
        if value is None:
            warnings.append(f"{program_name}: {metric.replace('_', ' ')} is unknown for {state.name}, so its production band was not evaluated.")
            return False, 0, []
        if not _in_range(value, rule.production_min, rule.production_max):
            return False, 0, []
        specificity += 1
        reasons.append(f"{metric.replace('_', ' ')} {value} within {rule.production_min or 0}–{rule.production_max or '∞'}")
    if rule.weight_min is not None or rule.weight_max is not None:
        if state.weight_kg is None:
            warnings.append(f"{program_name}: weight is unknown for {state.name}, so its weight band was not evaluated.")
            return False, 0, []
        if not _in_range(state.weight_kg, rule.weight_min, rule.weight_max):
            return False, 0, []
        specificity += 1
        reasons.append(f"weight {state.weight_kg} kg within {rule.weight_min or 0}–{rule.weight_max or '∞'}")
    if rule.age_min_days is not None or rule.age_max_days is not None:
        if state.age_days is None:
            warnings.append(f"{program_name}: age is unknown for {state.name}, so its age band was not evaluated.")
            return False, 0, []
        if not _in_range(state.age_days, rule.age_min_days, rule.age_max_days):
            return False, 0, []
        specificity += 1
        reasons.append(f"age {state.age_days} days within {rule.age_min_days or 0}–{rule.age_max_days or '∞'}")
    if not reasons:
        reasons.append("matches any subject")
    return True, specificity, reasons


def active_versions(db: Session, farm_id: str) -> list[fm.FeedingProgramVersion]:
    """Read once per request (with their rules, components and program) —
    the resolver asks for them for every subject on the farm."""
    return read_cache.cached(db, ("active_versions", farm_id), lambda: list(db.scalars(
        select(fm.FeedingProgramVersion).join(fm.FeedingProgram)
        .where(fm.FeedingProgram.farm_id == farm_id, fm.FeedingProgram.status == "active", fm.FeedingProgramVersion.status == "active")
        .options(selectinload(fm.FeedingProgramVersion.rules), selectinload(fm.FeedingProgramVersion.components),
                 selectinload(fm.FeedingProgramVersion.program))
    )))


def resolve_state(db: Session, state: SubjectState, *, current_program_id: str | None = None) -> dict:
    """§14: eligible programs, the best match, the rule and reasons behind
    it, warnings for what could not be evaluated, and whether a review is
    due. The decision is explainable by construction."""
    warnings: list[str] = []
    matches: list[Match] = []
    for version in active_versions(db, state.farm_id):
        best_for_version: Match | None = None
        for rule in version.rules:
            ok, specificity, reasons = _match_rule(rule, state, version.program.name, warnings)
            if not ok:
                continue
            candidate = Match(program=version.program, version=version, rule=rule, specificity=specificity, reasons=reasons)
            if best_for_version is None or (candidate.specificity, rule.priority) > (best_for_version.specificity, best_for_version.rule.priority):
                best_for_version = candidate
        if best_for_version is not None:
            matches.append(best_for_version)
    matches.sort(key=lambda m: (-m.specificity, -m.rule.priority, m.program.name))
    best = matches[0] if matches else None
    ties = [m for m in matches if best and (m.specificity, m.rule.priority) == (best.specificity, best.rule.priority)]
    if len(ties) > 1:
        warnings.append("More than one program matches equally well: " + ", ".join(m.program.name for m in ties) + ". Set a priority to break the tie.")
    requires_review = best is not None and best.program.id != current_program_id
    if best is None and current_program_id is not None:
        requires_review = True
        warnings.append(f"No active program's rules match {state.name} any more; the current assignment should be reviewed.")
    return {
        "subject": state.to_dict(),
        "eligible": [m.to_dict() for m in matches],
        "best": best.to_dict() if best else None,
        "warnings": warnings,
        "requires_review": requires_review,
        "current_program_id": current_program_id,
    }


# ------------------------------------------------------------ assignments
# An assignment that was ended or replaced was still in force until then:
# a past day is read with it (v0.8.6).
_ENDED = ("ended", "superseded")


def _active(rows, at: datetime | None = None):
    """The assignments in force at [at] — now by default: active ones in
    their validity. For a past time, also those ended or superseded since
    (in force from valid_from until they ended)."""
    t = ensure_utc(at) if at is not None else now()
    out = []
    for r in rows:
        if r.status != "active":
            if at is None or r.status not in _ENDED or r.ended_at is None or ensure_utc(r.ended_at) <= t:
                continue
        if r.valid_from and ensure_utc(r.valid_from) > t:
            continue
        if r.valid_to and ensure_utc(r.valid_to) < t:
            continue
        out.append(r)
    return out


def active_assignments(db: Session, subject_type: str, subject_id: str, at: datetime | None = None) -> list[fm.FeedingAssignment]:
    """The subject's assignments in force at [at] (now)."""
    prefetched = read_cache.peek(db, ("assignments",))
    if prefetched is not None and subject_id in prefetched["subjects"]:
        return _active(prefetched["rows"].get((subject_type, subject_id), []), at)
    rows = db.scalars(select(fm.FeedingAssignment).where(
        fm.FeedingAssignment.subject_type == subject_type, fm.FeedingAssignment.subject_id == subject_id,
    ).order_by(fm.FeedingAssignment.created_at)).all()
    return _active(rows, at)


def prefetch_farm(db: Session, farm_id: str, *, days: int = 7) -> None:
    """Loads, in three queries, what resolving every subject of the farm
    asks for one subject at a time: every feeding assignment, and the week's
    milk per animal. Used by the farm-wide reads (today's plan, demand, days
    of cover); dropped on the first write (app/core/read_cache.py)."""
    if read_cache.peek(db, ("assignments",)) is not None:
        return
    rows: dict[tuple, list] = {}
    for a in db.scalars(select(fm.FeedingAssignment).where(fm.FeedingAssignment.farm_id == farm_id).order_by(fm.FeedingAssignment.created_at)):
        rows.setdefault((a.subject_type, a.subject_id), []).append(a)
    subjects = set(db.scalars(select(models.Animal.id).where(models.Animal.farm_id == farm_id)))
    subjects |= set(db.scalars(select(models.Flock.id).where(models.Flock.farm_id == farm_id)))
    since = now() - timedelta(days=days)
    milk: dict[str, float] = {}
    for animal_id, total, day_count in db.execute(
        select(models.MilkRecord.animal_id, func.sum(models.MilkRecord.liters), func.count(func.distinct(func.date(models.MilkRecord.recorded_at))))
        .join(models.Animal, models.Animal.id == models.MilkRecord.animal_id)
        .where(models.Animal.farm_id == farm_id, models.MilkRecord.recorded_at >= since)
        .group_by(models.MilkRecord.animal_id)
    ):
        if total and day_count:
            milk[animal_id] = round(float(total) / int(day_count), 2)
    read_cache.put(db, ("assignments",), {"rows": rows, "subjects": subjects})
    read_cache.put(db, ("milk_per_day", days), milk)


def explicit_program(db: Session, subject_type: str, subject_id: str, at: datetime | None = None) -> fm.FeedingAssignment | None:
    for a in active_assignments(db, subject_type, subject_id, at):
        if a.assignment_type == "explicit" and a.program_version_id:
            return a
    return None


@dataclass
class BaseRation:
    """Where a head's one base ration comes from (v0.8.6, audit I-4)."""

    assignment: fm.FeedingAssignment | None
    source: str | None            # explicit | inherited | None
    group: models.Flock | None    # the group it is inherited from
    ignored: list[models.Flock]   # other groups of hers with a program — not her base


def base_ration(db: Session, animal: models.Animal, at: datetime | None = None) -> BaseRation:
    """Each head gets exactly one base ration, the most specific one in
    force at [at] (now):

        1. its own explicit program;
        2. the program of a status group it is in (pregnant, not pregnant,
           in milk, dry — groups that follow the herd records);
        3. the program of its herd / pen (its exclusive group);
        4. the program of any other group it is in.

    Ties at one level go to the group named first; the others are listed
    in `ignored`, so the plan can say a ration was not applied."""
    own = explicit_program(db, "animal", animal.id, at)
    if own is not None:
        return BaseRation(own, "explicit", None, [])
    groups = groups_of_animal(db, animal, at)
    ranked = []
    for g in groups:
        level = 0 if g.membership_rule else (1 if _is_exclusive(db, g) else 2)
        program = explicit_program(db, "group", g.id, at)
        if program is not None:
            ranked.append((level, (g.name or "").lower(), g.id, g, program))
    if not ranked:
        return BaseRation(None, None, None, [])
    ranked.sort(key=lambda r: r[:3])
    _lvl, _n, _id, group, program = ranked[0]
    return BaseRation(program, "inherited", group, [r[3] for r in ranked[1:]])


def _is_exclusive(db: Session, group: models.Flock) -> bool:
    from app.services import group_service

    return bool(group_service.policy(db, group.group_type).exclusive_membership)


def groups_of_animal(db: Session, animal: models.Animal, at: datetime | None = None) -> list[models.Flock]:
    """The groups the animal is in at [at] (now): her membership history,
    or — registered before memberships existed — the group her record names."""
    from app.domain import livestock_models as lm

    t = ensure_utc(at) if at is not None else now()
    rows = list(db.scalars(select(lm.AnimalGroupMembership).where(lm.AnimalGroupMembership.animal_id == animal.id)))
    if rows:
        ids = [m.animal_group_id for m in rows if ensure_utc(m.valid_from) <= t and (m.valid_to is None or t < ensure_utc(m.valid_to))]
        return [g for g in (db.get(models.Flock, i) for i in dict.fromkeys(ids)) if g is not None and g.status not in ("closed", "archived")]
    legacy = group_for_animal(db, animal)
    return [legacy] if legacy is not None else []


def effective_program(db: Session, subject_type: str, subject, at: datetime | None = None) -> tuple[fm.FeedingAssignment | None, str | None, models.Flock | None]:
    """The program a subject is on and where it came from: `explicit` for
    its own assignment, `inherited` for its group's ([base_ration])."""
    if subject_type == "animal":
        base = base_ration(db, subject, at)
        return base.assignment, base.source, base.group
    own = explicit_program(db, subject_type, subject.id, at)
    if own is not None:
        return own, "explicit", None
    return None, None, None


def _daily_per_head(component: fm.FeedingProgramComponent, feedings_per_day: int) -> float:
    if component.frequency == "per_feeding":
        return component.quantity_per_head * max(feedings_per_day, 1)
    return component.quantity_per_head


@dataclass
class GroupHeads:
    """The heads a group's own program feeds (v0.8.6, audit I-4)."""

    heads: int
    members: int
    excluded: list[dict]


def _planned_alone(db: Session, animal: models.Animal, at: datetime | None) -> str | None:
    """Why an animal is planned on her own rather than in her group's
    head count: her own adjustment of the ration (an override replaces a
    quantity, a restriction removes a feed). None when the group's ration
    is hers as it is (a supplement only adds, so she stays in the group)."""
    own = active_assignments(db, "animal", animal.id, at)
    if any(a.assignment_type == "override" for a in own):
        return "own_override"
    if any(a.assignment_type == "restriction" for a in own):
        return "own_restriction"
    return None


def group_heads(db: Session, group: models.Flock, at: datetime | None = None) -> GroupHeads:
    """How many heads the group's own program feeds: its head count less
    each member whose base ration comes from elsewhere — her own program,
    a more specific group, another group she is in — or who is planned on
    her own because her ration is adjusted. Each head is counted once, in
    exactly one place, so no base ration is planned twice."""
    from app.services import group_service

    members = animals_in_group(db, group, at)
    # The group's heads at [at]: its members at that time when the head
    # count is its membership; its counted total (never less than the
    # members registered) when it is a counted flock (group_service).
    if group.tracking_mode == group_service.MEMBERSHIP_DERIVED:
        state_count = len(members)
    else:
        state_count = max(group.count or 0, len(members))
    if explicit_program(db, "group", group.id, at) is None:
        # No ration of its own: it feeds nobody on a program, and there is
        # nothing to take its members out of.
        return GroupHeads(heads=state_count, members=len(members), excluded=[])
    excluded = []
    for a in members:
        base = base_ration(db, a, at)
        if base.source == "explicit":
            excluded.append({"animal_id": a.id, "name": a.name, "reason": "own_program"})
        elif base.group is None or base.group.id != group.id:
            excluded.append({"animal_id": a.id, "name": a.name, "reason": "other_group",
                             "group_id": base.group.id if base.group else None, "group_name": base.group.name if base.group else None})
        else:
            why = _planned_alone(db, a, at)
            if why:
                excluded.append({"animal_id": a.id, "name": a.name, "reason": why})
    return GroupHeads(heads=max(state_count - len(excluded), 0), members=len(members), excluded=excluded)


def effective_plan(db: Session, subject_type: str, subject, *, with_events: bool = True, at: datetime | None = None,
                   head_count: int | None = None) -> dict:
    """What this subject should be getting today, and what it did get:
    the program (own or inherited), its components per head and in total
    for the head count, supplements added, overrides applied, restricted
    products removed, the resolver's view, the last feedings and their cost.
    This is the animal-profile feeding section of §17 as data.

    The policy (v0.8.6, audit I-4), one for the plan, the reports and the
    forecast:
      base         one ration per head ([base_ration])
      override     replaces one product's quantity per head — the group's
                   own overrides apply to the heads it feeds, an animal's
                   apply to her on top of them
      supplement   adds per head on top of the base — the group's to the
                   heads it feeds, an animal's to her
      restriction  removes a product — the group's bind all its members
    A group's plan is for the heads its program feeds ([group_heads]),
    unless [head_count] says otherwise."""
    state = subject_state(db, subject_type, subject)
    assignment, source, group = effective_program(db, subject_type, subject, at)
    own = active_assignments(db, subject_type, subject.id, at)
    from_group = active_assignments(db, "group", group.id, at) if subject_type == "animal" and group is not None else []
    supplements = [a for a in own if a.assignment_type == "supplement"]
    overrides = [a for a in own if a.assignment_type == "override"]
    restrictions = [a for a in own if a.assignment_type == "restriction"]
    if subject_type == "animal":
        # Her base group's supplements and overrides are hers too (she is fed
        # its ration); a restriction of any group she is in binds her.
        supplements = [a for a in from_group if a.assignment_type == "supplement"] + supplements
        overrides = [a for a in from_group if a.assignment_type == "override"] + overrides
        for g in groups_of_animal(db, subject, at):
            restrictions += [a for a in active_assignments(db, "group", g.id, at) if a.assignment_type == "restriction"]
    heads_info = None
    if subject_type == "group":
        if head_count is None:
            heads_info = group_heads(db, subject, at)
            head = heads_info.heads
        else:
            head = head_count
    else:
        head = 1

    components: list[dict] = []
    warnings: list[str] = []
    version = db.get(fm.FeedingProgramVersion, assignment.program_version_id) if assignment else None
    restricted_products = {r.feed_product_id for r in restrictions if r.feed_product_id}
    if version is not None:
        for c in version.components:
            product = db.get(fm.FeedProduct, c.feed_product_id)
            per_head = _daily_per_head(c, version.feedings_per_day)
            note = None
            for o in overrides:  # the group's first, then her own: the most specific wins
                if o.feed_product_id == c.feed_product_id and o.quantity_per_head is not None:
                    per_head = uom.convert(o.quantity_per_head, o.unit or c.unit, c.unit)
                    note = f"override: {o.reason or 'individual quantity'}"
            if c.feed_product_id in restricted_products:
                warnings.append(f"{product.name if product else c.feed_product_id} is restricted for {state.name} and is left out of today's ration.")
                continue
            components.append({
                "feed_product_id": c.feed_product_id, "product_name": product.name if product else None,
                "quantity_per_head": round(c.quantity_per_head, 3), "unit": c.unit, "frequency": c.frequency, "timing": c.timing,
                "daily_per_head": round(per_head, 3), "daily_total": round(per_head * head, 3), "note": note,
            })
        in_ration = {c.feed_product_id for c in version.components}
        for o in overrides:
            if o.feed_product_id and o.feed_product_id not in in_ration:
                product = db.get(fm.FeedProduct, o.feed_product_id)
                warnings.append(f"The override of {product.name if product else o.feed_product_id} changes nothing: it is not in the ration. "
                                "A feed given on top is a supplement.")
    if subject_type == "animal" and source == "inherited":
        base = base_ration(db, subject, at)
        for g in base.ignored:
            warnings.append(f"{state.name} is also in {g.name}, which has its own ration; she is fed {group.name}'s (one base ration per head).")
    supplement_lines = []
    for s in supplements:
        if s.feed_product_id in restricted_products or s.feed_product_id is None or s.quantity_per_head is None:
            continue
        product = db.get(fm.FeedProduct, s.feed_product_id)
        supplement_lines.append({
            "assignment_id": s.id, "feed_product_id": s.feed_product_id, "product_name": product.name if product else None,
            "daily_per_head": round(s.quantity_per_head, 3), "unit": s.unit or (product.unit if product else "kg"),
            "daily_total": round(s.quantity_per_head * head, 3), "reason": s.reason, "valid_to": s.valid_to,
            "from_group": s.subject_type == "group" and subject_type == "animal",
        })
    targets: dict[str, dict] = {}
    for line in components + supplement_lines:
        entry = targets.setdefault(line["feed_product_id"], {"feed_product_id": line["feed_product_id"], "product_name": line["product_name"], "unit": line["unit"], "daily_total": 0.0})
        entry["daily_total"] = round(entry["daily_total"] + uom.convert(line["daily_total"], line["unit"], entry["unit"]), 3)

    resolution = resolve_state(db, state, current_program_id=version.program_id if version else None)
    plan = {
        "subject": state.to_dict(),
        "program": None if version is None else {
            "program_id": version.program_id, "program_name": version.program.name, "program_name_ar": version.program.name_ar,
            "program_code": version.program.code, "version_id": version.id, "version": version.version,
            "feedings_per_day": version.feedings_per_day, "source": source, "assignment_id": assignment.id,
            "inherited_from": None if group is None else {"group_id": group.id, "group_name": group.name},
            "since": assignment.valid_from,
        },
        "head_count": head,
        "member_count": heads_info.members if heads_info else None,
        "excluded_heads": heads_info.excluded if heads_info else [],
        "components": components,
        "supplements": supplement_lines,
        "overrides": [{"assignment_id": o.id, "feed_product_id": o.feed_product_id, "quantity_per_head": o.quantity_per_head, "unit": o.unit,
                       "reason": o.reason, "valid_to": o.valid_to, "subject_type": o.subject_type} for o in overrides],
        "restrictions": [{"assignment_id": r.id, "feed_product_id": r.feed_product_id, "reason": r.reason, "valid_to": r.valid_to, "subject_type": r.subject_type} for r in restrictions],
        "daily_targets": list(targets.values()),
        "review": {"required": resolution["requires_review"], "recommended": resolution["best"], "warnings": resolution["warnings"] + warnings},
        "eligible_programs": resolution["eligible"],
    }
    if with_events:
        events = feeding_history(db, subject_type, subject.id, days=7)
        recorded = [e for e in events if e.status == "recorded"]
        plan["recent_events"] = [event_to_dict(e) for e in events[:5]]
        plan["feed_cost_7d"] = round(sum(e.total_cost or 0 for e in recorded if e.event_type in STOCK_MOVING), 2)
        summary = summarize_events(recorded)
        plan["fed_7d"] = summary["fed"]
        plan["refused_7d"] = summary["refused"]
        plan["consumed_7d"] = summary["consumed"]
    return plan


# What a feeding event means (v0.8.6, audit I-5), for the plan, the
# reports, the forecast, the costing and the stock alike:
#   offered / delivered   feed left the store: the quantity is FED (and was
#                         issued from the lots). A measured quantity_consumed
#                         is what was eaten of it; the rest was left.
#   refusal               a record of feed refused — of feed already counted
#                         when it was offered. Moves nothing; never fed.
#   consumed_estimate     an estimate of intake. Moves nothing; never fed.
STOCK_MOVING = ("offered", "delivered")


def summarize_events(events: list[fm.FeedingEvent]) -> dict[str, list[dict]]:
    """Per product: `fed` (stock-moving quantities only), `consumed`
    (measured or estimated intake) and `refused`. Reversed events and their
    reversals are left out (status `recorded` only)."""
    out: dict[str, dict[str, dict]] = {"fed": {}, "consumed": {}, "refused": {}}

    def add(kind: str, c: fm.FeedingEventComponent, qty: float) -> None:
        entry = out[kind].setdefault(c.feed_product_id, {"feed_product_id": c.feed_product_id, "quantity": 0.0, "unit": c.unit})
        entry["quantity"] = round(entry["quantity"] + uom.convert(qty, c.unit, entry["unit"]), 3)

    for e in events:
        if e.status != "recorded":
            continue
        for c in e.components:
            if e.event_type in STOCK_MOVING:
                add("fed", c, c.quantity_offered)
                if c.quantity_consumed is not None:
                    add("consumed", c, c.quantity_consumed)
            elif e.event_type == "refusal":
                add("refused", c, c.quantity_offered)
            elif e.event_type == "consumed_estimate":
                add("consumed", c, c.quantity_consumed if c.quantity_consumed is not None else c.quantity_offered)
    return {k: list(v.values()) for k, v in out.items()}


def _fed_totals(events: list[fm.FeedingEvent]) -> list[dict]:
    """What was fed — stock-moving events only ([summarize_events])."""
    return summarize_events(events)["fed"]


def assign(
    db: Session,
    farm_id: str,
    subject_type: str,
    subject,
    *,
    assignment_type: str = "explicit",
    program_id: str | None = None,
    program_version_id: str | None = None,
    feed_product_id: str | None = None,
    quantity_per_head: float | None = None,
    unit: str | None = None,
    reason: str | None = None,
    valid_from=None,
    valid_to=None,
    user_id: str,
) -> fm.FeedingAssignment:
    if assignment_type not in catalog.ASSIGNMENT_TYPES:
        raise FeedError(f"assignment_type must be one of {list(catalog.ASSIGNMENT_TYPES)} — 'inherited' is derived from the group, never assigned.")
    state = subject_state(db, subject_type, subject)
    version: fm.FeedingProgramVersion | None = None
    if assignment_type == "explicit":
        if program_version_id:
            version = db.get(fm.FeedingProgramVersion, program_version_id)
        elif program_id:
            program = db.get(fm.FeedingProgram, program_id)
            if program is None or program.farm_id != farm_id:
                raise FeedError("Feeding program not found", 404)
            version = next((v for v in program.versions if v.status == "active"), None)
            if version is None:
                raise FeedError(f"{program.name} has no active version to assign.")
        if version is None or version.program.farm_id != farm_id:
            raise FeedError("Feeding program version not found", 404)
        if version.status != "active":
            raise FeedError(f"{version.program.name} v{version.version} is {version.status}; only an active version can be assigned.")
        # Every product in the ration must be permitted for this subject —
        # the policy check of §24 at assignment time.
        for c in version.components:
            product = db.get(fm.FeedProduct, c.feed_product_id)
            policy.check_or_raise(db, product, state.policy_target(), through_formula=True, context=f"assign:{version.program.code}", user_id=user_id)
        for old in active_assignments(db, subject_type, subject.id):
            if old.assignment_type == "explicit":
                old.status = "superseded"
                old.ended_at = now()
    else:
        if feed_product_id is None:
            raise FeedError(f"A {assignment_type} names the feed product it applies to.")
        product = inv.get_product(db, feed_product_id, farm_id)
        if assignment_type in ("supplement", "override"):
            if quantity_per_head is None or quantity_per_head <= 0:
                raise FeedError(f"A {assignment_type} needs a quantity per head.")
            policy.check_or_raise(db, product, state.policy_target(), through_formula=product.is_feedable, context=f"{assignment_type}", user_id=user_id)
    row = fm.FeedingAssignment(
        id=new_id(), farm_id=farm_id, subject_type=subject_type, subject_id=subject.id,
        program_version_id=version.id if version else None, assignment_type=assignment_type, feed_product_id=feed_product_id,
        quantity_per_head=quantity_per_head, unit=uom.normalise(unit) if unit else None, reason=reason,
        valid_from=valid_from or now(), valid_to=valid_to, status="active", created_by=user_id, created_at=now(),
    )
    db.add(row)
    db.flush()
    write_event(
        db, farm_id=farm_id, entity_type=subject_type, entity_id=subject.id, event_type="feeding_program_assigned",
        payload={"assignment_id": row.id, "assignment_type": assignment_type, "program": version.program.code if version else None,
                 "version": version.version if version else None, "feed_product_id": feed_product_id, "quantity_per_head": quantity_per_head, "reason": reason},
        created_by=user_id,
    )
    # An explicit change closes the review that asked for it.
    if assignment_type == "explicit":
        for task in db.scalars(select(models.Task).where(models.Task.source_type == "feeding_review", models.Task.source_id == subject.id, models.Task.status != "done")):
            task.status = "done"
    # FEED-PERFORMANCE-INTELLIGENCE §12: re-evaluate after FeedingProgramAssigned/changed.
    from app.services import feed_performance_service as perf  # local import: perf imports this module

    perf.on_context_changed(db, subject_type, subject, trigger="program_assigned", user_id=user_id)
    return row


def end_assignment(db: Session, assignment: fm.FeedingAssignment, *, user_id: str, reason: str | None = None) -> fm.FeedingAssignment:
    if assignment.status != "active":
        raise FeedError("This assignment is not active.")
    assignment.status = "ended"
    assignment.ended_at = now()
    write_event(
        db, farm_id=assignment.farm_id, entity_type=assignment.subject_type, entity_id=assignment.subject_id,
        event_type="feeding_program_changed", payload={"assignment_id": assignment.id, "ended": assignment.assignment_type, "reason": reason},
        created_by=user_id,
    )
    from app.services import feed_performance_service as perf  # local import: perf imports this module

    subject = db.get(models.Animal, assignment.subject_id) if assignment.subject_type == "animal" else db.get(models.Flock, assignment.subject_id)
    if subject is not None:
        perf.on_context_changed(db, assignment.subject_type, subject, trigger="program_changed", user_id=user_id)
    return assignment


# ------------------------------------------------------------------ events
def event_to_dict(e: fm.FeedingEvent) -> dict:
    return {
        "id": e.id, "farm_id": e.farm_id, "subject_type": e.subject_type, "subject_id": e.subject_id,
        "program_version_id": e.program_version_id, "occurred_at": e.occurred_at, "event_type": e.event_type,
        "head_count": e.head_count, "recorded_by": e.recorded_by, "notes": e.notes, "status": e.status,
        "reversal_of_id": e.reversal_of_id, "total_cost": e.total_cost, "created_at": e.created_at,
        "components": [
            {"id": c.id, "feed_product_id": c.feed_product_id, "lot_id": c.lot_id, "batch_id": c.batch_id,
             "quantity_offered": c.quantity_offered, "quantity_consumed": c.quantity_consumed, "unit": c.unit,
             "unit_cost": c.unit_cost, "cost": c.cost}
            for c in e.components
        ],
    }


def find_duplicate_feeding(db: Session, subject_type: str, subject_id: str, *, event_type: str, components: list[dict],
                           at=None) -> fm.FeedingEvent | None:
    """A recorded feeding of the same subject, of the same kind, with the
    same feeds in the same quantities, within half an hour of [at] — the
    same round entered twice (app/core/duplicates.py)."""
    from app.core import duplicates

    wanted: dict[str, float] = {}
    for c in components:
        product = db.get(fm.FeedProduct, c["feed_product_id"])
        if product is None:
            return None
        qty = uom.convert(float(c.get("quantity_offered") or 0), uom.normalise(c.get("unit") or product.unit), product.unit)
        wanted[product.id] = round(wanted.get(product.id, 0.0) + qty, 2)
    lo, hi = duplicates.near(at)
    for e in db.scalars(select(fm.FeedingEvent).where(
        fm.FeedingEvent.subject_type == subject_type, fm.FeedingEvent.subject_id == subject_id, fm.FeedingEvent.event_type == event_type,
        fm.FeedingEvent.status == "recorded", fm.FeedingEvent.occurred_at >= lo, fm.FeedingEvent.occurred_at <= hi,
    )):
        got: dict[str, float] = {}
        for c in e.components:
            got[c.feed_product_id] = round(got.get(c.feed_product_id, 0.0) + (c.quantity_offered or 0), 2)
        if got == wanted:
            return e
    return None


def record_feeding(
    db: Session,
    farm_id: str,
    *,
    subject_type: str,
    subject,
    components: list[dict],
    event_type: str = "offered",
    occurred_at=None,
    head_count: int | None = None,
    notes: str | None = None,
    program_version_id: str | None = None,
    override: inv.Override | None = None,
    user_id: str,
) -> fm.FeedingEvent:
    """§2.6, §16, §33: what was actually put in front of the subject.
    Offering or delivering moves stock out of lots (FIFO, respecting
    reservations); a consumption estimate or a refusal records a measurement
    against what was already issued and moves nothing. Every component is
    checked against the feed's usage policy and the subject's restrictions
    before a gram leaves the store. More than the stock on record goes out
    only with an approved [override] (a reason, an approver), and the part
    no lot covered is an open stock exception linked to this event."""
    if event_type not in catalog.FEEDING_EVENT_TYPES:
        raise FeedError(f"event_type must be one of {list(catalog.FEEDING_EVENT_TYPES)}")
    if subject_type == "animal" and not subject.active:
        # Behavioural model §14: an animal that left blocks future feeding.
        from app.services.livestock_state_service import ensure_on_farm

        ensure_on_farm(subject, "feeding")
    if not components:
        raise FeedError("A feeding event needs at least one feed.")
    state = subject_state(db, subject_type, subject)
    assignment, _, group = effective_program(db, subject_type, subject)
    restricted = {a.feed_product_id for a in active_assignments(db, subject_type, subject.id) if a.assignment_type == "restriction"}
    if subject_type == "animal":
        # A restriction of any group she is in binds her (a quarantined feed
        # for the pen, a vet's restriction for the dry cows) — v0.8.6.
        for g in groups_of_animal(db, subject):
            restricted |= {a.feed_product_id for a in active_assignments(db, "group", g.id) if a.assignment_type == "restriction"}
    when = not_in_future(occurred_at, "A feeding") or now()
    event = fm.FeedingEvent(
        id=new_id(), farm_id=farm_id, subject_type=subject_type, subject_id=subject.id,
        program_version_id=program_version_id or (assignment.program_version_id if assignment else None),
        # FEED-SCHEMA §20: every issue names the assignment in force —
        # the subject's own or the group's it inherits from.
        assignment_id=assignment.id if assignment else None,
        # A group's feeding is for the heads its ration feeds (members fed
        # on their own are not in it — group_heads), unless the feeder says
        # how many heads were actually fed (a partial feeding).
        occurred_at=when, event_type=event_type,
        head_count=head_count if head_count is not None else (group_heads(db, subject, when).heads if subject_type == "group" else 1),
        recorded_by=user_id, notes=notes, status="recorded", created_at=now(),
    )
    db.add(event)
    db.flush()
    moves_stock = event_type in ("offered", "delivered")
    if moves_stock:
        # Every feed of this event is locked up front, in one order, so two
        # feedings of the same feeds never wait on each other in a circle.
        inv.lock_stock(db, *(inv.get_product(db, line["feed_product_id"], farm_id) for line in components))
    total_cost = 0.0
    for line in components:
        product = inv.get_product(db, line["feed_product_id"], farm_id)
        qty = float(line.get("quantity_offered") or 0)
        if qty <= 0:
            raise FeedError(f"Quantity for {product.name} must be greater than zero.")
        unit = uom.normalise(line.get("unit") or product.unit)
        if product.id in restricted:
            raise FeedError(f"{product.name} is restricted for {state.name} (a veterinary or management restriction is active).")
        lot = inv.get_lot(db, line["lot_id"], farm_id) if line.get("lot_id") else None
        policy.check_or_raise(db, product, state.policy_target(), lot=lot, through_formula=product.is_feedable and not product.is_ingredient or bool(line.get("batch_id")),
                              context="feeding", user_id=user_id)
        if not product.is_feedable:
            # A raw material with no usage policy of its own (a grain) still
            # reaches animals only through the mix it goes into; the policy
            # check above gives the more specific reason when there is one.
            raise FeedError(f"{product.name} is an ingredient, not a feed given to animals. Record the mix it goes into, then feed that.")
        consumed = line.get("quantity_consumed")
        if moves_stock:
            draws = inv.consume(
                db, product, qty, unit, reason="feeding", linked_entity_type="feeding_event", linked_entity_id=event.id,
                purpose=Purpose(species_code=state.species_code, subject_type=subject_type, subject_id=subject.id,
                                feeding_program_id=assignment.program_version_id and db.get(fm.FeedingProgramVersion, assignment.program_version_id).program_id if assignment else None,
                                label=state.name),
                lot_id=lot.id if lot else None, override=override, user_id=user_id, occurred_at=when,
            )
            share = 1.0
            for d in draws:
                # A measured consumption is split across the lots in proportion.
                part_consumed = None if consumed is None else round(float(consumed) * (d.quantity / uom.convert(qty, unit, product.unit)), 3)
                comp = fm.FeedingEventComponent(
                    id=new_id(), event_id=event.id, feed_product_id=product.id, lot_id=d.lot.id if d.lot else None,
                    batch_id=line.get("batch_id") or (d.lot.feed_batch_id if d.lot else None), quantity_offered=round(d.quantity, 3),
                    quantity_consumed=part_consumed, unit=product.unit, unit_cost=d.unit_cost, cost=d.cost,
                )
                event.components.append(comp)
                total_cost += d.cost or 0
                share -= 0
        else:
            comp = fm.FeedingEventComponent(
                id=new_id(), event_id=event.id, feed_product_id=product.id, lot_id=lot.id if lot else None, batch_id=line.get("batch_id"),
                quantity_offered=round(uom.convert(qty, unit, product.unit), 3),
                quantity_consumed=None if consumed is None else float(consumed), unit=product.unit, unit_cost=None, cost=None,
            )
            event.components.append(comp)
    event.total_cost = round(total_cost, 4) if moves_stock else None
    write_event(
        db, farm_id=farm_id, entity_type=subject_type, entity_id=subject.id, event_type="feeding_event_recorded",
        payload={"feeding_event_id": event.id, "event_type": event_type, "head_count": event.head_count, "assignment_id": event.assignment_id,
                 "components": [{"feed_product_id": c.feed_product_id, "quantity": c.quantity_offered, "unit": c.unit, "lot_id": c.lot_id} for c in event.components],
                 "cost": event.total_cost},
        created_by=user_id,
    )
    # FEED-PERFORMANCE-INTELLIGENCE §12: re-evaluate after FeedingEventRecorded.
    from app.services import feed_performance_service as perf  # local import: perf imports this module

    perf.on_feeding_recorded(db, subject_type, subject, user_id=user_id)
    return event


def reverse_feeding(db: Session, event: fm.FeedingEvent, *, reason: str, user_id: str) -> fm.FeedingEvent:
    """A controlled correction: the original stays, marked reversed; a
    reversal event points at it and the stock returns to the lots it left."""
    if event.status != "recorded":
        raise FeedError("Only a recorded feeding can be reversed.")
    if not reason or not reason.strip():
        raise FeedError("A reversal needs a reason.")
    reversal = fm.FeedingEvent(
        id=new_id(), farm_id=event.farm_id, subject_type=event.subject_type, subject_id=event.subject_id,
        program_version_id=event.program_version_id, occurred_at=now(), event_type=event.event_type, head_count=event.head_count,
        recorded_by=user_id, notes=f"Reversal of {event.id}: {reason}", status="reversal", reversal_of_id=event.id,
        total_cost=-(event.total_cost or 0) if event.total_cost is not None else None, created_at=now(),
    )
    db.add(reversal)
    db.flush()
    by_product: dict[str, list[tuple[str | None, float]]] = {}
    for c in event.components:
        reversal.components.append(fm.FeedingEventComponent(
            id=new_id(), event_id=reversal.id, feed_product_id=c.feed_product_id, lot_id=c.lot_id, batch_id=c.batch_id,
            quantity_offered=-c.quantity_offered, quantity_consumed=None, unit=c.unit, unit_cost=c.unit_cost,
            cost=None if c.cost is None else -c.cost,
        ))
        by_product.setdefault(c.feed_product_id, []).append((c.lot_id, c.quantity_offered))
    if event.event_type in ("offered", "delivered"):
        for product_id, draws in by_product.items():
            product = db.get(fm.FeedProduct, product_id)
            inv.restore(db, product, draws, reason="feeding_reversal", linked_entity_type="feeding_event", linked_entity_id=reversal.id, user_id=user_id,
                        reverses_entity_id=event.id)
    event.status = "reversed"
    write_event(
        db, farm_id=event.farm_id, entity_type=event.subject_type, entity_id=event.subject_id, event_type="feeding_event_reversed",
        payload={"feeding_event_id": event.id, "reversal_id": reversal.id, "reason": reason}, created_by=user_id,
    )
    return reversal


def feeding_history(db: Session, subject_type: str, subject_id: str, *, days: int = 30, farm_id: str | None = None) -> list[fm.FeedingEvent]:
    """The subject's feedings over its last [days] farm days, today
    included (the farm's calendar, not 24-hour slices — farm_time)."""
    if farm_id is None:
        subject = db.get(models.Animal, subject_id) if subject_type == "animal" else db.get(models.Flock, subject_id)
        farm_id = getattr(subject, "farm_id", None)
    if farm_id is not None:
        _start, _end, since, _hi = farm_time.last_days(db, farm_id, days)
    else:
        since = now() - timedelta(days=days)
    return list(db.scalars(select(fm.FeedingEvent).where(
        fm.FeedingEvent.subject_type == subject_type, fm.FeedingEvent.subject_id == subject_id, fm.FeedingEvent.occurred_at >= since,
    ).order_by(fm.FeedingEvent.occurred_at.desc())))


# ------------------------------------------------------------ lifecycle
def review_feeding(db: Session, farm_id: str, subject_type: str, subject, *, trigger: str, user_id: str) -> dict:
    """§10, §19: an animal event re-evaluates the feeding program. If the
    best-matching program is not the one the subject is on, this raises
    `feeding_program_review_required` and opens a review task — and changes
    nothing else. The farm decides; the system explains."""
    assignment, source, _ = effective_program(db, subject_type, subject)
    current_program_id = None
    if assignment is not None:
        v = db.get(fm.FeedingProgramVersion, assignment.program_version_id)
        current_program_id = v.program_id if v else None
    state = subject_state(db, subject_type, subject)
    resolution = resolve_state(db, state, current_program_id=current_program_id)
    if not resolution["requires_review"]:
        return {"review_required": False, "trigger": trigger, "resolution": resolution}
    existing = db.scalar(select(models.Task).where(
        models.Task.farm_id == farm_id, models.Task.source_type == "feeding_review",
        models.Task.source_id == subject.id, models.Task.status != "done",
    ))
    if existing is not None:
        # One open review per subject: a second milk record or a second
        # edit while the first review is pending adds nothing.
        return {"review_required": True, "already_open": True, "task_id": existing.id, "trigger": trigger, "resolution": resolution}
    best = resolution["best"]
    write_event(
        db, farm_id=farm_id, entity_type=subject_type, entity_id=subject.id, event_type="feeding_program_review_required",
        payload={"trigger": trigger, "recommended_program_id": best["program_id"] if best else None,
                 "recommended_program": best["program_name"] if best else None, "current_program_id": current_program_id,
                 "reasons": best["reasons"] if best else resolution["warnings"], "source": source},
        created_by=user_id,
    )
    name = getattr(subject, "name", subject.id)
    if best:
        description = (f"{trigger.replace('_', ' ').capitalize()}: {name} now matches '{best['program_name']}' "
                       f"({'; '.join(best['reasons'])}). Currently on: {'no program' if current_program_id is None else 'a different program'}. "
                       "Review and assign — nothing changes until you do.")
    else:
        description = f"{trigger.replace('_', ' ').capitalize()}: no active feeding program matches {name} any more. Review the assignment."
    task = models.Task(
        id=new_id(), farm_id=farm_id, title=f"Review feeding program — {name}", description=description,
        assigned_to=None, due_at=now() + timedelta(days=2), priority="medium", status="open",
        source_type="feeding_review", source_id=subject.id,
    )
    db.add(task)
    return {"review_required": True, "already_open": False, "task_id": task.id, "trigger": trigger, "resolution": resolution}


# --------------------------------------------------------- program admin
def _unique_program_code(db: Session, farm_id: str, base: str) -> str:
    code, n = base, 2
    while db.scalar(select(fm.FeedingProgram.id).where(fm.FeedingProgram.farm_id == farm_id, fm.FeedingProgram.code == code)):
        code = f"{base}-{n}"
        n += 1
    return code


def _build_version_rows(db: Session, farm_id: str, components: list[dict], rules: list[dict]) -> tuple[list[fm.FeedingProgramComponent], list[fm.FeedingProgramRule]]:
    if not components:
        raise FeedError("A feeding program needs at least one feed in its ration.")
    comp_rows = []
    for i, c in enumerate(components):
        product = inv.get_product(db, c["feed_product_id"], farm_id)
        if not product.is_feedable:
            raise FeedError(f"{product.name} is an ingredient, not something that is fed as it is; put it in a formula.")
        qty = float(c.get("quantity_per_head") or 0)
        if qty <= 0:
            raise FeedError(f"Quantity per head for {product.name} must be greater than zero.")
        frequency = c.get("frequency") or "per_day"
        if frequency not in ("per_day", "per_feeding"):
            raise FeedError("frequency must be per_day or per_feeding")
        unit = uom.normalise(c.get("unit") or product.unit)
        if not uom.compatible(unit, product.unit):
            raise FeedError(f"{product.name} is kept in {product.unit}; the ration says {unit}.")
        comp_rows.append(fm.FeedingProgramComponent(
            id=new_id(), feed_product_id=product.id, quantity_per_head=qty, unit=unit, frequency=frequency,
            timing=c.get("timing"), notes=c.get("notes"), sort_order=i,
        ))
    rule_rows = []
    for r in rules or []:
        sex = r.get("sex")
        if sex is not None:
            sex = {"F": "F", "FEMALE": "F", "M": "M", "MALE": "M"}.get(str(sex).upper())
            if sex is None:
                raise FeedError("rule sex must be F or M (or left unset)")
        if r.get("species_code") and db.get(lm.Species, r["species_code"]) is None:
            raise FeedError(f"Unknown species '{r['species_code']}' in a program rule; add it to the species catalog first.")
        rule_rows.append(fm.FeedingProgramRule(
            id=new_id(), species_code=r.get("species_code"), sex=sex, life_stage=r.get("life_stage"),
            management_profile=r.get("management_profile"), reproductive_state=r.get("reproductive_state"),
            lactation_state=r.get("lactation_state"), production_metric=r.get("production_metric"),
            production_min=r.get("production_min"), production_max=r.get("production_max"),
            weight_min=r.get("weight_min"), weight_max=r.get("weight_max"),
            age_min_days=r.get("age_min_days"), age_max_days=r.get("age_max_days"),
            priority=int(r.get("priority") or 0), notes=r.get("notes"),
        ))
    return comp_rows, rule_rows


def create_program(
    db: Session,
    farm_id: str,
    *,
    code: str | None,
    name: str,
    name_ar: str | None,
    category: str | None,
    description: str | None,
    feedings_per_day: int,
    components: list[dict],
    rules: list[dict],
    notes: str | None = None,
    activate: bool = True,
    program_id: str | None = None,
    user_id: str,
) -> fm.FeedingProgram:
    program = fm.FeedingProgram(
        id=program_id or new_id(), farm_id=farm_id, code=_unique_program_code(db, farm_id, inv.slug(code or name)), name=name, name_ar=name_ar,
        category=category, status="active", description=description, created_at=now(),
    )
    db.add(program)
    db.flush()
    add_program_version(db, program, feedings_per_day=feedings_per_day, components=components, rules=rules, notes=notes, activate=activate, user_id=user_id)
    return program


def add_program_version(
    db: Session,
    program: fm.FeedingProgram,
    *,
    feedings_per_day: int | None,
    components: list[dict],
    rules: list[dict],
    notes: str | None = None,
    activate: bool = True,
    user_id: str,
) -> fm.FeedingProgramVersion:
    comp_rows, rule_rows = _build_version_rows(db, program.farm_id, components, rules)
    version = fm.FeedingProgramVersion(
        id=new_id(), program_id=program.id, version=(max((v.version for v in program.versions), default=0)) + 1, status="draft",
        feedings_per_day=feedings_per_day or (program.versions[-1].feedings_per_day if program.versions else 2), notes=notes,
        created_by=user_id, created_at=now(),
    )
    version.components.extend(comp_rows)
    version.rules.extend(rule_rows)
    db.add(version)
    program.versions.append(version)
    db.flush()
    if activate:
        activate_program_version(db, version, user_id=user_id)
    return version


def activate_program_version(db: Session, version: fm.FeedingProgramVersion, *, user_id: str) -> fm.FeedingProgramVersion:
    """Activation is where the ration meets the rules: every product in it
    must be permitted for every species the rules name (§24)."""
    program = version.program
    species = {r.species_code for r in version.rules if r.species_code}
    for c in version.components:
        product = db.get(fm.FeedProduct, c.feed_product_id)
        for code in species or {None}:
            policy.check_or_raise(db, product, policy.Target(species_code=code, label=f"{program.name} ({code or 'any species'})", partial=True),
                                  through_formula=not product.is_ingredient, context=f"program_activate:{program.code}", user_id=user_id)
    for other in program.versions:
        if other.id != version.id and other.status == "active":
            other.status = "retired"
            other.effective_to = now()
    version.status = "active"
    version.effective_from = now()
    version.effective_to = None
    # Subjects on the previous version follow the program: their explicit
    # assignment is moved to the new version, recorded as a change.
    for a in db.scalars(select(fm.FeedingAssignment).where(fm.FeedingAssignment.status == "active", fm.FeedingAssignment.assignment_type == "explicit")):
        old = db.get(fm.FeedingProgramVersion, a.program_version_id) if a.program_version_id else None
        if old is not None and old.program_id == program.id and old.id != version.id:
            a.program_version_id = version.id
    write_event(
        db, farm_id=program.farm_id, entity_type="feeding_program", entity_id=program.id, event_type="feeding_program_activated",
        payload={"version_id": version.id, "version": version.version, "components": len(version.components), "rules": len(version.rules)},
        created_by=user_id,
    )
    return version


def review_animal_if_relevant(db: Session, animal: models.Animal, changed: set[str], *, user_id: str) -> None:
    """Called by the animal endpoints after an update. Only the inputs the
    resolver reads trigger a review; a photo change does not."""
    relevant = {"sex", "life_stage", "management_profile", "pregnant", "lactating", "group_name", "weight_kg", "birth_date", "species"}
    hit = relevant & changed
    if not hit:
        return
    trigger = {
        "pregnant": "pregnancy_state_changed", "lactating": "lactation_state_changed", "group_name": "group_moved",
        "life_stage": "life_stage_changed", "management_profile": "management_profile_changed",
    }.get(next(iter(sorted(hit))), "animal_state_changed")
    if "pregnant" in hit and animal.pregnant:
        trigger = "pregnancy_confirmed"
    elif "lactating" in hit:
        trigger = "lactation_started" if animal.lactating else "dry_off_recorded"
    elif "group_name" in hit:
        trigger = "group_moved"
    review_feeding(db, animal.farm_id, "animal", animal, trigger=trigger, user_id=user_id)


def review_after_milk(db: Session, animal: models.Animal, *, user_id: str) -> None:
    """A milk record can move an animal across a production band (§11)."""
    versions = active_versions(db, animal.farm_id)
    banded = any(r.production_min is not None or r.production_max is not None for v in versions for r in v.rules)
    if not banded:
        return
    review_feeding(db, animal.farm_id, "animal", animal, trigger="production_band_changed", user_id=user_id)


# --------------------------------------------------------------- planning
def daily_plan(db: Session, farm_id: str, day: date | None = None) -> dict:
    """The planned feeding of one farm day (§17 Daily Feeding) — today by
    default — and what was fed that day: every group whose program feeds
    heads, every animal planned on her own, per-product totals.

    Each head is planned once (v0.8.6, audit I-4): a group line counts only
    the heads its own program feeds ([group_heads]); an animal with her own
    program, or whose base ration is adjusted (an override, a restriction),
    has her own full line and is not in her group's count; an animal fed
    her group's ration as it is adds only her own supplements. A day is the
    farm's calendar day ([farm_time], audit I-6); fed is what left the store
    (stock-moving events, audit I-5). For a past day the programs, the
    memberships and the assignments are those in force at the end of it."""
    tz = farm_time.farm_tz(db, farm_id)
    day = day or farm_time.local_day(tz)
    lo, hi = farm_time.day_bounds(tz, day)
    at = None if day >= farm_time.local_day(tz) else hi - timedelta(microseconds=1)
    prefetch_farm(db, farm_id)
    lines: list[dict] = []
    totals: dict[str, dict] = {}
    groups = db.scalars(select(models.Flock).where(models.Flock.farm_id == farm_id, models.Flock.status.notin_(("closed", "archived")))).all()
    for group in groups:
        if explicit_program(db, "group", group.id, at) is None:
            continue
        plan = effective_plan(db, "group", group, with_events=False, at=at)
        lines.append({"subject_type": "group", "subject_id": group.id, "name": group.name, "species": group.species,
                      "head_count": plan["head_count"], "member_count": plan["member_count"], "excluded_heads": plan["excluded_heads"],
                      "program": plan["program"], "daily_targets": plan["daily_targets"],
                      "warnings": plan["review"]["warnings"], "review_required": plan["review"]["required"]})
        for t in plan["daily_targets"]:
            _add_total(totals, t)
    animals = db.scalars(select(models.Animal).where(models.Animal.farm_id == farm_id, models.Animal.active.is_(True))).all()
    for animal in animals:
        base = base_ration(db, animal, at)
        own = active_assignments(db, "animal", animal.id, at)
        own_supplements = [a for a in own if a.assignment_type == "supplement"]
        alone = base.source == "explicit" or (base.source == "inherited" and _planned_alone(db, animal, at) is not None)
        if not alone and not own_supplements:
            continue
        plan = effective_plan(db, "animal", animal, with_events=False, at=at)
        if alone:
            # Her whole ration: her own program, or her group's as adjusted
            # for her (she is not in the group's head count).
            targets = plan["daily_targets"]
            basis = "own_program" if base.source == "explicit" else "adjusted_group_ration"
        else:
            # Fed her group's ration as it is (counted there): only what is
            # added for her on top.
            ids = {a.id for a in own_supplements}
            targets = [{"feed_product_id": s["feed_product_id"], "product_name": s["product_name"], "unit": s["unit"], "daily_total": s["daily_total"]}
                       for s in plan["supplements"] if s["assignment_id"] in ids]
            basis = "supplement_only"
            if not targets:
                continue
        lines.append({"subject_type": "animal", "subject_id": animal.id, "name": animal.name, "species": animal.species,
                      "head_count": 1, "basis": basis, "program": plan["program"], "daily_targets": targets,
                      "warnings": plan["review"]["warnings"], "review_required": plan["review"]["required"]})
        for t in targets:
            _add_total(totals, t)
    fed, fed_by_subject = _fed_between(db, farm_id, lo, hi)
    planned = set()
    for line in lines:
        key = (line["subject_type"], line["subject_id"])
        planned.add(key)
        line["fed"] = [{"feed_product_id": pid, "quantity": round(q, 3)} for pid, q in fed_by_subject.get(key, {}).items()]
    # Subjects fed that day that no line plans (fed with their group's
    # ration but on their own, a one-off feed, a past day before their
    # program): still listed, so what left the store is never unaccounted.
    unplanned = []
    for (stype, sid), mine in fed_by_subject.items():
        if (stype, sid) in planned:
            continue
        row = db.get(models.Animal, sid) if stype == "animal" else db.get(models.Flock, sid)
        unplanned.append({"subject_type": stype, "subject_id": sid, "name": getattr(row, "name", None), "species": getattr(row, "species", None),
                          "fed": [{"feed_product_id": pid, "quantity": round(q, 3)} for pid, q in mine.items()]})
    for pid, entry in totals.items():
        entry["fed_today"] = round(fed.get(pid, 0.0), 3)
        entry["remaining_today"] = round(max(entry["daily_total"] - entry["fed_today"], 0), 3)
    # Fed products no line plans (a one-off feeding) still show what left.
    for pid, q in fed.items():
        if pid not in totals:
            product = db.get(fm.FeedProduct, pid)
            totals[pid] = {"feed_product_id": pid, "product_name": product.name if product else None, "unit": product.unit if product else "kg",
                           "daily_total": 0.0, "fed_today": round(q, 3), "remaining_today": 0.0}
    return {"date": day.isoformat(), "timezone": str(tz), "from": lo, "to": hi, "lines": lines, "totals": list(totals.values()),
            "unplanned_fed": sorted(unplanned, key=lambda u: (u["subject_type"], u["name"] or ""))}


def _add_total(totals: dict, t: dict) -> None:
    entry = totals.setdefault(t["feed_product_id"], {"feed_product_id": t["feed_product_id"], "product_name": t.get("product_name"), "unit": t["unit"], "daily_total": 0.0})
    entry["daily_total"] = round(entry["daily_total"] + uom.convert(t["daily_total"], t["unit"], entry["unit"]), 3)


def _fed_between(db: Session, farm_id: str, lo, hi) -> tuple[dict[str, float], dict[tuple[str, str], dict[str, float]]]:
    """What left the store in [lo, hi), per product and per subject:
    stock-moving events only. A group's feeding stays the group's — it is
    never spread over its heads."""
    events = db.scalars(select(fm.FeedingEvent).where(
        fm.FeedingEvent.farm_id == farm_id, fm.FeedingEvent.occurred_at >= lo, fm.FeedingEvent.occurred_at < hi,
        fm.FeedingEvent.status == "recorded", fm.FeedingEvent.event_type.in_(STOCK_MOVING),
    )).all()
    out: dict[str, float] = {}
    by_subject: dict[tuple[str, str], dict[str, float]] = {}
    for e in events:
        mine = by_subject.setdefault((e.subject_type, e.subject_id), {})
        for c in e.components:
            product = db.get(fm.FeedProduct, c.feed_product_id)
            qty = uom.convert(c.quantity_offered, c.unit, product.unit) if product else c.quantity_offered
            out[c.feed_product_id] = out.get(c.feed_product_id, 0.0) + qty
            mine[c.feed_product_id] = mine.get(c.feed_product_id, 0.0) + qty
    return out, by_subject


def _fed_today(db: Session, farm_id: str) -> dict[str, float]:
    """What left the store today — the farm's today."""
    _day, lo, hi = farm_time.farm_day(db, farm_id)
    return _fed_between(db, farm_id, lo, hi)[0]


def demand_by_product(db: Session, farm_id: str) -> dict[str, dict]:
    """Daily demand per product from the active programs and head counts
    (§28.3), split by species so eligibility can be checked against usage
    policies and allocations. Farm-produced products with an active formula
    also pass their demand down to their ingredients in formula proportion."""
    plan = daily_plan(db, farm_id)
    demand: dict[str, dict] = {}

    def add(pid: str, qty: float, unit: str, species: str, via: str | None):
        entry = demand.setdefault(pid, {"feed_product_id": pid, "daily_quantity": 0.0, "unit": unit, "by_species": {}, "subjects": 0, "via": set()})
        q = uom.convert(qty, unit, entry["unit"])
        entry["daily_quantity"] = round(entry["daily_quantity"] + q, 3)
        entry["by_species"][species] = round(entry["by_species"].get(species, 0.0) + q, 3)
        if via:
            entry["via"].add(via)

    for line in plan["lines"]:
        for t in line["daily_targets"]:
            add(t["feed_product_id"], t["daily_total"], t["unit"], line["species"], None)
            demand[t["feed_product_id"]]["subjects"] += 1
    # Expand farm-produced demand into ingredient demand.
    for pid in list(demand):
        product = db.get(fm.FeedProduct, pid)
        if product is None or product.source_type != "farm_produced":
            continue
        version = db.scalar(select(fm.FeedFormulaVersion).join(fm.FeedFormula).where(
            fm.FeedFormula.feed_product_id == pid, fm.FeedFormula.status == "active", fm.FeedFormulaVersion.status == "active"))
        if version is None or not version.batch_size:
            continue
        for species, qty in list(demand[pid]["by_species"].items()):
            factor = uom.convert(qty, demand[pid]["unit"], version.unit) / version.batch_size
            for c in version.components:
                add(c.feed_product_id, c.target_quantity * factor, c.unit, species, product.code)
    for entry in demand.values():
        entry["via"] = sorted(entry["via"])
    return demand
