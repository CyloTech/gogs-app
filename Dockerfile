FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/git

ARG GOGS_VERSION=0.14.2

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl gosu git openssh-client python3 sqlite3 && \
    rm -rf /var/lib/apt/lists/*

# Ubuntu 24.04 ships with user "ubuntu" at UID 1000. Rename to "git"
# so the home directory and process ownership read naturally in logs.
RUN usermod -l git -d /home/git -m ubuntu && \
    usermod --shell /usr/sbin/nologin --home /home/git git && \
    groupmod -n git ubuntu

# TARGETARCH is set automatically by Docker (amd64, arm64, etc.).
ARG TARGETARCH
RUN cd /home/git && \
    curl -fsSL "https://github.com/gogs/gogs/releases/download/v${GOGS_VERSION}/gogs_v${GOGS_VERSION}_linux_${TARGETARCH}.tar.gz" | tar xz && \
    chown -R 1000:1000 /home/git

ADD entrypoint.sh /entrypoint.sh
ADD moduser.sh /moduser.sh
RUN chmod +x /entrypoint.sh /moduser.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/home/git/gogs/gogs", "web"]

EXPOSE 3000 10022
