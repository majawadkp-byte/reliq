# RELIQ Solutions V2.1.0 — Intelligence → Action

Build 210 · Database schema 27

## Inventory Intelligence / Smart Buying
- Keeps active out-of-stock products in forecasting and replenishment analysis.
- Uses true all-history last-sale date for demand recency instead of only the selected lookback window.
- Adds demand states: Active demand, Intermittent, Declining, Declining / review, Seasonal review, Dormant, and New / insufficient history.
- Disabled products remain excluded from operational inventory intelligence.
- Non-purchasable and non-active lifecycle products keep history/forecast context but cannot create purchase recommendations.
- Negative recorded stock is treated as a Stock Discrepancy. It is not added to purchase demand; RELIQ directs the user to count/correct stock.
- Automatic purchasing is limited to current demand (<=90 days since last sale) or strong seasonal evidence within the review window. Dormant demand is blocked from automatic purchasing.
- MOQ/order-multiple rounding is applied only after a positive, eligible purchase need exists; MOQ never creates demand.
- Smart Buying and Inventory Intelligence now show demand state and purchase-block reason.

## Business Action Center
- Adds Stock Discrepancy and Dormant Product actions.
- Adds action state: Snooze, Resolve, and Dismiss-until-condition-changes.
- Resolved/dismissed actions reappear when their condition fingerprint materially changes.
- Fixes navigation targets after the Quotations module was inserted.

## Morning Brief
- Adds stock discrepancy, dormant-product and quotation-follow-up signals.
- Corrects navigation to Payments, Reports and Business Action Center.

## Database reliability
- Repairs the V2.0.5 schema-26 upgrade path for quotations/communication history.
- Adds business_action_state in schema 27.

## Important
Back up the business database before first launch. The database upgrades automatically from schema 26 to 27.
