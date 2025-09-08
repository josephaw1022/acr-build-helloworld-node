#!/bin/bash
set -Eeuo pipefail

# Defaults (used only if the env var isn't set or is empty)
ACR_NAME="${ACR_NAME:-your-app-acr-registry-name}"
BASE_ACR="${BASE_ACR:-your-base-acr-registry-name}"
GIT_USER="${GIT_USER:-your-gh-username}"
GIT_PAT="${GIT_PAT:-your-gh-pat-token}"
TASK_NAME="${TASK_NAME:-your-task-name}"

missing=()
[[ -z "$ACR_NAME"  || "$ACR_NAME"  = "your-app-acr-registry-name"      ]] && missing+=("ACR_NAME")
[[ -z "$BASE_ACR"  || "$BASE_ACR"  = "your-base-acr-registry-name"      ]] && missing+=("BASE_ACR")
[[ -z "$GIT_USER"  || "$GIT_USER"  = "your-gh-username"                 ]] && missing+=("GIT_USER")
[[ -z "$GIT_PAT"   || "$GIT_PAT"   = "your-gh-pat-token"                ]] && missing+=("GIT_PAT")
[[ -z "$TASK_NAME" || "$TASK_NAME" = "your-task-name"                   ]] && missing+=("TASK_NAME")

if (( ${#missing[@]} )); then
  echo "❌ Missing or placeholder values detected:"
  for var in "${missing[@]}"; do
    # Use indirect expansion to show the variable’s value
    val="${!var}"
    echo "   - $var (current: '${val:-unset}')"
  done
  echo
  echo "👉 Please set these variables via environment variables, e.g.:"
  echo "   export ACR_NAME=myappacr"
  echo "   export BASE_ACR=baseacr"
  echo "   export GIT_USER=myuser"
  echo "   export GIT_PAT=ghp_XXXX"
  echo "   export TASK_NAME=mytask"
  echo
  exit 1
fi

echo "✅ Variables validated."
echo "   ACR_NAME=$ACR_NAME"
echo "   BASE_ACR=$BASE_ACR"
echo "   GIT_USER=$GIT_USER"
echo "   TASK_NAME=$TASK_NAME"

# Ensure the App and Base ACRs exist, create them if not
RG_NAME="quickacrtasksexercise"
LOCATION="eastus"   # change if you want a different region

echo "🔍 Checking resource group '$RG_NAME'..."
if ! az group show --name "$RG_NAME" &>/dev/null; then
  echo "⚙️  Creating resource group '$RG_NAME' in $LOCATION..."
  az group create --name "$RG_NAME" --location "$LOCATION" 1>/dev/null
  echo "✅ Resource group created."
else
  echo "✔️  Resource group '$RG_NAME' already exists."
fi

echo "🔍 Verifying Azure Container Registries..."
for acr in "$ACR_NAME" "$BASE_ACR"; do
  if az acr show --name "$acr" &>/dev/null; then
    echo "✔️  ACR '$acr' already exists."
  else
    echo "⚙️  Creating ACR '$acr' (Basic tier) in resource group '$RG_NAME'..."
    az acr create \
      --resource-group "$RG_NAME" \
      --name "$acr" \
      --sku Basic \
      --admin-enabled false
    echo "✅ Created ACR '$acr'."
  fi
done

echo "⚙️  Creating ACR task '$TASK_NAME' in registry '$ACR_NAME'..."
az acr task create \
    --registry $ACR_NAME \
    --name $TASK_NAME \
    --image helloworld:{{.Run.ID}} \
    --context https://github.com/$GIT_USER/acr-build-helloworld-node.git#master \
    --file Dockerfile-app \
    --git-access-token $GIT_PAT \
    --arg REGISTRY_NAME=$BASE_ACR.azurecr.io \
    --assign-identity
echo "✅ Task created."

echo "⏳ Waiting 10s to let task identity propagate..."
sleep 10s

echo "🔍 Fetching service principal ID for task..."
principalID=$(az acr task show --name $TASK_NAME --registry $ACR_NAME --query identity.principalId --output tsv)
echo "   principalID=$principalID"

echo "🔍 Fetching resource ID for base registry '$BASE_ACR'..."
baseregID=$(az acr show --name $BASE_ACR --query id --output tsv)
echo "   baseregID=$baseregID"

echo "⚙️  Assigning 'AcrPull' role to task principal..."
ROLE="AcrPull"
az role assignment create --assignee $principalID --scope $baseregID --role "$ROLE"
echo "✅ Role assigned."

echo "⏳ Waiting 10s before adding task credentials..."
sleep 10s

echo "⚙️  Adding credential for base ACR '$BASE_ACR' to task '$TASK_NAME'..."
az acr task credential add \
  --name $TASK_NAME \
  --registry $ACR_NAME \
  --login-server $BASE_ACR.azurecr.io \
  --use-identity [system]
echo "✅ Credential added."

echo "🎉 Script completed successfully!"
