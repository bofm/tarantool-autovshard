Feature: Master election

    Background:
        Given autovshard consul config:
            rs1:
                _default:
                    switchover_delay: 0
                    master: false
                t1:
                    master_weight: 1
                t2:
                    master_weight: 2
                t3:
                    master_weight: 1
                    master: true

    Scenario: Master is elected accorting to master_weigh after replicaset is started
        Given Tarantool autovshard cluster:
            rs1:
                _default:
                    automaster: true
                    router: true
                    storage: true
                t1: {}
                t2: {}
                t3: {}
        When all instances in rs1 are started
        Then t2 should become RW in less than 10 seconds
        And after 1 seconds have passed
        And t1 should be RO
        And t3 should be RO
        And vshard router API should work on all instances

    Scenario: Master is elected after master_weight is changed in Consul
        Given Tarantool autovshard cluster:
            rs1:
                _default:
                    automaster: true
                    router: true
                    storage: true
                t1: {}
                t2: {}
                t3: {}
        When all instances in rs1 are started
        Then t2 should become RW in less than 10 seconds
        And after 1 seconds have passed
        And t1 should be RO
        And t3 should be RO
        And vshard router API should work on all instances
        And autovshard consul config is changed:
            rs1:
                _default:
                    switchover_delay: 0
                    master: false
                t1:
                    master_weight: 1
                t2:
                    master_weight: 1
                    master: true
                t3:
                    master_weight: 2
        Then after 3 seconds have passed
        And t1 should be RO
        And t2 should be RO
        And t3 should be RW
        And vshard router API should work on all instances

    Scenario: Master should not be elected if automaster is false
         Given Tarantool autovshard cluster:
            rs1:
                _default:
                    automaster: false
                    router: true
                    storage: true
                t1: {}
                t2: {}
                t3: {}
        When all instances in rs1 are started
        Then after 5 seconds have passed
        And t1 should be RO
        # t2 has the highest weight
        And t2 should be RO
        And t3 should be RW
        And vshard router API should work on all instances
