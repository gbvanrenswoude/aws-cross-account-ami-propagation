# aws-cross-account-ami-propagation
cross-account ami propagation (concourse task file)


# assumes KMS keys are there
declare -r SOURCE_ENCRYPTION_KEY_ALIAS="propagation"
declare -r TARGET_ENCRYPTION_KEY_ALIAS="propagation "

# ami metadata
To keep metadata (like marketplace billing code)
- create volume from snapshot in target account
- launch an instance
- swap volume
- create image
