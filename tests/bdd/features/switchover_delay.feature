Feature: Switchover_delay

    Background:
        Given autovshard consul config:
            rs1:
                _default:
                    switchover_delay: 20
                    master: false
                t1:
                    master_weight: 1
                t2:
                    master_weight: 2

        And Tarantool autovshard cluster:
            rs1:
                _default:
                    automaster: true
                    router: true
                    storage: true
                    consul_session_ttl: 10
                t1: {}
                t2: {}

    Scenario: Switchover is delayed.
        When t1 is started
        And after 5 seconds have passed
        And t2 is started
        And after 5 seconds have passed
        And t1 should be RW
        And t2 should be RO
        And after 20 seconds have passed
        And t1 should be RO
        And t2 should be RW
