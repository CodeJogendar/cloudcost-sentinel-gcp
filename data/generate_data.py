"""CloudCost Sentinel dataset: 90 days x 6 GCP services of daily billing (540 clean rows)
+ 12 deliberately bad rows = 552 rows. Four cost incidents are seeded. Expected results are
computed with the same rules as the BigQuery view v_cost_anomalies."""
import csv, random, statistics
from datetime import date, timedelta

random.seed(21)
START, DAYS = date(2026, 8, 25), 90          # 2026-08-25 .. 2026-11-22
SERVICES = {   # service: (project_id, region, base daily cost USD, unit, USD per unit)
    "Compute Engine": ("prod-app", "asia-south1", 42.0, "vCPU-hours", 0.034),
    "BigQuery": ("analytics-prod", "asia-south1", 18.0, "TiB-scanned", 6.25),
    "Cloud Storage": ("data-lake", "asia-south1", 11.0, "GiB-months", 0.02),
    "Cloud SQL": ("prod-app", "asia-south1", 26.0, "vCPU-hours", 0.0413),
    "Dataflow": ("streaming-prod", "asia-south1", 15.0, "vCPU-hours", 0.056),
    "Networking": ("prod-app", "global", 9.0, "GiB-egress", 0.12),
}
INCIDENTS = {   # (service, date): multiplier
    ("Compute Engine", date(2026, 10, 5)): 5.0,     # runaway VM / autoscaler loop
    ("Dataflow", date(2026, 10, 18)): 6.0,          # forgotten streaming job (day 1)
    ("Dataflow", date(2026, 10, 19)): 5.0,          # ... still running (day 2)
    ("Networking", date(2026, 11, 2)): 4.5,         # cross-region egress spike
    ("BigQuery", date(2026, 11, 12)): 7.0,          # full table scan, no partition filter
}
HEADER = ["usage_date", "service", "project_id", "region", "usage_amount", "usage_unit", "cost_usd"]

rows = []
for i in range(DAYS):
    d = START + timedelta(days=i)
    weekday = d.weekday() < 5
    for svc, (proj, region, base, unit, price) in SERVICES.items():
        cost = base * (1 + 0.001 * i) * (1.05 if weekday else 0.90) * random.uniform(0.94, 1.06)
        cost *= INCIDENTS.get((svc, d), 1.0)
        cost = round(cost, 2)
        rows.append([d.isoformat(), svc, proj, region, round(cost / price, 2), unit, cost])
clean = [list(r) for r in rows]
assert len(clean) == 540

bad = []
for idx in (10, 150, 300, 420, 500):                     # 5 exact duplicates
    bad.append(list(rows[idx]))
for idx in (20, 200, 350, 480):                          # 4 rows with an invalid cost
    r = list(rows[idx]); r[6] = "N/A"; bad.append(r)
for idx in (30, 250, 400):                               # 3 rows with a missing service
    r = list(rows[idx]); r[1] = ""; bad.append(r)
file_rows = rows + bad

with open("data/billing_2026_q3q4.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(HEADER); w.writerows(file_rows)

# ---- mirror of v_cost_anomalies: 14-day trailing baseline, >=7 days, z>=3 and cost>=1.5x ----
by_svc = {}
for r in clean:
    by_svc.setdefault(r[1], []).append((r[0], r[6]))
flagged = []
for svc, series in by_svc.items():
    for i, (d, c) in enumerate(series):
        win = [x[1] for x in series[max(0, i - 14):i]]
        if len(win) >= 7:
            avg, sd = statistics.mean(win), statistics.stdev(win)
            if sd > 0 and (c - avg) / sd >= 3 and c >= 1.5 * avg:
                flagged.append((d, svc, c, round(avg, 2), round((c - avg) / sd, 1), round(c / avg, 1)))
flagged.sort()

print("file rows:", len(file_rows), "| clean rows expected in BigQuery:", len(clean),
      "| rejected expected: 12 (5 duplicate, 4 invalid cost, 3 missing service)")
print("total cost USD:", round(sum(r[6] for r in clean), 2))
print("anomalies the view should flag:", len(flagged))
for f in flagged: print("  ", f)
for svc in SERVICES:
    print(f"  {svc:15s} 90-day cost: {sum(c for _, c in by_svc[svc]):9.2f}")
