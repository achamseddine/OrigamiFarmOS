# Database Pass 7C — Revenue, Margin & Commercial Analytics

## 1. Principle
Revenue, cash and margin are different:
- Revenue/Invoice: commercial amount earned/billed under chosen accounting integration rules.
- Cash: money actually received.
- Margin: analytical revenue minus attributed operational cost.

## 2. sale_cost_snapshot
```sql
sale_cost_snapshot (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 delivery_line_id uuid not null references delivery_line(id),
 methodology_code varchar(60) not null,
 methodology_version varchar(30) not null,
 calculated_at timestamptz not null,
 delivered_quantity numeric(20,6) not null,
 revenue_amount numeric(20,4),
 inventory_cost_amount numeric(20,4),
 allocated_production_cost numeric(20,4),
 allocated_other_cost numeric(20,4),
 total_cost_amount numeric(20,4) not null,
 margin_amount numeric(20,4),
 currency char(3) not null,
 unique (delivery_line_id,methodology_code,methodology_version)
)
```
Snapshot is reproducible analytics, not statutory profit.

## 3. Example dairy chain
```text
Feed/Health/Labor/Asset Costs
 → Cow/Group
 → Milk Production
 → Milk Inventory/Lot
 → Delivery
 → Invoice
 → Customer Payment

Operational margin = attributable sales revenue - documented operational cost
Cash result = actual receipts/payments
```

## 4. Animal sale
Animal acquisition/rearing costs may be allocated analytically to animal sale. The sale closes/changes livestock status/ownership through livestock workflow; it does not create a fake inventory consumption.

## 5. Farm-produced crop/feed sale
A silage/crop lot sold externally retains its field → crop cycle → harvest/transformation → lot genealogy. Margin can therefore compare actual farm-production cost against sale value.

## 6. KPIs
Certified analytics can later expose:
- milk revenue/day;
- milk revenue/cow;
- average selling price/L;
- feed cost/L;
- operational margin/L;
- egg revenue/dozen;
- crop revenue/field/cycle;
- animal sale margin;
- customer receivables;
- days sales outstanding;
- cash collected vs invoiced;
- customer/product profitability.

Every derived KPI must identify period, currency and methodology.

## 7. Acceptance
Changing current feed price does not rewrite historic milk margin; cash receipt does not duplicate revenue; lot/animal genealogy supports cost attribution; profitability metrics disclose methodology and are rebuildable.
