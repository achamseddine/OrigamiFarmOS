from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import owned_or_404, require_any_permission, require_farm_access, require_permission, user_can
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import emergency_models as em
from app.domain import livestock_models as lm
from app.domain import models
from app.domain import pharmacy_models as pm
from app.repositories.base import diff_changes, ensure_utc, now, snapshot, write_audit_log, write_event
from app.schemas.animals import AnimalCreate, AnimalDigitalTwinOut, AnimalMove, AnimalOut, AnimalUpdate
from app.services import (
    animal_service,
    capability_service,
    feed_performance_service,
    feeding_program_service,
    group_service,
    health_case_service,
    identifier_service,
    livestock_state_service,
    reproduction_service,
)

router = APIRouter(prefix="/animals", tags=["animals"])

# Fields the audit trail follows on an animal — everything a manager might
# need to explain later ("who changed this cow's status?").
_AUDITED_ANIMAL_FIELDS = [
    "tag", "name", "species", "breed", "breed_id", "sex", "life_stage", "management_profile",
    "birth_date_estimated", "status", "location_label",
    "health_score", "weight_kg", "group_name", "pregnant", "lactating",
    "purchase_cost", "current_value", "active", "notes",
]

_FINANCIAL_FIELDS = animal_service.FINANCIAL_FIELDS

# Pregnancy and lactation are records, not fields (LIVESTOCK-SCHEMA §1.8,
# REPRODUCTION-SCHEMA): the animal's flags are their projection.
_REPRODUCTION_FIELDS = ("pregnant", "lactating")
_DERIVED_FIELDS = ("pregnancy_days",)
# Current-state fields whose every change is written to the animal's state
# history first (LIVESTOCK-SCHEMA §14).
_HISTORY_FIELDS = {
    "life_stage": livestock_state_service.LIFE_STAGE,
    "management_profile": livestock_state_service.MANAGEMENT_PROFILE,
    "location_label": livestock_state_service.LOCATION,
}


def _has_operational_history(db: Session, animal_id: str) -> bool:
    """Anything recorded *about* the animal since it was registered. While
    this is true its species cannot change (§12) — the history would no
    longer mean what it meant."""
    from app.domain import reproduction_models as rm

    checks = (
        select(models.MilkRecord.id).where(models.MilkRecord.animal_id == animal_id),
        select(models.Observation.id).where(models.Observation.entity_type == "animal", models.Observation.entity_id == animal_id),
        select(models.Treatment.id).where(models.Treatment.entity_type == "animal", models.Treatment.entity_id == animal_id),
        select(rm.BreedingEvent.id).where(rm.BreedingEvent.female_animal_id == animal_id),
        select(rm.BirthEvent.id).where(rm.BirthEvent.dam_animal_id == animal_id),
    )
    return any(db.scalar(q.limit(1)) for q in checks)


# The herd list is what the tablet's AnimalsProvider loads (for Animals);
# health, milk and feeding work all start from picking an animal.
_ANIMALS_VIEW = require_farm_access(perms.ANIMALS, perms.ANIMAL_HEALTH, perms.MILK_PRODUCTION, perms.FEED_NUTRITION)
# One animal's record is reached from anywhere an animal is named: a herd
# card, a milk entry, a priority or a notification.
_ANIMAL_RECORD_MODULES = (perms.ANIMALS, perms.ANIMAL_HEALTH, perms.MILK_PRODUCTION, perms.FEED_NUTRITION,
                          perms.EGG_PRODUCTION, perms.AI_INTELLIGENCE)
_ANIMAL_RECORD_VIEW = require_any_permission(*_ANIMAL_RECORD_MODULES)


def _identifier_match(like: str):
    return models.Animal.id.in_(select(lm.AnimalIdentifier.animal_id).where(func.lower(lm.AnimalIdentifier.identifier_value).like(like)))


