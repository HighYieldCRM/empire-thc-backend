# Empire THC Operations Backend

This repository provides the backend infrastructure for the **Empire NY Cannabis** THC‑only operations dashboard.  It implements a BigQuery‑centric ELT pipeline on Google Cloud and powers Grafana dashboards through a set of materialized reporting tables (marts).  The design strictly excludes all CBD data and treats Shopify/Google Analytics as demand signals (not sales).

The code here is intended to be deployed to Google Cloud using **Cloud Run jobs** for ingestion and transformation tasks, **BigQuery** for storage and analytics, **Secret Manager** for API credentials and other secrets, and **Cloud Scheduler** for scheduling periodic runs.  Grafana Cloud connects directly to the BigQuery marts to render dashboards.

## Directory Structure

```
empire-thc-backend/
├── src/                  # Python ingestion and orchestration code
│   ├── common/           # Shared utilities
│   │   ├── bq_client.py  # Thin wrapper around the BigQuery client
│   │   └── secrets.py    # Helper for accessing secrets (env vars or Secret Manager)
│   ├── jobs/
│   │   ├── ingest_qbo.py     # Ingest invoices and customers from QuickBooks Online
│   │   └── __init__.py
│   ├── main.py           # Cloud Run job entrypoint dispatching by JOB_NAME
│   └── __init__.py
├── sql/
│   ├── ddl/              # One‑time DDL scripts to create tables
│   │   ├── 01_raw.sql
│   │   ├── 02_stg.sql
│   │   └── 03_mart.sql
│   └── procedures/
│       └── transform_marts.sql
├── requirements.txt      # Python dependencies
└── backend_README.md     # Detailed guide for deployment and operations
```

## High‑Level Workflow

1. **Ingestion (Raw)**  – Each source (QuickBooks, LeafLink, Metrc, Flourish, Demand signals) has a dedicated Cloud Run job that fetches new or updated records, wraps them in a JSON payload, and appends them to a partitioned table in `thc_raw` with metadata such as `ingestion_time`, `source_primary_key` and `payload_hash`.
2. **Staging (Stg)**    – Views in `thc_stg` parse the JSON into typed columns and join related fields.  These views apply any basic transformations but remain one‑to‑one with the raw data.
3. **Mart (Presentation)** – Scheduled SQL populates the `thc_mart` tables.  These tables are wide, flattened schemas designed for Grafana dashboards.  They compute aggregations such as AR summaries, top debtors, stock‑out risk, compliance exceptions, and more.
4. **Grafana** – Panels connect directly to the `thc_mart` tables via the BigQuery datasource and apply only minimal formatting (e.g., value thresholds).

## Getting Started

1. **Create a GCP project and enable services:** BigQuery, Cloud Run, Cloud Scheduler, Secret Manager, and any other services required.
2. **Create the BigQuery datasets** listed in the DDL scripts: `thc_raw`, `thc_stg`, `thc_mart`.
3. **Create a service account** (e.g., `thc-backend-sa@PROJECT_ID.iam.gserviceaccount.com`) with roles `BigQuery Data Editor`, `Secret Manager Secret Accessor`, and `Cloud Run Invoker`.
4. **Store API credentials** (QuickBooks client ID, client secret, refresh token, company ID, etc.) in Secret Manager and grant the service account access.
5. **Deploy the Cloud Run job** by building the container and creating a job for each source.  The `JOB_NAME` environment variable determines which ingestion script runs.
6. **Schedule the jobs** via Cloud Scheduler.  For example, ingest QuickBooks invoices hourly, LeafLink orders every 15 minutes, etc.
7. **Run the transformation queries** on a schedule.  This can be achieved via scheduled queries or a Cloud Run job that executes the SQL in `transform_marts.sql`.
8. **Connect Grafana** to BigQuery using the `thc_mart` dataset as the primary datasource and build dashboards based on the panel queries outlined in `backend_README.md`.

See `backend_README.md` for detailed instructions and the full deployment procedure.