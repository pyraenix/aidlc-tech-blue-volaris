// fetch-input-data: pulls the property's regulatory/compliance inputs (EPC
// certificate, compliance data, etc.) from the UPSTREAM app in the ecosystem
// over REST. Called during the pipeline so the description + review have the
// authoritative data. Base URL + credentials from Secrets Manager.
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require("@aws-sdk/client-secrets-manager");

const secrets = new SecretsManagerClient({});
const SECRET_ID = process.env.INPUT_DATA_SECRET_ID; // { baseUrl, apiKey }

let cfg = null;
async function conf() {
  if (cfg) return cfg;
  const s = await secrets.send(new GetSecretValueCommand({ SecretId: SECRET_ID }));
  cfg = JSON.parse(s.SecretString);
  return cfg;
}

exports.handler = async (event) => {
  const { listingId, propertyRef } = event;
  const { baseUrl, apiKey } = await conf();

  // propertyRef is the shared identifier the ecosystem uses for this property
  // (e.g. UPRN in the UK). Falls back to listingId if not supplied.
  const ref = propertyRef || listingId;

  const res = await fetch(
    `${baseUrl.replace(/\/$/, "")}/properties/${encodeURIComponent(ref)}/compliance`,
    { method: "GET", headers: { "x-api-key": apiKey, accept: "application/json" } }
  );

  if (res.status === 404) {
    // No upstream record yet — proceed with empty inputs (reviewer will flag).
    return { inputData: { epc: null, compliance: null, missing: true } };
  }
  if (!res.ok) {
    throw new Error(`input-data app responded ${res.status}: ${await res.text()}`);
  }

  const body = await res.json();
  // Expected contract: { epc: {...}, compliance: {...} }
  return { inputData: { epc: body.epc || null, compliance: body.compliance || null, missing: false } };
};