@router.get("", response_model=list[AnimalOut])
def list_animals(
    species: str | None = None,
    status_filter: str | None = Query(None, alias="status"),
    search: str | None = None,
    include_exited: bool = Query(False, description="Also list animals that were sold, died, or otherwise left the farm."),
    db: Session = Depends(get_db),
    user: models.User = Depends(_ANIMALS_VIEW),
) -> list[models.Animal]:
    stmt = select(models.Animal).where(models.Animal.farm_id == user.farm_id)
    if not include_exited:
        stmt = stmt.where(models.Animal.active.is_(True))
    if species:
        stmt = stmt.where(models.Animal.species == species)
    if status_filter:
        stmt = stmt.where(models.Animal.status == status_filter)
    if search:
        # Name, the primary tag, and every identifier the animal carries or
        # carried (LIVESTOCK-SCHEMA §16: search by allowed identifiers).
        like = f"%{search.strip().lower()}%"
        stmt = stmt.where(models.Animal.name.ilike(like) | models.Animal.tag.ilike(like) | _identifier_match(like))
    return list(db.scalars(stmt.order_by(models.Animal.name)))


@router.get("/lookup")
def lookup_animal(
    value: str = Query(..., min_length=1, description="An identifier value as written on the animal: ear tag, RFID, microchip, band, name…"),
    db: Session = Depends(get_db),
    user: models.User = Depends(_ANIMAL_RECORD_VIEW),
) -> list[dict]:
    """Every animal on this farm an identifier value could mean, exact
    matches only (LIVESTOCK-SCHEMA §16). More than one result is an
    ambiguity for the person to resolve — the server never silently picks
    one. A retired tag still resolves, flagged, so an old paper record can
    be matched to its animal."""
    needle = value.strip().lower()
    rows = db.execute(
        select(lm.AnimalIdentifier, models.Animal).join(models.Animal, models.Animal.id == lm.AnimalIdentifier.animal_id)
        .where(models.Animal.farm_id == user.farm_id, func.lower(lm.AnimalIdentifier.identifier_value) == needle)
    ).all()
    out = [
        {"animal_id": a.id, "name": a.name, "tag": a.tag, "species": a.species, "active": a.active, "lifecycle_status": a.lifecycle_status,
         "matched_type": i.identifier_type, "matched_value": i.identifier_value, "identifier_status": i.status, "retired": i.status != "active"}
        for i, a in rows
    ]
    seen = {r["animal_id"] for r in out}
    for a in db.scalars(select(models.Animal).where(models.Animal.farm_id == user.farm_id, func.lower(models.Animal.name) == needle)):
        if a.id not in seen:
            out.append({"animal_id": a.id, "name": a.name, "tag": a.tag, "species": a.species, "active": a.active,
                        "lifecycle_status": a.lifecycle_status, "matched_type": "NAME", "matched_value": a.name,
                        "identifier_status": "active", "retired": False})
    # Current animals and active identifiers first: the likely answer on top.
    return sorted(out, key=lambda r: (not r["active"], r["retired"], r["name"]))


@router.post("", response_model=AnimalOut, status_code=status.HTTP_201_CREATED)
def create_animal(
    payload: AnimalCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.CREATE)),
) -> models.Animal:
    """Registers a new animal — the start of its digital twin (tech spec §13).

    Generic animal model §2: species, sex, stage and profile go through
    the capability resolver first; it decides which identifiers this
    animal may and must carry and whether it can be pregnant or lactating.
    An animal registered pregnant or in milk gets the pregnancy or lactation
    episode that says so; `group_name` must name an existing group of its
    species, which it then joins.
    """
    animal = animal_service.create_animal(
        db, current_user, payload.model_dump(exclude={"identifiers", "tag"}), identifiers_in=payload.identifiers, tag=payload.tag,
    )
    db.commit()
    db.refresh(animal)
    return animal


