#!/bin/bash
#
# Intune Reporting - Production Deployment Script
#
# This script deploys everything needed for Intune Reporting:
#   - Resource Group
#   - Log Analytics Workspace with custom tables
#   - Data Collection Endpoint & Rule
#   - Function App with all export functions
#   - App Registration for Microsoft Graph access
#   - Azure Monitor Workbooks for visualization
#
# Usage:
#   ./deploy.sh                                    # Interactive prompts
#   ./deploy.sh --name "contoso-intune"            # Custom naming prefix
#   ./deploy.sh --name "contoso-intune" --location "westeurope"
#
set -e

#######################################
# Configuration
#######################################
RESOURCE_GROUP=""
LOCATION="eastus"
NAME_PREFIX=""
SKIP_CONFIRMATION=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name|-n)
            NAME_PREFIX="$2"
            shift 2
            ;;
        --location|-l)
            LOCATION="$2"
            shift 2
            ;;
        --resource-group|-g)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --yes|-y)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --name, -n PREFIX       Naming prefix for resources (e.g., 'contoso-intune')"
            echo "  --location, -l REGION   Azure region (default: eastus)"
            echo "  --resource-group, -g RG Resource group name (default: rg-{prefix})"
            echo "  --yes, -y               Skip confirmation prompt"
            echo ""
            echo "Example:"
            echo "  $0 --name contoso-intune --location westeurope"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

#######################################
# Colors
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}=== $1 ===${NC}"; }

#######################################
# Error handling
#######################################
handle_error() {
    log_error "Deployment failed at line $1"
    log_error "Check the error above and re-run the script"
    exit 1
}
trap 'handle_error $LINENO' ERR

#######################################
# Check prerequisites
#######################################
check_prerequisites() {
    log_step "Checking prerequisites"

    # Check az cli
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI (az) is not installed"
        echo "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi
    log_success "Azure CLI installed"

    # Check func core tools
    if ! command -v func &> /dev/null; then
        log_error "Azure Functions Core Tools (func) is not installed"
        echo "Install: npm install -g azure-functions-core-tools@4"
        exit 1
    fi
    log_success "Functions Core Tools installed"

    # Check logged in
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure CLI"
        echo "Run: az login"
        exit 1
    fi

    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    TENANT_ID=$(az account show --query tenantId -o tsv)
    log_success "Logged in to: $SUBSCRIPTION_NAME"
}

