FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ruby ruby-dev build-essential rpm libarchive-tools zstd binutils python3 ca-certificates && gem install fpm -v 1.17.0 --no-document && rm -rf /var/lib/apt/lists/*
WORKDIR /source
