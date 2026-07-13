# GitHub Copilot Prompt Rules

- When the user asks to "provide a prompt," implementation is intended to be delegated to GitHub Copilot.
- Include complete, clear, directly actionable, repository-scoped information: the goal, relevant files or symbols, constraints, acceptance criteria, and test requirements.
- Do not assume GitHub Copilot can access other repositories, external workspaces, prior conversations, or undisclosed content.
- Recommend a suitable model for the change and briefly explain why.
- If implementation involves tests or databases, write the necessary actionable requirements from those modules into the prompt; do not merely reference Codex-local paths.
