# VS Code launch example

This folder contains a sanitized example launch configuration you can copy into your workspace's `.vscode/launch.json`.

Do NOT commit your real `.vscode/launch.json` if it contains organization names, saved-query IDs, or other sensitive values (PATs should always be kept in environment variables).

Quick steps

1. Copy the example to your local VS Code settings:

   ```bash
   mkdir -p .vscode
   cp dev/launch/launch.json.example .vscode/launch.json
   ```

2. Open `.vscode/launch.json` and replace the placeholder values:
   - `https://dev.azure.com/<ORG>` → your Azure DevOps organization URL
   - `<PROJECT>` → your project name
   - `<SAVED_QUERY_ID>` → optional saved query id

3. Set your Personal Access Token as an environment variable (recommended):

   - macOS / Linux (zsh/bash):
     ```bash
     export TEST_PAT="<your PAT>"
     ```

   - PowerShell (Windows/macOS):
     ```powershell
     $env:TEST_PAT = '<your PAT>'
     ```

4. Run the launch configuration in VS Code (Run view) or invoke the scripts from a terminal. Keep secrets out of Git.

If you accidentally stage `.vscode/launch.json`, you can unstage it with:

```bash
git restore --staged .vscode/launch.json
# or, to remove it from the index permanently, if you already committed:
git rm --cached .vscode/launch.json
```

If you want, I can also add a pre-commit hook example that warns about adding `.vscode` files.
