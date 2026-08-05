---
name: write-copilot-implementation-prompt
description: Produce a self-contained, repository-scoped implementation prompt for GitHub Copilot and recommend the lowest sufficient available model. Use when the user asks for a prompt that Copilot will use to implement, fix, refactor, or test a change.
---

# Write a GitHub Copilot Implementation Prompt

1. Treat a request to provide a prompt as delegation of implementation to GitHub Copilot.
2. Inspect the current repository for the relevant files, symbols, conventions, and applicable rules. Do not assume Copilot can access another repository, external workspace, prior conversation, or undisclosed context.
3. Recommend the lowest-capability currently available Copilot model that can complete the task reliably with reasonable quota usage:
   - Prefer a cost-appropriate model for routine implementation and testing.
   - Select a higher-capability model for cross-module reasoning, major architecture decisions, difficult diagnosis, or other high-risk work.
   - Explain the task-specific reason briefly. Do not invent model availability; state the required capability tier if the available model list cannot be established.
4. Make the prompt directly executable and include:
   - objective and expected behavior;
   - relevant files or symbols;
   - scope and explicit exclusions;
   - implementation constraints and repository conventions;
   - acceptance criteria;
   - test requirements and exact validation expectations;
   - required completion report.
5. When testing or database rules apply, write their necessary requirements directly into the prompt. Do not merely cite local instruction paths that Copilot might not load.
6. Write in the user's requested language, defaulting to the conversation language.

Return:

````markdown
Recommended model: <model or capability tier>
Reason: <brief task-specific reason>

Prompt:
```text
<self-contained Copilot prompt>
```
````
