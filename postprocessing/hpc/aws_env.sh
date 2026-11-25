# Exports the AWS keys of one profile in ~/.aws/credentials as AWS_* environment variables of the current
# shell, without printing them. Source it, don't run it:
#
#   source postprocessing/hpc/aws_env.sh
#
# Kestrel has no AWS CLI, so 'aws sso login' does not work there. Instead, paste the short-term keys from
# the AWS access portal (the role's "Access keys", "Option 2") into ~/.aws/credentials; README.md,
# "Running on Kestrel", has the steps. The pasted block's header is the profile name:
# [402490792549_resbldg-user] for the resbldg account, which holds ComStock's runs on S3 and its Athena
# database and workgroup.
#
# Settings: CSPP_AWS_PROFILE (default 402490792549_resbldg-user) and AWS_SHARED_CREDENTIALS_FILE (default
# ~/.aws/credentials). AWS_PROFILE and AWS_DEFAULT_PROFILE are unset, so that nothing falls back to a
# profile in ~/.aws/config: an SSO profile there fails on Kestrel.

if ! (return 0 2> /dev/null); then
    echo "aws_env.sh exports variables into your shell, so source it: source ${BASH_SOURCE[0]}" >&2
    exit 2
fi

_cspp_aws_export() {
    local file=${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}
    local profile=${CSPP_AWS_PROFILE:-402490792549_resbldg-user}
    local exports
    if [ ! -f "$file" ]; then
        echo "There is no $file. Paste the AWS access portal's 'Option 2' block into it (README.md," \
             "'Running on Kestrel')." >&2
        return 2
    fi
    # The keys travel from the file to this shell only through the command substitution below.
    exports=$(CSPP_AWS_FILE=$file CSPP_AWS_SECTION=$profile "${CSPP_PYTHON:-python3}" - << 'EOF'
import configparser
import os
import shlex
import sys

path, section = os.environ['CSPP_AWS_FILE'], os.environ['CSPP_AWS_SECTION']
parser = configparser.RawConfigParser()
try:
    parser.read(path)
except configparser.Error as e:
    sys.exit(f'{path} is not a valid AWS credentials file ({type(e).__name__})')
if not parser.has_section(section):
    sys.exit(f'{path} has no [{section}] section. Paste the portal\'s "Option 2" block for that profile.')
keys = parser[section]
names = {'aws_access_key_id': 'AWS_ACCESS_KEY_ID', 'aws_secret_access_key': 'AWS_SECRET_ACCESS_KEY',
         'aws_session_token': 'AWS_SESSION_TOKEN'}
values = {env: keys.get(key, '').strip() for key, env in names.items()}
missing = [key for key, env in names.items() if env != 'AWS_SESSION_TOKEN' and not values[env]]
if missing:
    sys.exit(f'The [{section}] section of {path} has no {" or ".join(missing)}.')
print('export ' + ' '.join(f'{env}={shlex.quote(v)}' for env, v in values.items() if v))
EOF
    ) || return 2
    unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    eval "$exports"
    export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-west-2}
}

# Never trace the lines that handle the keys, even when the caller runs with set -x. The && || form
# keeps a caller's set -e from exiting before the trace setting is restored.
{ _cspp_xtrace=$-; set +x; } 2> /dev/null
_cspp_aws_export && _cspp_aws_rc=0 || _cspp_aws_rc=$?
unset -f _cspp_aws_export
case $_cspp_xtrace in *x*) set -x ;; esac
eval "unset _cspp_xtrace _cspp_aws_rc; return $_cspp_aws_rc"
