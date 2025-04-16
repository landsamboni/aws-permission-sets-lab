#!/bin/bash
set -e

export AWS_SHARED_CREDENTIALS_FILE="/var/jenkins_home/.aws/credentials"
export AWS_PROFILE=default
export AWS_REGION=us-east-1

CONFIG_FILE="config/sets.yaml"
TEMPLATE_FILE="templates/permission-set.yaml"
INSTANCE_ARN="arn:aws:sso:::instance/ssoins-7223b9ca3cca17b3"

# Obtener Identity Store ID
IDENTITY_STORE_ID=$(aws sso-admin list-instances \
  --query "Instances[0].IdentityStoreId" \
  --output text | head -n1)

# Validar y procesar cada permission set
yq e -o=json '.permission_sets[]' "$CONFIG_FILE" | jq -c '.' | while read -r item; do
  PERMISSION_SET_NAME=$(echo "$item" | jq -r '.name')
  DESCRIPTION=$(echo "$item" | jq -r '.description')
  POLICY_FILE_NAME=$(echo "$item" | jq -r '.policy_file')
  GROUP_NAME=$(echo "$item" | jq -r '.group')
  ACCOUNTS=$(echo "$item" | jq -r '.accounts[]')
  SESSION_DURATION=$(echo "$item" | jq -r '.session_duration // "PT8H"')
  MANAGED_POLICIES=$(echo "$item" | jq -r '.managed_policies // empty' | jq -Rs 'split("\n") | map(select(length > 0)) | join(",")')

  POLICY_FILE="permission-sets/$POLICY_FILE_NAME"
  STACK_NAME="PermissionSet-$PERMISSION_SET_NAME"

  echo "🔍 Validando sintaxis del policy JSON ($POLICY_FILE)..."
  if ! jq empty "$POLICY_FILE"; then
    echo "❌ Error: El archivo JSON '$POLICY_FILE' tiene errores de sintaxis."
    exit 1
  fi

  echo "🔍 Validando plantilla CloudFormation con cfn-lint..."
  if ! cfn-lint "$TEMPLATE_FILE"; then
    echo "❌ Error: La plantilla '$TEMPLATE_FILE' contiene errores de CloudFormation."
    exit 1
  fi

  echo "✅ Validaciones completadas para $PERMISSION_SET_NAME"

  # Verificar stack en ROLLBACK_COMPLETE.
  existing_status=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "STACK_DOES_NOT_EXIST")

  if [[ "$existing_status" == "ROLLBACK_COMPLETE" ]]; then
    echo "Stack $STACK_NAME is in ROLLBACK_COMPLETE. Deleting..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
  fi

  DEPLOY_COMMAND=(
    aws cloudformation deploy
    --stack-name "$STACK_NAME"
    --template-file "$TEMPLATE_FILE"
    --capabilities CAPABILITY_NAMED_IAM
    --parameter-overrides
      PermissionSetName="$PERMISSION_SET_NAME"
      Description="$DESCRIPTION"
      InstanceArn="$INSTANCE_ARN"
      InlinePolicyDocument="$(< $POLICY_FILE)"
      SessionDuration="$SESSION_DURATION"
  )

  if [[ -n "$MANAGED_POLICIES" ]]; then
    DEPLOY_COMMAND+=(ManagedPolicies="$MANAGED_POLICIES")
  fi

  "${DEPLOY_COMMAND[@]}"

  echo "✅ Stack $STACK_NAME deployed"

  # Crear grupo si no existe
  GROUP_ID=$(aws identitystore list-groups \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --query "Groups[?DisplayName=='$GROUP_NAME'].GroupId" \
    --output text)

  if [[ -z "$GROUP_ID" ]]; then
    echo "Creating group: $GROUP_NAME"
    GROUP_ID=$(aws identitystore create-group \
      --identity-store-id "$IDENTITY_STORE_ID" \
      --display-name "$GROUP_NAME" \
      --description "Group for $PERMISSION_SET_NAME permission set" \
      --query "GroupId" \
      --output text)
  else
    echo "Group $GROUP_NAME already exists."
  fi

  # Obtener ARN del permission set
  ALL_PERMISSION_SETS=$(aws sso-admin list-permission-sets \
    --instance-arn "$INSTANCE_ARN" \
    --output text --query "PermissionSets[]")

  for arn in $ALL_PERMISSION_SETS; do
    name=$(aws sso-admin describe-permission-set \
      --instance-arn "$INSTANCE_ARN" \
      --permission-set-arn "$arn" \
      --query "PermissionSet.Name" \
      --output text)

    if [[ "$name" == "$PERMISSION_SET_NAME" ]]; then
      PERMISSION_SET_ARN="$arn"
      break
    fi
  done

  if [[ -z "$PERMISSION_SET_ARN" ]]; then
    echo "❌ Error: Permission Set '$PERMISSION_SET_NAME' not found."
    exit 1
  fi

  # Asignar a cada cuenta
  echo "$ACCOUNTS" | while read -r ACCOUNT_ID; do
    echo "Assigning $PERMISSION_SET_NAME to $GROUP_NAME in account $ACCOUNT_ID..."
    aws sso-admin create-account-assignment \
      --instance-arn "$INSTANCE_ARN" \
      --target-id "$ACCOUNT_ID" \
      --target-type AWS_ACCOUNT \
      --permission-set-arn "$PERMISSION_SET_ARN" \
      --principal-type GROUP \
      --principal-id "$GROUP_ID"
  done

  echo "✅ Completed: $PERMISSION_SET_NAME + $GROUP_NAME"
done