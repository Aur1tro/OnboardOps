# OnboardOps — RHEL User and Access Provisioning Kit

A RHEL 10 provisioning script that sets up a standardised user, group and
permission environment for a project team, together with the command output
that proves each part of the configuration behaves as intended.

---

## Problem Statement

When several people join a project team at the same time, setting up their
accounts by hand causes problems. One person gets the wrong shell, another
never gets added to the team group, someone is accidentally given full
administrative rights, and the shared folder ends up with permissions that
either lock the team out or leave the files readable by the whole system.

The result is inconsistent access, wasted time, and a security posture nobody
can describe accurately.

OnboardOps solves this by putting the entire setup into one script, so that
three new joiners receive an identical, correctly configured environment, and
by verifying the outcome with command output rather than assuming the commands
worked.

---

## Objectives

1. Create a `devteam` group and three user accounts, each with a home
   directory, a login shell, and `devteam` as a supplementary group.
2. Apply a password aging policy: maximum age 60 days, warning period 7 days,
   and a forced password change at first login.
3. Grant full `sudo` privileges to exactly one of the three users, through a
   drop-in file under `/etc/sudoers.d/`.
4. Build a shared workspace at `/shared/project` where new files inherit the
   `devteam` group and one user cannot delete another user's files.
5. Set default permissions so that files created in the shared area are
   group-writable and closed to other users.
6. Prove every one of the above with command output, including the failures
   that demonstrate the restrictions are real.

---

## Environment

| Item | Value |
|---|---|
| Operating system | Red Hat Enterprise Linux 10 |
| Virtualisation | VMware |
| Hostname | localhost |
| Administrative account | `auritro`, member of `wheel` |
| Shell | Bash |
| Script executed as | root, via `sudo ./provision.sh` |

The system was clean before provisioning: no `dev1`/`dev2`/`dev3` users, no
`devteam` group, no `/shared` directory, and an empty `/etc/sudoers.d/`. This
is recorded in section 0 of `verification_output.txt`.

---

## Architecture / Approach

`provision.sh` runs top to bottom in a plain sequence:

```
configuration variables
        |
        v
root privilege check  --->  exit 1 if not root
        |
        v
create devteam group (skipped if it exists)
        |
        v
for each user:
    create account with devteam and /bin/bash
    set initial password
    apply chage -M 60 -W 7
    apply chage -d 0
    append umask 007 to ~/.bashrc
        |
        v
write /etc/sudoers.d/devteam-admin, chmod 0440, validate
        |
        v
create /shared/project, chown root:devteam, chmod 3770
```

Every value the assignment describes as configurable — group name, usernames,
administrator, initial password, shared path, aging values, umask — is a
variable at the top of the file. No name is hard-coded further down.

**Idempotency.** The group creation and the `.bashrc` edit are guarded so that
rerunning the script does not fail or duplicate lines, and an existing user has
their group membership and shell refreshed rather than triggering an error.
Two operations are deliberately *not* idempotent: the password is reset and the
sudoers file is rewritten on every run. Both are cheap and both converge on the
correct state, so guarding them would have added complexity for no benefit.

**Teardown is not in the script.** Removing users is a destructive operation
and a provisioning tool that can delete three accounts is a hazard. Any
cleanup was performed manually and is recorded in `commands.txt`.

---

## Users and Groups

`devteam` is a supplementary group shared by all three accounts. Each user also
keeps their own private primary group, which RHEL creates automatically with
the same name as the user.

| Account | UID | Primary group | Supplementary | Shell | Role |
|---|---|---|---|---|---|
| dev1 | 1001 | dev1 (1002) | devteam (1001) | /bin/bash | Team lead, sole sudo user |
| dev2 | 1002 | dev2 (1003) | devteam (1001) | /bin/bash | Developer |
| dev3 | 1003 | dev3 (1004) | devteam (1001) | /bin/bash | Developer |

The users were created with `useradd -G devteam -s /bin/bash`, where `-G` adds
a supplementary group without touching the primary one.

Why supplementary rather than primary: if `devteam` were each user's primary
group, then every file they created anywhere on the system — including in their
own home directory — would be group-owned by `devteam`, which leaks private
work to the team. Keeping `devteam` supplementary means the sharing is scoped
to the directory where SGID is set, and nowhere else.

The GID of `devteam` (1001) is lower than the GIDs of the private groups
(1002–1004) because the script creates the group before the users. A user's UID
and primary GID do not need to match, and RH124 Chapter 10 says so explicitly.

---

## Password Policy

Applied with `chage` to all three accounts:

| Setting | Command | Effect |
|---|---|---|
| Maximum age | `chage -M 60` | The password expires 60 days after it is changed |
| Warning period | `chage -W 7` | The user is warned daily for the last 7 days before expiry |
| First-login change | `chage -d 0` | The last-change date is set to the epoch, so the password counts as expired and must be changed at the next login |

An initial password (`redhat@2345`) is set by the script so the accounts are
usable; `chage -d 0` then makes that password valid for one login only.

**Order of operations.** `chpasswd` resets the last-change date to today.
Running it after `chage -d 0` would therefore cancel the forced change without
any error message. The script sets the password first and applies `chage -d 0`
last. This is the single most fragile part of the implementation and is
commented in the script.

Because the last-change date is the epoch, `chage -l` prints
`password must be changed` on the date lines rather than a calendar date. The
`60` and `7` values still display normally.

---

## Sudo Policy

`/etc/sudoers.d/devteam-admin` contains one line:

```
dev1 ALL=(ALL) ALL
```

Reading it: on any host (`ALL=`), `dev1` may run commands as any user
(`(ALL)`), and may run any command (final `ALL`).

