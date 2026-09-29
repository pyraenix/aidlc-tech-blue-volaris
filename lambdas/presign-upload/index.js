// presign-upload: returns a short-lived presigned S3 PUT URL for the owner's
// video. The key prefix, content-type and max size are FIXED server-side so the
// browser cannot upload arbitrary objects anywhere. ownerId comes from the
// verified JWT (never the request body).
const { S3Client } = require("@aws-sdk/client-s3");
const { createPresignedPost } = require("@aws-sdk/s3-presigned-post");
const crypto = require("crypto");

const s3 = new S3Client({});
const RAW_BUCKET = process.env.RAW_BUCKET;
const MAX_MB = parseInt(process.env.MAX_UPLOAD_MB || "500", 10);

exports.handler = async (event) => {
  const claims = event.requestContext?.authorizer?.jwt?.claims || {};
  const ownerId = claims.sub;
  if (!ownerId) return resp(401, { error: "unauthenticated" });

  const body = JSON.parse(event.body || "{}");
  const contentType = body.contentType || "";
  if (!["video/mp4", "video/quicktime", "video/webm"].includes(contentType)) {
    return resp(400, { error: "unsupported content type" });
  }

  const listingId = crypto.randomUUID();
  const key = `listings/${listingId}/raw/upload`;

  const presigned = await createPresignedPost(s3, {
    Bucket: RAW_BUCKET,
    Key: key,
    Conditions: [
      ["content-length-range", 1, MAX_MB * 1024 * 1024],
      ["eq", "$Content-Type", contentType],
    ],
    Fields: { "Content-Type": contentType },
    Expires: 600, // 10 minutes
  });

  return resp(200, { listingId, key, upload: presigned });
};

function resp(status, obj) {
  return {
    statusCode: status,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(obj),
  };
}
