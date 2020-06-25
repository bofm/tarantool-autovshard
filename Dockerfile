FROM debian:buster-slim

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        debian-archive-keyring \
        curl \
        gnupg \
        apt-transport-https \
        ca-certificates \
    # https://packagecloud.io/tarantool/1_10/install#manual
    && curl -s -L https://packagecloud.io/tarantool/1_10/gpgkey | apt-key add - \
    && list=/etc/apt/sources.list.d/tarantool_1_10.list \
        && echo 'deb https://packagecloud.io/tarantool/1_10/debian/ buster main' > $list \
        && echo 'deb-src https://packagecloud.io/tarantool/1_10/debian/ buster main' >> $list \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        tarantool \
        lua5.1-dev \
        luarocks \
        build-essential \
        git \
    && rm -rf /var/lib/apt/lists/*

RUN luarocks install busted 2.0.rc12-1 \
    && luarocks install luacov 0.13.0 \
    && luarocks install luacov-coveralls

RUN cd /tmp/ \
    && set -ex \
    && mkdir -p /usr/share/tarantool \
    && echo "---------- vshard --------------" \
    && git clone https://github.com/tarantool/vshard.git \
    && cd vshard \
    && git checkout -q d5faa9c \
    && mv vshard /usr/share/tarantool/vshard \
    && cd /tmp \
    && rm -rf vshard \
    && echo "---------- package.reload --------------" \
    && git clone https://github.com/moonlibs/package-reload.git \
    && cd package-reload \
    && git checkout -q 870a2e3 \
    && mv package /usr/share/tarantool/package \
    && cd /tmp \
    && rm -rf package-reload

COPY . /tmp/autovshard

RUN cd /tmp/autovshard \
    && luarocks make \
    && cd /tmp \
    && rm -rf autovshard
