consul kv put "autovshard/mycluster/autovshard_cfg_yaml" '
---
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
                master_weight: 2000
                switchover_delay: 0
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

'
#consul kv delete "autovshard/mycluster/autovshard_cfg_yaml"
