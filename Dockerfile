FROM tarantool/tarantool:1.10.3

RUN apk add -U --no-cache build-base cmake git bash lua5.1-dev

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
