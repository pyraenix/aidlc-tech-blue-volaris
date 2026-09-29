# Property Onboarding on AWS — Implementation Package

Property owners record a video of their property; snapshots and an AI-written
description are produced; a human reviews and approves; the approved listing is
handed off to the existing publishing application for distribution. This
onboarding capability is **one component of a larger UK-market property
platform** and integrates with the surrounding ecosystem over REST.

Provisioned and deployed on AWS with **Terraform**, parameterized so you deploy
to **stage first, test, then prod**. Region: **eu-west-2 (London)** for UK data
residency.

## Ecosystem integration (this component's boundaries)

This app does **not** own video processing or publishing. It integrates with
three external systems over REST:

| External system | Direction | What crosses the boundary |
|---|---|---|
| **In-house video→image agent** | this app **calls** it | send the uploaded video reference → receive extracted snapshots |
| **Upstream data app** | this app **calls** it | GET the property's EPC certificate + compliance data |
| **Existing publishing app** | this app **calls** it | POST the approved, reviewed listing for downstream distribution |

Base URLs and API keys for all three live in **AWS Secrets Manager** — nothing
is hardcoded in code or state.

## What's in the box

| Path | What it is |
|------|-----------|
| `diagram/architecture.svg` / `.png` | Integration architecture with AWS icons |
| `terraform/` | End-to-end IaC: network, WAF/security, Cognito email-OTP, S3+KMS, ElastiCache Redis, DynamoDB, API Gateway+JWT, the integration Lambdas (fetch-input-data · invoke-video-agent · generate-description), Step Functions HITL, publish hand-off, CloudFront SPAs, observability. Parameterized per environment. |
| `terraform/env/` | `stage.tfvars` / `prod.tfvars` + per-env remote-state backend configs |
| `lambdas/` | Working source for the application + integration Lambdas |
| `terraform/modules/identity/src/` | The Cognito email-OTP trigger Lambdas |
| `step-functions/onboarding.asl.json` | The human-in-the-loop state machine |
| `docs/RUNBOOK.md` | Step-by-step provision → deploy → verify → promote to prod |
| `docs/DECISION-LOG.md` | Every decision, the alternatives, and doc links |
| `docs/ACTIVITY-LOG.md` | How the design was reached |
| `prompts/CLAUDE-PROMPT.md` | A prompt to hand Claude/Kiro to verify or adapt this against an existing codebase |

## Architecture at a glance

```
Owner (Node SPA on S3+CloudFront + Cognito email-OTP)
  --presigned PUT--> S3 raw-videos --EventBridge--> Step Functions:
      fetch-input-data     --REST--> Upstream data app (EPC/compliance)
      invoke-video-agent   --REST--> In-house video->image agent (snapshots)
      generate-description --------> Bedrock Claude (description JSON)
      waitForTaskToken     <== human review console approves/rejects
  --approve--> ListingApproved --> publish-to-ecosystem --REST--> Existing publishing app
In-journey wizard draft: ElastiCache Redis (TTL).  Region: eu-west-2.  IaC: Terraform stage->prod.
```

## The stack

- **Frontend:** Node.js SPA (owner + reviewer) on **S3 + CloudFront** (OAC)
- **Auth:** **Cognito email-OTP** (passwordless 6-digit code via **SES**)
- **In-journey state:** **ElastiCache for Redis** (TTL'd wizard draft)
- **Upload:** presigned **S3** PUT via **API Gateway + Lambda**
- **Orchestration:** **Step Functions** (Standard, human-in-the-loop)
- **Integration:** REST connectors to the in-house video agent, the upstream
  data app, and the publishing app (credentials in **Secrets Manager**)
- **Description:** **Amazon Bedrock — Claude Sonnet** (vision) → structured JSON
- **State:** **DynamoDB** single-table (`byStatus` / `byOwner` GSIs)
- **Publish:** **EventBridge** → **publish-to-ecosystem** Lambda → existing app (+ DLQ)
- **Security:** **WAF**, **Cognito JWT authorizer**, least-privilege **IAM**, **KMS**, private **VPC** for Redis
- **Observability:** **CloudWatch**, **X-Ray**, **CloudTrail**, **GuardDuty**
- **IaC:** **Terraform**, parameterized `env` (stage → prod), isolated remote state per environment, **eu-west-2**

## Quick start

```bash
# Prereqs: terraform >= 1.6, AWS creds for the STAGE account, Node 20, an SES
# verified sender, Bedrock model access in eu-west-2. See docs/RUNBOOK.md.
./build-lambdas.sh                       # install Lambda deps (optional)

cd terraform
terraform init -backend-config=env/stage.backend.hcl
terraform apply -var-file=env/stage.tfvars     # deploy + test in STAGE
# then, in the PROD account:
terraform init -reconfigure -backend-config=env/prod.backend.hcl
terraform apply -var-file=env/prod.tfvars
```

After apply, populate the three integration secrets with the real base URLs +
API keys (see `docs/RUNBOOK.md`). Full details in the runbook.
