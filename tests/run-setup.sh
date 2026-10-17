#!/usr/bin/env bash
# Runs playbooks/setup.yml against a throwaway Ubuntu container and checks the result.
# Usage: tests/run-setup.sh   (needs Docker; the container is removed at the end)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'docker rm -f -v infra-target >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

ssh-keygen -q -t ed25519 -N '' -f "$work/id_test"
cp "$work/id_test.pub" "$here/target/id_test.pub"
docker build -q -t infra-target "$here/target" >/dev/null
rm "$here/target/id_test.pub"

docker rm -f infra-target >/dev/null 2>&1 || true
# Docker inside the target needs its data on a real volume: overlayfs can't sit on top of overlayfs
docker run -d --name infra-target --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v /var/lib/docker -v /var/lib/containerd \
  -p 2222:22 infra-target >/dev/null
for _ in $(seq 1 30); do ssh-keyscan -p 2222 127.0.0.1 >/dev/null 2>&1 && break; sleep 1; done

cat > "$work/hosts.yml" <<YAML
all:
  hosts:
    target:
      ansible_host: 127.0.0.1
      ansible_port: 2222
      ansible_user: root
      ansible_ssh_private_key_file: $work/id_test
      ansible_ssh_common_args: -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      deploy_user: deploy
      deploy_ssh_public_key: "$(cat "$work/id_test.pub")"
      swap_size_mb: 0
YAML

cd "$here/../ansible"
ansible-playbook -i "$work/hosts.yml" playbooks/setup.yml

echo "--- second run must change nothing"
ansible-playbook -i "$work/hosts.yml" playbooks/setup.yml | tee "$work/second.log"
grep -q 'changed=0' "$work/second.log"

ssh_as() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "$work/id_test" -p 2222 "$1@127.0.0.1" "${@:2}"
}

echo "--- checks"
ssh_as deploy 'sudo -n true' && echo "deploy user can sudo"
if ssh_as root true 2>/dev/null; then echo "FAIL: root can still log in"; exit 1; else echo "root login refused"; fi
ssh_as deploy 'sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin) "'
ssh_as deploy 'sudo ufw status | head -6'
ssh_as deploy 'systemctl is-active fail2ban docker'
ssh_as deploy 'docker run --rm hello-world | grep -m1 "Hello from Docker"'
echo "ALL CHECKS PASSED"
