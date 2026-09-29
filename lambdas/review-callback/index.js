// review-callback: the reviewer console POSTs the decision here. Requires the
// "approvers" Cognito group (checked server-side from the JWT claim, never the
// UI). Resumes the paused Step Functions execution via the stored task token.
const {
  DynamoDBClient,
} = require("@aws-sdk/client-dynamodb");
const {
  DynamoDBDocumentClient,
  GetCommand,
  UpdateCommand,
} = require("@aws-sdk/lib-dynamodb");
const {
  SFNClient,
  SendTaskSuccessCommand,
  SendTaskFailureCommand,
} = require("@aws-sdk/client-sfn");

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sfn = new SFNClient({});
const TABLE = process.env.LISTINGS_TABLE;

exports.handler = async (event) => {
  const claims = event.requestContext?.authorizer?.jwt?.claims || {};
  const groups = parseGroups(claims["cognito:groups"]);
  if (!groups.includes("approvers")) {
    return resp(403, { error: "approver role required" });
  }

  const body = JSON.parse(event.body || "{}");
  const { listingId, decision, editedDraft, reason } = body;
  if (!listingId || !["approve", "reject"].includes(decision)) {
    return resp(400, { error: "listingId and decision (approve|reject) required" });
  }

  const item = await ddb.send(
    new GetCommand({ TableName: TABLE, Key: { PK: `LISTING#${listingId}`, SK: "META" } })
  );
  const token = item.Item?.taskToken;
  if (!token) return resp(409, { error: "no pending review for this listing" });

  if (decision === "approve") {
    // Persist any reviewer edits to the draft before resuming.
    if (editedDraft) {
      await ddb.send(
        new UpdateCommand({
          TableName: TABLE,
          Key: { PK: `LISTING#${listingId}`, SK: "META" },
          UpdateExpression: "SET draft = :d",
          ExpressionAttributeValues: { ":d": editedDraft },
        })
      );
    }
    await sfn.send(
      new SendTaskSuccessCommand({ taskToken: token, output: JSON.stringify({ approvedBy: claims.sub }) })
    );
  } else {
    await sfn.send(
      new SendTaskFailureCommand({
        taskToken: token,
        error: "ReviewRejected",
        cause: reason || "Rejected by reviewer",
      })
    );
  }

  // Clear the token so it cannot be replayed.
  await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { PK: `LISTING#${listingId}`, SK: "META" },
      UpdateExpression: "REMOVE taskToken",
    })
  );

  return resp(200, { ok: true, decision });
};

function parseGroups(g) {
  if (!g) return [];
  return Array.isArray(g) ? g : String(g).replace(/[\[\]]/g, "").split(/[\s,]+/).filter(Boolean);
}

function resp(status, obj) {
  return { statusCode: status, headers: { "content-type": "application/json" }, body: JSON.stringify(obj) };
}
