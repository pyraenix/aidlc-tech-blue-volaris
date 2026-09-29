// Cognito CUSTOM_AUTH: DefineAuthChallenge.
// Drives the challenge state machine. One CUSTOM_CHALLENGE (the 6-digit code).
// Cognito itself enforces the 3-attempt cap: after 3 failed answers it fails
// the auth session and the user must request a new code.
exports.handler = async (event) => {
  const { session } = event.request;

  if (session.length === 0) {
    // First call — issue the code challenge.
    event.response.issueTokens = false;
    event.response.failAuthentication = false;
    event.response.challengeName = "CUSTOM_CHALLENGE";
  } else if (
    session.length > 0 &&
    session[session.length - 1].challengeName === "CUSTOM_CHALLENGE" &&
    session[session.length - 1].challengeResult === true
  ) {
    // Correct code — issue tokens.
    event.response.issueTokens = true;
    event.response.failAuthentication = false;
  } else if (session.length >= 3) {
    // 3 wrong answers — fail the whole auth session. New code required.
    event.response.issueTokens = false;
    event.response.failAuthentication = true;
  } else {
    // Wrong so far, attempts remain — re-issue the same challenge.
    event.response.issueTokens = false;
    event.response.failAuthentication = false;
    event.response.challengeName = "CUSTOM_CHALLENGE";
  }
  return event;
};