@router.put("/{animal_id}", response_model=AnimalOut)
def update_animal(
    animal_id: str,
    payload: AnimalUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.EDIT)),
) -> models.Animal:
    """Full edit of an animal record (tech spec §12).

    What an edit cannot do, by design:
    - change `pregnant` or `lactating` — a pregnancy check, a birth, a loss,
      a lactation start or a dry-off records that (`/animals/{id}/...`); a
      re-sent unchanged value is fine, and `pregnancy_days` is derived;
    - change species once anything has been recorded about the animal.

    What an edit does on the way: a new stage, profile or location is
    written to the state history first; a new herd name moves the animal's
    group membership (it must name an existing group of its species);
    archiving closes its memberships, lactation and pregnancy like an exit.
    """
    animal = owned_or_404(db, models.Animal, animal_id, current_user, "Animal")

    changes = payload.model_dump(exclude_unset=True)
    if not user_can(db, current_user, perms.FINANCE, perms.EDIT):
        for field in _FINANCIAL_FIELDS:
            changes.pop(field, None)
    if changes.get("active") is False and not user_can(db, current_user, perms.ANIMALS, perms.DELETE):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "You do not have permission to archive an animal in Animals."
        )
    for field in _DERIVED_FIELDS:
        changes.pop(field, None)
    for field in _REPRODUCTION_FIELDS:
        if field in changes and changes[field] is not None and bool(changes[field]) != bool(getattr(animal, field)):
            what = "a pregnancy" if field == "pregnant" else "a lactation"
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                f"{animal.name}'s {'pregnancy' if field == 'pregnant' else 'milking'} state comes from its records. "
                f"Record {what} through the animal's reproduction actions (pregnancy check, birth, loss, start of milking or dry-off).",
            )
        changes.pop(field, None)
    if "lactation_cycle" in changes:
        from app.domain import reproduction_models as rm

        if changes["lactation_cycle"] != animal.lactation_cycle and db.scalar(
            select(rm.LactationEpisode.id).where(rm.LactationEpisode.animal_id == animal.id, rm.LactationEpisode.source != "registration").limit(1)
        ):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"{animal.name}'s lactation number comes from its recorded lactations.")
        if changes["lactation_cycle"] is not None and changes["lactation_cycle"] < 0:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "The lactation number cannot be negative.")

    # Species is the one thing history depends on (§12): once anything has
    # been recorded about the animal, it stays what it was registered as.
    new_species = changes.get("species", animal.species)
    if new_species != animal.species:
        animal_service.species_or_422(db, new_species)
        if _has_operational_history(db, animal.id):
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                f"{animal.name} already has milk, treatment, observation or reproduction records as a "
                f"{animal.species.replace('_', ' ')}. Its species cannot be changed; register a new animal instead.",
            )

    # Sex, stage or profile changing re-evaluates what the animal can be
    # — a cow cannot move to the meat profile while she is recorded in milk.
    resolver_inputs = {"species", "sex", "life_stage", "management_profile"}
    if resolver_inputs & changes.keys():
        cap_set = capability_service.resolve(
            db, new_species, changes.get("sex", animal.sex),
            changes.get("life_stage", animal.life_stage), changes.get("management_profile", animal.management_profile),
        )
        animal_service.check_state_against(cap_set, name=animal.name, pregnant=animal.pregnant, lactating=animal.lactating)
    else:
        cap_set = None

    new_tag = changes.pop("tag", None)
    group_name = changes.pop("group_name", None) if "group_name" in changes else ...
    active = changes.pop("active", None)

    before = snapshot(animal, _AUDITED_ANIMAL_FIELDS)
    # A weight is a dated record (HEALTH-VETERINARY-SCHEMA / per-weight
    # dosing); the animal's `weight_kg` is the latest of them.
    new_weight = changes.pop("weight_kg", None)
    for field, state_type in _HISTORY_FIELDS.items():
        if field in changes:
            reference = animal.location_id if field == "location_label" and changes[field] == animal.location_label else None
            livestock_state_service.record(db, animal, state_type, changes.pop(field), reference_id=reference, reason="edit",
                                           source_type="animal_update", user_id=current_user.id)
    for field, value in changes.items():
        setattr(animal, field, value)
    if new_weight is not None and new_weight != animal.weight_kg:
        health_case_service.record_weight(db, animal.farm_id, animal, weight_kg=new_weight, method="scale", source_type="animal_update", user_id=current_user.id)
    if group_name is not ... and (group_name or "").strip().lower() != (animal.group_name or "").strip().lower():
        group_service.move_by_name(db, animal, group_name, user_id=current_user.id)
    if active is False and animal.active:
        livestock_state_service.exit_animal(db, animal, livestock_state_service.ARCHIVED, reason="archived", user=current_user)
    elif active is True and not animal.active:
        livestock_state_service.reactivate(db, animal, user=current_user)
    after = snapshot(animal, _AUDITED_ANIMAL_FIELDS)
    changed = {k for k in _AUDITED_ANIMAL_FIELDS if before.get(k) != after.get(k)}
    # A change to what the feeding resolver reads (stage, profile, weight…)
    # asks for a feeding review (feed architecture §10) — an event and a
    # task, never a silent reassignment. A group move reviewed itself.
    if animal.active:
        feeding_program_service.review_animal_if_relevant(db, animal, changed - {"group_name"}, user_id=current_user.id)
        # FEED-PERFORMANCE-INTELLIGENCE §12: a lifecycle change moves the
        # confounders, so the reading is taken again.
        if {"life_stage", "management_profile", "status"} & changed:
            feed_performance_service.on_context_changed(db, "animal", animal, trigger="lifecycle_changed", user_id=current_user.id)
        if {"sex", "life_stage"} & changed:
            # A heifer that became an adult now belongs in "Open cows".
            group_service.sync_rule_groups(db, animal, user_id=current_user.id)
    if new_tag is not None and new_tag.strip() and new_tag.strip() != (animal.tag or ""):
        identifier_service.replace_primary_value(
            db, animal, new_tag.strip(), cap_set or capability_service.resolve_for_animal(db, animal)
        )

    write_event(
        db, farm_id=current_user.farm_id, entity_type="animal", entity_id=animal.id,
        event_type="animal_updated", payload={"fields": sorted(changed | ({"tag"} if new_tag else set()))}, created_by=current_user.id,
    )
    write_audit_log(
        db, farm_id=current_user.farm_id, user_id=current_user.id, action="animal_updated",
        entity_type="animal", entity_id=animal.id, module_code=perms.ANIMALS,
        summary=f"{current_user.name} updated {animal.name} #{animal.tag}",
        changes=diff_changes(before, animal, _AUDITED_ANIMAL_FIELDS),
    )
    db.commit()
    db.refresh(animal)
    return animal


