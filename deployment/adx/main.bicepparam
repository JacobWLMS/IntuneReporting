using 'main.bicep'

// Customize these values
param baseName = 'intune'
param location = 'uksouth'

// Optional: Set these if you already have an ADX cluster
// Otherwise leave empty and set after deployment
param adxClusterUri = ''
param adxDatabase = 'IntuneAnalytics'
