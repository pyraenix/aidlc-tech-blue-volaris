// Cognito CUSTOM_AUTH: VerifyAuthChallengeResponse.
// Timing-safe compare of the submitted answer against the server-side code.
const crypto = require("crypto");

exports.handler = async (event) => {
  const expected = String(event.request.privateChallengeParameters.code || "");
  const provided = String(event.request.challengeAnswer || "");

  let ok = false;
  // Only compare when lengths match, and use a constant-time comparison so
  // response timing cannot leak how many digits were correct.
  if (expected.length === provided.length && expected.length > 0) {
    ok = crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(provided));
  }

  event.response.answerCorrect = ok;
  return event;
};
