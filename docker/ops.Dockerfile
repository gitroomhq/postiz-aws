# Migration toolbox for the ops ECS task: PostgreSQL 16 client tools (same
# major as Railway and RDS), python3 for es-copy-index.py, and scripts/.
# Build context: this repository.
FROM postgres:16-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 ca-certificates curl jq less procps \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/ /opt/postiz/
RUN chmod +x /opt/postiz/*
ENV PATH=/opt/postiz:$PATH

WORKDIR /work
CMD ["sleep", "86400"]
