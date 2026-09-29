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

This app does **not** own identity, video processing, or publishing. It
integrates with the surrounding ecosystem over standard protocols:

| External system | Direction | What crosses the boundary |
|---|---|---|
| **Self-hosted Keycloak** (identity) | this app **trusts** it | owners + reviewers log in against Keycloak (incl. email-OTP); this app validates the issued JWTs (OIDC) |
| **In-house video→image agent** | this app **calls** it | send the uploaded video reference → receive extracted snapshots (REST) |
| **Upstream data app** | this app **calls** it | GET the property's EPC certificate + compliance data (REST) |
| **Existing publishing app** | this app **calls** it | POST the approved, reviewed listing for downstream distribution (REST) |

Base URLs and API keys for the three REST integrations live in **AWS Secrets
Manager** — nothing is hardcoded in code or state. Keycloak is trusted purely by
its OIDC issuer + JWKS (public keys); no secret is needed to validate its tokens.

## What's in the box

| Path | What it is |
|------|-----------|
| `diagram/architecture.svg` / `.png` | Integration architecture with AWS icons |
| `terraform/` | End-to-end IaC: network, WAF/security, Keycloak JWT authorizer, S3+KMS, ElastiCache Redis, DynamoDB, API Gateway+JWT, the two REST integrations as native Step Functions HTTP Tasks (EventBridge API Connections), the generate-description Bedrock Lambda, Step Functions HITL, publish hand-off, CloudFront SPAs, observability. Parameterized per environment. |
| `terraform/env/` | `stage.tfvars` / `prod.tfvars` + per-env remote-state backend configs |
| `lambdas/` | Working source for the 5 Lambdas: presign-upload, submit-for-review, review-callback, generate-description, publish-to-ecosystem |
| `terraform/modules/identity/` | Keycloak coordinates (issuer/audience/roles) the API authorizer + SPAs consume — no AWS identity resources are created here |
| `step-functions/onboarding.asl.json` | The human-in-the-loop state machine |
| `docs/RUNBOOK.md` | Step-by-step provision → deploy → verify → promote to prod |
| `docs/DECISION-LOG.md` | Every decision, the alternatives, and doc links |
| `docs/ACTIVITY-LOG.md` | How the design was reached |
| `prompts/CLAUDE-PROMPT.md` | A prompt to hand Claude/Kiro to verify or adapt this against an existing codebase |

## Architecture at a glance

```
Owner (Node SPA on S3+CloudFront; logs in via self-hosted Keycloak, email-OTP)
  --presigned PUT--> S3 raw-videos --EventBridge--> Step Functions:
      FetchInputData (HTTP Task)  --REST--> Upstream data app (EPC/compliance)
      InvokeVideoAgent (HTTP Task)--REST--> In-house video->image agent (snapshots)
      generate-description (Lambda) -------> Bedrock Claude (description JSON)
      waitForTaskToken     <== human review console approves/rejects
  --approve--> ListingApproved --> publish-to-ecosystem --REST--> Existing publishing app
In-journey wizard draft: ElastiCache Redis (TTL).  Region: eu-west-2.  IaC: Terraform stage->prod.
```

## The stack

- **Frontend:** Node.js SPA (owner + reviewer) on **S3 + CloudFront** (OAC)
- **Auth:** **self-hosted Keycloak** (OIDC; passwordless email-OTP owned by Keycloak). API Gateway validates Keycloak JWTs; the SPAs use OIDC auth-code + PKCE
- **In-journey state:** **ElastiCache for Redis** (TTL'd wizard draft)
- **Upload:** presigned **S3** PUT via **API Gateway + Lambda**
- **Orchestration:** **Step Functions** (Standard, human-in-the-loop)
- **Integration:** the upstream data app and in-house video agent are called by
  **native Step Functions HTTP Tasks** (no Lambda) via **EventBridge API
  Connections** (which hold the API keys); the publishing app is called by the
  `publish-to-ecosystem` Lambda (credentials in **Secrets Manager**)
- **Description:** **Amazon Bedrock — Claude Sonnet** (vision) → structured JSON
- **State:** **DynamoDB** single-table (`byStatus` / `byOwner` GSIs)
- **Publish:** **EventBridge** → **publish-to-ecosystem** Lambda → existing app (+ DLQ)
- **Security:** **WAF**, **Keycloak JWT authorizer** (API Gateway), least-privilege **IAM**, **KMS**, private **VPC** for Redis
- **Observability:** **CloudWatch**, **X-Ray**, **CloudTrail**, **GuardDuty**
- **IaC:** **Terraform**, parameterized `env` (stage → prod), isolated remote state per environment, **eu-west-2**

## Quick start

```bash
# Prereqs: terraform >= 1.6, AWS creds for the STAGE account, Node 20, a
# reachable Keycloak realm (issuer + client), Bedrock model access in eu-west-2.
# See docs/RUNBOOK.md.
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
