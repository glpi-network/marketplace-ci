# marketplace-ci

Nightly scan of the [GLPI Marketplace](https://marketplace.glpi-network.com) catalog that downloads, installs and
activates every plugin **cumulatively**, to detect plugin-vs-plugin conflicts that break the GLPI core when many
plugins are combined. It does not re-test plugins in isolation, each already has its own CI for that.

## How it works

`scripts/run-marketplace.sh`:

1. Fetches the plugin catalog via `bin/console marketplace:search`.
2. Orders it: `config/priority-plugins.txt` first, then the rest alphabetically.
3. For each plugin: skips it if incompatible with the running GLPI version, otherwise downloads, installs and
   activates it on top of every plugin already active, then checks the core is still healthy (HTTP + error log).
   Rolls back on failure.
4. Produces `/tmp/marketplace-report.md` and `/tmp/marketplace-report.json`.

`.github/workflows/marketplace.yml` runs this nightly and on demand, and publishes the report.

## Local testing

```bash
bash scripts/run-marketplace.sh config/priority-plugins.txt
```

Run from a GLPI root directory with a registered GLPI Network key.
