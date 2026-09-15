#!/bin/bash

GROUP="devteam"
USERS=(dev1 dev2 dev3)
ADMIN="dev1"
INITIAL_PASSWORD="redhat@2345"
SHARED_DIR="/shared/project"
SUDOERS_FILE="/etc/sudoers.d/devteam-admin"
MAX_AGE=60
WARN_AGE=7
TEAM_UMASK="007"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Try: sudo $0" >&2
    exit 1
fi

if grep -q "^${GROUP}:" /etc/group; then
    echo "Group ${GROUP} already exists."
else
    groupadd "$GROUP"
    echo "Created group ${GROUP}."
fi

for user in "${USERS[@]}"; do

    if id "$user" &> /dev/null; then
        usermod -aG "$GROUP" -s /bin/bash "$user"
        echo "User ${user} already exists; group and shell refreshed."
    else
        useradd -G "$GROUP" -s /bin/bash "$user"
        echo "Created user ${user}."
    fi

    # Order matters here. chpasswd resets the last-change date to today, so
    # setting the password AFTER chage -d 0 would silently cancel the
    # forced-change-at-first-login requirement.
    echo "${user}:${INITIAL_PASSWORD}" | chpasswd
    chage -M "$MAX_AGE" -W "$WARN_AGE" "$user"
    chage -d 0 "$user"

    if ! grep -q "^umask ${TEAM_UMASK}$" "/home/${user}/.bashrc"; then
        echo "umask ${TEAM_UMASK}" >> "/home/${user}/.bashrc"
    fi

done

echo "${ADMIN} ALL=(ALL) ALL" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"

if ! visudo -cf "$SUDOERS_FILE" > /dev/null; then
    rm -f "$SUDOERS_FILE"
    echo "Invalid sudoers syntax; drop-in removed and no changes applied." >&2
    exit 1
fi

echo "Granted full sudo privileges to ${ADMIN}."


mkdir -p "$SHARED_DIR"
chown root:"$GROUP" "$SHARED_DIR"
chmod 3770 "$SHARED_DIR"

echo "Configured shared workspace at ${SHARED_DIR}."
echo
