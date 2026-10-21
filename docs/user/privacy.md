# Privacy

Drop Sorter and Drop Mover work entirely on your Mac.

- **No network.** Neither app connects to the internet: no accounts, no update checks, no analytics,
  no telemetry, no crash reports.
- **The only server is your own, and off by default.** The optional REST API listens on `127.0.0.1`,
  which only programs on your Mac can reach, and needs a token.
- **File names stay local.** To suggest folders, Drop Sorter reads file and folder names in your target
  folders, and compares file contents (by checksum) only to find duplicates in the target folder.
  Nothing of that leaves your Mac.
- **What is stored**, all in `~/Library/Application Support/li.sudo.dropsorter/`: your settings, the
  words learned from earlier moves (with the folders they went to), and the last operation for Undo.
  **Forget…** in Settings › Advanced clears the learned words.
- **AI agents** see only what you let them: the MCP server runs when your agent starts it, and does what
  the agent asks within your target folders.
