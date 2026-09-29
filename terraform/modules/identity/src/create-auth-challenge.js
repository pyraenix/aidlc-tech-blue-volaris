// Cognito CUSTOM_AUTH: CreateAuthChallenge.
// Generates a cryptographically-random 6-digit code, emails it via SES, and
// stashes it in privateChallengeParameters (never returned to the client).
const crypto = require("crypto");
const { SESClient, SendEmailCommand } = require("@aws-sdk/client-ses");

const ses = new SESClient({});
const FROM = process.env.OTP_FROM;
const TTL = parseInt(process.env.OTP_TTL_SECONDS || "300", 10);

function sixDigitCode() {
  // crypto.randomInt is a CSPRNG — never Math.random().
  return crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
}

exports.handler = async (event) => {
  let code;
  if (event.request.session && event.request.session.length > 0) {
    // Re-issue the SAME code on a retry within one auth session, so retries
    // do not expand the set of valid codes.
    const prev = event.request.session[event.request.session.length - 1];
    code = prev.challengeMetadata ? prev.challengeMetadata.replace("CODE-", "") : sixDigitCode();
  } else {
    code = sixDigitCode();
  }

  const email = event.request.userAttributes.email;

  await ses.send(
    new SendEmailCommand({
      Source: FROM,
      Destination: { ToAddresses: [email] },
      Message: {
        Subject: { Data: "Your TechBlue verification code" },
        Body: {
          Text: {
            Data: `Your verification code is ${code}. It expires in ${Math.round(
              TTL / 60
            )} minutes. If you did not request this, ignore this email.`,
          },
        },
      },
    })
  );

  // Server-side only. The client only sees publicChallengeParameters.
  event.response.privateChallengeParameters = { code };
  event.response.publicChallengeParameters = { email };
  event.response.challengeMetadata = `CODE-${code}`;
  return event;
};