@router.patch("/{animal_id}", response_model=AnimalOut)
def move_animal(
    animal_id: str,
    payload: AnimalMove,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(require_permission(perms.ANIMALS, perms.EDIT)),
) -> models.Animal:
    """Moves the animal to another place — written to its location history
    (LIVESTOCK-SCHEMA §5 LOCATION) before the current value changes."""
    animal = owned_or_404(db, models.Animal, animal_id, current_user, "Animal")
    livestock_state_service.ensure_on_farm(animal, "a move")
    previous = animal.location_label
    livestock_state_service.record(db, animal, livestock_state_service.LOCATION, payload.location_label, reason="moved",
                                   source_type="animal_move", user_id=current_user.id)
    write_audit_log(
        db, farm_id=animal.farm_id, user_id=current_user.id, action="animal_moved",
        entity_type="animal", entity_id=animal.id, module_code=perms.ANIMALS,
        summary=f"{current_user.name} moved {animal.name} to {payload.location_label}",
        changes={"location_label": {"from": previous, "to": payload.location_label}},
    )
    write_event(
        db,
        farm_id=animal.farm_id,
        entity_type="animal",
        entity_id=animal.id,
        event_type="animal_moved",
        payload={"location_label": payload.location_label},
        created_by=current_user.id,
    )
    db.commit()
    db.refresh(animal)
    return animal


