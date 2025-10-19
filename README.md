Selforge Grid: Selenium on AWS Fargate + Allure Reports (CI/CD)

Spin up a temporary Selenium Grid (standalone Chrome) on AWS Fargate, run TestNG tests from GitHub Actions, generate Allure HTML reports, and publish them to S3. Infra is created → tested → destroyed in one workflow.

✅ Designed for learning + demo + lightweight daily runs.
🔒 Uses GitHub OIDC to assume an AWS role (no long-lived keys).
📈 Optional: export Allure results CSVs for QuickSight dashboards.

Architecture (at a glance)

Terraform (modules) creates:

VPC-default ALB with listeners:

:80 → Grid (/status, sessions)

:7900 → noVNC (live browser)

ECS Fargate Service running selenium/standalone-chrome:4.25.0

Security groups, IAM roles, CloudWatch logs

GitHub Actions job:

Assumes AWS role via OIDC

terraform apply (Fargate Grid)

Runs Maven/TestNG pointing to the Grid URL

Builds Allure HTML and publishes to S3

(Optional) emits CSV summaries for analytics

Tears down infra (terraform destroy)

Repo layout
.
├── iac/                            # Terraform (modular)
│   ├── main.tf                     # Root composition
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── networking/             # SGs, ALB, listeners, target groups
│       ├── ecs/                    # Cluster, roles, task def, service
│       └── observability/          # CloudWatch logs (optional)
├── src/test/java/ui/DuckTest.java  # Sample TestNG test
├── testng.xml                      # Suites (Chrome / Firefox etc.)
├── pom.xml                         # Selenium + TestNG + Allure setup
└── .github/workflows/e2e.yml       # CI: Fargate → Tests → Allure → Destroy

Prerequisites

AWS account with permissions to create ECS/ALB/S3/DynamoDB/IAM roles

GitHub repo with:

Actions enabled

OIDC trust to assume a role in your AWS account

S3 bucket for reports (e.g. reports-<env>-<region>)

Optional: S3 Static Website Hosting + bucket policy for public read

Terraform state backend (S3 + DynamoDB lock table), or use local for learning

Secrets & config (GitHub → Settings → Secrets and variables → Actions)

Create these repository secrets:

Name	Example / Notes
AWS_ROLE_TO_ASSUME	arn:aws:iam::<ACCOUNT_ID>:role/GitHubActionsRole (OIDC-trusted)
TF_STATE_BUCKET	tf-state-<env>-<region>
TF_STATE_REGION	us-east-1
TF_STATE_LOCK_TABLE	tf-state-locks
REPORTS_BUCKET	reports-<env>-<region>

Tip: if you don’t want public reports, skip static website hosting and just use the HTTPS object URL (requires auth/presign).

How to run (CI)

Push to main or run manually: Actions → “Grid E2E (Fargate → Tests → Destroy)” → Run workflow.

The job will:

terraform apply to bring up the Grid

run tests against GRID_URL output

build Allure HTML

publish to S3 at:

Versioned: s3://<REPORTS_BUCKET>/grid/allure/<runId>-<attempt>/index.html

Rolling latest: s3://<REPORTS_BUCKET>/grid/allure/latest/index.html

print HTTPS links in the job summary

Local development (optional)

You can run tests locally without Fargate using a local Selenium:

# 1) Start Selenium locally (example via Docker):
docker run --rm -p 4444:4444 -p 7900:7900 \
  selenium/standalone-chrome:4.25.0

# 2) Execute tests pointing to local Grid:
mvn -Dgrid.url="http://localhost:4444" test

# 3) Build Allure HTML report:
mvn io.qameta.allure:allure-maven:report

# 4) Open:
open target/site/allure-maven/index.html

Test framework details

Selenium: 4.25.0

TestNG: 7.10.2

Allure:

TestNG listener: io.qameta.allure:allure-testng

Maven plugin: io.qameta.allure:allure-maven

Results dir: target/allure-results

Report dir: target/site/allure-maven

testng.xml (example with two Chrome tests in parallel):

<!DOCTYPE suite SYSTEM "https://testng.org/testng-1.0.dtd">
<suite name="SelforgeGridSuite" parallel="tests" thread-count="2">
  <listeners>
    <listener class-name="io.qameta.allure.testng.AllureTestNg"/>
  </listeners>

  <test name="Chrome-1">
    <parameter name="browser" value="chrome"/>
    <classes>
      <class name="ui.DuckTest"/>
    </classes>
  </test>

  <test name="Chrome-2">
    <parameter name="browser" value="chrome"/>
    <classes>
      <class name="ui.DuckTest"/>
    </classes>
  </test>
</suite>


If you later add Firefox in infra, add <test name="Firefox"> with browser=firefox.

Allure to S3 (what you’ll see)

The workflow:

Runs tests with results in target/allure-results

Builds HTML to target/site/allure-maven

Syncs the HTML to S3 (versioned + latest)

Prints HTTPS URLs in the job summary

If you enable Static Website Hosting on the bucket and add a public read policy (only if acceptable), you can open:

http://<bucket>.s3-website-<region>.amazonaws.com/grid/allure/latest/index.html


Otherwise, use the standard HTTPS URL (requires auth or presigned URL):

https://<bucket>.s3.<region>.amazonaws.com/grid/allure/latest/index.html

Optional: QuickSight analytics

The workflow also emits CSV files you can ingest into QuickSight:

allure-tests.csv — per-test rows: name, status, timings, class/package, etc.

allure-summary.csv — run totals: passed/failed/broken/skipped.

Two easy ingestion patterns:

Push CSVs to S3 (recommended)

Add an Action step to aws s3 cp both CSVs to s3://<reports-bucket>/grid/analytics/<runId>/

In QuickSight: New dataset → S3 → manifest pointing to that prefix

Manual upload

Download artifacts from the run (allure-html and CSVs)

Upload the CSVs directly as datasets in QuickSight

Cost notes

Fargate: charged by vCPU/GB-hour while the task runs (short test windows → pennies)

ALB: hourly + LCU during runtime

S3: storage + requests (tiny for HTML + CSVs)

DynamoDB (state lock): on-demand, pennies

CloudWatch Logs: a few MB per run

Runs that create → test → destroy are very low cost.

Troubleshooting

“Allure report folder not found”

Ensure tests generated results in target/allure-results

The workflow already passes -Dallure.results.directory=target/allure-results

Can’t open …amazonaws.com/index.html

You’re using the object endpoint (not a website). Either:

use a presigned URL, or

enable Static Website Hosting + bucket policy for public read, or

open via AWS Console while authenticated

Firefox tests not starting

Task image is standalone-chrome. Switch to a custom grid or a Firefox/Distributed grid image and expose the right ports.

Destroy on failure

The workflow uses if: always() to destroy infra in the last step.

Security / redaction for public posts

Before sharing logs/screenshots publicly, replace:

Account IDs → 1234-5678-9012

Role ARNs → arn:aws:iam::<ACCOUNT_ID>:role/GitHubActionsRole

Bucket names → reports-<env>-<region>

ALB URLs → http://<alb-dns> and http://<alb-dns>:7900

Never post access keys, tokens, or full console links with your account ID.

Cleanup

If you created any persistent resources manually (e.g., S3 state bucket, DynamoDB lock table, reports bucket), delete them when done:

aws s3 rb s3://reports-<env>-<region> --force
aws dynamodb delete-table --table-name tf-state-locks
