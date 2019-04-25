#!/bin/bash

# env vars required
# AMI_NAME (support wildcards)
# or
# AMI_ID
# or
# AMI_FILE (pass in filename under source-ami e.g. source-ami/ami)
# SOURCE_ACCOUNT
# TARGET_ACCOUNT (target account)
# ENA (set to true to enable advanced networking in target AMI)
# BILLING_PRODUCT <code to apply in the register command >

# Check if required environment variables are set. If not, set it right here with a fixed default.
if [ -z ${AWS_DEFAULT_REGION} ] ; then export AWS_DEFAULT_REGION=eu-west-1 ; fi
if [ -z ${HTTP_PROXY} ] ;         then export HTTP_PROXY="http://someproxy:8000" ; fi
if [ -z ${HTTPS_PROXY} ] ;        then export HTTPS_PROXY="$HTTP_PROXY" ; fi
if [ -z ${NO_PROXY} ] ;           then export NO_PROXY="169.254.169.254,s3.amazonaws.com" ; fi

if [ -z ${AMI_ID} ] && [ -z ${AMI_ID} ] && [ -z ${AMI_FILE} ] ; then
  echo "No AMI details given, provide either AMI_NAME (supports wildcards) AMI_FILE (ami.txt) or AMI_ID" && exit 1 ;
fi

if [ -z ${SOURCE_ACCOUNT} ] ; then
  echo "No SOURCE_ACCOUNT details given mega sad panda" && exit 1 ;
fi

if [ -z ${TARGET_ACCOUNT} ] ; then
  echo "No TARGET_ACCOUNT details given sad panda" && exit 1 ;
fi

# switch role to some-admin role used for propagation
temp_credentials="$(aws sts assume-role --role-arn arn:aws:iam::${SOURCE_ACCOUNT}:role/some-admin   --role-session-name some-team-propagate)"
export AWS_ACCESS_KEY_ID="$(echo ${temp_credentials} | jq -r '.Credentials.AccessKeyId')"
export AWS_SECRET_ACCESS_KEY="$(echo ${temp_credentials} | jq -r ' .Credentials.SecretAccessKey')"
export AWS_SECURITY_TOKEN="$(echo ${temp_credentials} | jq -r '.Credentials.SessionToken')"
aws sts get-caller-identity

if [ ! -z ${AMI_FILE} ] ; then
  echo "AMI_FILE specified, taking precedence"
  AMI_ID=$(cat source-ami/${AMI_FILE})
  echo "Found AMI ID $AMI_ID" ;
