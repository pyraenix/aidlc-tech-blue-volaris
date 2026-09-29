// publish-to-ecosystem: on approval, sends the finished listing to TechBlue's
// EXISTING publishing application over REST. That app owns the downstream
// distribution to rental sites — this app is only the onboarding component that
// hands off the approved, reviewed listing. Idempotency key prevents a retry
// double-publishing on their side. Base URL + credentials from Secrets Manager.
const {
  DynamoDBClient,
} = require("@aws-sdk/client-dynamodb");
const {
  DynamoDBDocumentClient,
  GetCommand,
  UpdateCommand,
} = require("@aws-sdk/lib-dynamodb");
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const secrets = new SecretsManagerClient({});
const TABLE = process.env.LISTINGS_TABLE;
const SECRET_ID = process.env.PUBLISH_APP_SECRET_ID; // { baseUrl, apiKey }

let cfg = null;
async function conf() {
  if (cfg) return cfg;
  const s = await secrets.send(new GetSecretValueCommand({ SecretId: SECRET_ID }));
  cfg = JSON.parse(s.SecretString);
  return cfg;
}

// Triggered by EventBridge (ListingApproved). One retry path via the target's
// own retry policy + DLQ configured in Terraform.
exports.handler = async (event) => {
  const detail = event.detail || event;
  const listingId = detail.listingId;

  const item = await ddb.send(
    new GetCommand({ TableName: TABLE, Key: { PK: `LISTING#${listingId}`, SK: "META" } })
  );
  if (!item.Item) throw new Error(`listing ${listingId} not found`);

  const { baseUrl, apiKey } = await conf();
  const res = await fetch(`${baseUrl.replace(/\/$/, "")}/listings`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey },
    body: JSON.stringify({
      idempotencyKey: listingId,
      listing: item.Item.draft,
      snapshots: item.Item.snapshots,
      compliance: item.Item.inputData || null,
    }),
  });

  if (!res.ok) {
    throw new Error(`publishing app responded ${res.status}: ${await res.text()}`);
  }

  // Record the successful hand-off for audit.
  await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { PK: `LISTING#${listingId}`, SK: "META" },
      UpdateExpression: "SET #s = :s, publishedAt = :t",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: { ":s": "PUBLISHED", ":t": new Date().toISOString() },
    })
  );

  return { ok: true };
};
