#!/bin/bash
# count real python3 worker processes running the given sleep seconds (argv match, not shell text)
ps -axo command | awk -v s="time.sleep($1)" '$1 ~ /python3$/ && index($0, s) > 0' | wc -l | tr -d ' '