else
  if [ ! -z ${AMI_NAME} ] && [ -z ${AMI_ID} ] ; then
    AMI_ID=$(aws ec2 describe-images --filters "Name=name,Values=${AMI_NAME}" | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId') ;
  fi
fi

# by now AMI_ID is always filled. Fetch the ami name with a given AMI ID is that is unknown
if [ -z ${AMI_NAME} ] && [ ! -z ${AMI_ID} ] ; then
  AMI_NAME=$(aws ec2 describe-images --image-ids "${AMI_ID}" | jq -r '.Images | sort_by(.CreationDate) | last(.[]).Name') ;
fi

# declare target ami name based on Epoch time suffix to make the target_ami_name unique
declare -r TARGET_AMI_NAME="$AMI_NAME-$(date +%s)"

# Fixed 'read-only' variables
declare -r SOURCE_AMI_OWNER="some Team"
declare -r SOURCE_ENCRYPTION_KEY_ALIAS="propagation"
declare -r TARGET_ENCRYPTION_KEY_ALIAS="propagation "
declare -r TARGET_ACCOUNT_ROLE="arn:aws:iam::${TARGET_ACCOUNT}:role/some-admin"
declare -r AWS_AZ="${AWS_DEFAULT_REGION}a" # Availability Zone

if [ ${ENA} = "true" ] ; then
  ENA_SETTING=" --ena-support " ;
fi

if [ ! -z ${BILLING_PRODUCT} = "true" ] ; then
  BILLING_PRODUCT=" --billing-product ${BILLING_PRODUCT} " ;
fi

# kms details
SOURCE_SNAPSHOT_ID="$(aws ec2 describe-images --image-ids $AMI_ID | jq -r '.Images[].BlockDeviceMappings[].Ebs.SnapshotId')"
SOURCE_ENCRYPTION_KEY_ID="$(aws kms list-aliases | jq -r '.Aliases[] | select(.AliasArn | endswith($alias)) | .TargetKeyId' --arg alias $SOURCE_ENCRYPTION_KEY_ALIAS)"
SOURCE_ENCRYPTION_KEY="arn:aws:kms:$AWS_DEFAULT_REGION:$SOURCE_ACCOUNT:key/$SOURCE_ENCRYPTION_KEY_ID"

# into the fray we go
RE_ENCRYPTED_SNAPSHOT_ID="$(aws ec2 copy-snapshot --source-region ${AWS_DEFAULT_REGION} --source-snapshot-id ${SOURCE_SNAPSHOT_ID} \
                              --description re-encryption-of-${SOURCE_SNAPSHOT_ID} --destination-region ${AWS_DEFAULT_REGION} --encrypted \
                              --kms-key-id ${SOURCE_ENCRYPTION_KEY} | jq -r '.SnapshotId')"


aws ec2 wait snapshot-completed --snapshot-ids "$RE_ENCRYPTED_SNAPSHOT_ID"

aws ec2 modify-snapshot-attribute --snapshot-id "$RE_ENCRYPTED_SNAPSHOT_ID" --create-volume-permission "Add=[{UserId=\"$TARGET_ACCOUNT\"}]"

# switch role
# unset AWS_ACCESS_KEY_ID
# unset AWS_SECRET_ACCESS_KEY
# unset AWS_SECURITY_TOKEN
temp_credentials="$(aws sts assume-role --role-arn ${TARGET_ACCOUNT_ROLE} --role-session-name some-team-propagate)"
export AWS_ACCESS_KEY_ID="$(echo ${temp_credentials} | jq -r '.Credentials.AccessKeyId')"
export AWS_SECRET_ACCESS_KEY="$(echo ${temp_credentials} | jq -r ' .Credentials.SecretAccessKey')"
export AWS_SECURITY_TOKEN="$(echo ${temp_credentials} | jq -r '.Credentials.SessionToken')"

TARGET_ENCRYPTION_KEY_ID="$(aws kms list-aliases | jq -r '.Aliases[] | select(.AliasArn | endswith($alias)) | .TargetKeyId' --arg alias $TARGET_ENCRYPTION_KEY_ALIAS)"
TARGET_ENCRYPTION_KEY="arn:aws:kms:$AWS_DEFAULT_REGION:$TARGET_ACCOUNT:key/$TARGET_ENCRYPTION_KEY_ID"

# Copy re-encrypted snapshot into target account
TARGET_SNAPSHOT_ID="$(aws ec2 copy-snapshot --source-region ${AWS_DEFAULT_REGION} --source-snapshot-id ${RE_ENCRYPTED_SNAPSHOT_ID} --description cross-account-copy-of-${SOURCE_SNAPSHOT_ID} --destination-region ${AWS_DEFAULT_REGION} --encrypted --kms-key-id ${TARGET_ENCRYPTION_KEY}| jq -r '.SnapshotId')"
aws ec2 wait snapshot-completed --snapshot-ids "$TARGET_SNAPSHOT_ID"

TARGET_AMI_ID="$(aws ec2 register-image --architecture x86_64 --block-device-mappings "[{\"DeviceName\": \"/dev/xvda\",\"Ebs\":{\"DeleteOnTermination\":true,\"SnapshotId\":\"${TARGET_SNAPSHOT_ID}\",\"VolumeSize\":30,\"VolumeType\":\"gp2\"}}]" --name $TARGET_AMI_NAME  --root-device-name /dev/xvda ${ENA_SETTING} --virtualization-type hvm ${BILLING_PRODUCT} | jq -r '.ImageId')"

aws ec2 wait image-available --image-ids $TARGET_AMI_ID
echo "TARGET AMI ${TARGET_AMI_ID} created. Joy!"

aws ec2 create-tags --resources "${TARGET_AMI_ID}" "${TARGET_SNAPSHOT_ID}" --tags "Key=source-ami,Value=${AMI_ID}" \
                                                                                  "Key=source-account,Value=$SOURCE_ACCOUNT" \
                                                                                  "Key=owner,Value=$SOURCE_AMI_OWNER"

echo "Leaving target account."

unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SECURITY_TOKEN
# switch back role to some-admin
temp_credentials="$(aws sts assume-role --role-arn arn:aws:iam::${SOURCE_ACCOUNT}:role/some-admin   --role-session-name some-team-propagate)"
export AWS_ACCESS_KEY_ID="$(echo ${temp_credentials} | jq -r '.Credentials.AccessKeyId')"
export AWS_SECRET_ACCESS_KEY="$(echo ${temp_credentials} | jq -r ' .Credentials.SecretAccessKey')"
export AWS_SECURITY_TOKEN="$(echo ${temp_credentials} | jq -r '.Credentials.SessionToken')"

aws ec2 delete-snapshot --snapshot-id "$RE_ENCRYPTED_SNAPSHOT_ID"

echo "$TARGET_AMI_ID" > propagated-ami/ami
