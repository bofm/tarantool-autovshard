local yaml = require("yaml")

describe("autovshard.config", function()
    local config = require("autovshard.config")

    it("promote_to_master", function() --
        local autovshard_cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 10
                            address: a1:3301
                            name: a1
                            master: false
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 10
                            address: a2:3301
                            name: a2
                            master: false
        ]])
        local expected_new_cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 10
                            address: a1:3301
                            name: a1
                            master: true
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 10
                            address: a2:3301
                            name: a2
                            master: false
        ]])

    end)

    describe("set_instance_read_only", function() --

        it("changed", function()
            local autovshard_cfg = yaml.decode([[
                rebalancer_max_receiving: 10
                bucket_count: 100
                rebalancer_disbalance_threshold: 10
                sharding:
                    aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                        weight: 10
                        replicas:
                            aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                                master_weight: 10
                                switchover_delay: 10
                                address: a1:3301
                                name: a1
                                master: true
                            aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                                master_weight: 20
                                switchover_delay: 10
                                address: a2:3301
                                name: a2
                                master: false
            ]])
            local expected_new_cfg = yaml.decode([[
                rebalancer_max_receiving: 10
                bucket_count: 100
                rebalancer_disbalance_threshold: 10
                sharding:
                    aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                        weight: 10
                        replicas:
                            aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                                master_weight: 10
                                switchover_delay: 10
                                address: a1:3301
                                name: a1
                                master: false
                            aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                                master_weight: 20
                                switchover_delay: 10
                                address: a2:3301
                                name: a2
                                master: false
            ]])
            local changed, new_cfg = config.set_instance_read_only(autovshard_cfg,
                                                                   "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1")
            assert.are_same(expected_new_cfg, new_cfg)
            assert.is_true(changed)
        end)

        it("not changed", function()
            local autovshard_cfg = yaml.decode([[
                rebalancer_max_receiving: 10
                bucket_count: 100
                rebalancer_disbalance_threshold: 10
                sharding:
                    aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                        weight: 10
                        replicas:
                            aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                                master_weight: 10
                                switchover_delay: 10
                                address: a1:3301
                                name: a1
                                master: false
                            aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                                master_weight: 20
                                switchover_delay: 10
                                address: a2:3301
                                name: a2
                                master: false
            ]])

            local changed, new_cfg = config.set_instance_read_only(autovshard_cfg,
                                                                   "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1")
            assert.are_same(autovshard_cfg, new_cfg)
            assert.is_false(changed, new_cfg)
        end)
    end)

    it("master_count", function()
        local cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 10
                            address: a1:3301
                            name: a1
                            master: false
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 10
                            address: a2:3301
                            name: a2
                            master: false
        ]])
        assert.are.equal(0, config.master_count(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        local cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 10
                            address: a1:3301
                            name: a1
                            master: false
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 10
                            address: a2:3301
                            name: a2
                            master: true
            ]])
        assert.are.equal(1, config.master_count(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

        local cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 10
                            address: a1:3301
                            name: a1
                            master: true
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 10
                            address: a2:3301
                            name: a2
                            master: true
            ]])
        assert.are.equal(2, config.master_count(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        assert.are.equal(0, config.master_count(cfg, "0aaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))

    end)

    it("is_master", function()
        local cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 10
                            address: a1:3301
                            name: a1
                            master: true
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 10
                            address: a2:3301
                            name: a2
                            master: false
            ]])
        assert.is_true(config.is_master(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1"))
        assert.is_false(config.is_master(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2"))
        assert.is_false(config.is_master(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa99"))
    end)

    it("get_switchover_delay", function()
        local cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 11
                            address: a1:3301
                            name: a1
                            master: true
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 99
                            address: a2:3301
                            name: a2
                            master: false
            ]])
        assert.are.equal(11,
                         config.get_switchover_delay(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1"))
        assert.are.equal(99,
                         config.get_switchover_delay(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2"))
        assert.is_nil(config.get_switchover_delay(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa99"))
    end)

    it("get_master_weight", function()
        local cfg = yaml.decode([[
            rebalancer_max_receiving: 10
            bucket_count: 100
            rebalancer_disbalance_threshold: 10
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 10
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1:
                            master_weight: 10
                            switchover_delay: 11
                            address: a1:3301
                            name: a1
                            master: true
                        aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2:
                            master_weight: 20
                            switchover_delay: 99
                            address: a2:3301
                            name: a2
                            master: false
            ]])
        assert.are.equal(10, config.get_master_weight(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1"))
        assert.are.equal(20, config.get_master_weight(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2"))
        assert.are.equal(0, config.get_master_weight(cfg, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa99"))
    end)

    it("make_vshard_config", function()
        local autovshard_cfg = yaml.decode([[
            rebalancer_max_receiving: 3
            bucket_count: 4
            rebalancer_disbalance_threshold: 5
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 44
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-000000000001:
                            master_weight: 2
                            switchover_delay: 5
                            address: a1:3301
                            name: a1
                            master: false
                        aaaaaaaa-aaaa-aaaa-aaaa-000000000002:
                            master_weight: 3
                            switchover_delay: 10
                            address: a2:3301
                            name: a2
                            master: true
                bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb:
                    weight: 55
                    replicas:
                        bbbbbbbb-bbbb-bbbb-bbbb-000000000001:
                            master_weight: 6
                            switchover_delay: 20
                            address: b1:3301
                            name: b1
                            master: true
                        bbbbbbbb-bbbb-bbbb-bbbb-000000000002:
                            master_weight: 8
                            switchover_delay: 30
                            address: b2:3301
                            name: b2
                            master: false
        ]])

        local box_cfg = yaml.decode([[
            listen: 9999
            replicaset_uuid: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
            instance_uiid: aaaaaaaa-aaaa-aaaa-aaaa-000000000001
            wal_dir: /tmp
        ]])

        local login = "storage"
        local password = "secret"

        local expected_vshard_cfg = yaml.decode([[
            # box cfg
            listen: 9999
            replicaset_uuid: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
            instance_uiid: aaaaaaaa-aaaa-aaaa-aaaa-000000000001
            wal_dir: /tmp

            # vshard cfg
            rebalancer_max_receiving: 3
            rebalancer_disbalance_threshold: 5
            bucket_count: 4
            sharding:
                aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:
                    weight: 44
                    replicas:
                        aaaaaaaa-aaaa-aaaa-aaaa-000000000001:
                            name: a1
                            uri: storage:secret@a1:3301
                            master: false
                        aaaaaaaa-aaaa-aaaa-aaaa-000000000002:
                            name: a2
                            uri: storage:secret@a2:3301
                            master: true
                bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb:
                    weight: 55
                    replicas:
                        bbbbbbbb-bbbb-bbbb-bbbb-000000000001:
                            name: b1
                            uri: storage:secret@b1:3301
                            master: true
                        bbbbbbbb-bbbb-bbbb-bbbb-000000000002:
                            name: b2
                            uri: storage:secret@b2:3301
                            master: false
        ]])
        assert.are.same(expected_vshard_cfg,
                        config.make_vshard_config(autovshard_cfg, login, password, box_cfg))
    end)
end)
