#!/usr/bin/env bash
set -euo pipefail

# Run after AWS Support verifies the account for CloudFront.
export AWS_PROFILE="${AWS_PROFILE:-ttn-devops}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
REGION="$AWS_DEFAULT_REGION"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="ttn-devops-website-${ACCOUNT}"

OAC_ID="$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='ttn-devops-oac'].Id | [0]" --output text)"
if [[ -z "$OAC_ID" || "$OAC_ID" == "None" ]]; then
  OAC_ID="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "{
      \"Name\": \"ttn-devops-oac\",
      \"Description\": \"OAC for assignment website\",
      \"SigningProtocol\": \"sigv4\",
      \"SigningBehavior\": \"always\",
      \"OriginAccessControlOriginType\": \"s3\"
    }" --query 'OriginAccessControl.Id' --output text)"
fi

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

aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(cat <<EOF
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
    },
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    }
  ]
}
EOF
)"

printf '%s' "$DIST_ID" | gh secret set CLOUDFRONT_DISTRIBUTION_ID
echo "Set GitHub secret CLOUDFRONT_DISTRIBUTION_ID"
echo "Waiting for CloudFront Deployed..."
aws cloudfront wait distribution-deployed --id "$DIST_ID"
echo "Submit: https://$DIST_DOMAIN"
