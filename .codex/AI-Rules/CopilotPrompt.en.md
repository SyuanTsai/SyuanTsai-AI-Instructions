# GitHub Copilot Prompt Rules

- When the user asks to "provide a prompt," implementation is intended to be delegated to GitHub Copilot.
- Include complete, clear, directly actionable, repository-scoped information: the goal, relevant files or symbols, constraints, acceptance criteria, and test requirements.
- Do not assume GitHub Copilot can access other repositories, external workspaces, prior conversations, or undisclosed content.
- Reassess the currently available models for every task based on its complexity, risk, scope, required reasoning capability, and quota cost, then recommend the lowest sufficient capability that can complete it reliably with reasonable quota usage. Prefer a cost-appropriate model for routine implementation and testing; select a higher-capability model when cross-module reasoning, major architectural decisions, difficult diagnosis, or other high-risk requirements call for it. Briefly explain how the recommendation fits the task, and identify the specific challenge addressed when recommending a higher-capability model.
- If implementation involves tests or databases, write the necessary actionable requirements from those modules into the prompt; do not merely reference Codex-local paths.
