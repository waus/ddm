const int syncSourceFlagNone = 0;
const int syncSourceFlagSupportTree = 1 << 0;
const int syncSourceFlagSupportStreaming = 1 << 1;
const int syncSourceFlagSupportPeerExchange = 1 << 2;
const int syncSourceFlagWritable = 1 << 3;

const double ratingDefault = 1.0;
const double ratingGoodBlobReceived = 0.1;
const double ratingInvalidBlobReceived = 5.0;
const double ratingReceivedSomethingStrange = 2.0;

const int reverseSyncPushLimit = 5;

const Duration blobStorageRootRetention = Duration(minutes: 10);
const Duration sourceOnlineWindow = Duration(hours: 1);
const Duration sourceOfflineStartup = Duration(hours: 1);
const Duration sourceRetention = Duration(hours: 48);
