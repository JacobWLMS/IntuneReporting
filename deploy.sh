#!/bin/bash
#
# Intune Reporting - One-Command Deployment
#
# Usage: ./deploy.sh
#
# This script deploys everything you need:
#   - Resource Group
#   - Log Analytics Workspace
#   - Data Collection Endpoint & Rule
#   - Function App with all export functions
#   - App Registration for Microsoft Graph access
#
set -e

#######################################
# Configuration - EDIT THESE VALUES
#######################################
RESOURCE_GROUP="rg-intune-reporting"
LOCATION="eastus"
PREFIX="intune"  # Used to generate unique names

# Generate unique suffix from subscription ID
UNIQUE_SUFFIX=""

#######################################
# Colors for output
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#######################################
# Check prerequisites
#######################################
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check az cli
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI (az) is not installed."
        echo "Install it from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    # Check func core tools
    if ! command -v func &> /dev/null; then
        log_error "Azure Functions Core Tools (func) is not installed."
        echo "Install it from: https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local"
        echo ""
        echo "Quick install:"
        echo "  macOS:   brew tap azure/functions && brew install azure-functions-core-tools@4"
        echo "  Ubuntu:  curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg && sudo mv microsoft.gpg /etc/apt/trusted.gpg.d/ && sudo sh -c 'echo \"deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-ubuntu-\$(lsb_release -cs)-prod \$(lsb_release -cs) main\" > /etc/apt/sources.list.d/dotnetdev.list' && sudo apt-get update && sudo apt-get install azure-functions-core-tools-4"
        echo "  Windows: winget install Microsoft.Azure.FunctionsCoreTools"
        exit 1
    fi

    # Check logged in
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure CLI."
        echo "Run: az login"
        exit 1
    fi

    log_success "Prerequisites OK"
}

#######################################
# Generate unique names
#######################################
generate_names() {
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    UNIQUE_SUFFIX=$(echo -n "$SUBSCRIPTION_ID" | md5sum | head -c 8)

    STORAGE_ACCOUNT="${PREFIX}stor${UNIQUE_SUFFIX}"
    FUNCTION_APP="${PREFIX}-func-${UNIQUE_SUFFIX}"
    LOG_ANALYTICS_WORKSPACE="${PREFIX}-law-${UNIQUE_SUFFIX}"
    DCE_NAME="${PREFIX}-dce-${UNIQUE_SUFFIX}"
    DCR_NAME="${PREFIX}-dcr-${UNIQUE_SUFFIX}"
    APP_REGISTRATION_NAME="intune-reporting-${UNIQUE_SUFFIX}"

    log_info "Generated resource names:"
    echo "  Resource Group:     $RESOURCE_GROUP"
    echo "  Storage Account:    $STORAGE_ACCOUNT"
    echo "  Function App:       $FUNCTION_APP"
    echo "  Log Analytics:      $LOG_ANALYTICS_WORKSPACE"
    echo "  DCE:                $DCE_NAME"
    echo "  DCR:                $DCR_NAME"
}

#######################################
# Create Resource Group
#######################################
create_resource_group() {
    log_info "Creating resource group..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none
    log_success "Resource group created"
}

#######################################
# Create Storage Account (required for Functions)
#######################################
create_storage_account() {
    log_info "Creating storage account..."
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --output none
    log_success "Storage account created"
}

#######################################
# Create Log Analytics Workspace
#######################################
create_log_analytics() {
    log_info "Creating Log Analytics workspace..."

    az monitor log-analytics workspace create \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
        --location "$LOCATION" \
        --retention-time 90 \
        --output none

    WORKSPACE_ID=$(az monitor log-analytics workspace show \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
        --query customerId -o tsv)

    WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace show \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
        --query id -o tsv)

    log_success "Log Analytics workspace created (ID: $WORKSPACE_ID)"
}

