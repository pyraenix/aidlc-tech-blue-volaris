// invoke-video-agent: calls TechBlue's IN-HOUSE video->image agent over REST.
// We hand it the uploaded video reference; it returns the extracted snapshots
// (frame keys/URLs + any per-frame metadata). Frame extraction, snapshot
// selection and any moderation are the in-house agent's responsibility — this
// app only integrates with it. Credentials/base URL come from Secrets Manager.
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");

const secrets = new SecretsManagerClient({});
const SECRET_ID = process.env.VIDEO_AGENT_SECRET_ID; // { baseUrl, apiKey }

let cfg = null;
async function conf() {
  if (cfg) return cfg;
  const s = await secrets.send(new GetSecretValueCommand({ SecretId: SECRET_ID }));
  cfg = JSON.parse(s.SecretString);
  return cfg;
}

exports.handler = async (event) => {
  const { listingId, rawVideoKey, rawBucket } = event;
  const { baseUrl, apiKey } = await conf();

  const res = await fetch(`${baseUrl.replace(/\/$/, "")}/extract`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey },
    body: JSON.stringify({
      listingId,
      // Reference, not the bytes — the agent reads from the shared S3 location
      // it has been granted access to (or we presign; agreed per contract).
      video: { bucket: rawBucket, key: rawVideoKey },
    }),
  });

  if (!res.ok) {
    throw new Error(`video agent responded ${res.status}: ${await res.text()}`);
  }

  const body = await res.json();
  // Expected contract: { snapshots: [{ key|url, labels?, score? }, ...] }
  if (!Array.isArray(body.snapshots) || body.snapshots.length === 0) {
    throw new Error("video agent returned no snapshots");
  }

  return { snapshots: body.snapshots };
};
