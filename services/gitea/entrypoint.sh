#!/usr/bin/env sh
set -eu

runtime_passwd=/tmp/gitea-passwd
runtime_uid=$(id -u)
runtime_gid=$(id -g)
awk -F: -v uid="$runtime_uid" '$3 != uid' /etc/passwd > "$runtime_passwd"
printf 'git:x:%s:%s:Gitea runtime:/data/gitea:/sbin/nologin\n' "$runtime_uid" "$runtime_gid" >> "$runtime_passwd"

export NSS_WRAPPER_PASSWD="$runtime_passwd"
export NSS_WRAPPER_GROUP=/etc/group
export LD_PRELOAD=/usr/lib64/libnss_wrapper.so
exec /usr/local/bin/gitea "$@"
