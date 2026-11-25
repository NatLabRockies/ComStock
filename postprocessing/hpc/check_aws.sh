#!/bin/bash
# Checks the AWS keys that postprocessing will use, without printing them: the account and role they
# belong to and, if you name an S3 folder, whether they can list it. Run it on a login node after
# pasting new keys into ~/.aws/credentials. submit_driver.sh and the job run it too.
#
#   bash postprocessing/hpc/check_aws.sh
#   bash postprocessing/hpc/check_aws.sh s3://eulp/euss_com/0_production_runs_2026R1/tests/<run name>/
#
# The keys come from aws_env.sh (profile CSPP_AWS_PROFILE, default 402490792549_resbldg-user) and must
# belong to account CSPP_AWS_ACCOUNT (default 402490792549, resbldg). --quiet prints a single line.
set -eo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

QUIET=0
S3_URL=
for arg in "$@"; do
    case $arg in
        --quiet) QUIET=1 ;;
        -h|--help) cspp_usage "$0"; exit 0 ;;
        s3://*) S3_URL=$arg ;;
        *) echo "unknown argument: $arg (see --help)" >&2; exit 2 ;;
    esac
done

cspp_activate_env  # for boto3
CREDENTIALS=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}
if ! source "$CSPP_HPC_DIR/aws_env.sh"; then
    echo "To fix it, open $CREDENTIALS in an editor (for example: nano $CREDENTIALS), replace the" \
         "[${CSPP_AWS_PROFILE:-402490792549_resbldg-user}] section with the portal's 'Option 2' block, save" \
         "and exit." >&2
    exit 2
fi
MODE=$(stat -c %a "$CREDENTIALS")
if [ "$QUIET" = 0 ] && [ "$MODE" != 600 ]; then
    echo "note: $CREDENTIALS has mode $MODE, so others can read it; run: chmod 600 $CREDENTIALS"
fi

CSPP_S3_URL=$S3_URL python - << 'EOF'
import os
import sys

import boto3
import botocore.exceptions

want = os.environ.get('CSPP_AWS_ACCOUNT', '402490792549')
try:
    ident = boto3.client('sts').get_caller_identity()
except botocore.exceptions.ClientError as e:
    sys.exit(f"AWS rejected the keys ({e.response['Error']['Code']}); they have probably expired. Paste a "
             "fresh 'Option 2' block from the AWS access portal into ~/.aws/credentials.")
except botocore.exceptions.BotoCoreError as e:
    sys.exit(f'The AWS keys could not be used: {type(e).__name__}: {e}')
account, arn = ident['Account'], ident['Arn']
role = arn.split('/')[1] if ':assumed-role/' in arn else arn.rsplit(':', 1)[-1]
if account != want:
    sys.exit(f'WRONG ACCOUNT: these keys belong to account {account}, not {want}. In the AWS access '
             'portal, take the keys of the resbldg account.')
message = f'AWS keys OK: account {account}, role {role}'
url = os.environ['CSPP_S3_URL']
if url:
    bucket, _, prefix = url[len('s3://'):].partition('/')
    try:
        listing = boto3.client('s3').list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=5)
    except botocore.exceptions.ClientError as e:
        sys.exit(f"{message}, but they cannot list {url} ({e.response['Error']['Code']})")
    names = [o['Key'][len(prefix):] or o['Key'] for o in listing.get('Contents', [])]
    if not names:
        sys.exit(f'{message}, but {url} is empty or does not exist')
    message += f'; {url} has ' + ', '.join(names) + (', ...' if listing.get('IsTruncated') else '')
print(message)
EOF
