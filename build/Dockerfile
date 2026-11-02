# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# OpenStudio base image (https://hub.docker.com/r/nrel/openstudio/tags)
FROM nrel/openstudio:3.10.0 as os-base

LABEL maintainer="Henry (Ry) Horsey henry.horsey@nrel.gov"

# Ensure CA tooling exists in this stage (needed for Bundler TLS verification)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      openssl \
      curl \
    && rm -rf /var/lib/apt/lists/*

# Copy the Gemfile from the ComStock Repo into the container
COPY /resources/Gemfile /var/oscli/

# Install NREL root certs (current version per nrel-certs repo)
RUN mkdir -p /usr/local/share/ca-certificates && \
  curl -fsSLk -o /usr/local/share/ca-certificates/nrel_root.crt https://raw.github.nrel.gov/TADA/nrel-certs/v20251216/certs/nrel_root.pem && \
  curl -fsSLk -o /usr/local/share/ca-certificates/nrel_xca1.crt https://raw.github.nrel.gov/TADA/nrel-certs/v20251216/certs/nrel_xca1.pem && \
  update-ca-certificates && \
  ln -sf /etc/ssl/certs/ca-certificates.crt /usr/lib/ssl/cert.pem && \
  ln -sfn /etc/ssl/certs /usr/lib/ssl/certs

# Force runtimes (Ruby/Bundler/OpenSSL/curl) to use the system trust store
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_DIR=/etc/ssl/certs
ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Install custom gems
RUN bundle config set git.allow_insecure true \
    && bundle config set path /var/oscli/gems/ \
    && bundle config set without 'test' \
    && bundle install --gemfile /var/oscli/Gemfile \
    && openstudio --verbose --bundle /var/oscli/Gemfile --bundle_path /var/oscli/gems --bundle_without test gem_list \
    && bundle config

# Remove blobs from gems installed through git
RUN rm -rf /var/oscli/gems/ruby/3.2.0/bundler/gems/**/.git \
    /var/oscli/gems/ruby/3.2.0/bundler/gems/**/test \
    /var/oscli/gems/ruby/3.2.0/cache/bundler


# Create a slimmer container without development libraries leftover by OpenStudio
# Must match the glibc of the nrel/openstudio:3.10.0 base (Ubuntu 24.04, glibc 2.39);
# an older base like 22.04 lacks GLIBC_2.38 and the copied openstudio binaries fail to load.
FROM ubuntu:24.04 AS os-comstock

ARG OPENSTUDIO_VERSION=3.10.0
ARG OPENSTUDIO_VERSION_EXT=""
ENV OPENSTUDIO_VERSION=3.10.0

# copy executable and energyplus from install
COPY --from=os-base /usr/local/openstudio-${OPENSTUDIO_VERSION}${OPENSTUDIO_VERSION_EXT}/ /usr/local/openstudio-${OPENSTUDIO_VERSION}${OPENSTUDIO_VERSION_EXT}/
COPY --from=os-base /var/oscli/ /var/oscli/

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update && apt-get install -y --no-install-recommends \
            libdbus-glib-1-2 \
            libglu1 \
            libssl-dev \
            libpng-dev \
            libgdbm-dev \
            libgomp1 \
            libgl-dev \
            libglib2.0-dev \
            wget \
            build-essential \
            curl \
            ca-certificates \
            openssl \
    && rm -rf /var/lib/apt/lists/*

# Install NREL root certs (current version per nrel-certs repo)
RUN mkdir -p /usr/local/share/ca-certificates && \
    curl -fsSLk -o /usr/local/share/ca-certificates/nrel_root.crt https://raw.github.nrel.gov/TADA/nrel-certs/v20251216/certs/nrel_root.pem && \
    curl -fsSLk -o /usr/local/share/ca-certificates/nrel_xca1.crt https://raw.github.nrel.gov/TADA/nrel-certs/v20251216/certs/nrel_xca1.pem && \
    update-ca-certificates

# Force curl/python/etc. to use the system trust store in this final image too
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_DIR=/etc/ssl/certs
ENV CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

RUN apt-get update && apt-get install -y \
    software-properties-common tzdata && \
    add-apt-repository -y ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y python3.11 python3.11-dev python3.11-distutils curl && \
    curl -sS https://bootstrap.pypa.io/get-pip.py -o get-pip.py && \
    python3.11 get-pip.py --ignore-installed && \
    rm get-pip.py

RUN apt-get update && apt-get install -y git
RUN python3.11 -m pip install --upgrade pip
RUN python3.11 -m pip install git+https://github.com/betsrg/GHEDesigner.git@0436e75834255327fbc33372d2e230c5a7a50a49
RUN python3.11 -m pip install "numpy<2"
RUN python3.11 -m pip install NREL-PySAM==4.2.0

RUN ghedesigner --help

# link executable from /usr/local/bin
RUN ln -s /usr/local/openstudio-${OPENSTUDIO_VERSION}${OPENSTUDIO_VERSION_EXT}/bin/openstudio /usr/local/bin/openstudio
ENV LC_ALL=C

VOLUME /var/simdata/openstudio
WORKDIR /var/simdata/openstudio

# Ensure that openstudio can load the custom gems
# Must exclude the same 'test' group that was skipped during `bundle install` in the os-base stage;
RUN openstudio --verbose --bundle /var/oscli/Gemfile --bundle_path /var/oscli/gems --bundle_without test gem_list
