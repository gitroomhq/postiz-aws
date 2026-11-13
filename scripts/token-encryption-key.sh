#!/bin/bash
# Create the data key that encrypts the channel tokens in the Postiz database
# (environments/production/encryption.tf). Run it once, after the apply that
# created the KMS key and before token_encryption leaves "off".
#   token-encryption-key.sh
# KMS returns the key only encrypted by the KMS key, and that is what is stored:
# nobody sees the key itself, the services get it from KMS when they start.
# Refuses when the secret already holds a key: a second key would make every
# token encrypted with the first one unreadable.
# Needs an admin sign-in (kms:GenerateDataKeyWithoutPlaintext, secretsmanager:PutSecretValue).
set -euo pipefail
NAME=${NAME:-postiz-production}
SECRET=${SECRET:-postiz/production/token-encryption-data-key}

versions=$(aws secretsmanager describe-secret --secret-id "$SECRET" \
  --query 'length(keys(VersionIdsToStages || `{}`))' --output text)
if [ "$versions" != 0 ]; then
  echo "$SECRET already holds a data key, not replacing it" >&2
  exit 1
fi

key=$(aws kms generate-data-key-without-plaintext --key-id "alias/$NAME-token-encryption" \
  --key-spec AES_256 --query CiphertextBlob --output text)
aws secretsmanager put-secret-value --secret-id "$SECRET" --secret-string "$key" >/dev/null
echo "data key stored in $SECRET"
