Feature: Config application

    Background:
        Given autovshard consul config:
            rs1:
                t1:
                    switchover_delay: 0
                    master_weight: 10
                    master: true
                t2:
                    switchover_delay: 0
                    master_weight: 5
                    master: false

        And Tarantool autovshard cluster:
            rs1:
                _default:
                    automaster: false
                    router: true
                    storage: true
                t1: {}
                t2: {}


    Scenario: Config is applied automatically
        When all instances in rs1 are started
        Then t1 should become RW in less than 5 seconds
        And t2 should become RO in less than 2 seconds
        And vshard router API should work on all instances
        And autovshard consul config is changed:
            rs1:
                t1:
                    switchover_delay: 0
                    master_weight: 10
                    master: false
                t2:
                    switchover_delay: 0
                    master_weight: 5
                    master: true
        Then t2 should become RW in less than 5 seconds
        Then t1 should become RO in less than 2 seconds
        And vshard router API should work on all instances