@router.get("/{animal_id}", response_model=AnimalDigitalTwinOut)
def get_animal(animal_id: str, db: Session = Depends(get_db), user: models.User = Depends(_ANIMAL_RECORD_VIEW)):
    animal = owned_or_404(db, models.Animal, animal_id, user, "Animal")

    observations = db.scalars(
        select(models.Observation)
        .where(models.Observation.entity_type == "animal", models.Observation.entity_id == animal_id)
        .order_by(models.Observation.observed_at.desc())
        .limit(20)
    ).all()
    events = db.scalars(
        select(models.Event)
        .where(models.Event.entity_type == "animal", models.Event.entity_id == animal_id)
        .order_by(models.Event.created_at.desc())
        .limit(20)
    ).all()
    recs = db.scalars(
        select(models.Recommendation)
        .where(
            models.Recommendation.entity_type == "animal",
            models.Recommendation.entity_id == animal_id,
            models.Recommendation.status == "generated",
        )
        .order_by(models.Recommendation.generated_at.desc())
    ).all()

    # The care record: doses with their lots, the withdrawal windows they
    # imply, standing conditions, the latest dated weight, the open case and
    # the live emergency.
    from app.services import pharmacy_service as ph  # local: the pharmacy module is optional reading for this router

    administrations = db.scalars(
        select(pm.MedicationAdministration)
        .where(pm.MedicationAdministration.subject_type == "animal", pm.MedicationAdministration.subject_id == animal_id)
        .order_by(pm.MedicationAdministration.administered_at.desc())
        .limit(10)
    ).all()
    at = now()
    milk_until = [ensure_utc(a.withdrawal_milk_until) for a in administrations if a.status == "recorded" and a.withdrawal_milk_until and ensure_utc(a.withdrawal_milk_until) > at]
    meat_until = [ensure_utc(a.withdrawal_meat_until) for a in administrations if a.status == "recorded" and a.withdrawal_meat_until and ensure_utc(a.withdrawal_meat_until) > at]
    record_until = ensure_utc(animal.withdrawal_until) if animal.withdrawal_until and ensure_utc(animal.withdrawal_until) > at else None
    withdrawals = {
        "active": bool(milk_until or meat_until or record_until),
        "milk_until": max(milk_until).isoformat() if milk_until else None,
        "meat_until": max(meat_until).isoformat() if meat_until else None,
        "record_until": record_until.isoformat() if record_until else None,
        "reason": animal.withdrawal_reason,
    }
    conditions = health_case_service.active_conditions(db, animal_id)
    weight = health_case_service.latest_weight(db, animal_id)
    case = health_case_service.current_case(db, "animal", animal_id)
    live = db.scalar(
        select(em.EmergencyAssessment)
        .where(em.EmergencyAssessment.animal_id == animal_id, em.EmergencyAssessment.status.in_(("open", "protocol_started", "escalated")))
        .order_by(em.EmergencyAssessment.started_at.desc())
    )
    live_run = db.scalar(select(em.EmergencyProtocolRun).where(em.EmergencyProtocolRun.emergency_assessment_id == live.id).order_by(em.EmergencyProtocolRun.started_at.desc())) if live else None

    return AnimalDigitalTwinOut(
        **AnimalOut.model_validate(animal).model_dump(),
        capabilities=capability_service.resolve_for_animal(db, animal).to_dict(),
        recent_administrations=[ph.administration_dict(db, a) for a in administrations],
        withdrawals=withdrawals,
        active_conditions=[health_case_service.condition_dict(db, c) for c in conditions],
        latest_weight=health_case_service.weight_dict(db, weight) if weight else None,
        open_health_case=health_case_service.case_dict(db, case, with_details=False) if case else None,
        emergency=(
            {"id": live.id, "status": live.status, "triage_level": live.triage_level, "started_at": live.started_at.isoformat(), "explanation": live.explanation,
             "escalation_reasons": live.escalation_reasons or [], "run_id": live_run.id if live_run else None, "run_status": live_run.status if live_run else None}
            if live else None
        ),
        recent_observations=[
            {
                "id": o.id,
                "observation_type": o.observation_type,
                "value_numeric": o.value_numeric,
                "value_text": o.value_text,
                "severity": o.severity,
                "observed_at": o.observed_at.isoformat(),
            }
            for o in observations
        ],
        recent_events=[
            {"id": e.id, "event_type": e.event_type, "created_at": e.created_at.isoformat(), "payload": e.payload_json}
            for e in events
        ],
        open_recommendations=[{"id": r.id, "title": r.title, "priority": r.priority, "confidence": r.confidence} for r in recs],
        reproduction=reproduction_service.summary(db, animal),
        groups=[group_service.membership_dict(db, m, animal=animal) for m in group_service.memberships_of_animal(db, animal.id, current_only=True)],
        relationships=reproduction_service.relationships(db, animal),
        recent_history=[livestock_state_service.history_dict(h) for h in livestock_state_service.history(db, animal.id)[:20]],
    )
