**Selforge Grid: Selenium on AWS Fargate + Allure Reports (CI/CD)**

Spin up a temporary Selenium Grid (standalone Chrome) on AWS Fargate, run TestNG tests from GitHub Actions, generate Allure HTML reports, and publish them to Amazon S3.
The entire lifecycle — create → test → report → destroy — happens automatically in one workflow.

✅ Highlights

🧪 Designed for learning, demo, and lightweight daily runs

🔒 Uses GitHub OIDC to assume an AWS IAM role (no long-lived credentials)

📊 Exports Allure results CSVs for optional Amazon QuickSight dashboards

🏗️ **Architecture Overview**
Terraform (Modular Infrastructure)

Default VPC + ALB with listeners:

:80 → Selenium Grid (/status, sessions)

:7900 → noVNC (live browser)

ECS Fargate Service running selenium/standalone-chrome:4.25.0

Security Groups, IAM Roles, CloudWatch Logs

GitHub Actions CI/CD

Assumes AWS Role via OIDC

Runs terraform apply to spin up Fargate Grid

Executes Maven/TestNG tests against Grid URL

Builds Allure HTML Report

Publishes reports to S3 (versioned + latest)

(Optional) Uploads CSV results for analytics

Cleans up infra with terraform destroy

📁 Repository Structure
.
**├── iac/                            # Terraform (modular)
│   ├── main.tf                     # Root composition
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── networking/             # SGs, ALB, listeners, target groups
│       ├── ecs/                    # Cluster, roles, task definition, service
│       └── observability/          # CloudWatch logs (optional)
├── src/test/java/ui/DuckTest.java  # Sample Selenium TestNG test
├── testng.xml                      # Test suite (Chrome / Firefox etc.)
├── pom.xml                         # Maven config (Selenium + TestNG + Allure)
└── .github/workflows/e2e.yml       # CI: Fargate → Tests → Allure → Destroy**

**⚙️ Prerequisites**

AWS Account with permissions for ECS, ALB, S3, DynamoDB, and IAM

GitHub Repository with:

GitHub Actions enabled

OIDC trust to assume a role in AWS

S3 Bucket for reports → e.g. reports-<env>-<region>

(Optional) Enable Static Website Hosting for public viewing

Terraform backend (S3 + DynamoDB for remote state)

🔐** GitHub Secrets Configuration**
Secret Name	Example Value / Description
AWS_ROLE_TO_ASSUME	arn:aws:iam::<ACCOUNT_ID>:role/GitHubActionsRole (OIDC trusted)
TF_STATE_BUCKET	tf-state-<env>-<region>
TF_STATE_REGION	us-east-1
TF_STATE_LOCK_TABLE	tf-state-locks
REPORTS_BUCKET	reports-<env>-<region>

💡 If you prefer private reports, skip static website hosting and use the S3 HTTPS object URL (requires authentication).

🧪 **How to Run the Pipeline**

Trigger the workflow:

Push to the main branch, or

Manually from GitHub Actions → “Grid E2E (Fargate → Tests → Destroy)” → Run Workflow

Pipeline steps:

terraform apply → creates Selenium Grid infra

Runs Selenium tests via TestNG

Builds Allure HTML reports

Publishes reports to:

📘 Versioned: s3://<REPORTS_BUCKET>/grid/allure/<runId>-<attempt>/index.html

🔁 Latest: s3://<REPORTS_BUCKET>/grid/allure/latest/index.html

Destroys infra automatically after test run

💻 Run Tests Locally (Optional)

You can run the same tests locally using Docker:

# 1️⃣ Start Selenium Grid locally
docker run --rm -p 4444:4444 -p 7900:7900 selenium/standalone-chrome:4.25.0

# 2️⃣ Run tests pointing to the local Grid
mvn -Dgrid.url="http://localhost:4444" test

# 3️⃣ Generate Allure HTML report
mvn io.qameta.allure:allure-maven:report

# 4️⃣ Open the report
open target/site/allure-maven/index.html

🧩 Test Framework Stack
Tool	Version	Purpose
Selenium	4.25.0	Browser automation
TestNG	7.10.2	Test orchestration
Allure	latest	Rich HTML reporting

Key Paths:

Allure Results → target/allure-results

Allure HTML → target/site/allure-maven

🧾 Example testng.xml (2 Chrome tests in parallel)
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


🔄 Add <test name="Firefox"> with browser=firefox when your infra supports it.

☁️ Allure Report in S3

The workflow:

Runs tests and stores results in target/allure-results

Builds HTML into target/site/allure-maven

Uploads the HTML to S3 (versioned and latest)

Prints direct URLs in the job summary

Access options:

Static Website URL (public):

http://<bucket>.s3-website-<region>.amazonaws.com/grid/allure/latest/index.html


Private HTTPS (recommended):

https://<bucket>.s3.<region>.amazonaws.com/grid/allure/latest/index.html

📊 Optional: QuickSight Analytics Integration

The workflow generates two CSV files:

allure-tests.csv — detailed test data (name, status, duration, etc.)

allure-summary.csv — high-level summary (total, passed, failed, skipped)

Integration options:

Automatic via S3

Add a GitHub step to upload CSVs to:
s3://<REPORTS_BUCKET>/grid/analytics/<runId>/

In QuickSight → “New Dataset → S3 → Upload manifest”

Manual upload

Download artifacts (allure-html + CSVs)

Upload directly as QuickSight datasets
