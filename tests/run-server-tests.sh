#!/usr/bin/env bash
# Runs playbooks/setup.yml and playbooks/deploy.yml against a throwaway Ubuntu container
# and checks the result. Usage: tests/run-server-tests.sh   (needs Docker; everything is removed at the end)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'docker rm -f -v infra-test-server >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

ssh-keygen -q -t ed25519 -N '' -f "$work/id_test"
ssh-keygen -q -t ed25519 -N '' -f "$work/id_ci"
cp "$work/id_test.pub" "$here/server/id_test.pub"
docker build -q -t infra-test-server "$here/server" >/dev/null
rm "$here/server/id_test.pub"

docker rm -f infra-test-server >/dev/null 2>&1 || true
# Docker inside the target needs its data on a real volume: overlayfs can't sit on top of overlayfs
docker run -d --name infra-test-server --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v /var/lib/docker -v /var/lib/containerd \
  -p 2222:22 infra-test-server >/dev/null
# node-exporter mounts / with rslave; a real server has / shared already, a container doesn't
docker exec infra-test-server mount --make-rshared /
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
      deploy_ci_ssh_public_key: "$(cat "$work/id_ci.pub")"
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
ssh_ci() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "$work/id_ci" -p 2222 deploy@127.0.0.1 "$@"
}

echo "--- checks"
ssh_as deploy 'sudo -n true' && echo "deploy user can sudo"
if ssh_as root true 2>/dev/null; then echo "FAIL: root can still log in"; exit 1; else echo "root login refused"; fi
ssh_as deploy 'sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin) "'
ssh_as deploy 'sudo ufw status | head -6'
ssh_as deploy 'systemctl is-active fail2ban docker'
ssh_as deploy 'docker run --rm hello-world | grep -m1 "Hello from Docker"'
echo "--- deploy: the real proxy stack plus a tiny test app"
mkdir -p "$work/stacks/proxy" "$work/stacks/apps/whoami"
cp "$here/../proxy/compose.yml" "$work/stacks/proxy/"
cp -r "$here/../monitoring" "$work/stacks/"
cat > "$work/stacks/apps/whoami/compose.yml" <<'YAML'
name: whoami
services:
  whoami:
    image: traefik/whoami:v1.11
    networks: [proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.whoami.rule=Host(`whoami.${DOMAIN}`)
      - traefik.http.routers.whoami.tls=false
networks:
  proxy:
    external: true
YAML
# An app with a database, for the backup checks; pgvector like docs-assistant, so extensions are covered too
mkdir -p "$work/stacks/apps/notes"
cat > "$work/stacks/apps/notes/compose.yml" <<'YAML'
name: notes
services:
  db:
    image: pgvector/pgvector:pg17
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
  web:
    image: traefik/whoami:v1.11
YAML
cat >> "$work/hosts.yml" <<YAML
      stacks_source_dir: $work/stacks
      stacks_domain: test.local
      stacks_apps: [whoami, notes]
      stacks_env:
        whoami:
          GREETING: hello
        notes:
          DB_NAME: notes
          DB_USER: notes
          DB_PASSWORD: notes-pass
      stacks_monitoring: true
      stacks_grafana_password: test-pass
      stacks_alert_bot_token: "123:fake"
      stacks_alert_chat_id: 42
YAML
sed -i 's/ansible_user: root/ansible_user: deploy/' "$work/hosts.yml"
ansible-playbook -i "$work/hosts.yml" playbooks/deploy.yml

ssh_as deploy 'docker ps --format "{{.Names}}" | sort'
ssh_as deploy 'cat /opt/stacks/apps/whoami/.env; stat -c "%a %U" /opt/stacks/apps/whoami/.env'
# Port 80 redirects to HTTPS, which proves Traefik is routing; follow it with a self-signed cert
ssh_as deploy 'curl -sk --resolve whoami.test.local:443:127.0.0.1 https://whoami.test.local/ | grep -m1 Hostname'
ssh_as deploy 'deploy-app whoami | tail -2'
if ssh_as deploy 'deploy-app "../../etc"' 2>/dev/null; then echo "FAIL: deploy-app accepted a path"; exit 1; else echo "deploy-app rejects bad names"; fi
ssh_ci deploy-app whoami | tail -1
# shellcheck disable=SC2016  # the $(id) must reach the server unexpanded
for command in 'id' 'deploy-app whoami; id' 'deploy-app whoami latest extra' 'deploy-app whoami $(id)'; do
  if ssh_ci "$command" 2>/dev/null | grep -q uid=; then echo "FAIL: CI key ran: $command"; exit 1; fi
done
answer="$(ssh_ci 'id' 2>&1 || true)"
grep -q 'can only run' <<< "$answer" && echo "CI key is limited to deploy-app"

echo "--- monitoring"
ssh_as deploy 'grep chat_id /opt/stacks/monitoring/alertmanager/alertmanager.yml'
for _ in $(seq 1 30); do
  ssh_as deploy 'docker exec monitoring-prometheus-1 wget -qO- localhost:9090/api/v1/targets' > "$work/targets.json" 2>/dev/null \
    && [ "$(grep -o '"health":"up"' "$work/targets.json" | wc -l)" -ge 4 ] && break
  sleep 5
done
grep -o '"job":"[a-z]*"' "$work/targets.json" | sort -u
[ "$(grep -o '"health":"up"' "$work/targets.json" | wc -l)" -ge 4 ] && echo "all Prometheus targets are up"
ssh_as deploy 'curl -sk -u admin:test-pass --resolve grafana.test.local:443:127.0.0.1 https://grafana.test.local/api/search' \
  | grep -o '"title":"[A-Za-z]*"'

echo "--- backups"
ssh_as deploy 'systemctl is-enabled backup-db.timer; systemctl list-timers backup-db.timer --no-pager | head -2'
psql_notes() { ssh_as deploy "cd /opt/stacks/apps/notes && docker compose exec -T db psql -U notes -tAc \"$1\""; }
for _ in $(seq 1 30); do psql_notes 'select 1' >/dev/null 2>&1 && break; sleep 2; done
psql_notes 'create extension vector; create table note (id serial primary key, body text, embedding vector(3))'
psql_notes "insert into note (body, embedding) values ('keep me', '[1,2,3]')"
ssh_as deploy 'sudo systemctl start backup-db.service && sudo journalctl -u backup-db.service -o cat --no-pager | tail -1'
ssh_as deploy 'sudo ls /var/backups/postgres/notes; cat /var/lib/node_exporter/backup-notes.prom'
psql_notes 'drop table note'
ssh_as deploy 'sudo restore-db notes'
[ "$(psql_notes 'select body from note')" = "keep me" ] && echo "restored row is back"
ssh_as deploy 'cd /opt/stacks/apps/notes && docker compose ps --format "{{.Service}} {{.State}}"'
for _ in $(seq 1 12); do
  ssh_as deploy 'docker exec monitoring-prometheus-1 wget -qO- "localhost:9090/api/v1/query?query=backup_last_success_timestamp_seconds"' \
    | grep -q '"app":"notes"' && echo "Prometheus sees the backup time" && break
  sleep 5
done

echo "ALL CHECKS PASSED"
