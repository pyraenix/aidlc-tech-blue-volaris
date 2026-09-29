# Runbook — Provision, Deploy, Verify, Promote

Step-by-step to stand up the onboarding component, test it in **stage**, then
promote the identical code to **prod**. Region is **eu-west-2 (London)**.
Commands assume macOS/Linux. `<env>` is `stage` or `prod`.

---

## 1. Prerequisites (once)

| Requirement | Check |
|---|---|
| Terraform ≥ 1.6 | `terraform version` |
| Node.js 20 | `node -v` |
| AWS credentials for the **target account** | `aws sts get-caller-identity` |
| AWS CLI v2 | `aws --version` |
| **SES verified sender** for the OTP email (in eu-west-2) | must match `otp_email_from` |
| **Bedrock model access** for the Claude model in **eu-west-2** | Bedrock console → Model access |
| **Reachability to the three external systems** from Lambda egress | the in-house video agent, the upstream data app, the publishing app |
| **Separate AWS accounts (recommended)** for stage and prod | blast-radius isolation |

> ⚠️ **SES sandbox:** a new SES account can only email verified addresses.
> Request production SES access before onboarding real external owners.

---

## 2. One-time: create the remote-state backends (per environment)

State lives in S3 with a DynamoDB lock table, **separate per environment**, in
eu-west-2. Run once per account:

```bash
ENV=stage   # then repeat with ENV=prod in the prod account
REGION=eu-west-2
aws s3api create-bucket --bucket techblue-tfstate-$ENV --region $REGION \
  --create-bucket-configuration LocationConstraint=$REGION
aws s3api put-bucket-versioning --bucket techblue-tfstate-$ENV \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket techblue-tfstate-$ENV \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
aws dynamodb create-table --table-name techblue-tflock-$ENV \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region $REGION
```

The backend config files already reference these names + region:
`terraform/env/stage.backend.hcl`, `terraform/env/prod.backend.hcl`.

---

## 3. Build the Lambda dependencies

The Node 20 runtime bundles AWS SDK v3, so this is optional unless you want
pinned versions. Recommended for reproducibility:

```bash
cd <package-root>
./build-lambdas.sh
```

---

## 4. Configure the environment values

Edit `terraform/env/<env>.tfvars`:
- `app_domains` — the real owner + reviewer domains (locks CORS + WAF)
- `otp_email_from` — the SES-verified sender
- `bedrock_model_id` — the enabled Claude model id
- `region` — `eu-west-2`

Never set CORS/app_domains to `*`.

---

## 5. Deploy to STAGE

```bash
cd terraform
terraform init -backend-config=env/stage.backend.hcl
terraform plan  -var-file=env/stage.tfvars -out=stage.plan
terraform apply stage.plan
```

Outputs include `api_base_url`, `owner_app_url`, `reviewer_app_url`,
`cognito_user_pool_id`, `raw_videos_bucket`, `publish_dlq_url`, and
`integration_secrets` (the three secret ARNs to populate next).

---

## 6. Populate the three integration secrets

The integration Lambdas read the external base URLs + API keys from Secrets
Manager. Set them with the real values for this environment:

```bash
PFX=techblue-stage
aws secretsmanager put-secret-value --secret-id $PFX-integration-video-agent \
  --secret-string '{"baseUrl":"https://video-agent.internal.techblue","apiKey":"REPLACE"}'
aws secretsmanager put-secret-value --secret-id $PFX-integration-input-data \
  --secret-string '{"baseUrl":"https://data-app.internal.techblue","apiKey":"REPLACE"}'
aws secretsmanager put-secret-value --secret-id $PFX-integration-publish-app \
  --secret-string '{"baseUrl":"https://publish-app.internal.techblue","apiKey":"REPLACE"}'
```

> The exact fields must match the REST contracts of each external system. The
> Lambdas expect `{ baseUrl, apiKey }`; adjust the handler + secret shape
> together if a system uses OAuth or mTLS instead of an API key.

---

## 7. Deploy the frontends + seed reviewers

```bash
# host the Node.js SPA builds (owner + reviewer)
aws s3 sync ./owner-app/dist    "s3://$(terraform output -raw owner_app_bucket)"    --delete
aws s3 sync ./reviewer-app/dist "s3://$(terraform output -raw reviewer_app_bucket)" --delete
# then invalidate the CloudFront distributions

# create a reviewer in the approvers group
POOL=$(terraform output -raw cognito_user_pool_id)
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username reviewer@techblue.example
aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" \
  --username reviewer@techblue.example --group-name approvers
```

---

## 8. Verify STAGE end-to-end

1. **Login:** open `owner_app_url`, enter an email, receive the 6-digit code via
   SES, sign in.
2. **Upload:** upload a short property video → `/presign` → S3 PUT.
3. **Pipeline:** in the Step Functions console, confirm the execution ran
   `FetchInputData` (upstream data app) → `InvokeVideoAgent` (in-house agent) →
   `GenerateDescription` (Bedrock), then paused at `SaveDraftAndRequestReview`.
4. **Review:** as the approver, see the draft + snapshots + EPC/compliance,
   click Approve → the execution resumes.
5. **Publish hand-off:** confirm `ListingApproved` fired and `publish-to-ecosystem`
   POSTed to the publishing app (CloudWatch logs). Confirm `publish_dlq_url` is
   empty.
6. **Security spot-checks:** `/presign` without a token → 401; exceed the OTP
   rate limit → WAF blocks; a cross-origin PUT from a non-`app_domains` origin is
   rejected.

Watch the CloudWatch dashboard `techblue-stage-onboarding`; the failed-execution
alarm should not be firing.

---

## 9. Promote to PROD

```bash
cd terraform
terraform init -reconfigure -backend-config=env/prod.backend.hcl
terraform plan  -var-file=env/prod.tfvars -out=prod.plan
terraform apply prod.plan
```

Then repeat steps 6–8 with prod values. Ensure SES is out of the sandbox,
Bedrock model access is enabled in the prod account/eu-west-2, and the three
integration secrets point at the **production** external endpoints.

---

## 10. Rollback / teardown

- **App deploy rollback:** re-sync the previous frontend build; Lambda code rolls
  back by re-applying the previous commit.
- **Infra rollback:** revert the Terraform change and re-apply.
- **Full teardown (non-prod only):** `terraform destroy -var-file=env/stage.tfvars`
  (empty S3 buckets first). Never destroy prod without a reviewed decision.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| OTP email never arrives | SES sandbox / unverified sender | verify sender, request prod SES access |
| `AccessDeniedException` on Bedrock | model access not enabled in eu-west-2 | enable it in the Bedrock console |
| `InvokeVideoAgent` fails | agent unreachable / contract mismatch / bad secret | check the video-agent secret + the agent's `/extract` contract |
| `FetchInputData` returns missing | upstream 404 for the property ref | confirm the shared property reference (UPRN) mapping |
| Listing not published | publishing app rejected the POST | inspect `publish-to-ecosystem` logs; check the publish-app secret + contract; failed events are in the DLQ |
| Step Functions stuck at review | no reviewer / token not sent | confirm reviewer in `approvers`, check `/review/decision` logs |
| `terraform init` backend error | state bucket/lock missing | complete §2 for that account |
