#!/bin/bash
set -e

export AWS_SHARED_CREDENTIALS_FILE="/var/jenkins_home/.aws/credentials"
export AWS_PROFILE=default
export AWS_REGION=us-east-1

# Parámetros
PERMISSION_SET_NAME="ReadOnlyAccess"
DESCRIPTION="Lab permission set"
INSTANCE_ARN="arn:aws:sso:::instance/ssoins-xxxxxxxxxxxxxxx"
POLICY_FILE="permission-sets/${PERMISSION_SET_NAME}.json"
STACK_NAME="PermissionSet-${PERMISSION_SET_NAME}"
TEMPLATE_FILE="templates/permission-set.yaml"

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    PermissionSetName="$PERMISSION_SET_NAME" \
    Description="$DESCRIPTION" \
    InstanceArn="$INSTANCE_ARN" \
    InlinePolicyDocument="$(< $POLICY_FILE)"