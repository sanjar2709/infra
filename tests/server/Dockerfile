# A stand-in for a fresh VPS: Ubuntu 24.04 with systemd and SSH, root login by key only
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd systemd-sysv openssh-server python3 sudo iptables kmod \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /root/.ssh && chmod 700 /root/.ssh

COPY id_test.pub /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys && systemctl enable ssh

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
