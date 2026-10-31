# Migration toolbox, for the ops ECS task and the temporary Railway toolbox that
# exports the data: PostgreSQL 16 client tools (same major as Railway and RDS),
# python3 for es-copy-index.py, the AWS CLI for the migration bucket, tmux so a
# long copy survives a dropped shell, and scripts/.
# Build context: this repository.
FROM postgres:16-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates curl jq less procps awscli tmux \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/ /opt/postiz/
# Linked into /usr/local/bin as well: tmux starts login shells, whose /etc/profile
# resets PATH as root and drops /opt/postiz. The scripts find their siblings
# through their own directory, so every script is linked.
RUN chmod +x /opt/postiz/* && ln -s /opt/postiz/* /usr/local/bin/
ENV PATH=/opt/postiz:$PATH
# ECS Exec sets no TERM, and tmux refuses to start without one
ENV TERM=xterm-256color

WORKDIR /work
CMD ["sleep", "86400"]
