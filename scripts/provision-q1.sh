#!/usr/bin/env bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-ttn-devops}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
REGION="$AWS_DEFAULT_REGION"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.aws-resources.env"

echo "Using profile=$AWS_PROFILE region=$REGION"

AMI_ID="$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)"
echo "AMI $AMI_ID"

VPC_ID="$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications \
  'ResourceType=vpc,Tags=[{Key=Name,Value=ttn-devops-vpc}]' \
  --query Vpc.VpcId --output text)"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
echo "VPC $VPC_ID"

SUBNET_A="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 \
  --availability-zone "${REGION}a" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ttn-devops-public-a}]' \
  --query Subnet.SubnetId --output text)"
SUBNET_B="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 \
  --availability-zone "${REGION}b" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=ttn-devops-public-b}]' \
  --query Subnet.SubnetId --output text)"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_A" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_B" --map-public-ip-on-launch
echo "Subnets $SUBNET_A $SUBNET_B"

IGW_ID="$(aws ec2 create-internet-gateway --tag-specifications \
  'ResourceType=internet-gateway,Tags=[{Key=Name,Value=ttn-devops-igw}]' \
  --query InternetGateway.InternetGatewayId --output text)"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "IGW $IGW_ID"

RT_ID="$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications \
  'ResourceType=route-table,Tags=[{Key=Name,Value=ttn-devops-public-rt}]' \
  --query RouteTable.RouteTableId --output text)"
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_A"
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_B"
echo "Route table $RT_ID"

EC2_SG="$(aws ec2 create-security-group --group-name ttn-devops-ec2-sg \
  --description "SSH and HTTP for Q1 EC2" --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=ttn-devops-ec2-sg}]' \
  --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0

ALB_SG="$(aws ec2 create-security-group --group-name ttn-devops-alb-sg \
  --description "HTTP for Q1 ALB" --vpc-id "$VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=ttn-devops-alb-sg}]' \
  --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0
echo "SGs EC2=$EC2_SG ALB=$ALB_SG"

if ! aws ec2 describe-key-pairs --key-names ttn-devops-q1 >/dev/null 2>&1; then
  mkdir -p "$HOME/.ssh"
  aws ec2 create-key-pair --key-name ttn-devops-q1 --query KeyMaterial --output text > "$HOME/.ssh/ttn-devops-q1.pem"
  chmod 400 "$HOME/.ssh/ttn-devops-q1.pem"
fi

USER_DATA="$(base64 < "$ROOT/q1/userdata.sh")"

INSTANCE_ID="$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name ttn-devops-q1 \
  --subnet-id "$SUBNET_A" \
  --security-group-ids "$EC2_SG" \
  --user-data "file://$ROOT/q1/userdata.sh" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ttn-devops-nginx}]' \
  --query 'Instances[0].InstanceId' --output text)"
echo "Instance $INSTANCE_ID"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "Public IP $PUBLIC_IP"

TG_ARN="$(aws elbv2 create-target-group \
  --name ttn-devops-tg \
  --protocol HTTP --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-path / \
  --health-check-protocol HTTP \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=$INSTANCE_ID"

ALB_ARN="$(aws elbv2 create-load-balancer \
  --name ttn-devops-alb \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --subnets "$SUBNET_A" "$SUBNET_B" \
  --security-groups "$ALB_SG" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
echo "ALB http://$ALB_DNS"

{
  echo "Q1_VPC_ID=$VPC_ID"
  echo "Q1_SUBNET_A=$SUBNET_A"
  echo "Q1_SUBNET_B=$SUBNET_B"
  echo "Q1_IGW_ID=$IGW_ID"
  echo "Q1_RT_ID=$RT_ID"
  echo "Q1_EC2_SG=$EC2_SG"
  echo "Q1_ALB_SG=$ALB_SG"
  echo "Q1_INSTANCE_ID=$INSTANCE_ID"
  echo "Q1_PUBLIC_IP=$PUBLIC_IP"
  echo "Q1_TG_ARN=$TG_ARN"
  echo "Q1_ALB_ARN=$ALB_ARN"
  echo "Q1_ALB_URL=http://$ALB_DNS"
} >> "$OUT"

echo "Waiting for target health..."
for i in $(seq 1 36); do
  STATE="$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)"
  echo "  health=$STATE"
  if [[ "$STATE" == "healthy" ]]; then
    break
  fi
  sleep 10
done
