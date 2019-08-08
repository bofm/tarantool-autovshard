# Autovshard

A wrapper around [Vshard](https://github.com/tarantool/vshard) with automatic master election, failover and
centralized configuration storage in Consul.

[![Sponsored by Avito](https://cdn.rawgit.com/css/csso/8d1b89211ac425909f735e7d5df87ee16c2feec6/docs/avito.svg)](https://www.avito.ru/)

## Features

* Centralized config storage with [Consul](https://www.consul.io).
* Automatic Vsahrd reconfiguration (both storage and router) when the config
  changes in Consul.
* Automatic master election for each replicaset with a distributed lock with Consul.
* Automatic failover when a master instance becomes unavailable.
* Master weight to set the preferred master instance.
* Switchover delay.

## Status

It works in dev enviromnent (docker-compose). It is still WIP. Use at your own risk. No guarantees.

## Usage

1. Put Autovshard config to Consul KV under `<consul_kv_prefix>/<vshard_cluster_name>/autovshard_cfg_yaml`.
  
   ```yaml
   # autovshard_cfg.yaml
   rebalancer_max_receiving: 10
   bucket_count: 100
   rebalancer_disbalance_threshold: 10
   sharding:
       aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
           weight: 10
           replicas:
               aaaaaaaa-aaaa-aaaa-aaaa-000000000001:
                   master_weight: 99
                   switchover_delay: 10
                   address: a1:3301
                   name: a1
                   master: false
               aaaaaaaa-aaaa-aaaa-aaaa-000000000002:
                   master_weight: 20
                   switchover_delay: 10
                   address: a2:3301
                   name: a2
                   master: false
       bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb:
           weight: 10
           replicas:
               bbbbbbbb-bbbb-bbbb-bbbb-000000000001:
                   master_weight: 10
                   switchover_delay: 10
                   address: b1:3301
                   name: b1
                   master: false
               bbbbbbbb-bbbb-bbbb-bbbb-000000000002:
                   master_weight: 55
                   switchover_delay: 10
                   address: b2:3301
                   name: b2
                   master: false
   ```
   
   ```sh
   #!/usr/bin/env sh

   cat autovshard_cfg.yaml | consul kv put "autovshard/mycluster/autovshard_cfg_yaml" -
   ```

   The config is similar to Vshard config, but it has some extra fields
    and has `address` field instead of `uri` because we don't want to
    mix config with passwords.

   ### Autovshard config parameters

   * `master_weight` - an instance with higher weight in a replica set eventually gets master role. This parameter is dynamic and can be changed by administrator at any time.
   * `switchover_delay` - a delay in seconds to wait before taking master role away from another running instance with lower *master_weight*. This parameter is dynamic and can be changed by administrator at any time. A case when this parameter is useful is when an instance with the highest *master_weight* is restarted several times in a short amount of time. If the instance is up for a shorter time than the  *switchover_delay* there will be no master switch (switchover) every time the instance is restarted. And when the instance with the highest *master_weight* stays up for longer than the *switchover_delay* then the instance will finally get promoted to master role.
   * `address` - TCP address of the Tarantool instance in this format: `<host>:<port>`. It is passed through to Vshard as part of `uri` parameter.
   * `name` - same as *name* in Vshard.
   * `master` - same as *master* in Vshard. The role of the instance. **DO NOT set *master=true* for multiple instances in one replica set**. This parameter will be changed dynamically during the lifecycle of Autovshard. It can also be changed by administrator at any time. It is safe to set `master=false` for all instances.

2. Put this into your tarantool init.lua.

   ```lua

   local box_cfg = {
       listen = 3301,  -- required
       instance_uuid = "aaaaaaaa-aaaa-aaaa-aaaa-000000000001",  -- required, prefer lowercase
       replicaset_uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",  -- required, prefer lowercase
       -- ! DO NOT set `replication` parameter, Vshard will take care of it
       -- specify any other_box_cfg options
   }

   autovshard = require("autovshard").Autovshard.new{
       box_cfg = box_cfg,  -- Tarantool instance config
       cluster_name = "mycluster",  -- the name of your sharding cluster
       login = "storage",  -- login for Vshard
       password = "storage",  -- password for Vshard
       consul_http_address = "http://consul:8500",  --
       consul_token = nil,
       consul_kv_prefix = "autovshard",
       router = true,  -- true for Vshard router instance
       storage = true,  -- true for Vshard storage instance
       automaster = true,  -- enables automatic master election and auto-failover
   }

   autovshard:start()  -- autovshard will run in the background
   -- to stop it call autovshard:stop()

   -- This might be helpful
   -- box.ctl.on_shutdown(function() autovshard:stop() end)

   ```

 **Important:** If Consul is unreachable the Tarantool instance is set to **read-only** mode.

### See also

* examples
* docker-compose.yaml

## Installation

Luarocks sucks at pinning dependencies, and Vshard does not support (as of 2019-07-01) painless
installation without Tarantool sources. Therefore Vshard is not mentioned in the rockspec.

1. Install Vshard first.
2. Install Autovshard. Autovshard depends only on Vshard.

## TODO

* [] Versioning
* [] Packaging
* [] package-reload compatibility
* [] More testing
* [] Integration testing and CI
* [] Documentation
* [] Improve logging
* [] See todo's in the sources
