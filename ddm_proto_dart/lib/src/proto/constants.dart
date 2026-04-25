const int unencryptedMessageMagic = 0x77617573;
const int unencryptedMessageVersionV1 = 1;
const int encryptedMessageVersionV1 = 1;
const int powEnvelopeVersionV1 = 1;

const int powProofComponentSize = 128;
const int powModulusSize = 128;

const int maxMessagePayloadBytes = 640 * 1024;

const int maxCborNestedLevels = 16;
const int maxCborArrayElements = 64;
const int maxCborMapPairs = 16;

const int addressVersionV1 = 176;
const int addressDisplayPayloadSize = 34;
const int addressDisplaySize = addressDisplayPayloadSize + 1;

const int addressPolicyAckExpected = 1 << 0;
const int maxConfigPayloadBytes = 4 * 1024;
const int maxSignedMessageBytes = 2 * 1024 * 1024;
const int maxEncryptedMessageBytes = 2 * 1024 * 1024;
const int maxPowEnvelopeBytes = 2 * 1024 * 1024;

const int configRecordVersionV1 = 1;

const int syncBlobIdSize = 36;
const int messageIndexNodeIdSize = 32;

const int messageIndexChildSlotCount = 16;
const int messageIndexNodeBranchTagNum = 40000;
const int messageIndexNodeLeafTagNum = 40001;

const String base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
final RegExp streamHexPrefixRe = RegExp(r'^[0-9a-f]*$');
const int streamPrefixMaxLength = 8;

const int coseHeaderAlg = 1;
const int coseAlgorithmEdDsa = -8;

bool isAddressPolicySupported(int policy) =>
    (policy & ~addressPolicyAckExpected) == 0;
