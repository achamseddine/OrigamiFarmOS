"""The capability resolver (docs/GENERIC-ANIMAL-CAPABILITY-MODEL.md §10).

    resolve(species, sex, life_stage, management_profile) -> CapabilitySet

Called by the API before it will accept a milk record, a pregnancy flag or
an identifier, and by the tablet to decide which fields and tabs to draw.
One function, two callers, so the form can never offer something the
server will refuse — "the same capability rules must govern API
validation and UI visibility" (§8).

Resolution is configuration first, biology last:

1. Every rule for the species whose sex / stage / profile either match or
   are unset is a candidate. For each capability the most *specific*
   granting candidate wins (most dimensions set); `priority` breaks
   ties. Any matching rule that *disables* the capability is a veto and
   wins outright.
2. Then the invariants. A male is never pregnant; a hen is never in calf;
   a ewe never lays. These are not configurable, because a rule that got
   them wrong would corrupt a herd's records, and no farm needs the
   option.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.domain import livestock_models as lm
from app.livestock import catalog


@dataclass(frozen=True)
class ResolvedCapability:
    code: str
    category: str
    label_en: str
    label_ar: str
    required: bool
    configuration: dict | None


@dataclass
class CapabilitySet:
    species: str
    sex: str | None
    life_stage: str | None
    management_profile: str | None
    reproduction_mode: str
    capabilities: list[ResolvedCapability] = field(default_factory=list)
    terminology: dict = field(default_factory=dict)
    # What the invariants removed, so a caller can explain *why* a tab is
    # missing ("hens do not have a pregnancy record").
    suppressed: list[str] = field(default_factory=list)

    @property
    def codes(self) -> frozenset[str]:
        return frozenset(c.code for c in self.capabilities)

    def has(self, code: str) -> bool:
        return code in self.codes

    def required_codes(self) -> frozenset[str]:
        return frozenset(c.code for c in self.capabilities if c.required)

    @property
    def subject_kind(self) -> str:
        """individual | group | either — from the tracking capabilities."""
        individual = self.has(catalog.Cap.INDIVIDUAL_TRACKING)
        group = self.has(catalog.Cap.GROUP_TRACKING)
        if individual and group:
            return "either"
        if group:
            return "group"
        return "individual"

    def allowed_identifier_types(self) -> frozenset[str]:
        allowed = set(catalog.IDENTIFIER_TYPES_ALWAYS_ALLOWED)
        for cap_code, id_type in catalog.IDENTIFIER_TYPE_FOR_CAPABILITY.items():
            if self.has(cap_code):
                allowed.add(id_type)
        return frozenset(allowed)

    def required_identifier_types(self) -> frozenset[str]:
        required = self.required_codes()
        return frozenset(
            id_type for cap_code, id_type in catalog.IDENTIFIER_TYPE_FOR_CAPABILITY.items() if cap_code in required
        )

    def to_dict(self) -> dict:
        return {
            "species": self.species,
            "sex": self.sex,
            "life_stage": self.life_stage,
            "management_profile": self.management_profile,
            "reproduction_mode": self.reproduction_mode,
            "subject_kind": self.subject_kind,
            "capabilities": [
                {
                    "code": c.code,
                    "category": c.category,
                    "label_en": c.label_en,
                    "label_ar": c.label_ar,
                    "required": c.required,
                    "configuration": c.configuration,
                }
                for c in self.capabilities
            ],
            "allowed_identifier_types": sorted(self.allowed_identifier_types()),
            "required_identifier_types": sorted(self.required_identifier_types()),
            "terminology": self.terminology,
            "suppressed": self.suppressed,
        }


# The biological invariants. Keyed by what triggers them; the value is
# the set of capabilities that can never apply.
_NEVER_FOR_MALES = frozenset({
    catalog.Cap.PREGNANCY, catalog.Cap.LIVE_BIRTH, catalog.Cap.LACTATION,
    catalog.Cap.MILK_PRODUCTION, catalog.Cap.EGG_PRODUCTION,
})
_NEVER_FOR_OVIPAROUS = frozenset({
    catalog.Cap.PREGNANCY, catalog.Cap.LIVE_BIRTH, catalog.Cap.LACTATION, catalog.Cap.MILK_PRODUCTION,
})
_NEVER_FOR_VIVIPAROUS = frozenset({
    catalog.Cap.EGG_PRODUCTION, catalog.Cap.INCUBATION, catalog.Cap.HATCHING,
})


class UnknownSpecies(ValueError):
    pass


def get_species(db: Session, code: str) -> lm.Species:
    species = db.get(lm.Species, code)
    if species is None or not species.active:
        raise UnknownSpecies(code)
    return species


def resolve(
    db: Session,
    species_code: str,
    sex: str | None,
    life_stage: str | None = None,
    management_profile: str | None = None,
) -> CapabilitySet:
    species = get_species(db, species_code)
    stage = life_stage or catalog.DEFAULT_LIFE_STAGE
    sex_code = (sex or catalog.UNKNOWN).upper()

    rules = db.scalars(
        select(lm.SpeciesCapabilityRule).where(lm.SpeciesCapabilityRule.species_code == species_code)
    ).all()
    labels = {c.code: c for c in db.scalars(select(lm.Capability).where(lm.Capability.active.is_(True)))}

    # Per capability: the most specific matching *grant* wins (priority
    # breaks ties) — unless any matching rule disables it. A disable is a
    # veto. "Broiler flocks do not lay" must hold even though "adult
    # females lay" is the more specific-looking rule; a farm that writes
    # a rule saying no means no.
    grants: dict[str, tuple[int, int, lm.SpeciesCapabilityRule]] = {}
    vetoed: set[str] = set()
    for rule in rules:
        if rule.sex is not None and rule.sex.upper() != sex_code:
            continue
        if rule.life_stage is not None and rule.life_stage != stage:
            continue
        if rule.management_profile is not None and rule.management_profile != management_profile:
            continue
        if not rule.enabled:
            vetoed.add(rule.capability_code)
            continue
        specificity = sum(x is not None for x in (rule.sex, rule.life_stage, rule.management_profile))
        key = (specificity, rule.priority)
        current = grants.get(rule.capability_code)
        if current is None or key > current[:2]:
            grants[rule.capability_code] = (specificity, rule.priority, rule)

    enabled = {code: rule for code, (_, _, rule) in grants.items() if code in labels and code not in vetoed}

    # Invariants — applied after configuration so a misconfigured rule
    # can never override biology. `suppressed` lists everything biology
    # rules out for this animal, granted or not, so a screen can say
    # "hens do not have a pregnancy record" rather than just omit the tab.
    forbidden: set[str] = set()
    if sex_code == catalog.MALE:
        forbidden |= _NEVER_FOR_MALES
    if species.reproduction_mode == catalog.OVIPAROUS:
        forbidden |= _NEVER_FOR_OVIPAROUS
    elif species.reproduction_mode == catalog.VIVIPAROUS:
        forbidden |= _NEVER_FOR_VIVIPAROUS
    suppressed = sorted(code for code in forbidden if code in labels)
    for code in suppressed:
        enabled.pop(code, None)

    order = {code: i for i, (code, *_rest) in enumerate(catalog.CAPABILITIES)}
    resolved = [
        ResolvedCapability(
            code=code,
            category=labels[code].category,
            label_en=labels[code].label_en,
            label_ar=labels[code].label_ar,
            required=bool(rule.required),
            configuration=rule.configuration_json,
        )
        for code, rule in sorted(enabled.items(), key=lambda kv: order.get(kv[0], 999))
    ]

    return CapabilitySet(
        species=species_code,
        sex=sex_code,
        life_stage=stage,
        management_profile=management_profile,
        reproduction_mode=species.reproduction_mode,
        capabilities=resolved,
        terminology=dict(species.terminology_json or {}),
        suppressed=suppressed,
    )


def resolve_for_animal(db: Session, animal) -> CapabilitySet:
    """The resolver as the animal itself is configured."""
    return resolve(db, animal.species, animal.sex, animal.life_stage, animal.management_profile)


def resolve_for_group(db: Session, group) -> CapabilitySet:
    """A group resolves by its stated sex composition. An unstated one is
    treated as female, because a group a farm bothers to keep records on
    is nearly always a laying or breeding flock; a `mixed` composition
    resolves as unknown, so the resolver will not claim every bird lays.
    """
    composition = (group.sex_composition or "").lower()
    sex = catalog.FEMALE if composition in ("", "female", "f", "hens", "all_female") else (
        catalog.MALE if composition in ("male", "m", "all_male") else catalog.UNKNOWN
    )
    return resolve(db, group.species, sex, group.life_stage, group.management_profile)


def describe_missing(cap_set: CapabilitySet, code: str, subject_name: str) -> str:
    """A refusal a farmer can read: says what the animal is and what was
    asked, not which rule fired."""
    label = next((c[2] for c in catalog.CAPABILITIES if c[0] == code), code.replace("_", " ").title())
    term = cap_set.terminology
    what = term.get("female_en") if cap_set.sex == catalog.FEMALE else term.get("male_en") if cap_set.sex == catalog.MALE else None
    kind = f"a {what.lower()}" if what else f"a {cap_set.species.replace('_', ' ')}"
    reason = ""
    if code in cap_set.suppressed:
        reason = " — that does not apply to this kind of animal"
    elif cap_set.management_profile:
        reason = f" for the {cap_set.management_profile.replace('_', ' ')} profile"
    return f"{subject_name} is {kind}; {label.lower()} is not available{reason}."
