## Backend Deployment Guide

This document supplements the top‑level `README.md` with step‑by‑step instructions to deploy and operate the backend of the Empire NY Cannabis THC operations system.  The goal of this backend is to provide BigQuery tables that accurately reflect the operational state of the THC business and power Grafana dashboards without manual intervention.

### 1. Prerequisites

* **Google Cloud project** (e.g., `empire-thc-ops`).
* **Billing enabled** for your project.
* **Service account** with the following roles:
  - `roles/bigquery.dataEditor`
  - `roles/bigquery.jobUser`
  - `roles/secretmanager.secretAccessor`
  - `roles/run.invoker`
* **APIs enabled**: BigQuery, BigQuery Storage API, Cloud Run, Cloud Scheduler, Secret Manager, Artifact Registry, Cloud Build.
* **QuickBooks Developer access** with client ID, client secret, refresh token, and company ID (realm).  See Intuit's developer documentation for instructions on how to create an app and obtain credentials.

### 2. BigQuery Schema Creation

Run the DDL scripts in `sql/ddl` either in the BigQuery console or via the CLI.  Example using the CLI:

```
#!/bin/bash
# Set your project and location
PROJECT_ID="your-gcp-project-id"
BQ_LOC="US"

# Create datasets (skip if they already exist)
bq --location=$BQ_LOC mk --dataset --if_exists=skip "$PROJECT_ID:thc_raw"
bq --location=$BQ_LOC mk --dataset --if_exists=skip "$PROJECT_ID:thc_stg"
bq --location=$BQ_LOC mk --dataset --if_exists=skip "$PROJECT_ID:thc_mart"

# Create raw, staging, and mart tables
cat sql/ddl/01_raw.sql | bq query --location=$BQ_LOC --project_id=$PROJECT_ID --use_legacy_sql=false
cat sql/ddl/02_stg.sql | bq query --location=$BQ_LOC --project_id=$PROJECT_ID --use_legacy_sql=false
cat sql/ddl/03_mart.sql | bq query --location=$BQ_LOC --project_id=$PROJECT_ID --use_legacy_sql=false
```

If you prefer the Web UI, copy the SQL from each file and execute it in the BigQuery Query Editor.

### 3. Building the Container

Use Cloud Build to build and push the Docker image.  From the root of this repository run:

```
gcloud builds submit --tag gcr.io/$PROJECT_ID/thc-backend:latest .
```

### 4. Deploying Cloud Run Jobs

Create a Cloud Run job for the QuickBooks ingestion.  Each job uses the same container image but is parameterized via environment variables.  Replace `REGION` with your preferred region.

```
REGION="us-east1"

# Create ingestion job for QuickBooks
gcloud run jobs create ingest-qbo \
  --image gcr.io/$PROJECT_ID/thc-backend:latest \
  --set-env-vars JOB_NAME=ingest-qbo,PROJECT_ID=$PROJECT_ID \
  --region $REGION \
  --service-account thc-backend-sa@$PROJECT_ID.iam.gserviceaccount.com

# Create job for running transformations
gcloud run jobs create transform-marts \
  --image gcr.io/$PROJECT_ID/thc-backend:latest \
  --set-env-vars JOB_NAME=transform-marts,PROJECT_ID=$PROJECT_ID \
  --region $REGION \
  --service-account thc-backend-sa@$PROJECT_ID.iam.gserviceaccount.com
```

### 5. Scheduling Jobs

Use Cloud Scheduler to trigger the Cloud Run jobs on a recurring schedule.  For example:

```
# QuickBooks ingestion hourly
gcloud scheduler jobs create http qbo-ingest-trigger \
  --schedule "0 * * * *" \
  --uri "https://REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT_ID/jobs/ingest-qbo:run" \
  --http-method POST \
  --oauth-service-account-email thc-backend-sa@$PROJECT_ID.iam.gserviceaccount.com

# Marts transformation five minutes after top of hour
gcloud scheduler jobs create http transform-marts-trigger \
  --schedule "5 * * * *" \
  --uri "https://REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT_ID/jobs/transform-marts:run" \
  --http-method POST \
  --oauth-service-account-email thc-backend-sa@$PROJECT_ID.iam.gserviceaccount.com
```

### 6. Loading Secrets

Store your API credentials in Secret Manager.  For example, create a secret `qbo-client-id` with your QuickBooks Client ID, and similar secrets for `qbo-client-secret`, `qbo-refresh-token`, and `qbo-company-id`.  Then grant the service account access:

```
gcloud secrets create qbo-client-id --data-file=<(echo -n "YOUR_QBO_CLIENT_ID")
gcloud secrets add-iam-policy-binding qbo-client-id \
  --member="serviceAccount:thc-backend-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Repeat for other secrets (qbo-client-secret, qbo-refresh-token, qbo-company-id)
```

The ingestion job uses the helper in `src/common/secrets.py` to fetch these secrets at runtime.

### 7. Ingesting Data from QuickBooks

The job `ingest_qbo.py` fetches invoices and customers from the QuickBooks Online API.  It uses the refresh token from Secret Manager to obtain an access token, then queries the API.  New records are deduplicated via the `source_primary_key` and appended to `thc_raw` tables with ingestion metadata.

To run the job manually for testing:

```
docker run --rm -e JOB_NAME=ingest-qbo -e PROJECT_ID=$PROJECT_ID \
  -e SECRET_PREFIX=qbo -e REGION=$REGION \
  -e GOOGLE_CLOUD_PROJECT=$PROJECT_ID \
  -v $HOME/.config/gcloud:/root/.config/gcloud \
  gcr.io/$PROJECT_ID/thc-backend:latest
```

### 8. Transformations and Marts

Scheduled queries or the `transform-marts` Cloud Run job use the SQL in `sql/procedures/transform_marts.sql` to populate the presentation tables.  These queries aggregate and pivot the staging data into the metrics required for Grafana.

### 9. Grafana Integration

Once the marts are populated, configure Grafana Cloud to connect to BigQuery using the service account credentials or IAM role.  Each panel on your dashboards should query the relevant `thc_mart` table.  Examples of SQL for each panel are provided in the "Grafana query cookbook" section below.

## Grafana Query Cookbook

Below are sample queries that your Grafana panels can use directly against BigQuery.  Replace `YOUR_PROJECT_ID` with your project.

### Cash & Runway (Stat)

```
SELECT cash_on_hand
FROM `YOUR_PROJECT_ID.thc_mart.exec_health_snapshot`
WHERE snapshot_date = CURRENT_DATE()
```

### A/R Summary (Gauge)

```
SELECT past_due_pct
FROM `YOUR_PROJECT_ID.thc_mart.ar_summary`
WHERE as_of_date = CURRENT_DATE()
```

### Top 5 Debtors (Table)

```
SELECT customer_name, past_due_amount, over_60_amount, oldest_invoice_days
FROM `YOUR_PROJECT_ID.thc_mart.ar_top5_debtors`
WHERE as_of_date = CURRENT_DATE()
ORDER BY past_due_amount DESC
LIMIT 5
```

### Orders Trend (Time Series)

```
SELECT order_date AS time, daily_order_count AS value
FROM `YOUR_PROJECT_ID.thc_mart.sales_daily`
WHERE order_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
ORDER BY time ASC
```

Further queries should be defined according to your marts once other sources (LeafLink, Metrc, Flourish) are ingested.

---

This backend design is intentionally modular so that additional sources can be integrated iteratively.  Start with QuickBooks to unlock the finance tiles on the dashboard, then proceed with LeafLink and Flourish to add sales and inventory metrics, and Metrc for compliance.  Demand signals (Shopify/GA/social) can be added last.