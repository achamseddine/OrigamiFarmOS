# Database Pass 3C — Feed Replenishment, Forecasting & Stockout Control

## 1. Goal
Origami must answer not only **what is in stock**, but **whether permitted stock will cover upcoming feeding demand**.

```text
Eligible Available Stock
+ Confirmed Incoming Supply
- Forecast Feeding/Mixing Demand
- Safety Stock
= Projected Surplus / Shortfall
```

## 2. feed_reorder_policy
```sql
feed_reorder_policy (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 location_id uuid references location(id),
 policy_type varchar(30) not null,
 reorder_point_base numeric(20,6),
 safety_stock_base numeric(20,6),
 target_stock_base numeric(20,6),
 lead_time_days numeric(10,2),
 minimum_order_quantity_base numeric(20,6),
 review_horizon_days integer not null default 30,
 active boolean not null default true,
 updated_at timestamptz not null
)
```
Policies may use STATIC_POINT, DAYS_COVER or FORECAST.

## 3. feed_demand_forecast
Forecast is a versioned/reproducible planning output, not inventory truth.
```sql
feed_demand_forecast (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 generated_at timestamptz not null,
 horizon_start date not null,
 horizon_end date not null,
 methodology_version varchar(50) not null,
 status varchar(30) not null,
 created_by uuid references user_account(id)
)

feed_demand_forecast_line (
 id uuid primary key,
 forecast_id uuid not null references feed_demand_forecast(id),
 inventory_item_id uuid not null references inventory_item(id),
 feed_product_id uuid references feed_product(id),
 date_bucket date not null,
 demand_quantity_base numeric(20,6) not null,
 available_quantity_base numeric(20,6),
 incoming_quantity_base numeric(20,6),
 projected_closing_base numeric(20,6),
 source_summary jsonb
)
```

Demand can derive from active feeding programs × subject/head counts × formula ingredient requirements. Confirmed incoming procurement is integrated when Procurement exists.

## 4. days of cover
```text
days_cover = eligible_available_quantity / expected_daily_demand
```
If demand is zero, do not return infinity as a business value; return NOT_APPLICABLE/no-demand state.

Eligible availability excludes expired, blocked, recalled, quarantined, incompatible and purpose-reserved stock.

## 5. feed_replenishment_alert
```sql
feed_replenishment_alert (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 inventory_item_id uuid not null references inventory_item(id),
 location_id uuid references location(id),
 alert_type varchar(40) not null,
 severity varchar(20) not null,
 detected_at timestamptz not null,
 projected_stockout_at timestamptz,
 days_cover numeric(12,4),
 recommended_order_quantity_base numeric(20,6),
 status varchar(30) not null,
 acknowledged_by uuid references user_account(id),
 acknowledged_at timestamptz,
 source_forecast_id uuid references feed_demand_forecast(id),
 deduplication_key varchar(255) not null
)
```
Types: BELOW_REORDER_POINT, LOW_DAYS_COVER, PROJECTED_STOCKOUT, ALLOCATION_SHORTFALL.

Alert deduplication prevents repeated identical notifications every forecast run.

## 6. Reorder recommendation
```text
Required through horizon
+ Safety stock
- Eligible available
- Confirmed incoming
= Suggested replenishment
```
Round to configured minimum/order pack rules when available.

A recommendation may create a draft purchase requisition later, but never bypasses procurement approval.

## 7. Example
500 kg cattle premix received.
- 400 kg reserved for lactating cattle.
- 100 kg general cattle stock.
- Horse/sheep eligibility = 0 kg because usage policy blocks it.
- Current eligible cattle stock after consumption = 50 kg.
- Forecast cattle demand = 12 kg/day.
- Days cover = 4.17.
- Supplier lead time = 7 days.
Result: PROJECTED_STOCKOUT alert and replenishment recommendation before stock reaches zero.

## 8. Events
FeedStockBelowReorderPoint, FeedStockoutRiskDetected, FeedReorderRequired, FeedReorderAcknowledged.

## 9. Acceptance
Farm manager can see on-hand, reserved, eligible available, daily demand, days cover, projected stockout and suggested reorder quantity; alerts are generated before projected shortage; cross-species blocked stock never inflates availability; forecast/recommendation does not alter inventory or procurement truth.
