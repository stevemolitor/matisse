#!/bin/bash
# Wrapper script to handle Claude Code hooks
# Reads JSON from stdin and passes it to Emacs

# Read all stdin into a variable
json_data=$(cat)

# Get the hook type from command line args
hook_type="$1"

# Escape the JSON data for passing to Emacs
escaped_json=$(echo "$json_data" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

# Call the appropriate Emacs function, redirecting stderr to suppress connection messages
if [ "$hook_type" = "pretooluse" ]; then
    result=$(emacsclient --eval "(matisse-handle-pretooluse-hook \"$escaped_json\")" 2>/dev/null)
elif [ "$hook_type" = "posttooluse" ]; then
    result=$(emacsclient --eval "(matisse-handle-posttooluse-hook \"$escaped_json\")" 2>/dev/null)
else
    echo '{"error": "Unknown hook type"}'
    exit 1
fi

# Output the result without extra quotes
echo "$result" | sed 's/^"//;s/"$//' | sed 's/\\"/"/g'