#######################################
# Get configuration
#######################################
get_configuration() {
    log_step "Configuration"

    # Get name prefix if not provided
    if [[ -z "$NAME_PREFIX" ]]; then
        echo ""
        echo "Enter a naming prefix for your resources."
        echo "This will be used to create readable resource names like:"
        echo "  - {prefix}-law (Log Analytics Workspace)"
        echo "  - {prefix}-func (Function App)"
        echo ""
        read -p "Naming prefix (e.g., contoso-intune): " NAME_PREFIX

        if [[ -z "$NAME_PREFIX" ]]; then
            log_error "Naming prefix is required"
            exit 1
        fi
    fi

    # Sanitize name prefix (lowercase, alphanumeric and hyphens only)
    NAME_PREFIX=$(echo "$NAME_PREFIX" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

    # Set resource names
    [[ -z "$RESOURCE_GROUP" ]] && RESOURCE_GROUP="rg-${NAME_PREFIX}"
    STORAGE_ACCOUNT=$(echo "${NAME_PREFIX}stor" | sed 's/-//g' | cut -c1-24)
    FUNCTION_APP="${NAME_PREFIX}-func"
    LOG_ANALYTICS="${NAME_PREFIX}-law"
    DCE_NAME="${NAME_PREFIX}-dce"
    DCR_NAME="${NAME_PREFIX}-dcr"
    APP_REGISTRATION="${NAME_PREFIX}-app"

    echo ""
    echo "Resources to be created:"
    echo "  Resource Group:     $RESOURCE_GROUP"
    echo "  Location:           $LOCATION"
    echo "  Storage Account:    $STORAGE_ACCOUNT"
    echo "  Function App:       $FUNCTION_APP"
    echo "  Log Analytics:      $LOG_ANALYTICS"
    echo "  DCE:                $DCE_NAME"
    echo "  DCR:                $DCR_NAME"
    echo "  App Registration:   $APP_REGISTRATION"
    echo ""

    if [[ "$SKIP_CONFIRMATION" != "true" ]]; then
        read -p "Deploy with these settings? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deployment cancelled"
            exit 0
        fi
    fi
}

#######################################
# Create Resource Group
#######################################
create_resource_group() {
    log_step "Creating Resource Group"

    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        log_warn "Resource group $RESOURCE_GROUP already exists"
    else
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
        log_success "Created resource group: $RESOURCE_GROUP"
    fi
}

#######################################
# Create Storage Account
#######################################
create_storage_account() {
    log_step "Creating Storage Account"

    if az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        log_warn "Storage account $STORAGE_ACCOUNT already exists"
    else
        az storage account create \
            --name "$STORAGE_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --sku Standard_LRS \
            --output none
        log_success "Created storage account: $STORAGE_ACCOUNT"
    fi
}

#######################################
# Create Log Analytics Workspace
#######################################
create_log_analytics() {
    log_step "Creating Log Analytics Workspace"

    if az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" --workspace-name "$LOG_ANALYTICS" &> /dev/null; then
        log_warn "Log Analytics workspace $LOG_ANALYTICS already exists"
    else
        az monitor log-analytics workspace create \
            --resource-group "$RESOURCE_GROUP" \
            --workspace-name "$LOG_ANALYTICS" \
            --location "$LOCATION" \
            --retention-time 30 \
            --output none
        log_success "Created Log Analytics workspace: $LOG_ANALYTICS"
    fi

    # Get workspace IDs
    WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace show \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$LOG_ANALYTICS" \
        --query id -o tsv)

    WORKSPACE_CUSTOMER_ID=$(az monitor log-analytics workspace show \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$LOG_ANALYTICS" \
        --query customerId -o tsv)

    log_info "Workspace ID: $WORKSPACE_CUSTOMER_ID"
}

#######################################
# Create Custom Tables via REST API
#######################################
create_custom_tables() {
    log_step "Creating Custom Tables"

    declare -A TABLES

    TABLES["IntuneDevices_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneDevices_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "DeviceName", "type": "string"},
                    {"name": "UserPrincipalName", "type": "string"},
                    {"name": "UserDisplayName", "type": "string"},
                    {"name": "OperatingSystem", "type": "string"},
                    {"name": "OSVersion", "type": "string"},
                    {"name": "ComplianceState", "type": "string"},
                    {"name": "ManagementState", "type": "string"},
                    {"name": "EnrolledDateTime", "type": "datetime"},
                    {"name": "LastSyncDateTime", "type": "datetime"},
                    {"name": "Manufacturer", "type": "string"},
                    {"name": "Model", "type": "string"},
                    {"name": "SerialNumber", "type": "string"},
                    {"name": "IsEncrypted", "type": "boolean"},
                    {"name": "AutopilotEnrolled", "type": "boolean"},
                    {"name": "TotalStorageGB", "type": "real"},
                    {"name": "FreeStorageGB", "type": "real"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneCompliancePolicies_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneCompliancePolicies_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "PolicyId", "type": "string"},
                    {"name": "PolicyName", "type": "string"},
                    {"name": "Description", "type": "string"},
                    {"name": "PolicyType", "type": "string"},
                    {"name": "CreatedDateTime", "type": "datetime"},
                    {"name": "LastModifiedDateTime", "type": "datetime"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneComplianceStates_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneComplianceStates_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "DeviceName", "type": "string"},
                    {"name": "UserId", "type": "string"},
                    {"name": "UserPrincipalName", "type": "string"},
                    {"name": "PolicyId", "type": "string"},
                    {"name": "PolicyName", "type": "string"},
                    {"name": "Status", "type": "string"},
                    {"name": "StatusRaw", "type": "int"},
                    {"name": "SettingCount", "type": "int"},
                    {"name": "FailedSettingCount", "type": "int"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneDeviceScores_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneDeviceScores_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "DeviceName", "type": "string"},
                    {"name": "Model", "type": "string"},
                    {"name": "Manufacturer", "type": "string"},
                    {"name": "HealthStatus", "type": "string"},
                    {"name": "EndpointAnalyticsScore", "type": "real"},
                    {"name": "StartupPerformanceScore", "type": "real"},
                    {"name": "AppReliabilityScore", "type": "real"},
                    {"name": "WorkFromAnywhereScore", "type": "real"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneStartupPerformance_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneStartupPerformance_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "StartTime", "type": "datetime"},
                    {"name": "CoreBootTimeInMs", "type": "int"},
                    {"name": "GroupPolicyBootTimeInMs", "type": "int"},
                    {"name": "TotalBootTimeInMs", "type": "int"},
                    {"name": "TotalLoginTimeInMs", "type": "int"},
                    {"name": "IsFirstLogin", "type": "boolean"},
                    {"name": "IsFeatureUpdate", "type": "boolean"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneAppReliability_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneAppReliability_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "AppName", "type": "string"},
                    {"name": "AppDisplayName", "type": "string"},
                    {"name": "AppPublisher", "type": "string"},
                    {"name": "ActiveDeviceCount", "type": "int"},
                    {"name": "AppCrashCount", "type": "int"},
                    {"name": "AppHangCount", "type": "int"},
                    {"name": "MeanTimeToFailureInMinutes", "type": "int"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneAutopilotDevices_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneAutopilotDevices_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "AutopilotDeviceId", "type": "string"},
                    {"name": "SerialNumber", "type": "string"},
                    {"name": "Manufacturer", "type": "string"},
                    {"name": "Model", "type": "string"},
                    {"name": "GroupTag", "type": "string"},
                    {"name": "EnrollmentState", "type": "string"},
                    {"name": "DeploymentProfileAssignmentStatus", "type": "string"},
                    {"name": "LastContactedDateTime", "type": "datetime"},
                    {"name": "UserPrincipalName", "type": "string"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneAutopilotProfiles_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneAutopilotProfiles_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "ProfileId", "type": "string"},
                    {"name": "DisplayName", "type": "string"},
                    {"name": "Description", "type": "string"},
                    {"name": "CreatedDateTime", "type": "datetime"},
                    {"name": "LastModifiedDateTime", "type": "datetime"},
                    {"name": "DeviceNameTemplate", "type": "string"},
                    {"name": "ProfileType", "type": "string"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    TABLES["IntuneSyncState_CL"]='{
        "properties": {
            "schema": {
                "name": "IntuneSyncState_CL",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "ExportType", "type": "string"},
                    {"name": "RecordCount", "type": "int"},
                    {"name": "Status", "type": "string"},
                    {"name": "DurationSeconds", "type": "real"},
                    {"name": "ErrorMessage", "type": "string"}
                ]
            },
            "retentionInDays": 30,
            "plan": "Analytics"
        }
    }'

    for TABLE_NAME in "${!TABLES[@]}"; do
        log_info "Creating table: $TABLE_NAME"

        az rest --method PUT \
            --uri "https://management.azure.com${WORKSPACE_RESOURCE_ID}/tables/${TABLE_NAME}?api-version=2022-10-01" \
            --body "${TABLES[$TABLE_NAME]}" \
            --output none 2>/dev/null || log_warn "Table $TABLE_NAME may already exist"
    done

    log_success "Custom tables created"
}

#######################################
# Create Data Collection Endpoint
#######################################
create_dce() {
    log_step "Creating Data Collection Endpoint"

    if az monitor data-collection endpoint show --resource-group "$RESOURCE_GROUP" --name "$DCE_NAME" &> /dev/null; then
        log_warn "DCE $DCE_NAME already exists"
    else
        az monitor data-collection endpoint create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$DCE_NAME" \
            --location "$LOCATION" \
            --public-network-access Enabled \
            --output none
        log_success "Created DCE: $DCE_NAME"
    fi

    DCE_ENDPOINT=$(az monitor data-collection endpoint show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DCE_NAME" \
        --query logsIngestion.endpoint -o tsv)

    DCE_RESOURCE_ID=$(az monitor data-collection endpoint show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DCE_NAME" \
        --query id -o tsv)

    log_info "DCE Endpoint: $DCE_ENDPOINT"
}

#######################################
# Create Data Collection Rule via REST API
#######################################
create_dcr() {
    log_step "Creating Data Collection Rule"

    # Build DCR JSON with all stream declarations
    DCR_JSON=$(cat <<EOF
{
    "location": "$LOCATION",
    "properties": {
        "dataCollectionEndpointId": "$DCE_RESOURCE_ID",
        "streamDeclarations": {
            "Custom-IntuneDevices_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "DeviceName", "type": "string"},
                    {"name": "UserPrincipalName", "type": "string"},
                    {"name": "UserDisplayName", "type": "string"},
                    {"name": "OperatingSystem", "type": "string"},
                    {"name": "OSVersion", "type": "string"},
                    {"name": "ComplianceState", "type": "string"},
                    {"name": "ManagementState", "type": "string"},
                    {"name": "EnrolledDateTime", "type": "datetime"},
                    {"name": "LastSyncDateTime", "type": "datetime"},
                    {"name": "Manufacturer", "type": "string"},
                    {"name": "Model", "type": "string"},
                    {"name": "SerialNumber", "type": "string"},
                    {"name": "IsEncrypted", "type": "boolean"},
                    {"name": "AutopilotEnrolled", "type": "boolean"},
                    {"name": "TotalStorageGB", "type": "real"},
                    {"name": "FreeStorageGB", "type": "real"}
                ]
            },
            "Custom-IntuneCompliancePolicies_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "PolicyId", "type": "string"},
                    {"name": "PolicyName", "type": "string"},
                    {"name": "Description", "type": "string"},
                    {"name": "PolicyType", "type": "string"},
                    {"name": "CreatedDateTime", "type": "datetime"},
                    {"name": "LastModifiedDateTime", "type": "datetime"}
                ]
            },
            "Custom-IntuneComplianceStates_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "DeviceName", "type": "string"},
                    {"name": "UserId", "type": "string"},
                    {"name": "UserPrincipalName", "type": "string"},
                    {"name": "PolicyId", "type": "string"},
                    {"name": "PolicyName", "type": "string"},
                    {"name": "Status", "type": "string"},
                    {"name": "StatusRaw", "type": "int"},
                    {"name": "SettingCount", "type": "int"},
                    {"name": "FailedSettingCount", "type": "int"}
                ]
            },
            "Custom-IntuneDeviceScores_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "DeviceName", "type": "string"},
                    {"name": "Model", "type": "string"},
                    {"name": "Manufacturer", "type": "string"},
                    {"name": "HealthStatus", "type": "string"},
                    {"name": "EndpointAnalyticsScore", "type": "real"},
                    {"name": "StartupPerformanceScore", "type": "real"},
                    {"name": "AppReliabilityScore", "type": "real"},
                    {"name": "WorkFromAnywhereScore", "type": "real"}
                ]
            },
            "Custom-IntuneStartupPerformance_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "DeviceId", "type": "string"},
                    {"name": "StartTime", "type": "datetime"},
                    {"name": "CoreBootTimeInMs", "type": "int"},
                    {"name": "GroupPolicyBootTimeInMs", "type": "int"},
                    {"name": "TotalBootTimeInMs", "type": "int"},
                    {"name": "TotalLoginTimeInMs", "type": "int"},
                    {"name": "IsFirstLogin", "type": "boolean"},
                    {"name": "IsFeatureUpdate", "type": "boolean"}
                ]
            },
            "Custom-IntuneAppReliability_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "AppName", "type": "string"},
                    {"name": "AppDisplayName", "type": "string"},
                    {"name": "AppPublisher", "type": "string"},
                    {"name": "ActiveDeviceCount", "type": "int"},
                    {"name": "AppCrashCount", "type": "int"},
                    {"name": "AppHangCount", "type": "int"},
                    {"name": "MeanTimeToFailureInMinutes", "type": "int"}
                ]
            },
            "Custom-IntuneAutopilotDevices_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "AutopilotDeviceId", "type": "string"},
                    {"name": "SerialNumber", "type": "string"},
                    {"name": "Manufacturer", "type": "string"},
                    {"name": "Model", "type": "string"},
                    {"name": "GroupTag", "type": "string"},
                    {"name": "EnrollmentState", "type": "string"},
                    {"name": "DeploymentProfileAssignmentStatus", "type": "string"},
                    {"name": "LastContactedDateTime", "type": "datetime"},
                    {"name": "UserPrincipalName", "type": "string"}
                ]
            },
            "Custom-IntuneAutopilotProfiles_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "ProfileId", "type": "string"},
                    {"name": "DisplayName", "type": "string"},
                    {"name": "Description", "type": "string"},
                    {"name": "CreatedDateTime", "type": "datetime"},
                    {"name": "LastModifiedDateTime", "type": "datetime"},
                    {"name": "DeviceNameTemplate", "type": "string"},
                    {"name": "ProfileType", "type": "string"}
                ]
            },
            "Custom-IntuneSyncState_CL": {
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "IngestionTime", "type": "datetime"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "ExportType", "type": "string"},
                    {"name": "RecordCount", "type": "int"},
                    {"name": "Status", "type": "string"},
                    {"name": "DurationSeconds", "type": "real"},
                    {"name": "ErrorMessage", "type": "string"}
                ]
            }
        },
        "destinations": {
            "logAnalytics": [
                {
                    "workspaceResourceId": "$WORKSPACE_RESOURCE_ID",
                    "name": "logAnalyticsWorkspace"
                }
            ]
        },
        "dataFlows": [
            {"streams": ["Custom-IntuneDevices_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneDevices_CL"},
            {"streams": ["Custom-IntuneCompliancePolicies_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneCompliancePolicies_CL"},
            {"streams": ["Custom-IntuneComplianceStates_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneComplianceStates_CL"},
            {"streams": ["Custom-IntuneDeviceScores_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneDeviceScores_CL"},
            {"streams": ["Custom-IntuneStartupPerformance_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneStartupPerformance_CL"},
            {"streams": ["Custom-IntuneAppReliability_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneAppReliability_CL"},
            {"streams": ["Custom-IntuneAutopilotDevices_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneAutopilotDevices_CL"},
            {"streams": ["Custom-IntuneAutopilotProfiles_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneAutopilotProfiles_CL"},
            {"streams": ["Custom-IntuneSyncState_CL"], "destinations": ["logAnalyticsWorkspace"], "transformKql": "source", "outputStream": "Custom-IntuneSyncState_CL"}
        ]
    }
}
EOF
)

    DCR_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Insights/dataCollectionRules/${DCR_NAME}"

    az rest --method PUT \
        --uri "https://management.azure.com${DCR_RESOURCE_ID}?api-version=2022-06-01" \
        --body "$DCR_JSON" \
        --output none 2>/dev/null || log_warn "DCR may already exist"

    # Get DCR immutable ID
    DCR_IMMUTABLE_ID=$(az rest --method GET \
        --uri "https://management.azure.com${DCR_RESOURCE_ID}?api-version=2022-06-01" \
        --query properties.immutableId -o tsv 2>/dev/null || echo "")

    if [[ -n "$DCR_IMMUTABLE_ID" ]]; then
        log_success "Created DCR: $DCR_NAME (ID: $DCR_IMMUTABLE_ID)"
    else
        log_error "Failed to create DCR"
        exit 1
    fi
}

#######################################
# Create Function App
#######################################
create_function_app() {
    log_step "Creating Function App"

    if az functionapp show --resource-group "$RESOURCE_GROUP" --name "$FUNCTION_APP" &> /dev/null; then
        log_warn "Function App $FUNCTION_APP already exists"
    else
        # Try Flex Consumption first, fall back to legacy
        if az functionapp create \
            --resource-group "$RESOURCE_GROUP" \
            --flexconsumption-location "$LOCATION" \
            --runtime python \
            --runtime-version 3.11 \
            --name "$FUNCTION_APP" \
            --storage-account "$STORAGE_ACCOUNT" \
            --output none 2>/dev/null; then
            log_success "Created Function App (Flex Consumption): $FUNCTION_APP"
        else
            log_warn "Flex Consumption not available, using legacy Consumption plan"
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
            log_success "Created Function App (Consumption): $FUNCTION_APP"
        fi
    fi
}

#######################################
# Create App Registration
#######################################
create_app_registration() {
    log_step "Creating App Registration"

    # Check if exists
    EXISTING_APP=$(az ad app list --display-name "$APP_REGISTRATION" --query "[0].appId" -o tsv 2>/dev/null || echo "")

    if [[ -n "$EXISTING_APP" ]]; then
        log_warn "App Registration already exists: $EXISTING_APP"
        APP_CLIENT_ID="$EXISTING_APP"
    else
        APP_CLIENT_ID=$(az ad app create --display-name "$APP_REGISTRATION" --query appId -o tsv)
        az ad sp create --id "$APP_CLIENT_ID" --output none 2>/dev/null || true
        log_success "Created App Registration: $APP_REGISTRATION"
    fi

    # Create/reset secret
    APP_CLIENT_SECRET=$(az ad app credential reset \
        --id "$APP_CLIENT_ID" \
        --display-name "intune-reporting-secret" \
        --years 2 \
        --query password -o tsv)

    log_info "Client ID: $APP_CLIENT_ID"
}

#######################################
# Grant DCR Permissions
#######################################
grant_dcr_permissions() {
    log_step "Granting DCR Permissions"

    # Get service principal object ID
    SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_CLIENT_ID'" --query "[0].id" -o tsv 2>/dev/null || echo "")

    if [[ -z "$SP_OBJECT_ID" ]]; then
        log_warn "Could not find service principal, skipping DCR permission"
        return
    fi

    # Monitoring Metrics Publisher role definition ID
    ROLE_DEF_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb"
    ASSIGNMENT_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$(echo $RANDOM)")

    az rest --method PUT \
        --uri "https://management.azure.com${DCR_RESOURCE_ID}/providers/Microsoft.Authorization/roleAssignments/${ASSIGNMENT_ID}?api-version=2022-04-01" \
        --body "{
            \"properties\": {
                \"roleDefinitionId\": \"${ROLE_DEF_ID}\",
                \"principalId\": \"${SP_OBJECT_ID}\",
                \"principalType\": \"ServicePrincipal\"
            }
        }" --output none 2>/dev/null || log_warn "DCR permission may already exist"

    log_success "Granted Monitoring Metrics Publisher role on DCR"
}

#######################################
# Configure Function App
#######################################
configure_function_app() {
    log_step "Configuring Function App"

    az functionapp config appsettings set \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNCTION_APP" \
        --settings \
            "AZURE_TENANT_ID=$TENANT_ID" \
            "AZURE_CLIENT_ID=$APP_CLIENT_ID" \
            "AZURE_CLIENT_SECRET=$APP_CLIENT_SECRET" \
            "ANALYTICS_BACKEND=LogAnalytics" \
            "LOG_ANALYTICS_DCE=$DCE_ENDPOINT" \
            "LOG_ANALYTICS_DCR_ID=$DCR_IMMUTABLE_ID" \
        --output none

    log_success "Function App configured"
}

#######################################
# Deploy Function Code
#######################################
deploy_function_code() {
    log_step "Deploying Function Code"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FUNCTIONS_DIR="$SCRIPT_DIR/functions"

    if [[ ! -d "$FUNCTIONS_DIR" ]]; then
        log_error "Functions directory not found: $FUNCTIONS_DIR"
        exit 1
    fi

    cd "$FUNCTIONS_DIR"
    func azure functionapp publish "$FUNCTION_APP" --python
    cd "$SCRIPT_DIR"

    log_success "Function code deployed"
}

#######################################
# Deploy Workbooks
#######################################
deploy_workbooks() {
    log_step "Deploying Workbooks"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WORKBOOKS_DIR="$SCRIPT_DIR/workbooks"

    if [[ ! -d "$WORKBOOKS_DIR" ]]; then
        log_warn "Workbooks directory not found, skipping"
        return
    fi

    # Install application-insights extension if needed
    az extension add --name application-insights --yes 2>/dev/null || true

    declare -A WORKBOOK_NAMES
    WORKBOOK_NAMES["device-inventory.workbook"]="Intune Device Inventory"
    WORKBOOK_NAMES["compliance-overview.workbook"]="Intune Compliance Overview"
    WORKBOOK_NAMES["device-health.workbook"]="Intune Device Health"
    WORKBOOK_NAMES["autopilot-deployment.workbook"]="Intune Autopilot Deployment"

    for WORKBOOK_FILE in "${!WORKBOOK_NAMES[@]}"; do
        WORKBOOK_PATH="$WORKBOOKS_DIR/$WORKBOOK_FILE"
        DISPLAY_NAME="${WORKBOOK_NAMES[$WORKBOOK_FILE]}"

        if [[ ! -f "$WORKBOOK_PATH" ]]; then
            log_warn "Workbook not found: $WORKBOOK_FILE"
            continue
        fi

        # Generate deterministic UUID based on name
        WORKBOOK_UUID=$(echo -n "${NAME_PREFIX}-${WORKBOOK_FILE}" | md5sum | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\).*/\1-\2-\3-\4-\5/')

        log_info "Deploying: $DISPLAY_NAME"

        az monitor app-insights workbook create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$WORKBOOK_UUID" \
            --display-name "$DISPLAY_NAME" \
            --kind shared \
            --category "workbook" \
            --location "$LOCATION" \
            --source-id "$WORKSPACE_RESOURCE_ID" \
            --serialized-data "@$WORKBOOK_PATH" \
            --output none 2>/dev/null || log_warn "Workbook may already exist: $DISPLAY_NAME"
    done

    log_success "Workbooks deployed"
}

#######################################
# Print Summary
#######################################
print_summary() {
    echo ""
    echo "=============================================="
    echo -e "${GREEN}DEPLOYMENT COMPLETE${NC}"
    echo "=============================================="
    echo ""
    echo "Resources created in: $RESOURCE_GROUP"
    echo ""
    echo "Function App:    https://${FUNCTION_APP}.azurewebsites.net"
    echo "Log Analytics:   $LOG_ANALYTICS"
    echo ""
    echo "App Registration:"
    echo "  Name:          $APP_REGISTRATION"
    echo "  Client ID:     $APP_CLIENT_ID"
    echo "  Tenant ID:     $TENANT_ID"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Grant Microsoft Graph API permissions${NC}"
    echo ""
    echo "1. Open Azure Portal > App Registrations > $APP_REGISTRATION"
    echo "2. Go to API Permissions > Add a permission > Microsoft Graph"
    echo "3. Select Application permissions and add:"
    echo "   - DeviceManagementManagedDevices.Read.All"
    echo "   - DeviceManagementConfiguration.Read.All"
    echo "   - DeviceManagementServiceConfig.Read.All"
    echo "4. Click 'Grant admin consent'"
    echo ""
    echo "Quick link:"
    echo "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/${APP_CLIENT_ID}"
    echo ""
    echo "Test endpoints:"
    echo "  Health:  https://${FUNCTION_APP}.azurewebsites.net/api/export/health"
    echo "  Test:    https://${FUNCTION_APP}.azurewebsites.net/api/export/test"
    echo ""
    echo "=============================================="
}

#######################################
# Main
#######################################
main() {
    echo ""
    echo "=============================================="
    echo "  Intune Reporting - Production Deployment"
    echo "=============================================="
    echo ""

    check_prerequisites
    get_configuration
    create_resource_group
    create_storage_account
    create_log_analytics
    create_custom_tables
    create_dce
    create_dcr
    create_function_app
    create_app_registration
    grant_dcr_permissions
    configure_function_app
    deploy_function_code
    deploy_workbooks
    print_summary
}

main "$@"
