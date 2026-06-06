Output safedeps-demo.gif

Set Shell zsh
Set FontSize 22
Set Width 1240
Set Height 600
Set Padding 26
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type "setopt interactive_comments"
Enter
Type "export PATH=/Users/soohongkim/Documents/workspace/personal/alex-extensions/safedeps/bin:$PATH"
Enter
Type "export SAFEDEPS_HOME=/tmp/safedeps-demo/home"
Enter
Type "export PROMPT='%F{cyan}❯%f '"
Enter
Type "clear"
Enter
Show

Sleep 600ms
Type "# safedeps checks every dependency your AI agent installs — OSV / CISA KEV / GHSA"
Sleep 400ms
Enter
Sleep 900ms
Type "safedeps check npm minimist@1.2.0"
Sleep 400ms
Enter
Sleep 3200ms
Type "# vulnerable → withheld before it ever installs. the patched version clears:"
Sleep 400ms
Enter
Sleep 900ms
Type "safedeps check npm minimist@1.2.6"
Sleep 400ms
Enter
Sleep 3200ms
Sleep 1800ms
