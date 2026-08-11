# Credential handling

Do not commit any of the following:

- Buildkite cluster agent-registration tokens (`bkct_...`)
- Buildkite API tokens
- SSH private keys or generated `known_hosts` files
- Hugging Face tokens or model-access credentials
- cloud-provider credentials

Provide the Buildkite agent token to the installer using one of these methods:

```bash
sudo BUILDKITE_AGENT_TOKEN_FILE=/secure/path/agent-token \
  ./buildkite/install-coordinator-agent.sh
```

or:

```bash
sudo ./buildkite/install-coordinator-agent.sh < /secure/path/agent-token
```

The token file should be root-owned and mode `0600`. Rotate the token through
Buildkite if it is ever pasted into a ticket, chat, terminal transcript, or
other durable record.
