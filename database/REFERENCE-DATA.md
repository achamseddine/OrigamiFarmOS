# Foundation Reference Data

Reference data is governed and configurable. Seed values accelerate deployment but are not hard-coded business logic.

## Species starter set
- CATTLE
- SHEEP
- GOAT
- HORSE
- CHICKEN
- DUCK
- TURKEY

## Capabilities starter set
- INDIVIDUAL_TRACKING
- GROUP_TRACKING
- EAR_TAG
- RFID
- MICROCHIP
- LEG_BAND
- PASSPORT
- BREEDING
- PREGNANCY
- LIVE_BIRTH
- INCUBATION
- HATCHING
- MILK_PRODUCTION
- LACTATION
- EGG_PRODUCTION
- WOOL_PRODUCTION
- GROWTH_TRACKING
- WEIGHT_TRACKING
- BODY_CONDITION
- HOOF_CARE
- FARRIER

These values do not imply every species has every capability; `species_capability_rule` resolves applicability.

## UOM starter dimensions
- MASS: kg base; g; tonne
- VOLUME: L base; mL
- COUNT: head/unit base
- LENGTH: m base; cm; mm
- AREA: m2 base; hectare; dunum may be configured with locally agreed conversion
- TEMPERATURE: Celsius base; Fahrenheit using offset conversion
- TIME: second base; minute; hour; day
- ENERGY: governed base chosen by nutrition/engineering needs

Do not silently assume regional units without configured conversion.

## Status/reference policy
Stable technical codes are uppercase snake case where practical. Display names/localization are separate. Retiring a code prevents new use but preserves historical references.