#######################################
# Create custom tables in Log Analytics
#######################################
create_custom_tables() {
    log_info "Creating custom tables..."

    # Table definitions
    declare -A TABLES
    TABLES["IntuneDevices_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"DeviceId","type":"string"},{"name":"DeviceName","type":"string"},{"name":"UserPrincipalName","type":"string"},{"name":"UserDisplayName","type":"string"},{"name":"OperatingSystem","type":"string"},{"name":"OSVersion","type":"string"},{"name":"ComplianceState","type":"string"},{"name":"ManagementState","type":"string"},{"name":"EnrolledDateTime","type":"datetime"},{"name":"LastSyncDateTime","type":"datetime"},{"name":"Manufacturer","type":"string"},{"name":"Model","type":"string"},{"name":"SerialNumber","type":"string"},{"name":"IsEncrypted","type":"boolean"},{"name":"AutopilotEnrolled","type":"boolean"},{"name":"TotalStorageGB","type":"real"},{"name":"FreeStorageGB","type":"real"}'

    TABLES["IntuneCompliancePolicies_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"PolicyId","type":"string"},{"name":"PolicyName","type":"string"},{"name":"Description","type":"string"},{"name":"PolicyType","type":"string"},{"name":"CreatedDateTime","type":"datetime"},{"name":"LastModifiedDateTime","type":"datetime"}'

    TABLES["IntuneComplianceStates_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"DeviceId","type":"string"},{"name":"DeviceName","type":"string"},{"name":"UserId","type":"string"},{"name":"UserPrincipalName","type":"string"},{"name":"PolicyId","type":"string"},{"name":"PolicyName","type":"string"},{"name":"Status","type":"string"},{"name":"StatusRaw","type":"int"},{"name":"SettingCount","type":"int"},{"name":"FailedSettingCount","type":"int"}'

    TABLES["IntuneDeviceScores_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"DeviceId","type":"string"},{"name":"DeviceName","type":"string"},{"name":"Model","type":"string"},{"name":"Manufacturer","type":"string"},{"name":"HealthStatus","type":"string"},{"name":"EndpointAnalyticsScore","type":"real"},{"name":"StartupPerformanceScore","type":"real"},{"name":"AppReliabilityScore","type":"real"},{"name":"WorkFromAnywhereScore","type":"real"}'

    TABLES["IntuneStartupPerformance_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"DeviceId","type":"string"},{"name":"StartTime","type":"datetime"},{"name":"CoreBootTimeInMs","type":"int"},{"name":"GroupPolicyBootTimeInMs","type":"int"},{"name":"TotalBootTimeInMs","type":"int"},{"name":"TotalLoginTimeInMs","type":"int"},{"name":"IsFirstLogin","type":"boolean"},{"name":"IsFeatureUpdate","type":"boolean"}'

    TABLES["IntuneAppReliability_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"AppName","type":"string"},{"name":"AppDisplayName","type":"string"},{"name":"AppPublisher","type":"string"},{"name":"ActiveDeviceCount","type":"int"},{"name":"AppCrashCount","type":"int"},{"name":"AppHangCount","type":"int"},{"name":"MeanTimeToFailureInMinutes","type":"int"}'

    TABLES["IntuneAutopilotDevices_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"AutopilotDeviceId","type":"string"},{"name":"SerialNumber","type":"string"},{"name":"Manufacturer","type":"string"},{"name":"Model","type":"string"},{"name":"GroupTag","type":"string"},{"name":"EnrollmentState","type":"string"},{"name":"DeploymentProfileAssignmentStatus","type":"string"},{"name":"LastContactedDateTime","type":"datetime"},{"name":"UserPrincipalName","type":"string"}'

    TABLES["IntuneAutopilotProfiles_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"ProfileId","type":"string"},{"name":"DisplayName","type":"string"},{"name":"Description","type":"string"},{"name":"CreatedDateTime","type":"datetime"},{"name":"LastModifiedDateTime","type":"datetime"},{"name":"DeviceNameTemplate","type":"string"},{"name":"ProfileType","type":"string"}'

    TABLES["IntuneSyncState_CL"]='{"name":"TimeGenerated","type":"datetime"},{"name":"IngestionTime","type":"datetime"},{"name":"SourceSystem","type":"string"},{"name":"ExportType","type":"string"},{"name":"RecordCount","type":"int"},{"name":"Status","type":"string"},{"name":"DurationSeconds","type":"real"},{"name":"ErrorMessage","type":"string"}'

    for TABLE_NAME in "${!TABLES[@]}"; do
        log_info "  Creating table: $TABLE_NAME"
        COLUMNS="${TABLES[$TABLE_NAME]}"

        az monitor log-analytics workspace table create \
            --resource-group "$RESOURCE_GROUP" \
            --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
            --name "$TABLE_NAME" \
            --columns "$COLUMNS" \
            --output none 2>/dev/null || log_warn "  Table $TABLE_NAME may already exist"
    done

    log_success "Custom tables created"
}

#######################################
# Create Data Collection Endpoint
#######################################
create_dce() {
    log_info "Creating Data Collection Endpoint..."

    az monitor data-collection endpoint create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DCE_NAME" \
        --location "$LOCATION" \
        --public-network-access Enabled \
        --output none

    DCE_ENDPOINT=$(az monitor data-collection endpoint show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DCE_NAME" \
        --query logsIngestion.endpoint -o tsv)

    DCE_RESOURCE_ID=$(az monitor data-collection endpoint show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DCE_NAME" \
        --query id -o tsv)

    log_success "DCE created: $DCE_ENDPOINT"
}

#######################################
# Create Data Collection Rule
#######################################
create_dcr() {
    log_info "Creating Data Collection Rule..."

    # Build stream declarations and data flows for all tables
    STREAM_DECLARATIONS=""
    DATA_FLOWS=""

    declare -a TABLE_NAMES=(
        "IntuneDevices_CL"
        "IntuneCompliancePolicies_CL"
        "IntuneComplianceStates_CL"
        "IntuneDeviceScores_CL"
        "IntuneStartupPerformance_CL"
        "IntuneAppReliability_CL"
        "IntuneAutopilotDevices_CL"
        "IntuneAutopilotProfiles_CL"
        "IntuneSyncState_CL"
    )

    for i in "${!TABLE_NAMES[@]}"; do
        TABLE="${TABLE_NAMES[$i]}"
        STREAM="Custom-${TABLE}"

        if [ $i -gt 0 ]; then
            STREAM_DECLARATIONS+=","
            DATA_FLOWS+=","
        fi

        STREAM_DECLARATIONS+="\"$STREAM\":{\"columns\":[{\"name\":\"TimeGenerated\",\"type\":\"datetime\"},{\"name\":\"RawData\",\"type\":\"string\"}]}"
        DATA_FLOWS+="{\"streams\":[\"$STREAM\"],\"destinations\":[\"logAnalytics\"],\"transformKql\":\"source\",\"outputStream\":\"$STREAM\"}"
    done

    # Create DCR JSON
    DCR_JSON=$(cat <<EOF
{
    "location": "$LOCATION",
    "properties": {
        "dataCollectionEndpointId": "$DCE_RESOURCE_ID",
        "streamDeclarations": {$STREAM_DECLARATIONS},
        "destinations": {
            "logAnalytics": [{
                "workspaceResourceId": "$WORKSPACE_RESOURCE_ID",
                "name": "logAnalytics"
            }]
        },
        "dataFlows": [$DATA_FLOWS]
    }
}
EOF
)

    # Create DCR via REST API (more reliable for complex DCRs)
    az rest --method PUT \
        --uri "https://management.azure.com${WORKSPACE_RESOURCE_ID%/*}/providers/Microsoft.Insights/dataCollectionRules/${DCR_NAME}?api-version=2022-06-01" \
        --body "$DCR_JSON" \
        --output none 2>/dev/null || {
            # Fallback: Try simpler creation
            log_warn "Complex DCR creation failed, trying simplified version..."
            az monitor data-collection rule create \
                --resource-group "$RESOURCE_GROUP" \
                --name "$DCR_NAME" \
                --location "$LOCATION" \
                --data-collection-endpoint-id "$DCE_RESOURCE_ID" \
                --output none 2>/dev/null || log_warn "DCR may need manual configuration"
        }

    DCR_ID=$(az monitor data-collection rule show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DCR_NAME" \
        --query immutableId -o tsv 2>/dev/null || echo "")

    if [ -z "$DCR_ID" ]; then
        log_warn "Could not get DCR ID - you may need to configure it manually in Azure Portal"
    else
        log_success "DCR created: $DCR_ID"
    fi
}

#######################################
# Create Function App
#######################################
create_function_app() {
    log_info "Creating Function App (Flex Consumption)..."

    # Try Flex Consumption first (modern), fall back to legacy if region doesn't support it
    if az functionapp create \
        --resource-group "$RESOURCE_GROUP" \
        --flexconsumption-location "$LOCATION" \
        --runtime python \
        --runtime-version 3.11 \
        --name "$FUNCTION_APP" \
        --storage-account "$STORAGE_ACCOUNT" \
        --output none 2>/dev/null; then
        log_success "Function App created (Flex Consumption): $FUNCTION_APP"
    else
        log_warn "Flex Consumption not available in $LOCATION, using legacy Consumption plan"
        az functionapp create \
            --resource-group "$RESOURCE_GROUP" \
            --consumption-plan-location "$LOCATION" \
            --runtime python \
            --runtime-version 3.11 \
            --functions-version 4 \
            --name "$FUNCTION_APP" \
            --storage-account "$STORAGE_ACCOUNT" \
            --os-type Linux \
            --output none
        log_success "Function App created (Consumption): $FUNCTION_APP"
    fi
}

#######################################
# Create App Registration for Graph API
#######################################
create_app_registration() {
    log_info "Creating App Registration for Microsoft Graph access..."

    # Check if app already exists
    EXISTING_APP=$(az ad app list --display-name "$APP_REGISTRATION_NAME" --query "[0].appId" -o tsv 2>/dev/null)

    if [ -n "$EXISTING_APP" ]; then
        log_info "App Registration already exists, using existing: $EXISTING_APP"
        APP_CLIENT_ID="$EXISTING_APP"
    else
        # Create app registration
        APP_CLIENT_ID=$(az ad app create \
            --display-name "$APP_REGISTRATION_NAME" \
            --query appId -o tsv)

        # Create service principal
        az ad sp create --id "$APP_CLIENT_ID" --output none 2>/dev/null || true
    fi

    # Create client secret
    APP_CLIENT_SECRET=$(az ad app credential reset \
        --id "$APP_CLIENT_ID" \
        --display-name "intune-reporting-secret" \
        --years 2 \
        --query password -o tsv)

    TENANT_ID=$(az account show --query tenantId -o tsv)

    log_success "App Registration created"
    log_info "Client ID: $APP_CLIENT_ID"

    # Note about Graph API permissions
    echo ""
    log_warn "IMPORTANT: You must grant Microsoft Graph API permissions manually:"
    echo "  1. Go to Azure Portal > App Registrations > $APP_REGISTRATION_NAME"
    echo "  2. Go to API Permissions > Add a permission > Microsoft Graph > Application permissions"
    echo "  3. Add these permissions:"
    echo "     - DeviceManagementManagedDevices.Read.All"
    echo "     - DeviceManagementConfiguration.Read.All"
    echo "     - DeviceManagementServiceConfig.Read.All"
    echo "  4. Click 'Grant admin consent'"
    echo ""
}

#######################################
# Configure Function App settings
#######################################
configure_function_app() {
    log_info "Configuring Function App settings..."

    az functionapp config appsettings set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNCTION_APP" \
        --settings \
            "AZURE_TENANT_ID=$TENANT_ID" \
            "AZURE_CLIENT_ID=$APP_CLIENT_ID" \
            "AZURE_CLIENT_SECRET=$APP_CLIENT_SECRET" \
            "ANALYTICS_BACKEND=LogAnalytics" \
            "LOG_ANALYTICS_DCE=$DCE_ENDPOINT" \
            "LOG_ANALYTICS_DCR_ID=$DCR_ID" \
        --output none

    log_success "Function App configured"
}

#######################################
# Deploy Function App code
#######################################
deploy_function_code() {
    log_info "Deploying Function App code..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FUNCTIONS_DIR="$SCRIPT_DIR/functions"

    if [ ! -d "$FUNCTIONS_DIR" ]; then
        log_error "Functions directory not found: $FUNCTIONS_DIR"
        exit 1
    fi

    cd "$FUNCTIONS_DIR"

    # Deploy using func core tools
    func azure functionapp publish "$FUNCTION_APP" --python

    cd "$SCRIPT_DIR"

    log_success "Function App code deployed"
}

#######################################
# Print summary
#######################################
print_summary() {
    echo ""
    echo "=============================================="
    echo -e "${GREEN}DEPLOYMENT COMPLETE${NC}"
    echo "=============================================="
    echo ""
    echo "Resources created in resource group: $RESOURCE_GROUP"
    echo ""
    echo "Function App:        https://$FUNCTION_APP.azurewebsites.net"
    echo "Log Analytics:       $LOG_ANALYTICS_WORKSPACE"
    echo ""
    echo "App Registration:"
    echo "  Name:              $APP_REGISTRATION_NAME"
    echo "  Client ID:         $APP_CLIENT_ID"
    echo "  Tenant ID:         $TENANT_ID"
    echo ""
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo "1. Grant Microsoft Graph permissions to the App Registration:"
    echo "   - DeviceManagementManagedDevices.Read.All"
    echo "   - DeviceManagementConfiguration.Read.All"
    echo "   - DeviceManagementServiceConfig.Read.All"
    echo ""
    echo "2. Test the functions manually in Azure Portal:"
    echo "   https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP/functions"
    echo ""
    echo "3. View logs in Log Analytics after first run"
    echo ""
    echo "=============================================="
}

#######################################
# Main
#######################################
main() {
    echo ""
    echo "=============================================="
    echo "  Intune Reporting - Deployment Script"
    echo "=============================================="
    echo ""

    check_prerequisites
    generate_names

    echo ""
    read -p "Deploy to Azure with these settings? (y/n) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled"
        exit 0
    fi

    echo ""

    create_resource_group
    create_storage_account
    create_log_analytics
    create_custom_tables
    create_dce
    create_dcr
    create_function_app
    create_app_registration
    configure_function_app
    deploy_function_code
    print_summary
}

main "$@"
