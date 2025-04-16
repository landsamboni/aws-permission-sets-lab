#!/bin/bash
set -e

# Parámetros
PERMISSION_SET_NAME="ReadOnlyAccess"
DESCRIPTION="Lab permission set"
INSTANCE_ARN="arn:aws:sso:::instance/ssoins-7223b9ca3cca17b3"
POLICY_FILE="permission-sets/${PERMISSION_SET_NAME}.json"
STACK_NAME="PermissionSet-${PERMISSION_SET_NAME}"
TEMPLATE_FILE="templates/permission-set.yaml"

# Deploy con CloudFormation
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    PermissionSetName="$PERMISSION_SET_NAME" \
    Description="$DESCRIPTION" \
    InstanceArn="$INSTANCE_ARN" \
    InlinePolicyDocument="$(< $POLICY_FILE)"