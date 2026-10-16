#!/usr/bin/env bash
# Usage: DRY_RUN=false ./delete-default-vpcs-fixed.sh arn:aws:iam::123456789012:role/RoleName
# Default is DRY RUN.

set -uo pipefail

ROLE_ARN="${1:-}"
DRY_RUN="${DRY_RUN:-true}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

if [[ ! "$ROLE_ARN" =~ ^arn:aws:iam::([0-9]{12}):role/.+ ]]; then
  log "Usage: $0 <role-arn>"
  exit 1
fi
ACCOUNT_ID="${BASH_REMATCH[1]}"

assume_role() {
  local creds
  creds=$(aws sts assume-role \
    --role-arn "$ROLE_ARN" \
    --role-session-name "default-vpc-cleanup" \
    --duration-seconds 3600 \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>&1) || { log "!! Cannot assume role in ${ACCOUNT_ID}: ${creds}"; return 1; }
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  log "Assumed role in ${ACCOUNT_ID}"
}

get_all_regions() {
  aws ec2 describe-regions --region us-east-1 --query 'Regions[].RegionName' --output text
}

delete_default_vpc() {
  local region="$1" vpc_id eni_count
  vpc_id=$(aws ec2 describe-vpcs --region "$region" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    log "[$region] no default VPC"
    return 0
  fi

  eni_count=$(aws ec2 describe-network-interfaces --region "$region" \
    --filters Name=vpc-id,Values="$vpc_id" \
    --query 'length(NetworkInterfaces)' --output text 2>/dev/null)
  if [[ "${eni_count:-0}" != "0" ]]; then
    log "[$region] SKIP $vpc_id: ${eni_count} network interface(s) in use"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[$region] DRY RUN: would delete $vpc_id"
    return 0
  fi

  for igw in $(aws ec2 describe-internet-gateways --region "$region" \
      --filters Name=attachment.vpc-id,Values="$vpc_id" \
      --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$igw" --vpc-id "$vpc_id" &&
    aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$igw"
  done

  for subnet in $(aws ec2 describe-subnets --region "$region" \
      --filters Name=vpc-id,Values="$vpc_id" \
      --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --region "$region" --subnet-id "$subnet"
  done

  if aws ec2 delete-vpc --region "$region" --vpc-id "$vpc_id"; then
    log "[$region] Deleted $vpc_id"
  else
    log "[$region] !! FAILED to delete $vpc_id"
  fi
}

assume_role || exit 1

for region in $(get_all_regions); do
  delete_default_vpc "$region"
done
