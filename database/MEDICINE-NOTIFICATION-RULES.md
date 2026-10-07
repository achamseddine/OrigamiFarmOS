# Medicine Stock Monitoring & Notification Rules

## Trigger model
Re-evaluate a pharmacy stock policy after:
- medicine receipt/acceptance;
- medication/vaccine administration;
- waste/adjustment/transfer/return;
- reservation/release;
- lot quarantine/release/recall;
- expiry boundary;
- stock-policy change;
- scheduled daily pharmacy scan;
- procurement incoming-supply change.

## Severity
- OUT: eligible available <= 0 for an enabled essential medicine.
- CRITICAL: eligible available <= user-set critical threshold.
- LOW: eligible available < user-set minimum threshold.
- OK: eligible available >= minimum threshold.
- EXPIRY warnings are independent and can coexist with stock status.

## Notification behavior
A domain alert is authoritative; notification delivery is a consequence. Use a stable deduplication key such as farm + item + location + alert type + policy version/condition window. Do not notify repeatedly on every scan while the same unresolved condition remains.

Escalation may notify configured roles such as FARM_MANAGER or designated pharmacy/stock responsible user. Channel delivery (in-app/push/email/SMS) belongs to the notification subsystem and user preferences.

When stock recovers above the applicable threshold, resolve the active stock alert and emit MedicineStockRecovered. Acknowledging an alert only records that it was seen.

## Scheduled expiry scan
At least daily, inspect active medicine lots:
- expiry_date < today → EXPIRED_STOCK;
- expiry_date <= today + configured expiry_warning_days → EXPIRING_SOON;
- after-opening use-by passed → EXPIRED_STOCK/blocked eligibility;
- recalled/storage-noncompliant → separate high-priority condition.

## Reorder workflow
LOW/CRITICAL/OUT may generate MedicineReorderRequired with calculated shortage. If policy permits, create one linked DRAFT purchase requisition. Never create duplicate drafts for the same unresolved shortage and never auto-approve a PO.

## Safety boundary
Stock alerts are logistics alerts, not treatment advice. “Fever support stock low” means the configured product/category is below farm policy; it does not advise administering it to an animal with fever.
