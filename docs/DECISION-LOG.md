# Decision Log — Property Onboarding Platform (UK ecosystem component)

Every non-trivial architectural decision, the alternatives considered, why the
choice was made, and a link to the authoritative AWS documentation. Read this
alongside `ACTIVITY-LOG.md`, which records the order the decisions were made in.

Legend: **Decision** · *Alternatives* · **Why** · 📄 *Docs*

---

## DL-01 — Overall pattern: event-driven serverless with human-in-the-loop
**Decision:** S3 → EventBridge → Step Functions orchestrating the steps, pausing
for human review, then handing off to the publishing app.
*Alternatives:* a monolithic service polling a queue; a container app inline.
**Why:** The workflow is asynchronous with a multi-day human wait. Step Functions
models that natively (task tokens), scales to zero, and gives per-step
retry/catch, tracing, and an auditable execution history.
📄 [Step Functions — wait for a callback with the task token](https://docs.aws.amazon.com/step-functions/latest/dg/callback-task-sample-sqs.html) ·
[EventBridge with S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/EventBridge.html)

## DL-02 — This app is an integration COMPONENT, not a standalone
**Decision:** Treat the onboarding app as one component of a larger property
platform. It does not own video processing or publishing; it integrates over
REST with an in-house video agent, an upstream EPC/compliance data app, and an
existing publishing app.
*Alternatives:* build video processing (MediaConvert/Rekognition) and publishing
(SQS fan-out) inside this app.
**Why:** Those capabilities already exist elsewhere in the ecosystem. Rebuilding
them would duplicate and diverge. Clean REST seams keep this component focused on
onboarding + review and let each system evolve independently.
📄 [Well-Architected — loosely coupled dependencies](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_prevent_interaction_failure_loosely_coupled_system.html)

## DL-03 — External integration secrets in AWS Secrets Manager
**Decision:** Each external system's base URL + API key is a Secrets Manager
secret; the integration Lambdas read them at runtime. Nothing is hardcoded in
code or Terraform state.
*Alternatives:* environment variables or hardcoded endpoints.
**Why:** Endpoints/credentials rotate independently of deploys, stay out of
source control and state, and are scoped by IAM per Lambda.
📄 [Secrets Manager — retrieve secrets in Lambda](https://docs.aws.amazon.com/secretsmanager/latest/userguide/retrieving-secrets_lambda.html)

## DL-04 — Video→image: call TechBlue's in-house agent (REST)
**Decision:** The `invoke-video-agent` Lambda POSTs the uploaded video reference
to the in-house agent and receives the extracted snapshots. Frame extraction,
snapshot selection and any moderation are the agent's responsibility.
*Alternatives:* MediaConvert + Rekognition inside this app (the earlier design).
**Why:** TechBlue already has this agent; this component only integrates with it.
Modelled as a Step Functions Task so the surrounding flow is unchanged if the
agent's transport later changes.
**Update (DL-20):** this call is now a **native Step Functions HTTP Task** (via
an EventBridge API Connection), not a Lambda — the Lambda was a thin REST
wrapper with no logic beyond an empty-result guard, which is now a `Choice`.
📄 [Step Functions — call HTTPS APIs (HTTP Task)](https://docs.aws.amazon.com/step-functions/latest/dg/connect-third-party-apis.html)

## DL-05 — Input data: fetch EPC/compliance from the upstream app (REST)
**Decision:** GET the property's EPC certificate and compliance data from the
upstream app early in the pipeline, keyed on a shared property reference (e.g.
UPRN in the UK). A 404 proceeds with empty inputs flagged for the reviewer.
*Alternatives:* have owners re-enter compliance data by hand.
**Why:** The authoritative data already lives upstream; pulling it avoids
re-keying, keeps the description grounded, and gives the reviewer the real EPC.
**Update (DL-20):** this is now a **native Step Functions HTTP Task**; the
404-tolerance is a `Catch` on `States.Http.StatusCode.404` routing to a Pass
state that sets `missing:true` (was Lambda `if (status===404)`).
📄 [Well-Architected — integrate through well-defined APIs](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_prevent_interaction_failure_service_contracts.html)

## DL-06 — Publish: hand off approved listing to the existing publishing app (REST)
**Decision:** On `ListingApproved`, the `publish-to-ecosystem` Lambda POSTs the
reviewed listing to the existing publishing app, with an idempotency key. Failed
hand-offs dead-letter to SQS after EventBridge retries.
*Alternatives:* per-rental-site SQS + adapter Lambdas inside this app (the
earlier design).
**Why:** The publishing app already owns distribution to rental sites. This
component's job ends at handing over an approved listing. The idempotency key
prevents a retry from double-publishing on their side.
📄 [EventBridge target retry + dead-letter queue](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rule-dlq.html)

## DL-07 — Region: eu-west-2 (London) for UK data residency
**Decision:** Deploy to `eu-west-2`. The CloudFront-scoped WAF is still created
in us-east-1 (an AWS requirement) via a provider alias; all data-bearing
resources are in eu-west-2.
*Alternatives:* a US region.
**Why:** This is a UK-market product; keeping property data and PII in the UK
region supports UK GDPR data-residency expectations.
📄 [AWS Regions](https://docs.aws.amazon.com/general/latest/gr/rande.html) ·
[CloudFront WAF must be us-east-1](https://docs.aws.amazon.com/waf/latest/developerguide/how-aws-waf-works-resources.html)

## DL-08 — Auth: Cognito email-OTP passwordless — ⚠️ SUPERSEDED by DL-19
**Decision (original):** Cognito user pool with a custom authentication flow
(passwordless 6-digit email code) via the three challenge triggers, delivering
the code through SES.
*Alternatives:* home-grown "generate a code, store in Redis, email it"; Okta.
**Why (original):** Keeps the existing 6-digit-code UX but hands the
security-sensitive parts — attempt caps, code expiry, token issuance/refresh,
lockout — to Cognito, and plugs straight into the API Gateway JWT authorizer.
**Superseded:** The ecosystem standardizes identity on a self-hosted Keycloak
that already owns login and email-OTP. See DL-19 — Cognito, its OTP trigger
Lambdas, and SES were removed.
📄 [Custom authentication challenge Lambda triggers](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-challenge.html)

## DL-09 — OTP brute-force / flooding defense — ⚠️ SUPERSEDED by DL-19
**Decision (original):** 3-attempt cap per code (via `DefineAuthChallenge`),
CSPRNG code, timing-safe compare, short TTL, one code reused across retries in a
session, plus a WAF rate-based rule scoped to the OTP path and API Gateway
throttling.
**Why (original):** A 6-digit code is only 1,000,000 values; the defense that
matters is limiting guesses per code and requests per IP.
**Superseded:** OTP is now issued and verified by Keycloak, so per-code attempt
caps and OTP-flood throttling move to Keycloak's edge. The WAF `OtpRequestRateLimit`
rule (scoped to `/auth/request-otp`, a route that no longer exists on this API)
was removed. The global API rate limit and API Gateway throttling remain. See DL-19.
📄 [WAF rate-based rules](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based.html)

## DL-10 — In-journey draft state: ElastiCache for Redis
**Decision:** Hold the active wizard draft in ElastiCache for Redis with a TTL;
write to DynamoDB only on final submit.
**Why:** Matches the existing stack (Redis already used for the journey) and is
the right tool for ephemeral TTL'd state. DynamoDB is the durable, queryable
store for submitted listings + pipeline state.
📄 [ElastiCache for Redis](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/WhatIs.html)

## DL-11 — Frontend hosting: S3 + CloudFront (not Amplify Hosting)
**Decision:** Host the Node.js SPAs as static builds on S3 behind CloudFront
with Origin Access Control.
**Why:** The team standardizes on Terraform with a stage→prod flow; Amplify
Hosting's own deploy lifecycle would be a competing source of truth. Static SPAs
need only S3 + CloudFront, fully under Terraform.
📄 [Restrict S3 access to CloudFront with OAC](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html)

## DL-12 — Description: Amazon Bedrock (Claude Sonnet, vision), strict JSON
**Decision:** Bedrock `InvokeModel` on the agent's snapshots + owner details +
the fetched EPC/compliance, returning a strict JSON schema (incl. `epc_rating`,
`compliance_notes`, PII flags); retry once on parse failure.
**Why:** Managed, guardrailed, vision-capable, no model ops. Grounding on the
real compliance data keeps the copy accurate.
📄 [Bedrock InvokeModel](https://docs.aws.amazon.com/bedrock/latest/userguide/api-methods-run.html) ·
[Claude messages API on Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages.html)

## DL-13 — Least-privilege IAM; Bedrock scoped to one model; CORS locked
**Decision:** Each Lambda role grants only what it needs; `bedrock:InvokeModel`
is scoped to the configured model ARN; each integration Lambda can read only its
own secret; S3 CORS is locked to `app_domains`, never `*`.
**Why:** Limits blast radius and closes the common over-permissioning gaps.
📄 [IAM least-privilege](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#grant-least-privilege) ·
[S3 CORS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/cors.html)

## DL-14 — API auth: API Gateway HTTP API + JWT authorizer (updated by DL-19)
**Decision:** HTTP API with a JWT authorizer; server side enforces
`ownerId == token.sub` and reviewer role membership.
**Why:** Native JWT validation rejects bad tokens before the Lambda runs;
ownership/role checks must be server-side, never trusting the UI.
**Update (DL-19):** the authorizer now validates **Keycloak**-issued tokens
(issuer + JWKS), not Cognito. Reviewer authority comes from a Keycloak role
claim (`keycloak_roles_claim`, e.g. `realm_access.roles`) instead of Cognito
groups.
📄 [HTTP API JWT authorizers](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html)

## DL-15 — Edge security: AWS WAF on API Gateway and CloudFront
**Decision:** Two WAF web ACLs (REGIONAL for the API in eu-west-2, CLOUDFRONT for
the SPAs in us-east-1) with managed rule groups, IP reputation, a global rate
limit. (The OTP-path rate limit was removed with the move to Keycloak — see DL-09/DL-19.)
**Why:** Defense in depth — stop SQLi/XSS, bad IPs, and floods at the edge before
compute runs.
📄 [WAF managed rule groups](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-list.html)

## DL-16 — Encryption + network isolation
**Decision:** KMS-encrypted S3 and DynamoDB; ElastiCache encrypted at-rest and
in-transit in private subnets reachable only from the Lambda SG; TLS everywhere.
**Why:** UK property data + PII warrant customer-managed keys and datastore
network isolation.
📄 [S3 encryption with KMS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html) ·
[ElastiCache encryption](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/in-transit-encryption.html)

## DL-17 — IaC: Terraform, parameterized, isolated state per environment
**Decision:** One Terraform codebase; differences isolated to `env/*.tfvars`; a
separate S3 state bucket + DynamoDB lock table per environment selected with
`-backend-config`.
**Why:** Stage-first-then-prod with isolated state means a stage apply can never
touch prod, and what you test is what you ship.
📄 [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3) ·
[tfvars files](https://developer.hashicorp.com/terraform/language/values/variables#variable-definitions-tfvars-files)

## DL-18 — Observability: CloudWatch + X-Ray + CloudTrail + GuardDuty
**Decision:** X-Ray on every Lambda + the state machine; CloudWatch dashboard +
a failed-execution alarm; CloudTrail audit; GuardDuty.
**Why:** An async multi-step pipeline with three external integrations is
undebuggable without distributed tracing and per-step logs.
📄 [X-Ray with Lambda](https://docs.aws.amazon.com/lambda/latest/dg/services-xray.html)

## DL-19 — Auth: self-hosted Keycloak instead of Cognito (supersedes DL-08/09)
**Decision:** Use the ecosystem's existing **self-hosted Keycloak** as the
identity provider. Keycloak owns the full login lifecycle, including passwordless
email-OTP. This app creates no identity resources: the `identity` module is a
thin pass-through of Keycloak coordinates (`keycloak_issuer`, `keycloak_audience`,
`keycloak_roles_claim`, reviewer role names), the API Gateway JWT authorizer
validates Keycloak tokens, and the SPAs authenticate via OIDC auth-code + PKCE
against Keycloak. Removed: the Cognito user pool + app client + groups, the three
`CUSTOM_AUTH` trigger Lambdas and their IAM role, the SES send policy, and the
WAF OTP-path rule.
*Alternatives:* keep Cognito and federate it to Keycloak (OIDC broker); migrate
users into Cognito.
**Why:** The ecosystem standardizes on Keycloak, which already runs email-OTP for
these users. A second IdP (Cognito) would mean two user stores and two places to
manage reviewers. Trusting Keycloak's JWTs keeps this component a pure integration
consumer of identity — consistent with DL-02.
**Assumptions / to confirm:** (a) Keycloak's OIDC issuer/JWKS is **publicly
reachable** so API Gateway's native JWT authorizer can fetch keys — if Keycloak
is VPC-internal, this must become a VPC Lambda authorizer instead; (b) the real
issuer URL, client `aud`, and reviewer role claim (the tfvars ship placeholders).
📄 [HTTP API JWT authorizers (any OIDC IdP)](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html) ·
[Keycloak — OIDC endpoints](https://www.keycloak.org/docs/latest/securing_apps/#_oidc)

## DL-20 — Fewer Lambdas: the two REST calls become native HTTP Tasks
**Decision:** Convert `fetch-input-data` and `invoke-video-agent` from Lambdas to
**native Step Functions HTTP Tasks** (`arn:aws:states:::http:invoke`) that
authenticate via **EventBridge API Connections** (the connection stores the
`x-api-key` in a connection-managed Secrets Manager secret and injects it). The
small amounts of logic move into ASL: `propertyRef || listingId` becomes a
`Choice`, the upstream 404-tolerance a `Catch` + Pass, and the video agent's
empty-snapshot guard a `Choice`. This takes the app from 7 Lambdas to 5.
*Alternatives:* (a) keep the two wrapper Lambdas; (b) also fold
`generate-description` and `publish-to-ecosystem` in (rejected — see below).
**Why:** Both were thin REST wrappers whose only real work was sending a request
and shaping the response — exactly what HTTP Tasks do natively. Removing them
cuts deployable code, IAM roles, and cold-start surface, and the API Connection
handles the credential more cleanly than a `GetSecretValue` in code.
**Deliberately kept as Lambdas (strong reasons):**
- `generate-description` — assembles a multimodal Bedrock payload (base64 images)
  and does a JSON parse-and-retry loop that ASL cannot express.
- `publish-to-ecosystem` — an **event-driven** target of `ListingApproved` with
  its own EventBridge retry + SQS DLQ; folding it into the state machine would
  trade away that decoupling and independent failure handling.
- `presign-upload`, `submit-for-review`, `review-callback` — per-request API
  Gateway handlers.
**Trade-off:** HTTP Task request/response shaping is expressed in ASL (JSONPath),
which is less flexible than JS if a contract needs heavy transformation. If either
external contract grows complex, that call can move back into a Lambda.
📄 [Step Functions — call third-party HTTPS APIs](https://docs.aws.amazon.com/step-functions/latest/dg/connect-third-party-apis.html) ·
[EventBridge connections](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-api-destination-connection.html)

---

## Open items to confirm before go-live
1. **REST contracts** for the three external systems — exact request/response
   shapes, auth scheme, and the shared property reference (UPRN?). The Lambdas
   assume sensible contracts; align them to the real APIs.
2. **Keycloak coordinates** — confirm the real realm issuer URL, client `aud`,
   and reviewer role claim, and that the issuer/JWKS is publicly reachable from
   API Gateway (else switch to a VPC Lambda authorizer). tfvars ship placeholders.
3. **Redis today** — self-managed vs ElastiCache; this package provisions
   ElastiCache. If they keep their own, drop the `cache` module and point at it.
4. **Video/volume profile** — to right-size Bedrock spend and confirm Standard
   vs Express Step Functions.
5. **UK GDPR** — confirm retention windows for raw video + PII with their DPO;
   `raw_video_retention_days` is set per env but should match their policy.
