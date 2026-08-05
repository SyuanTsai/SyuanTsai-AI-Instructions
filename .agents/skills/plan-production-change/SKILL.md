---
name: plan-production-change
description: Create implementation plans whose detail matches change scope, risk, and uncertainty, including validation and TDD sequencing. Use when asked to plan or propose an implementation approach, or before production-code changes when repository guidance requires a plan.
---

# Plan a Production Change

1. Search the relevant symbols, files, interfaces, direct references, and existing conventions before planning. Keep the investigation scoped to evidence needed for implementation and acceptance.
2. Read the repository's applicable testing and domain rules. Preserve mandatory guardrails in the plan instead of copying irrelevant rule text.
3. Match plan detail to scope, risk, and uncertainty:
   - Use the concise format for a well-understood, low-risk change within one area.
   - Use the full format for cross-area work, data migrations, security changes, public contracts, or other high-risk changes.
4. When test-first development applies, describe the Red-Green-Refactor sequence. When a repository testing exemption applies, state the reason and the closest alternative validation.
5. Write the plan in the user's language and include only information that helps implementation or acceptance.

Concise format:

```markdown
- Objective:
- Change:
- Validation:
- Risks / out of scope:
```

Full format:

```markdown
# Plan: <feature or problem>

## 1. Objective and scope
- Expected outcome:
- Deliverables:
- Out of scope:

## 2. Planned changes

### 2.1 <change item>
- Change:
- Reason:
- Impact or risk:

## 3. Test scenarios

### 3.1 <scenario>
- Related change:
- Test level:
- Given:
- When:
- Then:
- TDD: Red <failing test> → Green <minimum production change> → Refactor <cleanup while tests pass>; when exempt, give the reason and alternative validation.
```
