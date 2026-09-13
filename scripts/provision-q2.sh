#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-ttn-devops}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
REGION="$AWS_DEFAULT_REGION"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="ttn-devops-website-${ACCOUNT}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.aws-resources.env"

echo "Creating bucket $BUCKET in $REGION"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

OAC_ID="$(aws cloudfront create-origin-access-control \
  --origin-access-control-config "{
    \"Name\": \"ttn-devops-oac\",
    \"Description\": \"OAC for assignment website\",
    \"SigningProtocol\": \"sigv4\",
    \"SigningBehavior\": \"always\",
    \"OriginAccessControlOriginType\": \"s3\"
  }" --query 'OriginAccessControl.Id' --output text 2>/dev/null || true)"

if [[ -z "$OAC_ID" || "$OAC_ID" == "None" ]]; then
  OAC_ID="$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='ttn-devops-oac'].Id | [0]" --output text)"
fi
echo "OAC $OAC_ID"

aws s3 sync "$ROOT" "s3://$BUCKET" --exclude "*" --include "index.html" --include "styles.css" --include "script.js"

CALLER_REF="ttn-devops-$(date +%s)"
DIST_CONFIG="$(mktemp)"
cat > "$DIST_CONFIG" <<EOF
{
  "CallerReference": "$CALLER_REF",
  "Comment": "TTN DevOps assignment website",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "s3-origin",
        "DomainName": "${BUCKET}.s3.${REGION}.amazonaws.com",
        "S3OriginConfig": { "OriginAccessIdentity": "" },
        "OriginAccessControlId": "${OAC_ID}"
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["HEAD", "GET"],
      "CachedMethods": { "Quantity": 2, "Items": ["HEAD", "GET"] }
    },
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "TrustedSigners": { "Enabled": false, "Quantity": 0 }
  },
  "PriceClass": "PriceClass_100"
}
EOF

DIST_ID="$(aws cloudfront create-distribution --distribution-config "file://$DIST_CONFIG" --query 'Distribution.Id' --output text)"
DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text)"
echo "CloudFront $DIST_ID https://$DIST_DOMAIN"

ACCOUNT_ARN="arn:aws:iam::${ACCOUNT}:root"
cat > /tmp/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontOAC",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT}:distribution/${DIST_ID}"
        }
      }
    }
  ]
}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/bucket-policy.json

{
  echo "Q2_BUCKET=$BUCKET"
  echo "Q2_OAC_ID=$OAC_ID"
  echo "Q2_CF_ID=$DIST_ID"
  echo "Q2_CF_URL=https://$DIST_DOMAIN"
} >> "$OUT"

echo "Waiting for CloudFront to become Deployed (this can take several minutes)..."
aws cloudfront wait distribution-deployed --id "$DIST_ID"
echo "CloudFront deployed: https://$DIST_DOMAIN"