**Why a drop-in and not `/etc/sudoers`.** The main file is included from
`/etc/sudoers.d/` by default, so a drop-in achieves the same result while
keeping the change isolated. Access can be granted or revoked by adding or
removing a single file, without ever editing the file the whole system depends
on. RH124 Chapter 10 states that this is the method the course uses.

**Why exactly one user.** Least privilege. The team needs an administrator for
package installs and service restarts, but three administrators means three
accounts whose compromise costs the whole system, and no audit trail
distinguishing who should have acted. One named administrator keeps the blast
radius small and makes `/var/log/secure` meaningful.

**Safety.** The file is created with mode `0440` and validated with
`visudo -cf` before the script exits. If validation fails the file is deleted
immediately, so a syntax error can never leave the system in a state where sudo
is broken for everyone.

---

## Shared Directory

`/shared/project`, owned by `root:devteam`, mode `3770`:

```
drwxrws--T. 2 root devteam 6 Sep 15 00:29 /shared/project
```

The octal `3770` is three decisions in one number:

| Digit | Meaning |
|---|---|
| `2` | SGID — new files and directories inherit the `devteam` group |
| `1` | Sticky bit — a user can delete only files they own |
| `770` | Full access for owner and `devteam`, nothing for others |

**SGID.** Without it, a file created by `dev1` would be group-owned by `dev1`,
and `dev2` would have no group access to it. SGID overrides the creating user's
primary group with the directory's group, so everything created inside belongs
to `devteam` and the whole team can work on it. It also applies to new
subdirectories, which inherit the `s` bit themselves — visible in `dev1_work`
showing `drwxrws---`.

**Sticky bit.** Normally, write permission on a *directory* allows deleting any
file inside it, regardless of who owns the file. Since `devteam` needs write
access to create files, without the sticky bit any member could delete any
other member's work. The sticky bit restricts deletion and renaming to the
file's owner and root. `/tmp` uses the same mechanism.

The mode string shows an uppercase `T` rather than lowercase `t` because others
have no execute permission. The sticky bit is set either way; the case only
indicates whether the underlying execute bit is also present.

---

## Default Permissions

`umask 007` is appended to each user's `~/.bashrc`, so the setting survives
logout rather than lasting only for one shell session.

```
files:       666 - 007 = 660  ->  -rw-rw----
directories: 777 - 007 = 770  ->  drwxrwx---
```

The RHEL 10 default of `0022` would have produced `-rw-r--r--`: readable by
every user on the system and not writable by the group. That fails both halves
of the requirement. `007` removes all permissions from others and leaves read
and write for the group, which is what collaboration needs.

`umask` cannot *add* permissions — it only masks bits out of the 666 and 777
starting values — which is why files never come out executable by default.

---

## Verification

Full output is in `verification_output.txt`. The key results:

**Supplementary group membership**

```
$ id dev1
uid=1001(dev1) gid=1002(dev1) groups=1002(dev1),1001(devteam)
$ grep devteam /etc/group
devteam:x:1001:dev1,dev2,dev3
```

**Password policy**

```
$ sudo chage -l dev1
Last password change                                    : password must be changed
Maximum number of days between password change          : 60
Number of days of warning before password expires       : 7
```

**Sudo restricted to one user**

```
dev1$ sudo -l
User dev1 may run the following commands on localhost:
    (ALL) ALL

dev2$ sudo -l
Sorry, user dev2 may not run sudo on localhost.

dev3$ sudo -l
Sorry, user dev3 may not run sudo on localhost.
```

**SGID inheritance and umask, in one line**

```
dev1$ ls -l
-rw-rw----. 1 dev1 devteam 16 Sep 15 01:09 dev1_notes.txt
drwxrws---. 2 dev1 devteam  6 Sep 15 01:10 dev1_work
```

Group is `devteam` (SGID), permissions are `rw-rw----` (umask 007).

**Collaboration works**

```
dev2$ echo "reviewed by dev2" >> dev1_notes.txt
dev2$ cat dev1_notes.txt
created by dev1
reviewed by dev2
```

**But deletion of another user's file does not**

```
dev2$ rm dev1_notes.txt
rm: cannot remove 'dev1_notes.txt': Operation not permitted
```

**While deleting your own file does**

```
dev2$ touch dev2_notes.txt
dev2$ rm dev2_notes.txt
(succeeds)
```

**Non-members are locked out entirely**

```
$ id
uid=1000(auritro) gid=1000(auritro) groups=1000(auritro),10(wheel)
$ cd /shared/project
bash: cd: /shared/project: Permission denied
```

---

## How to Run

On a RHEL 10 system, as a user with `sudo` access:

```bash
git clone <repository-url>
cd OnboardOps
chmod +x provision.sh
sudo ./provision.sh
```

Then verify:

```bash
id dev1
sudo chage -l dev1
sudo cat /etc/sudoers.d/devteam-admin
ls -ld /shared/project
```

And test the behaviour by logging in as each user:

```bash
su - dev1          # forced password change on first login
sudo -l            # (ALL) ALL for dev1, refused for dev2 and dev3
```

To remove everything and start over:

```bash
sudo userdel -r dev1
sudo userdel -r dev2
sudo userdel -r dev3
sudo groupdel devteam
sudo rm -f /etc/sudoers.d/devteam-admin
sudo rm -rf /shared
```

---

## Evidence

| File | Contents |
|---|---|
| `provision.sh` | The provisioning script |
| `verification_output.txt` | Full command output, in nine sections, captured from the live VM |
| `commands.txt` | The commands typed directly during development and testing |


