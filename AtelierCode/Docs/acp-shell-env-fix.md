The current approach in LocalACPTransport.swift (line 10) is a good fix, but it’s still a PATH bootstrap, not full environment fidelity.

Current approach drawbacks

It only captures PATH. If a tool depends on GOPATH, JAVA_HOME, NVM_DIR, PNPM_HOME, HOMEBREW_PREFIX, SDKROOT, auth vars, or custom config vars, we still won’t match the user’s real terminal.
We ask the shell for PATH from HOME, not the workspace directory. That means project-scoped env managers like direnv, some mise configs, and shell hooks that depend on PWD may not activate the same way they would inside the repo.
Login/interactive shell startup is messy. .zshrc, .zprofile, .bash_profile, etc. can behave differently depending on shell flags, TTY presence, or terminal app checks, so “shell-derived PATH” may still differ from Ghostty/iTerm.
Shell startup can be slow or noisy. If a dotfile prints output, prompts for something, or does expensive work, env discovery gets brittle.
It’s dynamic and user-specific, which is great for fidelity but worse for reproducibility. Bugs can become “works on one machine, fails on another because their shell config is different.”
It snapshots once per environment build. If the user changes shell config or activates something later, the agent won’t automatically track that unless we rebuild the env.
What a more robust design adds

Capture a curated full environment, not just PATH.
Resolve it from the actual workspace directory, not just HOME.
Use a machine-readable shell probe like env -0 with tight timeout/validation instead of printf $PATH.
Cache results per workspace and refresh when needed.
Support explicit user overrides in app settings.
Optionally integrate project env tools directly, like mise, direnv, asdf, or language-specific setup.
So the short version is: the current fix solves the most visible problem well, but a more robust solution is about correctness, determinism, and project-specific env parity, not just finding go.

If you want, I can sketch a “phase 5” style design for full workspace environment resolution.
