# Activity Log — How this design was reached

A chronological record of the reasoning behind the architecture, so the design
choices are transparent. Pairs with `DECISION-LOG.md` (the what/why per decision).

---

### 1. Established the onboarding pipeline shape
The core flow: property owner records a video → snapshots + an AI description are
produced → a human reviews and approves → the approved listing is published.
Chosen implementation: event-driven serverless with a human-in-the-loop pause
(Step Functions task token). This scales to zero, models the multi-day review
wait natively, and gives an auditable execution history. (DL-01)

### 2. Fixed the delivery model: Terraform, stage → prod
Requirement: Terraform, parameterized, deploy to stage → test → prod. Decided on
one codebase, differences isolated to `env/*.tfvars`, and isolated remote state
per environment so a stage apply can never touch prod. (DL-17)

### 3. Auth resolved as Cognito email-OTP
The product signs users in with a 6-digit email code. Chose Cognito's passwordless
custom-auth flow (SES delivers the code) so the UX is unchanged but Cognito owns
the brute-force protection, token lifecycle, and lockout — and integrates with
the API Gateway JWT authorizer. Hardened the flow: per-code attempt cap, CSPRNG
code, timing-safe compare, short TTL, and a WAF rate limit on the OTP path.
(DL-08, DL-09)

### 4. Matched the existing runtime stack
The product already runs a Node.js frontend, uses Redis for in-journey wizard
state, and S3 for uploads. Kept all three: host the Node build on S3+CloudFront,
use ElastiCache for Redis for the TTL'd draft, and DynamoDB only for submitted
listings + pipeline state. (DL-10, DL-11)

### 5. Reframed the app as an ecosystem integration component
Key change: this onboarding capability is part of a larger UK property platform.
Three capabilities are owned elsewhere and are integrated over REST rather than
rebuilt here:
- **Video → image** is done by an in-house agent → `invoke-video-agent` calls it.
  (Replaced the earlier MediaConvert + Rekognition design.) (DL-04)
- **Input data** (EPC certificate, compliance data) comes from an upstream app →
  `fetch-input-data` pulls it. (DL-05)
- **Publishing** to rental sites is done by an existing app → `publish-to-ecosystem`
  hands the approved listing to it. (Replaced the earlier per-partner SQS fan-out.)
  (DL-06)
External base URLs + API keys live in Secrets Manager. (DL-03)

### 6. Localized to the UK market
Retargeted to eu-west-2 (London) for UK data residency; the description schema
carries `epc_rating` and `compliance_notes`; retention windows are per-env and
flagged for the DPO. The CloudFront-scoped WAF remains in us-east-1 (an AWS
requirement) via a provider alias. (DL-07)

### 7. Security + observability pass
Layered the API: WAF → API Gateway throttling → Cognito JWT authorizer →
server-side authorization → least-privilege IAM (Bedrock scoped to one model,
each integration Lambda scoped to its own secret, CORS locked to the app
domains) → KMS + private-VPC Redis. X-Ray, CloudWatch, CloudTrail, GuardDuty
across the board. (DL-13, DL-14, DL-15, DL-16, DL-18)

### 8. Built and validated the package
Wrote the Terraform (network, security/WAF, identity, storage, cache, data, api,
integration, workflow, events, publish, frontend, observability), the
integration + application Lambdas, the Step Functions state machine, the
architecture diagram, and this doc set. Ran `terraform fmt`,
`terraform init -backend=false`, and `terraform validate` — the configuration
validates cleanly.

---

## Provenance / honesty notes
- The Terraform validates but has not been applied to a live account. Real
  deployment needs the SES verified sender, Bedrock model access in eu-west-2,
  the state backends, and the three integration secrets populated.
- The integration Lambdas assume sensible REST contracts for the in-house agent,
  the upstream data app, and the publishing app. Align the request/response
  shapes to the real APIs before go-live (open item in the decision log).
- Lambda handlers are complete and functional but call external systems and
  Bedrock; integration-test them in stage.
