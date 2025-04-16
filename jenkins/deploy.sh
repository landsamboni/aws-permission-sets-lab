#!/bin/bash
set -e

export AWS_SHARED_CREDENTIALS_FILE="/var/jenkins_home/.aws/credentials"
export AWS_PROFILE=default
export AWS_REGION=us-east-1

# Parámetros
PERMISSION_SET_NAME="ReadOnlyAccessSuperman"
DESCRIPTION="This is a permission set created from Jenkins"
INSTANCE_ARN="arn:aws:sso:::instance/ssoins-7223b9ca3cca17b3"
POLICY_FILE="permission-sets/${PERMISSION_SET_NAME}.json"
STACK_NAME="PermissionSet-${PERMISSION_SET_NAME}"
TEMPLATE_FILE="templates/permission-set.yaml"

# === Validaciones previas ===
echo "🔍 Validando sintaxis del policy JSON..."
if ! jq empty "$POLICY_FILE"; then
  echo "❌ Error: El archivo JSON '$POLICY_FILE' tiene errores de sintaxis."
  exit 1
fi

echo "🔍 Validando plantilla CloudFormation con cfn-lint..."
if ! cfn-lint "$TEMPLATE_FILE"; then
  echo "❌ Error: La plantilla '$TEMPLATE_FILE' contiene errores de CloudFormation."
  exit 1
fi

echo "✅ Validaciones completadas correctamente. Continuando con el despliegue..."


# Check if stack exists and is in ROLLBACK_COMPLETE
existing_status=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].StackStatus" \
  --output text 2>/dev/null || echo "STACK_DOES_NOT_EXIST")

if [[ "$existing_status" == "ROLLBACK_COMPLETE" ]]; then
  echo "Stack $STACK_NAME is in ROLLBACK_COMPLETE. Deleting before redeploy..."
  aws cloudformation delete-stack --stack-name "$STACK_NAME"

  # Wait for deletion to complete
  echo "Waiting for stack deletion..."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
  echo "Stack deleted."
fi


aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    PermissionSetName="$PERMISSION_SET_NAME" \
    Description="$DESCRIPTION" \
    InstanceArn="$INSTANCE_ARN" \
    InlinePolicyDocument="$(< $POLICY_FILE)"

echo "✅ Deployment script completed successfully"


# === Paso 1: Obtener el Identity Store ID ===
IDENTITY_STORE_ID=$(aws sso-admin list-instances \
  --query "Instances[0].IdentityStoreId" \
  --output text | head -n1)

# === Paso 2: Crear el grupo  si no existe ===
GROUP_NAME="BatmanGroupReadOnly"

# Verificar si ya existe
GROUP_ID=$(aws identitystore list-groups \
  --identity-store-id "$IDENTITY_STORE_ID" \
  --query "Groups[?DisplayName=='$GROUP_NAME'].GroupId" \
  --output text)

if [[ -z "$GROUP_ID" ]]; then
  echo "Creating group: $GROUP_NAME"
  GROUP_ID=$(aws identitystore create-group \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --display-name "$GROUP_NAME" \
    --description "Group for ReadOnly permission set" \
    --query "GroupId" \
    --output text)
else
  echo "Group $GROUP_NAME already exists. Using existing group."
fi

# === Paso 3: Obtener el ARN del Permission Set creado ===
# Obtener todos los ARNs de permission sets
ALL_PERMISSION_SETS=$(aws sso-admin list-permission-sets \
  --instance-arn "$INSTANCE_ARN" \
  --output text --query "PermissionSets[]")

# Buscar cuál ARN corresponde al nombre del permission set deseado
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

# === Paso 4: Asignar el Permission Set al grupo en la cuenta objetivo ===
TARGET_ACCOUNT_ID="867344432024"

echo "Assigning permission set to group..."
aws sso-admin create-account-assignment \
  --instance-arn "$INSTANCE_ARN" \
  --target-id "$TARGET_ACCOUNT_ID" \
  --target-type AWS_ACCOUNT \
  --permission-set-arn "$PERMISSION_SET_ARN" \
  --principal-type GROUP \
  --principal-id "$GROUP_ID"

echo "✅ Group and permission set assignment completed"