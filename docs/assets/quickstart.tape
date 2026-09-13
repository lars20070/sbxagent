# VHS tape for the sbxagent quickstart demo.
#
# Regenerate the GIF from the repo root:
#
#   brew install vhs
#   PATH="/tmp:$PATH" vhs docs/assets/quickstart.tape
#

Output docs/assets/quickstart.gif

Set Shell "bash"
Set FontSize 16
Set Width 1000
Set Height 640
Set Padding 16
Set Theme "iTerm2 Default"
Set TypingSpeed 45ms
Set PlaybackSpeed 1.0

# Start from a clean scratch directory so the demo is reproducible.
Hide
Type "cd $(mktemp -d) && clear"  Enter
Show

Type "sbx login" Sleep 400ms  Enter  Sleep 3s
Type "ln -s /Users/lars/Code/sbxagent/scripts/sbxagent ~/.local/bin/sbxcodex" Sleep 400ms  Enter  Sleep 2000ms
Type "sbxcodex version"  Sleep 400ms  Enter  Sleep 2000ms
Type "sbx secret set openai --oauth" Sleep 400ms  Enter  Sleep 2000ms
Type "N" Sleep 400ms  Enter  Sleep 900ms

Type "sbxcodex"  Sleep 400ms  Enter
Sleep 6s                                   # Show the first lines of progress
Hide
Wait+Screen@180s /Created sandbox/         # Pause recording until it finishes
Show
Sleep 2s                                   # Let the result sit on screen

Sleep 400ms  Enter
Sleep 6s
Type "What is the capital of France?" Sleep 400ms  Enter
Sleep 10s
