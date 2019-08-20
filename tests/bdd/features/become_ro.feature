Feature: Fencing. If Consul is unavailable, Tarantool instances should become RO.

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
        And Tarantool autovshard cluster:
            rs1:
                _default:
                    automaster: true
                    router: true
                    storage: true
                t1: {}
                t2: {}
                t3: {}

    Scenario: Become RO if Consul is unavailable.
        When all instances in rs1 are started
        And after 5 seconds have passed
        And t1 should be RO
        And t2 should be RW
        And t3 should be RO
        And vshard router API should work on all instances
        And consul becomes unreachable
        Then t1 should become RO in less than 2 seconds
        Then t2 should become RO in less than 2 seconds
        Then t3 should become RO in less than 2 seconds
