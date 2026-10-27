# Separate, retained toolchain. This is NOT part of the Redmine image build.
ARG REDMINE_IMAGE=redmine:7.0.1@sha256:6129b73568e19901222eb3947b87ac18bc63280dc3478492b28f32d989262dc1
FROM ${REDMINE_IMAGE}
USER root
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      build-essential binutils file pkg-config xz-utils \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/bin/sh"]
