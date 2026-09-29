// GenerateDescription: call Bedrock Claude (vision) on the snapshots returned by
// TechBlue's in-house video agent, plus the owner details and the EPC/compliance
// data fetched from the upstream app, and return a STRICT JSON listing draft.
// Retries once on JSON parse failure with a stricter instruction.
const {
  BedrockRuntimeClient,
  InvokeModelCommand,
} = require("@aws-sdk/client-bedrock-runtime");
const { S3Client, GetObjectCommand } = require("@aws-sdk/client-s3");

const bedrock = new BedrockRuntimeClient({});
const s3 = new S3Client({});
const MODEL_ID = process.env.BEDROCK_MODEL_ID;
const FRAMES_BUCKET = process.env.FRAMES_BUCKET;

// Snapshots may arrive as an S3 key (agent wrote to our bucket) or a URL.
async function toBase64(snapshot) {
  if (snapshot.key) {
    const obj = await s3.send(new GetObjectCommand({ Bucket: FRAMES_BUCKET, Key: snapshot.key }));
    const bytes = await obj.Body.transformToByteArray();
    return Buffer.from(bytes).toString("base64");
  }
  const r = await fetch(snapshot.url);
  const buf = Buffer.from(await r.arrayBuffer());
  return buf.toString("base64");
}

const SYSTEM = `You are a property-listing copywriter for a UK rental marketplace.
Use the property photos, the owner-supplied details, and the supplied EPC /
compliance data to produce a listing. Return ONLY valid JSON matching exactly:
{
  "title": string,
  "summary": string,
  "bedrooms": number,
  "bathrooms": number,
  "amenities": string[],
  "highlights": string[],
  "epc_rating": string | null,      // reflect the supplied EPC certificate if present
  "compliance_notes": string[],     // surface anything from the compliance data
  "pii_flags": string[],            // visible faces, plates, house numbers, documents
  "moderation": "pass" | "review"
}
Never invent amenities you cannot see or that the owner did not state. Set
moderation to "review" if anything is unsafe, off-brand, or contradicts the
compliance data.`;

async function invoke(images, ownerDetails, inputData, strict) {
  const content = [
    ...images.map((b64) => ({
      type: "image",
      source: { type: "base64", media_type: "image/jpeg", data: b64 },
    })),
    {
      type: "text",
      text:
        `Owner-supplied details: ${JSON.stringify(ownerDetails || {})}. ` +
        `EPC / compliance data: ${JSON.stringify(inputData || {})}.` +
        (strict ? " Your previous reply was not valid JSON. Return ONLY the JSON object." : ""),
    },
  ];

  const res = await bedrock.send(
    new InvokeModelCommand({
      modelId: MODEL_ID,
      contentType: "application/json",
      accept: "application/json",
      body: JSON.stringify({
        anthropic_version: "bedrock-2023-05-31",
        max_tokens: 1500,
        system: SYSTEM,
        messages: [{ role: "user", content }],
      }),
    })
  );
  const parsed = JSON.parse(Buffer.from(res.body).toString("utf8"));
  return parsed.content[0].text;
}

exports.handler = async (event) => {
  const { snapshots, ownerDetails, inputData } = event;
  const top = (snapshots || []).slice(0, 5);
  const images = [];
  for (const s of top) images.push(await toBase64(s));

  let text = await invoke(images, ownerDetails, inputData, false);
  let listing;
  try {
    listing = JSON.parse(text);
  } catch {
    text = await invoke(images, ownerDetails, inputData, true);
    listing = JSON.parse(text);
  }

  listing.snapshots = top.map((s) => s.key || s.url);
  return { listing };
};
