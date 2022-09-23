#!/bin/bash
ADDRESS="0x39ce2ae8d65ceb28cd8688ea78dafdf2177fd7a574e535035ad2f2feacb9998d"
aptos move run --function-id $ADDRESS::shared_stake_pool::crank_on_new_epoch --args address:$ADDRESS
