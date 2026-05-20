#!/bin/bash
# Check build and download progress - run from your Mac

echo "=== Jetson Build & Download Status ==="
expect -c '
spawn ssh -o StrictHostKeyChecking=no george@192.168.68.61
expect "password:"
send "jetson\r"
expect "$ "
send "echo \"--- Build log (last 5 lines) ---\" && tail -5 /data/george/setup.log\r"
expect "$ "
send "echo \"--- llama-bench binary ---\" && ls -lh /data/george/llama.cpp/build/bin/llama-bench 2>/dev/null || echo not built yet\r"
expect "$ "
send "echo \"--- Qwen download ---\" && ls -lh /data/george/models/ 2>/dev/null\r"
expect "$ "
send "echo \"--- Processes ---\" && ps aux | grep -E \"make|wget|llama\" | grep -v grep\r"
expect "$ "
send "exit\r"
interact
' 2>&1 | grep -v "^\]0;" | grep -v "password:" | grep -v "^spawn" | grep -v "Welcome\|Ubuntu\|Documentation\|Management\|Support\|system has\|restore\|Expanded\|updates\|standard\|To see\|Learn more\|Last login\|not required"
