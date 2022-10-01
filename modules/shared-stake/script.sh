#!/bin/bash
ADDRESS="0xcadbcff493ec6dcae1e0ef978e22f19201b20ed269da1e8070534f3f6ed604b3"
aptos move run --assume-yes --function-id $ADDRESS::shared_stake_pool::crank_on_new_epoch --args address:$ADDRESS
