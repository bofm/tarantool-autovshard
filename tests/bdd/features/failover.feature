Feature: Failover

    Background:
        Given autovshard consul config:
            rs1:
                _default:
                    switchover_delay: 0
                    master: false
                t1:
                    master_weight: 13
                t2:
                    master_weight: 11
                t3:
                    master_weight: 12

        And Tarantool autovshard cluster:
            rs1:
                _default:
                    automaster: true
                    router: true
                    storage: true
                    consul_session_ttl: 10
                t1: {}
                t2: {}
                t3: {}

    Scenario: A new master is elected if the old master crashes
        When all instances in rs1 are started
        Then t1 should become RW in less than 10 seconds
        And after 1 seconds have passed
        And t2 should be RO
        And t3 should be RO
        And vshard router API should work on all instances
        # Crash master instance
        And t1 is crashed
        And t2 should be RO
        And t3 should be RO
        And t1 should be down
        #  Wait for consul_session_ttl + Cosul lock delay (15s by default) + 10 sec
        And t3 should become RW in less than 35 seconds
        And t2 should be RO
        And t1 should be down
        And t2 vshard router API should work
        And t3 vshard router API should work
        # Master with highest master_weight comes back
        And t1 is started
        Then t1 should become RW in less than 10 seconds
        And t2 should be RO
        And t3 should be RO
        And vshard router API should work on all instances



