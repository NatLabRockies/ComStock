# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# This Dockerfile is designed for running BuildStockBatch and ComStock processing
# in integrated test situations. It provides the necessary environment for:
# - OpenStudio operations
# - Python-based BuildStockBatch execution
# - GHEDesigner and PySAM functionality
# - Custom gem support for ComStock workflows


# OpenStudio base image (https://hub.docker.com/r/nrel/openstudio/tags)
FROM nrel/openstudio:3.11.0 as os-base

LABEL maintainer="Henry (Ry) Horsey henry.horsey@nrel.gov"

# Copy the Gemfile from the ComStock Repo into the container
# COPY /resources/Gemfile /var/oscli/

# Install NREL root certs
RUN curl -fsSLk -o /usr/local/share/ca-certificates/nrel_root.crt https://raw.github.nrel.gov/TADA/nrel-certs/v20180329/certs/nrel_root.pem && \
  curl -fsSLk -o /usr/local/share/ca-certificates/nrel_xca1.crt https://raw.github.nrel.gov/TADA/nrel-certs/v20180329/certs/nrel_xca1.pem && \
  update-ca-certificates

# Install custom gems
# ENV BUNDLE_WITHOUT=
# RUN bundle config set git.allow_insecure true \
#     && bundle config set path /var/oscli/gems/ \
#     && bundle config set without 'test' \
#     && bundle install --gemfile /var/oscli/Gemfile \
#     && openstudio --verbose --bundle /var/oscli/Gemfile --bundle_path /var/oscli/gems --bundle_without test  gem_list \
#     && bundle config

# Remove blobs from gems installed through git
RUN rm -rf /var/oscli/gems/ruby/3.2.0/bundler/gems/**/.git \
    /var/oscli/gems/ruby/3.2.0/bundler/gems/**/test \
    /var/oscli/gems/ruby/3.2.0/cache/bundler

# Create a slimmer container without development libraries leftover by OpenStudio
# Must match the glibc of the nrel/openstudio:3.11.0 base (Ubuntu 24.04, glibc 2.39).
FROM ubuntu:24.04 AS os-comstock

ARG OPENSTUDIO_VERSION=3.11.0
ARG OPENSTUDIO_VERSION_EXT=""
ENV OPENSTUDIO_VERSION=3.11.0

# copy executable and energyplus from install
COPY --from=os-base /usr/local/openstudio-${OPENSTUDIO_VERSION}${OPENSTUDIO_VERSION_EXT}/ /usr/local/openstudio-${OPENSTUDIO_VERSION}${OPENSTUDIO_VERSION_EXT}/
COPY --from=os-base /var/oscli/ /var/oscli/


#Since the apportion need a huge amount of RAM, unset the limit.
RUN echo "session required pam_limits.so" >> /etc/pam.d/common-session && \
    echo "session required pam_limits.so" >> /etc/pam.d/common-session-noninteractive && \
    echo "* soft memlock unlimited" >> /etc/security/limits.conf && \
    echo "* hard memlock unlimited" >> /etc/security/limits.conf && \
    echo "* soft as unlimited" >> /etc/security/limits.conf && \
    echo "* hard as unlimited" >> /etc/security/limits.conf && \
    echo "* soft nofile 65535" >> /etc/security/limits.conf && \
    echo "* hard nofile 65535" >> /etc/security/limits.conf

ENV DEBIAN_FRONTEND=noninteractive


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
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    build-essential \
    zlib1g-dev \
    libncurses5-dev \
    libgdbm-dev \
    libnss3-dev \
    libssl-dev \
    libreadline-dev \
    libffi-dev \
    libsqlite3-dev \
    wget \
    libbz2-dev \
    libdbus-glib-1-2 \
    libglu1 \
    libpng-dev \
    libgomp1 \
    libgl-dev \
    libglib2.0-dev \
    liblzma-dev \
    tk-dev && \
    wget https://www.python.org/ftp/python/3.11.8/Python-3.11.8.tgz --no-check-certificate && \
    tar xzf Python-3.11.8.tgz && \
    cd Python-3.11.8 && \
    ./configure --enable-optimizations --with-ensurepip=install && \
    make altinstall && \
    rm -rf Python-3.11.8 && \
    rm -rf Python-3.11.8.tgz


SHELL ["/bin/bash", "-c"]
RUN apt-get update && apt-get install -y \
    gnupg2 \
    curl \
    procps \
    git \
    build-essential && \
    # Import RVM keys and install RVM
    curl -sSL https://rvm.io/mpapis.asc | gpg2 --import - && \
    curl -sSL https://rvm.io/pkuczynski.asc | gpg2 --import - && \
    curl -sSL https://get.rvm.io | bash -s stable && \
    echo 'source /etc/profile.d/rvm.sh' >> /root/.bashrc && \
    source /etc/profile.d/rvm.sh && \
    rvm install 3.2.2 && \
    rvm use 3.2.2 --default && \
    gem install bundler:2.4.10

RUN python3.11 -m pip install --upgrade pip
RUN python3.11 -m pip install "numpy<2"
RUN python3.11 -m pip install GHEDesigner==1.0
RUN python3.11 -m pip install NREL-PySAM==4.2.0
RUN python3.11 -m pip install pytest==7.4.3
RUN ghedesigner --help

# link executable from /usr/local/bin
RUN ln -s /usr/local/openstudio-${OPENSTUDIO_VERSION}${OPENSTUDIO_VERSION_EXT}/bin/openstudio /usr/local/bin/openstudio
ENV LC_ALL=C

VOLUME /var/simdata/openstudio
WORKDIR /var/simdata/openstudio

# Ensure that openstudio can load the custom gems
# RUN openstudio --verbose --bundle /var/oscli/Gemfile --bundle_path /var/oscli/gems --bundle_without native_ext gem_list