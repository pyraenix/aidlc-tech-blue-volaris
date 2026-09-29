// submit-for-review: the waitForTaskToken target. Persists the AI-generated
// draft + the task token to DynamoDB (status=PENDING_REVIEW) so the reviewer
// queue (byStatus GSI) can pick it up. Does NOT return — the execution stays
// paused until review-callback calls SendTaskSuccess/SendTaskFailure.
const {
  DynamoDBClient,
} = require("@aws-sdk/client-dynamodb");
const {
  DynamoDBDocumentClient,
  UpdateCommand,
} = require("@aws-sdk/lib-dynamodb");

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.LISTINGS_TABLE;

exports.handler = async (event) => {
  const { listingId, draft, snapshots, taskToken } = event;

  await ddb.send(
    new UpdateCommand({
      TableName: TABLE,
      Key: { PK: `LISTING#${listingId}`, SK: "META" },
      UpdateExpression:
        "SET #s = :s, draft = :d, snapshots = :snap, taskToken = :t, updatedAt = :u",
      ExpressionAttributeNames: { "#s": "status" },
      ExpressionAttributeValues: {
        ":s": "PENDING_REVIEW",
        ":d": draft,
        ":snap": snapshots,
        ":t": taskToken,
        ":u": new Date().toISOString(),
      },
    })
  );

  // Intentionally no return value / no SendTaskSuccess here — the reviewer does that.
  return {};
};
