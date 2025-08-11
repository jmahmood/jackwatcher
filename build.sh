#!/usr/bin/env bash

cross build --release --target aarch64-unknown-linux-gnu
scp ~/jackwatcher/target/aarch64-unknown-linux-gnu/release/jack-watcher root@10.0.0.159:/storage
scp ~/jackwatcher/musicctl.sh root@10.0.0.159:/storage
