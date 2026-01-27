using 'main.bicep'

// Customize these values
param baseName = 'intune'
param location = 'uksouth'

// Choose backend: 'ADX' or 'LogAnalytics'
param analyticsBackend = 'ADX'

// ---- ADX Backend ----
param adxClusterUri = ''
param adxDatabase = 'IntuneAnalytics'

// ---- Log Analytics Backend ----
// Uncomment and fill in if using LogAnalytics backend
// param logAnalyticsWorkspaceId = ''
// param logAnalyticsDce = ''
// param logAnalyticsDcrId = ''
