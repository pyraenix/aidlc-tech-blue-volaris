# Prompt for Claude / Kiro — verify, adapt, and deploy this package

Give this whole package folder to Claude (via Kiro, Amazon Q Developer, or Claude
Code) as project context. If you have an existing codebase, open both together so
the agent can reconcile them. This app is an **integration component** of a larger
UK property platform — it integrates over REST with an in-house video agent, an
upstream EPC/compliance data app, and an existing publishing app.

---

## Prompt A — Verify the Terraform is correct and safe (start here)

```
You are reviewing an AWS property-onboarding platform in this folder, deployed
with Terraform to eu-west-2 (UK). Flow: owner records a video → an in-house
video agent (REST) extracts snapshots → EPC/compliance data is pulled from an
upstream app (REST) → Bedrock Claude writes a description → a human approves →
the listing is handed to an existing publishing app (REST). Auth is Cognito
email-OTP. Deploy is stage-first-then-prod with isolated Terraform state per env.

Do the following and report findings — do NOT apply anything:
1. Read docs/DECISION-LOG.md and docs/ACTIVITY-LOG.md for the intended design.
2. Run `cd terraform && terraform init -backend=false && terraform validate` and
   `terraform fmt -recursive -check`. Report any errors.
3. Review every module against AWS best practices and the decision log. Flag any
   IAM grant broader than needed, any `*` exposure (CORS, security groups), any
   missing encryption/logging/tracing, and anything that fails in the SES sandbox
   or without Bedrock model access in eu-west-2.
4. Confirm the Step Functions ASL matches the Lambda I/O contracts in
   lambdas/*/index.js (payload field names line up), including the three REST
   integration Lambdas.
5. Produce a ranked punch-list of fixes before a stage deploy.
```

## Prompt B — Reconcile with the existing codebase + real REST contracts

```
Here is our existing codebase: <point Claude at the repo/path>.
Our current stack: Node.js frontend, Redis for in-journey wizard state, S3 for
uploads, 6-digit email-code login. We integrate with three internal systems over
REST: an in-house video→image agent, an upstream EPC/compliance data app, and an
existing publishing app.

Compare it against this package and:
1. Identify what we REUSE as-is (Node frontend, Redis, S3 uploads) versus what
   this package adds (Cognito email-OTP, the Step Functions pipeline, Bedrock,
   the three REST integrations, WAF, parameterized Terraform).
2. Align the three integration Lambdas to our REAL REST contracts:
   - lambdas/invoke-video-agent: match our agent's request/response (endpoint,
     auth, how it returns snapshot keys/URLs).
   - lambdas/fetch-input-data: match the upstream app's EPC/compliance endpoint
     and our shared property reference (UPRN?).
   - lambdas/publish-to-ecosystem: match the publishing app's listing-intake API.
   Update the Secrets Manager secret shapes to match (apiKey vs OAuth vs mTLS).
3. If we run Redis ourselves (not ElastiCache), remove the terraform `cache`
   module and wire the frontend to our Redis; list the changes.
4. Decide Cognito email-OTP vs keeping our home-grown login; if we keep ours,
   replace the identity module with an API Gateway Lambda authorizer validating
   our own JWT, and give me the exact files to change.
5. Keep everything deployable via `terraform apply -var-file=env/<env>.tfvars`,
   stage-first-then-prod, isolated state, eu-west-2. No second deploy system.
Output a concrete change plan (files + diffs), then implement it on a branch.
```

## Prompt C — Wire the frontend to Cognito email-OTP + the API

```
In our Node.js frontend, implement Cognito passwordless email-OTP sign-in and the
authorized API calls, using the Terraform outputs (cognito_user_pool_id,
cognito_user_pool_client_id, api_base_url).
1. Sign-in: Cognito CUSTOM_AUTH flow — initiateAuth (email) then
   respondToAuthChallenge (the 6-digit code). Store the JWT.
2. Upload: POST {api_base_url}/presign with the JWT → presigned S3 POST → upload
   the video. Validate size/duration client-side first.
3. Wizard state: keep the in-journey draft in our Redis via our backend; call
   POST /listings/submit only when the owner finishes.
4. Reviewer console: list PENDING_REVIEW listings, show the draft + snapshots +
   EPC/compliance, POST /review/decision with the JWT (requires the 'approvers'
   Cognito group).
Reference the shapes in lambdas/presign-upload/index.js,
lambdas/submit-for-review/index.js, lambdas/review-callback/index.js.
```

---

## Notes for the agent
- Region is eu-west-2 (UK). The CloudFront-scoped WAF is created in us-east-1
  (an AWS requirement) via the `aws.use1` provider alias — do not "fix" that.
- External base URLs + API keys are in Secrets Manager
  (`*-integration-video-agent`, `*-integration-input-data`,
  `*-integration-publish-app`). Never hardcode endpoints or keys.
- Node 20 Lambda runtime bundles AWS SDK v3; `./build-lambdas.sh` is only needed
  for pinned versions or extra deps.
- Never widen `bedrock:InvokeModel` to `*` or set S3 CORS to `*` — deliberate
  least-privilege decisions (DL-13).
- This app does not own video processing or publishing; those are external
  systems integrated over REST (DL-02). Do not reintroduce MediaConvert,
  Rekognition, or a per-partner publish fan-out.
```
