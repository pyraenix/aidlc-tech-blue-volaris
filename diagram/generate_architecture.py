#!/usr/bin/env python3
"""
Generate the Property Onboarding architecture diagram using official AWS icons.

Renders diagram/architecture.png (and .svg via a second pass) from the real
system described in terraform/ and step-functions/onboarding.asl.json.

Run:  python3 diagram/generate_architecture.py
Deps: `pip install diagrams` and Graphviz (`dot`) on PATH.
"""
from diagrams import Diagram, Cluster, Edge

from diagrams.aws.network import CloudFront, APIGateway, VPC
from diagrams.aws.storage import SimpleStorageServiceS3 as S3
from diagrams.aws.security import SecretsManager, KMS, Guardduty, IAMRole, WAF
from diagrams.aws.database import ElasticacheForRedis, Dynamodb
from diagrams.aws.compute import Lambda
from diagrams.aws.integration import (
    Eventbridge,
    StepFunctions,
    SimpleNotificationServiceSns as SNS,
    SimpleQueueServiceSqs as SQS,
)
from diagrams.aws.ml import Bedrock
from diagrams.aws.management import Cloudwatch, Cloudtrail
from diagrams.aws.general import Users
from diagrams.onprem.client import Client
from diagrams.onprem.auth import Oauth2Proxy  # stands in for self-hosted Keycloak (OIDC IdP)

graph_attr = {
    "fontsize": "22",
    "labelloc": "t",
    "label": "Property Onboarding — Integration Component (UK ecosystem, eu-west-2)",
    "pad": "0.75",
    "nodesep": "0.6",
    "ranksep": "1.1",
    "bgcolor": "white",
    "splines": "ortho",
    "compound": "true",
}

node_attr = {"fontsize": "12"}


def rest_edge(label):
    return Edge(color="darkgreen", style="bold", label=label)


with Diagram(
    "architecture",
    filename="diagram/architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    owner = Users("Property owner")

    # --- Client & Edge -----------------------------------------------------
    with Cluster("Client & Edge"):
        cdn = CloudFront("CloudFront (OAC)\nOwner + Reviewer SPAs")
        spa_bucket = S3("S3 static hosting")
        waf = WAF("AWS WAF\nmanaged rules · rate limit")
        redis = ElasticacheForRedis("ElastiCache Redis\nin-journey draft (TTL)")
        cdn >> spa_bucket

    # --- API Layer ---------------------------------------------------------
    with Cluster("API Layer"):
        api = APIGateway("API Gateway (HTTP)\nKeycloak JWT authorizer")
        presign = Lambda("presign-upload\nshort-lived S3 PUT")
        review_cb = Lambda("review-callback\nSendTaskSuccess/Failure")
        raw_videos = S3("S3 raw-videos\nKMS · EventBridge on")
        api >> presign
        api >> review_cb
        presign >> raw_videos

    # --- Orchestration & Integration --------------------------------------
    with Cluster("Orchestration & Integration"):
        trigger_bus = Eventbridge("EventBridge\nS3 ObjectCreated → SFN")

        with Cluster("Step Functions — HITL workflow"):
            sfn = StepFunctions("State machine\n(Standard)")
            desc_fn = Lambda("generate-description\n(Bedrock payload + retry)")
            bedrock = Bedrock("Bedrock Claude\nvision → JSON")
            submit_fn = Lambda("submit-for-review\nwaitForTaskToken")

            sfn >> desc_fn >> bedrock
            sfn >> submit_fn

        # The two REST integrations are native HTTP Tasks (no Lambda); the API
        # Connections hold the x-api-key and inject it at call time.
        api_conns = Eventbridge("EventBridge API Connections\nupstream data · video agent\n(x-api-key)")

        ddb = Dynamodb("DynamoDB\nlisting state\nbyStatus · byOwner")
        owner_sns = SNS("SNS\nowner / ops notify")
        publish_secret = SecretsManager("Secrets Manager\npublishing app creds")

        trigger_bus >> sfn
        sfn >> Edge(color="gray", style="dashed") >> ddb
        sfn >> Edge(color="gray", style="dashed") >> owner_sns
        sfn >> Edge(color="firebrick", style="dotted", label="auth") >> api_conns

    # --- Publish hand-off --------------------------------------------------
    with Cluster("Publish hand-off"):
        approved_bus = Eventbridge("EventBridge\nListingApproved")
        publish_fn = Lambda("publish-to-ecosystem")
        dlq = SQS("SQS DLQ\nfailed hand-offs")
        approved_bus >> publish_fn
        publish_fn >> Edge(color="gray", style="dashed") >> dlq

    # --- External ecosystem (owned elsewhere) ------------------------------
    with Cluster("External ecosystem (owned elsewhere)"):
        keycloak = Oauth2Proxy("Keycloak (self-hosted)\nOIDC IdP · email-OTP login")
        upstream = Client("Upstream data app\nEPC / compliance (we GET)")
        video_agent = Client("In-house video→image agent\nsnapshots (we POST)")
        publishing = Client("Existing publishing app\ndistributes listing (we POST)")

    # --- Cross-cutting -----------------------------------------------------
    with Cluster("Cross-cutting"):
        cw = Cloudwatch("CloudWatch + X-Ray")
        ct = Cloudtrail("CloudTrail")
        gd = Guardduty("GuardDuty")
        kms = KMS("KMS")
        iam = IAMRole("IAM least-privilege")
        vpc = VPC("VPC (private Redis)")

    # --- Primary request path ---------------------------------------------
    owner >> cdn
    owner >> Edge(color="darkgreen", style="bold", label="OIDC login (email-OTP)") >> keycloak
    cdn >> Edge(label="wizard draft") >> redis
    owner >> Edge(label="presigned PUT (JWT)") >> api
    cdn >> waf
    raw_videos >> Edge(label="ObjectCreated") >> trigger_bus

    # API Gateway validates Keycloak-issued JWTs (fetches JWKS from the issuer)
    api >> Edge(color="darkgreen", style="dashed", label="validate JWT / JWKS") >> keycloak

    # --- Integration REST calls --------------------------------------------
    # The two upstream calls are native Step Functions HTTP Tasks (no Lambda).
    sfn >> rest_edge("HTTP Task: GET EPC/compliance") >> upstream
    sfn >> rest_edge("HTTP Task: POST video → snapshots") >> video_agent
    # Publish stays a Lambda (event-driven, own DLQ).
    publish_fn >> rest_edge("POST approved listing") >> publishing
    publish_fn << Edge(color="firebrick", style="dotted") << publish_secret

    # approval hand-off
    sfn >> Edge(label="ListingApproved") >> approved_bus
    review_cb >> Edge(color="purple", style="dashed", label="task token") >> sfn
