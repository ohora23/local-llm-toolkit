# systemd user units (optional auto-start)

Templates to auto-start the optional support services on login. Install per-user:

```bash
# edit the browser-mcp unit if your repo isn't at ~/0_AI/local-llm, then:
cp docs/systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now llm-searxng.service llm-openwebui.service llm-browser-mcp.service
```

These assume the `open-webui` and `searxng` **docker containers already exist** (create them once;
the units just `docker start` them so systemd manages their lifecycle). Adjust the docker path
(`/snap/bin/docker` vs `/usr/bin/docker`) for your install. `%h` expands to your home directory.
