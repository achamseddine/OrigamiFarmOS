"""The module catalog and permission vocabulary (tech spec §10/§11).

Two deliberate choices here:

* **Modules are a fixed catalog, responsibilities are not.** The list of
  things a farm *can* do is part of the product; who is responsible for
  each of them is farm data (`user_module_permissions`). So this file
  names the modules but never says who holds them.

* **Permissions are per (user, module, action)**, not a single
  "admin/user" flag — an employee can hold Animals with create+edit but
  no delete, and Mouneh with view only, at the same time.
"""
from __future__ import annotations

# --------------------------------------------------------------- Actions
VIEW = "view"
CREATE = "create"
EDIT = "edit"
DELETE = "delete"
APPROVE = "approve"
EXPORT = "export"
ASSIGN = "assign"
CONFIGURE = "configure"

ACTIONS = (VIEW, CREATE, EDIT, DELETE, APPROVE, EXPORT, ASSIGN, CONFIGURE)

# The `user_module_permissions` column backing each action.
ACTION_COLUMNS = {action: f"can_{action}" for action in ACTIONS}

# --------------------------------------------------------------- Modules
MORNING_OPERATIONS = "morning_operations"
ANIMALS = "animals"
ANIMAL_HEALTH = "animal_health"
FEED_NUTRITION = "feed_nutrition"
INVENTORY = "inventory"
MILK_PRODUCTION = "milk_production"
EGG_PRODUCTION = "egg_production"
AGRICULTURE = "agriculture"
PRODUCE_HARVEST = "produce_harvest"
MOUNEH_PRODUCTION = "mouneh_production"
MOUNEH_INVENTORY = "mouneh_inventory"
SALES = "sales"
EXPENSES = "expenses"
FINANCE = "finance"
FARM_VISITS = "farm_visits"
EMPLOYEES = "employees"
TASKS = "tasks"
REPORTS = "reports"
AI_INTELLIGENCE = "ai_intelligence"
SETTINGS = "settings"


class ModuleDef:
    __slots__ = ("code", "label_en", "label_ar", "group", "licensed")

    def __init__(self, code: str, label_en: str, label_ar: str, group: str, licensed: str | None = None):
        self.code = code
        self.label_en = label_en
        self.label_ar = label_ar
        self.group = group
        # Set when the module is additionally gated by a `module_licenses`
        # row (the Mouneh and Visits add-ons) — holding the permission is
        # not enough if the farm has not licensed the module.
        self.licensed = licensed

    def as_dict(self) -> dict:
        return {
            "code": self.code,
            "label_en": self.label_en,
            "label_ar": self.label_ar,
            "group": self.group,
            "license_code": self.licensed,
        }


MODULE_CATALOG: tuple[ModuleDef, ...] = (
    ModuleDef(MORNING_OPERATIONS, "Morning Operations", "عمليات الصباح", "operations"),
    ModuleDef(ANIMALS, "Animals", "الحيوانات", "livestock"),
    ModuleDef(ANIMAL_HEALTH, "Animal Health", "صحة الحيوانات", "livestock"),
    ModuleDef(FEED_NUTRITION, "Feed & Nutrition", "الأعلاف والتغذية", "livestock"),
    ModuleDef(INVENTORY, "Inventory", "المخزون", "operations"),
    ModuleDef(MILK_PRODUCTION, "Milk Production", "إنتاج الحليب", "livestock"),
    ModuleDef(EGG_PRODUCTION, "Egg Production", "إنتاج البيض", "livestock"),
    ModuleDef(AGRICULTURE, "Agriculture & Fields", "الزراعة والحقول", "agriculture"),
    ModuleDef(PRODUCE_HARVEST, "Produce & Harvest", "المحاصيل والحصاد", "agriculture"),
    ModuleDef(MOUNEH_PRODUCTION, "Mouneh Production", "إنتاج المونة", "mouneh", licensed="mouneh"),
    ModuleDef(MOUNEH_INVENTORY, "Mouneh Inventory", "مخزون المونة", "mouneh", licensed="mouneh"),
    ModuleDef(SALES, "Sales", "المبيعات", "commercial"),
    ModuleDef(EXPENSES, "Expenses", "المصاريف", "commercial"),
    ModuleDef(FINANCE, "Finance", "المالية", "commercial"),
    ModuleDef(FARM_VISITS, "Farm Visits & Agri-Tourism", "الزيارات والسياحة الزراعية", "visits", licensed="visits_agritourism"),
    ModuleDef(EMPLOYEES, "Employees", "الموظفون", "administration"),
    ModuleDef(TASKS, "Tasks", "المهام", "operations"),
    ModuleDef(REPORTS, "Reports", "التقارير", "administration"),
    ModuleDef(AI_INTELLIGENCE, "AI / Health Intelligence", "الذكاء الاصطناعي", "operations"),
    ModuleDef(SETTINGS, "Settings", "الإعدادات", "administration"),
)

MODULE_CODES = tuple(m.code for m in MODULE_CATALOG)
MODULES_BY_CODE = {m.code: m for m in MODULE_CATALOG}

# Roles that implicitly hold every permission on every module. Tech spec
# §7: "The Farm Manager must be able to perform any operational function
# personally if no employee is assigned" — so a farm is never locked out
# of its own data, and no permission row is needed to bootstrap one.
FULL_ACCESS_ROLES = frozenset({"owner", "manager"})


def is_full_access(role: str) -> bool:
    return role in FULL_ACCESS_ROLES


# Sensible starting grants when a manager first assigns a module to an
# employee, and what `app/seed_production.py` gives the seeded staff
# accounts. An employee responsible for an area can do the day-to-day work
# in it (record, correct a mistake) but not delete history, approve, or
# reconfigure the module — those stay with the manager until granted.
DEFAULT_RESPONSIBILITY_GRANT = {
    VIEW: True,
    CREATE: True,
    EDIT: True,
    DELETE: False,
    APPROVE: False,
    EXPORT: False,
    ASSIGN: False,
    CONFIGURE: False,
}

READ_ONLY_GRANT = {action: (action == VIEW) for action in ACTIONS}

# The module sets behind the seeded staff accounts' departments. A
# department is only a starting point — a manager can add or remove any
# module for any employee afterwards, including combinations no department
# describes (tech spec §9 "Example C/D/E/F").
DEPARTMENT_MODULE_PRESETS: dict[str, tuple[str, ...]] = {
    "animals": (ANIMALS, ANIMAL_HEALTH, FEED_NUTRITION, MILK_PRODUCTION, EGG_PRODUCTION, INVENTORY, AI_INTELLIGENCE),
    "produce": (AGRICULTURE, PRODUCE_HARVEST, INVENTORY),
    "mouneh": (MOUNEH_PRODUCTION, MOUNEH_INVENTORY, INVENTORY),
    "visits": (FARM_VISITS, SALES),
}

# Every employee gets these regardless of department: their own day, their
# own tasks. Without them an employee would log in to an empty app.
BASELINE_EMPLOYEE_MODULES: tuple[str, ...] = (MORNING_OPERATIONS, TASKS)
